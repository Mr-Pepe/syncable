import 'dart:async';

import 'package:collection/collection.dart';
import 'package:drift/drift.dart';
import 'package:logging/logging.dart';
import 'package:supabase/supabase.dart';
import 'package:syncable/src/supabase_names.dart';
import 'package:syncable/src/sync_timestamp_storage.dart';
import 'package:syncable/src/syncable.dart';
import 'package:syncable/src/syncable_database.dart';
import 'package:syncable/src/syncable_table.dart';

class SyncManager<T extends SyncableDatabase> {
  SyncManager({
    required T localDatabase,
    required SupabaseClient supabaseClient,
    SyncTimestampStorage? syncTimestampStorage,
    Duration syncInterval = const Duration(seconds: 1),
    Duration otherDevicesConsideredInactiveAfter = const Duration(minutes: 2),
  })  : _localDb = localDatabase,
        _supabaseClient = supabaseClient,
        _syncInterval = syncInterval,
        _syncTimestampStorage = syncTimestampStorage,
        _devicesConsideredInactiveAfter = otherDevicesConsideredInactiveAfter,
        assert(
          syncInterval.inMilliseconds > 0,
          'Sync interval must be positive',
        ) {
    _setUpLogger();
  }

  final _logger = Logger('syncable');

  final T _localDb;
  final SupabaseClient _supabaseClient;
  final SyncTimestampStorage? _syncTimestampStorage;
  final Duration _syncInterval;
  final Duration _devicesConsideredInactiveAfter;

  /// This is what gets set when [enableSync] gets called. Internally, whether
  /// the syncing is enabled or not is determined by [_syncingEnabled].
  bool __syncingEnabled = false;
  bool get syncingEnabled => __syncingEnabled;
  bool get _syncingEnabled =>
      __syncingEnabled && !_disposed && userId.isNotEmpty;

  void enableSync() {
    if (__syncingEnabled == true) return;

    if (_syncables.isEmpty) {
      throw Exception(
        'Failed to enable syncing because there are no registered syncables. '
        'Please register at least one syncable before enabling syncing.',
      );
    }

    __syncingEnabled = true;
    _startLoop();
    _onDependenciesChanged('syncing enabled');
  }

  void disableSync() {
    if (__syncingEnabled == false) return;
    __syncingEnabled = false;
    _onDependenciesChanged('syncing disabled');
  }

  String _userId = '';
  String get userId => _userId;

  void setUserId(String value) {
    if (_userId == value) return;
    _userId = value;
    _onDependenciesChanged("userId set to '$value'");
  }

  DateTime? _lastTimeOtherDeviceWasActive;
  DateTime? get lastTimeOtherDeviceWasActive => _lastTimeOtherDeviceWasActive;

  void setLastTimeOtherDeviceWasActive(DateTime? value) {
    if (_lastTimeOtherDeviceWasActive == value) return;
    _lastTimeOtherDeviceWasActive = value;
    _onDependenciesChanged('lastTimeOtherDeviceWasActive set to $value');
  }

  bool get isSyncingFromBackend =>
      _inQueues.values.any((queue) => queue.isNotEmpty);
  bool get isSyncingToBackend =>
      _outQueues.values.any((queue) => queue.isNotEmpty);

  bool _disposed = false;
  bool _loopRunning = false;

  final _syncables = <Type>[];
  List<Type> get syncables => _syncables;

  final Map<Type, TableInfo<SyncableTable, Syncable>> _localTables = {};
  final Map<Type, String> _backendTables = {};

  final Map<Type, Syncable Function(Map<String, dynamic>)> _fromJsons = {};
  final Map<Type, CompanionConstructor> _companions = {};

  final Map<Type, Set<Syncable>> _inQueues = {};
  final Map<Type, Map<String, Syncable>> _outQueues = {};

  final Map<Type, Set<Syncable>> _sentItems = {};
  final Map<Type, Set<Syncable>> _receivedItems = {};

  final Map<Type, StreamSubscription<List<Syncable>>> _localSubscriptions = {};

  RealtimeChannel? _backendSubscription;
  bool get isSubscribedToBackend => _backendSubscription != null;

  final Map<Type, int> _nSyncedToBackend = {};
  int nSyncedToBackend(Type T) => _nSyncedToBackend[T] ??= 0;

  final Map<Type, int> _nSyncedFromBackend = {};
  int nSyncedFromBackend(Type T) => _nSyncedFromBackend[T] ??= 0;

  int _nFullSyncs = 0;
  int get nFullSyncs => _nFullSyncs;

  void dispose() {
    _disposed = true;
    for (final subscription in _localSubscriptions.values) {
      subscription.cancel();
    }
    _backendSubscription?.unsubscribe();
  }

  void registerSyncable<S extends Syncable>({
    required String backendTable,
    required Syncable Function(Map<String, dynamic>) fromJson,
    required CompanionConstructor companionConstructor,
  }) {
    if (S == Syncable) {
      throw Exception(
        'Please provide the concrete type of your syncable class as a generic '
        'parameter. For example: `registerSyncable<MySyncable>(...)`',
      );
    }

    if (_loopRunning) {
      throw Exception(
        'Cannot register syncables after the sync manager was started',
      );
    }

    if (_syncables.contains(S)) return;

    _syncables.add(S);
    _localTables[S] = _localDb.getTable<S>();
    _backendTables[S] = backendTable;
    _fromJsons[S] = fromJson;
    _companions[S] = companionConstructor;
    _inQueues[S] = {};
    _outQueues[S] = {};
    _sentItems[S] = {};
    _receivedItems[S] = {};
  }

  Future<void> _startLoop() async {
    _loopRunning = true;
    _logger.info('Sync loop started');

    while (!_disposed) {
      try {
        for (final syncable in _syncables) {
          if (_disposed) break;
          await _processOutgoing(syncable);
        }
      } catch (e, s) {
        // coverage:ignore-start
        _logger.severe('Error processing outgoing: $e\n$s');
        // coverage:ignore-end
      }

      try {
        for (final syncable in _syncables) {
          if (_disposed) break;
          await _processIncoming(syncable);
        }
      } catch (e, s) {
        // coverage:ignore-start
        _logger.severe('Error processing incoming: $e\n$s');
        // coverage:ignore-end
      }

      if (_disposed) break;
      await Future.delayed(_syncInterval);
    }

    _loopRunning = false;
    _logger.info('Sync loop stopped');
  }

  /// Goes through the local tables for all registered syncables and sets the
  /// user ID to the currently set [userId] for all entries that don't have
  /// a user ID yet.
  ///
  /// This is useful if you support anonymous usage of your app. You can leave
  /// the user ID until the user registers or logs in. Afterwards, you can call
  /// this method to set the user ID and sync the data to the backend (requires
  /// syncing to be enabled via [enableSync]).
  Future<void> fillMissingUserIdForLocalTables() async {
    if (userId.isEmpty) {
      _logger.warning('Not setting user ID for local tables because user ID is '
          'empty');
      return;
    }

    final tables = _syncables.map((s) => _localTables[s]!).toList();
    final companions = List<UpdateCompanion<Syncable>>.from(
      _syncables.map((s) => _companions[s]!(userId: Value(userId))),
    );

    await _localDb.transaction(() async {
      for (int i = 0; i < tables.length; i++) {
        await (_localDb.update(tables[i])..where((row) => row.userId.isNull()))
            .write(companions[i]);
      }
    });
  }

  Future _onDependenciesChanged(String reason) async {
    _maybeSubscribeToLocalChanges();
    _maybeSubscribeToBackendChanges();

    await _syncTables(reason);
  }

  void _maybeSubscribeToLocalChanges() {
    _clearLocalSubscriptions();

    if (userId.isEmpty) {
      _logger
          .warning('Not subscribed to local changes because user ID is empty');
      return;
    }

    if (!_syncingEnabled) {
      _logger.warning('Not subscribed to local changes because syncing is '
          'disabled');
      return;
    }

    for (final syncable in _syncables) {
      _localSubscriptions[syncable] = _localDb.subscribe(
        table: _localTables[syncable]!,
        filter: (SyncableTable row) => row.userId.equals(_userId),
        onChange: (rows) {
          if (_syncingEnabled) {
            _pushLocalChangesToOutQueue(syncable, rows.cast());
          }
        },
      );
    }

    _logger.info('Subscribed to local changes');
  }

  void _pushLocalChangesToOutQueue(
    Type syncable,
    Iterable<Syncable> rows,
  ) {
    final outQueue = _outQueues[syncable]!;

    bool updateHasNotBeenSentYet(Syncable row) =>
        row.updatedAt.isAfter(outQueue[row.id]?.updatedAt ?? DateTime(0)) &&
        row.updatedAt.isAfter(_lastPushedTimestamp(syncable) ?? DateTime(0));

    for (final row in rows
        .where((r) => !_receivedItems[syncable]!.contains(r))
        .where(updateHasNotBeenSentYet)) {
      outQueue[row.id] = row;
    }
  }

  void _maybeSubscribeToBackendChanges() {
    if (!_syncingEnabled || !_otherDevicesActive()) {
      if (_backendSubscription != null) {
        _backendSubscription?.unsubscribe();
        _backendSubscription = null;
      }

      _logger.warning('Not subscribed to backend changes. '
          'syncingEnabled=$__syncingEnabled '
          'userId=$_userId '
          'otherDevicesActive=${_otherDevicesActive()}');

      return;
    }

    if (_backendSubscription != null) {
      return;
    }

    _backendSubscription = _supabaseClient.channel('backend_changes');

    for (final syncable in _syncables) {
      _backendSubscription?.onPostgresChanges(
        schema: publicSchema,
        table: _backendTables[syncable],
        event: PostgresChangeEvent.all,
        callback: (p) {
          if (_disposed) return;
          if (p.newRecord.isNotEmpty) {
            final item = _fromJsons[syncable]!(p.newRecord);
            _inQueues[syncable]!.add(item);
          }
        },
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: userIdKey,
          value: _userId,
        ),
      );
    }

    _backendSubscription?.subscribe(
      (status, error) {
        if (error != null) {
          // coverage:ignore-start
          _logger.severe('Backend subscription error: $error');
          // coverage:ignore-end
        }
      },
    );

    _logger.info('Subscribed to backend changes');
  }

  /// Syncs all tables registered with the sync manager.
  ///
  /// This method is called automatically when the sync manager is started,
  /// or when dependencies change (e.g. user ID, last active time of other
  /// devices, ...).
  ///
  /// It can also be called manually to force a sync.
  Future<void> syncTables() async {
    await _syncTables('Manual sync');
  }

  Future<void> _syncTables(String reason) async {
    if (userId.isEmpty) {
      _logger.warning('Tables not getting synced because user ID is empty');
      return;
    }

    if (!__syncingEnabled) {
      _logger.warning('Tables not getting synced because syncing is disabled');
      return;
    }

    _logger.info('Syncing all tables. Reason: $reason');

    for (final syncable in _syncables) {
      await _syncTable(syncable);
    }

    _nFullSyncs++;
  }

  Future<void> _syncTable(Type syncable) async {
    if (!_syncingEnabled) return;

    final localItems = await _localDb.select(_localTables[syncable]!).get();

    // Check after async gap
    if (!_syncingEnabled) return;

    assert(_userId.isNotEmpty);
    _pushLocalChangesToOutQueue(
      syncable,
      localItems.where((i) => i.userId == _userId),
    );

    if (_skipSyncFromBackend(syncable)) {
      _logger.info(
        'Skipping sync of table ${_backendTables[syncable]} from backend '
        'because no other device was active since last sync',
      );
      return;
    }

    final localItemsUpdatedAt = {for (final i in localItems) i.id: i.updatedAt};

    assert(_userId.isNotEmpty);
    final backendItems = await _supabaseClient
        .from(_backendTables[syncable]!)
        .select('$idKey,$updatedAtKey')
        .eq(userIdKey, _userId);

    final itemsToPull =
        _getItemsToPullFromBackend(backendItems, localItemsUpdatedAt);

    if (itemsToPull.isNotEmpty) {
      _logger.info(
        "Syncing ${itemsToPull.length} items from backend table '${_backendTables[syncable]}'",
      );
    }

    for (final batch in itemsToPull.slices(100)) {
      if (!_syncingEnabled) return;
      final pulledBatch = await _supabaseClient
          .from(_backendTables[syncable]!)
          .select()
          .eq(userIdKey, _userId)
          .inFilter(idKey, batch)
          .then((data) => data.map(_fromJsons[syncable]!));

      _inQueues[syncable]!.addAll(pulledBatch);
    }

    _updateLastPulledTimeStamp(syncable, DateTime.now().toUtc());
  }

  bool _skipSyncFromBackend(Type syncable) {
    final lastSyncFromBackend = _lastPulledTimestamp(syncable);

    // If no device was active since our last sync from backend, we don't need
    // to sync again.
    if (lastSyncFromBackend != null &&
        lastTimeOtherDeviceWasActive != null &&
        lastSyncFromBackend.isAfter(
          lastTimeOtherDeviceWasActive!.add(_devicesConsideredInactiveAfter),
        )) {
      return true;
    }

    return false;
  }

  Iterable<String> _getItemsToPullFromBackend(
    List<Map<String, dynamic>> backendItems,
    Map<String, DateTime> localItemsUpdatedAt,
  ) {
    bool needsPulling(String itemId, DateTime backendItemUpdatedAt) =>
        localItemsUpdatedAt[itemId] == null ||
        backendItemUpdatedAt.isAfter(localItemsUpdatedAt[itemId]!);

    return backendItems
        .where(
          (backendItem) => needsPulling(
            backendItem[idKey]! as String,
            DateTime.parse(backendItem[updatedAtKey]! as String),
          ),
        )
        .map((backendItem) => backendItem[idKey]! as String);
  }

  Future<void> _processOutgoing(Type syncable) async {
    final outQueue = _outQueues[syncable]!;
    final backendTable = _backendTables[syncable]!;
    final sentItems = _sentItems[syncable]!;

    while (_syncingEnabled && outQueue.isNotEmpty) {
      final outgoing = Set<Syncable>.from(
        outQueue.values.where((f) => f.userId == _userId),
      );
      outQueue.clear();

      if (outgoing.isEmpty) continue;

      _logger.info(
        'Syncing ${outgoing.length} items to backend table $backendTable',
      );

      assert(!outgoing.any((s) => s.userId?.isEmpty ?? true));

      await _supabaseClient.from(backendTable).upsert(
            outgoing.map((x) => x.toJson()).toList(),
            onConflict: '$idKey,$userIdKey',
          );

      sentItems.addAll(outgoing);

      _nSyncedToBackend[syncable] =
          nSyncedToBackend(syncable) + outgoing.length;

      final lastUpdatedAtForThisBatch = outgoing.map((r) => r.updatedAt).max;

      if (_lastPushedTimestamp(syncable) == null ||
          lastUpdatedAtForThisBatch.isAfter(_lastPushedTimestamp(syncable)!)) {
        await _updateLastPushedTimestamp(syncable, lastUpdatedAtForThisBatch);
      }
    }
  }

  Future<void> _processIncoming(Type syncable) async {
    final inQueue = _inQueues[syncable]!;

    while (inQueue.isNotEmpty) {
      final item = inQueue.elementAt(0);
      inQueue.remove(item);

      if (_sentItems[syncable]!.contains(item) ||
          _receivedItems[syncable]!.contains(item)) {
        // No need to process this item because it was either previously sent to
        // the backend by us or we already received it from the backend before.
        continue;
      }

      _logger.info('Processing incoming item: $item');

      await _writeIncoming(syncable, item);

      _receivedItems[syncable]!.add(item);
      _nSyncedFromBackend[syncable] = nSyncedFromBackend(syncable) + 1;
    }
  }

  Future<void> _writeIncoming(Type syncable, Syncable incoming) async {
    final table = _localTables[syncable]!;
    final newValues = incoming.toCompanion();
    try {
      await _localDb.into(table).insert(newValues);
    } catch (_) {
      final existingItem = await (_localDb.select(table)
            ..where((tbl) => tbl.id.equals(incoming.id)))
          .getSingle();

      if (incoming.updatedAt.isAfter(existingItem.updatedAt)) {
        await _localDb.update(table).replace(newValues);
      }
    }
  }

  DateTime? _lastPushedTimestamp(Type syncable) {
    return _syncTimestampStorage?.getSyncTimestamp(
      _keyForPersistentStorage(TimestampType.lastSyncToBackend, syncable),
    );
  }

  Future<void> _updateLastPushedTimestamp(
    Type syncable,
    DateTime timestamp,
  ) async {
    await _syncTimestampStorage?.setSyncTimestamp(
      _keyForPersistentStorage(TimestampType.lastSyncToBackend, syncable),
      timestamp,
    );
  }

  DateTime? _lastPulledTimestamp(Type syncable) {
    return _syncTimestampStorage?.getSyncTimestamp(
      _keyForPersistentStorage(TimestampType.lastSyncFromBackend, syncable),
    );
  }

  Future<void> _updateLastPulledTimeStamp(
    Type syncable,
    DateTime timestamp,
  ) async {
    _syncTimestampStorage?.setSyncTimestamp(
      _keyForPersistentStorage(TimestampType.lastSyncFromBackend, syncable),
      DateTime.now().toUtc(),
    );
  }

  void _clearLocalSubscriptions() {
    for (final subscription in _localSubscriptions.values) {
      subscription.cancel();
    }
    _localSubscriptions.clear();
  }

  String _keyForPersistentStorage(
    TimestampType type,
    Type syncable,
  ) {
    return '${type.name}_${_localTables[syncable]!.actualTableName}';
  }

  bool _otherDevicesActive() {
    // Assume other devices are active if we don't have a timestamp for the last
    // time they were active.
    if (lastTimeOtherDeviceWasActive == null) return true;
    return DateTime.now().difference(lastTimeOtherDeviceWasActive!) <
        _devicesConsideredInactiveAfter;
  }

  void _setUpLogger() {
    if (const bool.hasEnvironment('SYNCABLE_ENABLE_LOGGING')) {
      // coverage:ignore-start
      _logger.onRecord.listen((record) {
        // ignore: avoid_print
        print('${record.level.name}: ${record.time}: ${record.message}');
      });
      // coverage:ignore-end
    }
  }
}

typedef CompanionConstructor = Object Function({
  Value<int> rowid,
  Value<String> id,
  Value<String?> userId,
  Value<DateTime> updatedAt,
  Value<bool> deleted,
});

enum TimestampType {
  lastSyncFromBackend('lastSyncFromBackend'),
  lastSyncToBackend('lastSyncToBackend'),
  ;

  const TimestampType(this.name);
  final String name;
}
