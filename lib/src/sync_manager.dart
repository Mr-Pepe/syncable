import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:supabase/supabase.dart';
import 'package:syncable/src/supabase_names.dart';
import 'package:syncable/src/sync_dead_letter_queue.dart';
import 'package:syncable/src/sync_error_classifier.dart';
import 'package:syncable/src/sync_event.dart';
import 'package:syncable/src/sync_timestamp_storage.dart';
import 'package:syncable/src/syncable.dart';
import 'package:syncable/src/syncable_database.dart';
import 'package:syncable/src/syncable_table.dart';

/// Callback pour notifier les erreurs persistées dans la Dead Letter Queue.
///
/// Permet au code appelant (ex: SyncService) d'envoyer ces erreurs vers
/// un système de monitoring externe (ex: Sentry) sans créer de dépendance
/// directe dans le package syncable.
///
/// [tableName] Nom de la table backend (ex: "competitions", "photos")
/// [itemId] ID de l'item en erreur
/// [itemJson] Représentation JSON complète de l'item
/// [errorType] Type d'erreur: 'network' ou 'application'
/// [errorMessage] Message d'erreur lisible
/// [stackTrace] Stack trace de l'erreur (peut être null)
/// [retryCount] Nombre de tentatives avant échec final
typedef OnDLQErrorCallback =
    void Function({
      required String tableName,
      required String itemId,
      required Map<String, dynamic> itemJson,
      required String errorType,
      required String errorMessage,
      String? stackTrace,
      required int retryCount,
    });

/// Callback pour envoyer des breadcrumbs de synchronisation.
///
/// Permet de tracer les événements importants du cycle de sync vers
/// un système de monitoring externe (ex: Sentry breadcrumbs).
///
/// [message] Description de l'événement
/// [category] Catégorie (ex: "sync", "circuit_breaker", "error_recovery")
/// [level] Niveau de sévérité: "debug", "info", "warning", "error"
/// [data] Données contextuelles additionnelles
typedef OnSyncBreadcrumbCallback =
    void Function({
      required String message,
      required String category,
      required String level,
      Map<String, dynamic>? data,
    });

/// Sync mode based on user activity patterns.
///
/// This is used to adaptively adjust sync intervals to balance
/// battery consumption and responsiveness.
enum SyncMode {
  /// User is actively modifying data (last change < 10 seconds).
  /// Sync interval: 5 seconds for maximum responsiveness.
  active,

  /// Recent modifications but user is no longer actively editing (10s - 2min).
  /// Sync interval: 15 seconds for good balance.
  recent,

  /// No modifications for > 2 minutes.
  /// Sync interval: 30 seconds for battery conservation.
  idle,
}

/// 🔴 NEW: Maximum retry counter value to prevent integer overflow.
///
/// For network errors that retry indefinitely, we cap the counter at this value.
/// This prevents memory issues while maintaining retry behavior.
const int _maxRetryCount = 10000;

/// Circuit breaker state to prevent spamming the backend during network outages.
///
/// After detecting multiple consecutive network errors, the circuit breaker
/// enters an "open" state and pauses sync attempts for a cooldown period.
class CircuitBreakerState {
  CircuitBreakerState();

  /// Number of consecutive network errors
  int consecutiveNetworkErrors = 0;

  /// Timestamp when the circuit breaker was opened
  DateTime? openedAt;

  /// Whether the circuit breaker is currently open (paused)
  bool get isOpen {
    if (openedAt == null) return false;

    // Auto-reset after 2 minutes
    final cooldownPeriod = const Duration(minutes: 2);
    final now = DateTime.now();

    if (now.difference(openedAt!) > cooldownPeriod) {
      // Reset the circuit breaker
      reset();
      return false;
    }

    return true;
  }

  /// Opens the circuit breaker (pauses syncing)
  void open({OnSyncBreadcrumbCallback? onBreadcrumb, Logger? logger}) {
    openedAt = DateTime.now();

    // 🔴 Breadcrumb: Circuit breaker opened
    try {
      onBreadcrumb?.call(
        message:
            'Circuit breaker opened after $consecutiveNetworkErrors consecutive network errors',
        category: 'circuit_breaker',
        level: 'warning',
        data: {
          'consecutive_errors': consecutiveNetworkErrors,
          'cooldown_minutes': 2,
        },
      );
    } catch (e, s) {
      logger?.warning('Error in onSyncBreadcrumb callback: $e\n$s');
    }
  }

  /// Resets the circuit breaker (resumes syncing)
  void reset() {
    consecutiveNetworkErrors = 0;
    openedAt = null;
  }

  /// Records a network error and opens circuit if threshold is reached
  void recordNetworkError({
    OnSyncBreadcrumbCallback? onBreadcrumb,
    Logger? logger,
  }) {
    consecutiveNetworkErrors++;

    // Open circuit after 5 consecutive network errors
    if (consecutiveNetworkErrors >= 5) {
      open(onBreadcrumb: onBreadcrumb, logger: logger);
    }
  }

  /// Records a successful sync (resets error counter and closes circuit breaker)
  void recordSuccess() {
    consecutiveNetworkErrors = 0;
    openedAt = null; // 🔴 FIXED: Close circuit breaker on success
  }
}

/// The [SyncManager] is the main class for syncing data between a local Drift
/// database and a Supabase backend.
///
/// It handles the syncing of multiple tables and manages the state of the
/// syncing process. It also provides methods to register syncable tables and
/// to enable or disable syncing.
///
/// The [SyncManager] is designed to be used with the [SyncableDatabase]
/// class, which provides the local database functionality.
///
/// The [SyncManager] extends [ChangeNotifier] to provide a simple way to listen
/// for sync state changes via the [syncInProgress] property.
class SyncManager<T extends SyncableDatabase> extends ChangeNotifier {
  /// Creates a new [SyncManager] instance.
  ///
  /// The [localDatabase] parameter is required and must be an instance of
  /// [SyncableDatabase]. The [supabaseClient] parameter is also required and
  /// must be an instance of [SupabaseClient].
  ///
  /// The [syncInterval] parameter specifies the interval at which the
  /// internal sync loop runs. The sync loop is responsible for
  ///  - sending local changes to the backend,
  ///  - writing data received from the backend via a real-time subscription to
  ///    the local database.
  ///
  /// The [maxRows] parameter specifies the maximum number of rows that can be
  /// retrieved from the backend in one batch. Set this value to the one you
  /// configured in your Supabase dashboard or `supabase/config.toml`.
  ///
  /// The [syncTimestampStorage] parameter is optional and can be used to
  /// provide a custom implementation of [SyncTimestampStorage] for storing
  /// timestamps of the last sync operations. This can drastically reduce
  /// the amount of data that needs to be synced because only changed data
  /// since the last sync must be synced. Implementing a solution that persists
  /// the timestamps across app restarts (e.g. via shared preferences) is
  /// recommended.
  ///
  /// The [otherDevicesConsideredInactiveAfter] parameter specifies the
  /// duration after which other devices are considered inactive. This is used
  /// in combination with [lastTimeOtherDeviceWasActive] to determine whether
  /// other devices are currently active or not. A real-time subscription to
  /// the backend is only created if other devices are considered active.
  ///
  /// For simple use cases, you can listen to sync state changes using the
  /// [syncInProgress] property and [ChangeNotifier] interface.
  ///
  /// For advanced use cases, set [enableDetailedEvents] to `true` and provide
  /// [onSyncStarted] and [onSyncCompleted] callbacks. These will be called when
  /// sync events occur, allowing your application to respond to detailed
  /// synchronization events per syncable type.
  SyncManager({
    required T localDatabase,
    required SupabaseClient supabaseClient,
    Duration syncInterval = const Duration(seconds: 1),
    int maxRows = 1000,
    SyncTimestampStorage? syncTimestampStorage,
    Duration otherDevicesConsideredInactiveAfter = const Duration(minutes: 2),
    bool enableDetailedEvents = false,
    SyncStartedEventCallback? onSyncStarted,
    SyncCompletedEventCallback? onSyncCompleted,
    OnDLQErrorCallback? onDLQError,
    OnSyncBreadcrumbCallback? onSyncBreadcrumb,
  }) : _localDb = localDatabase,
       _supabaseClient = supabaseClient,
       _syncInterval = syncInterval,
       _maxRows = maxRows,
       _syncTimestampStorage = syncTimestampStorage,
       _devicesConsideredInactiveAfter = otherDevicesConsideredInactiveAfter,
       _enableDetailedEvents = enableDetailedEvents,
       _onSyncStarted = enableDetailedEvents ? onSyncStarted : null,
       _onSyncCompleted = enableDetailedEvents ? onSyncCompleted : null,
       _onDLQError = onDLQError,
       _onSyncBreadcrumb = onSyncBreadcrumb,
       assert(
         syncInterval.inMilliseconds > 0,
         'Sync interval must be positive',
       );

  final _logger = Logger('syncable');

  final T _localDb;
  final SupabaseClient _supabaseClient;
  final SyncTimestampStorage? _syncTimestampStorage;
  final int _maxRows;
  final Duration _syncInterval;
  final Duration _devicesConsideredInactiveAfter;

  // 🔴 NEW: Dead Letter Queue for persistent error storage
  // Initialized in enableSync() to ensure database is ready
  SyncDeadLetterQueue? _deadLetterQueue;

  // Enable detailed events (disabled by default for simplicity)
  final bool _enableDetailedEvents;

  // Callback functions for sync events
  final SyncStartedEventCallback? _onSyncStarted;
  final SyncCompletedEventCallback? _onSyncCompleted;

  // Callback functions for monitoring integration (Sentry, etc.)
  final OnDLQErrorCallback? _onDLQError;
  final OnSyncBreadcrumbCallback? _onSyncBreadcrumb;

  /// This is what gets set when [enableSync] gets called. Internally, whether
  /// the syncing is enabled or not is determined by [_syncingEnabled].
  bool __syncingEnabled = false;
  bool get syncingEnabled => __syncingEnabled;
  bool get _syncingEnabled =>
      __syncingEnabled && !_disposed && userId.isNotEmpty;

  /// Whether a sync is currently in progress.
  ///
  /// This is a simple boolean that tracks if any sync operation is currently
  /// running. Use this with [ChangeNotifier] to listen for sync state changes.
  /// For more granular sync events per syncable type, set [enableDetailedEvents]
  /// to `true` and use the callback functions.
  bool _syncInProgress = false;
  bool get syncInProgress => _syncInProgress;

  /// Sets the sync in progress state and notifies listeners.
  void _setSyncInProgress(bool inProgress) {
    if (_syncInProgress != inProgress) {
      _syncInProgress = inProgress;
      notifyListeners();
    }
  }

  // ============= ADAPTIVE SYNC INTERVAL FIELDS =============

  /// Timestamp of the last detected local change.
  /// Used to determine the current sync mode (active/recent/idle).
  DateTime? _lastChangeDetected;

  /// Completer used to interrupt the sync loop sleep when immediate sync is needed.
  /// This allows waking up the loop before the normal interval expires.
  Completer<void>? _syncTrigger;

  /// Counter for sync loop iterations.
  /// Used to trigger periodic safety checks (e.g., re-sync from Drift every N iterations).
  int _loopIterationCounter = 0;

  /// Enables syncing for all registered syncables.
  ///
  /// This method will throw an exception if no syncables are registered.
  /// It will also start the sync loop, which will run in the background and
  /// handle the syncing of data between the local database and the backend.
  ///
  /// For any syncs to happen, the user ID must be set via [setUserId].
  void enableSync() {
    if (__syncingEnabled == true) return;

    if (_syncables.isEmpty) {
      throw Exception(
        'Failed to enable syncing because there are no registered syncables. '
        'Please register at least one syncable before enabling syncing.',
      );
    }

    // 🔴 NEW: Initialize Dead Letter Queue
    _deadLetterQueue = SyncDeadLetterQueue(_localDb);

    __syncingEnabled = true;
    _startLoop();
    _onDependenciesChanged('syncing enabled');
  }

  /// Disables syncing to and from the backend.
  void disableSync() {
    if (__syncingEnabled == false) return;
    __syncingEnabled = false;
    _onDependenciesChanged('syncing disabled');
  }

  String _userId = '';
  String get userId => _userId;

  /// Sets the user ID for syncing. This is required for syncing to work.
  ///
  /// This must be the user ID of the currently logged in user. If the user ID is
  /// empty, syncing will be disabled and no data will be synced to or from
  /// the backend.
  void setUserId(String value) {
    if (_userId == value) return;
    _userId = value;
    _onDependenciesChanged("userId set to '$value'");
  }

  DateTime? _lastTimeOtherDeviceWasActive;
  DateTime? get lastTimeOtherDeviceWasActive => _lastTimeOtherDeviceWasActive;

  /// Sets the last time another device was active.
  ///
  /// This is used to determine whether other devices are currently active or
  /// not. A real-time subscription to the backend is only created if other
  /// devices are considered active.
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

  // 🔴 NEW: Error queues for application errors (moved after N retries)
  final Map<Type, Map<String, Syncable>> _errorQueues = {};

  // 🔴 NEW: Permanent tracking of item IDs that failed with application errors
  // This prevents re-injection after cleanup. Items stay here until manual resolution.
  final Map<Type, Set<String>> _permanentErrorItemIds = {};

  // 🔴 NEW: Retry counters for each item (key: "tableName:itemId")
  final Map<String, int> _retryCounters = {};

  // 🔴 NEW: Error classifier instance
  final _errorClassifier = SyncErrorClassifier();

  // 🔴 NEW: Circuit breaker state (per table)
  final Map<Type, CircuitBreakerState> _circuitBreakers = {};

  // Track sync source for incoming items
  final Map<Type, Map<String, SyncEventSource>> _incomingSources = {};

  final Map<Type, Set<Syncable>> _sentItems = {};
  final Map<Type, Set<Syncable>> _receivedItems = {};

  final Map<Type, StreamSubscription<List<Syncable>>> _localSubscriptions = {};

  final Map<String, RealtimeChannel> _backendSubscriptions = {};
  bool get isSubscribedToBackend => _backendSubscriptions.isNotEmpty;

  /// The number of items of type [syncable] that have been synced to the
  /// backend.
  int nSyncedToBackend(Type syncable) => _nSyncedToBackend[syncable] ??= 0;
  final Map<Type, int> _nSyncedToBackend = {};

  /// The number of items of type [syncable] that have been synced from the
  /// backend.
  int nSyncedFromBackend(Type syncable) => _nSyncedFromBackend[syncable] ??= 0;
  final Map<Type, int> _nSyncedFromBackend = {};

  int _nFullSyncs = 0;
  int get nFullSyncs => _nFullSyncs;

  @override
  void dispose() {
    _disposed = true;
    for (final subscription in _localSubscriptions.values) {
      subscription.cancel();
    }
    // Unsubscribe from all channels
    for (final subscription in _backendSubscriptions.values) {
      subscription.unsubscribe();
    }
    _backendSubscriptions.clear();

    // 🔴 NEW: Cleanup error management structures
    _errorQueues.clear();
    _permanentErrorItemIds.clear();
    _retryCounters.clear();
    _circuitBreakers.clear();
    _deadLetterQueue = null; // Allow GC to collect

    super.dispose();
  }

  /// Registers a syncable table with the sync manager.
  ///
  /// This method must be called before enabling syncing. It registers the
  /// table with the sync manager and sets up the necessary mappings for
  /// syncing data between the local database and the backend.
  ///
  /// The [backendTable] parameter specifies the name of the table on the
  /// backend. The [fromJson] parameter is used to convert the JSON data
  /// received from the backend into a [Syncable] object. The
  /// [companionConstructor] parameter is then used create a companion object
  /// from the [Syncable] object to write it to the local database.
  ///
  /// The generic type parameter must be provided and must be a  concrete
  /// subclass of [Syncable].
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
    _errorQueues[S] = {}; // 🔴 NEW: Initialize error queue
    _permanentErrorItemIds[S] =
        {}; // 🔴 NEW: Initialize permanent error tracking
    _circuitBreakers[S] =
        CircuitBreakerState(); // 🔴 NEW: Initialize circuit breaker
    _incomingSources[S] = {};
    _sentItems[S] = {};
    _receivedItems[S] = {};
  }

  Future<void> _startLoop() async {
    if (_loopRunning) {
      _logger.warning('Sync loop already running, skipping start');
      return;
    }
    _loopRunning = true;
    _logger.info('Sync loop started with adaptive intervals');

    // 🔴 Breadcrumb: Sync loop started
    try {
      _onSyncBreadcrumb?.call(
        message: 'Sync loop started with adaptive intervals',
        category: 'sync',
        level: 'info',
      );
    } catch (e, s) {
      _logger.warning('Error in onSyncBreadcrumb callback: $e\n$s');
    }

    while (!_disposed) {
      final iterationStart = DateTime.now();
      _loopIterationCounter++;
      _logger.fine('Sync loop iteration #$_loopIterationCounter starting');

      // ✅ SÉCURITÉ : Tous les 20 loops, resynchroniser depuis Drift
      // Cela capture tout item qui aurait pu être perdu de la RAM
      if (_loopIterationCounter % 20 == 0) {
        _logger.info(
          '🔄 Periodic safety check (iteration #$_loopIterationCounter): re-syncing from Drift',
        );
        try {
          for (final syncable in _syncables) {
            if (_disposed) break;

            // Récupérer les items locaux depuis Drift
            final localItems = await _localDb
                .select(_localTables[syncable]!)
                .get();

            // Pousser vers outQueue seulement les items du user actuel
            _pushLocalChangesToOutQueue(
              syncable,
              localItems.where((i) => i.userId == _userId),
            );
          }
        } catch (e, s) {
          _logger.severe('Error during periodic Drift re-sync: $e\n$s');
        }
      }

      // 🔴 NEW: Tous les 100 loops, nettoyer errorQueue pour éviter fuite mémoire
      // Les erreurs sont déjà persistées dans DLQ (SQLite), on peut vider la RAM
      if (_loopIterationCounter % 100 == 0) {
        _cleanupErrorQueues();
      }

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

      // ✨ ADAPTIVE SYNC: Determine current mode and interval
      final currentMode = _getCurrentMode();
      final interval = _getIntervalForMode(currentMode);

      print(
        '💤 [Syncable] Loop iteration complete, sleeping for ${interval.inSeconds}s (mode: $currentMode)',
      );

      // Create a new completer for the next potential interruption
      _syncTrigger = Completer<void>();

      // Wait for EITHER the timeout OR an immediate sync trigger
      await Future.any([Future.delayed(interval), _syncTrigger!.future]);

      final actualWaitTime = DateTime.now().difference(iterationStart);
      print(
        '⏰ [Syncable] Woke up after ${actualWaitTime.inSeconds}s (expected: ${interval.inSeconds}s)',
      );
    }

    _loopRunning = false;
    _logger.info('Sync loop stopped');
  }

  /// Goes through the local tables for all registered syncables and sets the
  /// user ID to the currently set [userId] for all entries that don't have
  /// a user ID yet.
  ///
  /// This is useful if you support anonymous usage of your app. You can first
  /// write items to the local database without setting the user ID until
  /// the user registers or logs in. Afterwards, you can call
  /// this method to set the user ID and sync the data to the backend (requires
  /// syncing to be enabled via [enableSync]).
  Future<void> fillMissingUserIdForLocalTables() async {
    if (userId.isEmpty) {
      _logger.warning(
        'Not setting user ID for local tables because user ID is empty',
      );
      return;
    }

    final tables = _syncables.map((s) => _localTables[s]!).toList();
    final companions = List<UpdateCompanion<Syncable>>.from(
      _syncables.map((s) => _companions[s]!(userId: Value(userId))),
    );

    await _localDb.transaction(() async {
      for (int i = 0; i < tables.length; i++) {
        await (_localDb.update(
          tables[i],
        )..where((row) => row.userId.isNull())).write(companions[i]);
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

    if (!_syncingEnabled) {
      _logger.warning(
        'Not subscribed to local changes because syncing is disabled',
      );
      return;
    }

    if (userId.isEmpty) {
      _logger.warning(
        'Not subscribed to local changes because user ID is empty',
      );
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

  void _pushLocalChangesToOutQueue(Type syncable, Iterable<Syncable> rows) {
    final outQueue = _outQueues[syncable]!;
    final receivedItems = _receivedItems[syncable]!;
    final errorQueue = _errorQueues[syncable]!;
    final permanentErrorIds = _permanentErrorItemIds[syncable]!;

    bool updateHasNotBeenSentYet(Syncable row) =>
        row.updatedAt.isAfter(outQueue[row.id]?.updatedAt ?? DateTime(0)) &&
        row.updatedAt.isAfter(_lastPushedTimestamp(syncable) ?? DateTime(0));

    bool hasNewItems = false;

    for (final row
        in rows
            .where((r) => !receivedItems.contains(r))
            .where(updateHasNotBeenSentYet)) {
      // 🔴 NEW: Check permanent error tracking first (survives cleanup)
      // This prevents re-injection of items that failed even after errorQueue is cleared
      if (permanentErrorIds.contains(row.id)) {
        // Check if user modified the item (updatedAt changed)
        final errorItem = errorQueue[row.id]; // May be null if cleanup happened

        // If item is in errorQueue, check if it was modified
        if (errorItem != null && row.updatedAt.isAfter(errorItem.updatedAt)) {
          _logger.info(
            '🔄 Item ${row.id} was in permanent error tracking but has been modified locally '
            '(${errorItem.updatedAt} → ${row.updatedAt}) - giving it a second chance',
          );

          // 🔴 Breadcrumb: Second chance for item
          final backendTable = _backendTables[syncable]!;
          try {
            _onSyncBreadcrumb?.call(
              message: 'Item modified after error - giving second chance',
              category: 'error_recovery',
              level: 'info',
              data: {
                'table': backendTable,
                'item_id': row.id,
                'previous_update': errorItem.updatedAt.toIso8601String(),
                'new_update': row.updatedAt.toIso8601String(),
              },
            );
          } catch (e, s) {
            _logger.warning('Error in onSyncBreadcrumb callback: $e\n$s');
          }

          errorQueue.remove(row.id);
          permanentErrorIds.remove(row.id);
          // Also clear its retry counter to start fresh
          final retryKey = '$backendTable:${row.id}';
          _retryCounters.remove(retryKey);
        } else {
          // Item still in permanent error tracking, skip it
          _logger.fine(
            '⏭️ Skipping item ${row.id} - in permanent error tracking (needs manual resolution or modification)',
          );
          continue;
        }
      }

      // Legacy check for errorQueue (redundant but kept for safety)
      if (errorQueue.containsKey(row.id)) {
        final errorItem = errorQueue[row.id]!;
        // If updatedAt changed, user made changes → give it a second chance
        if (row.updatedAt.isAfter(errorItem.updatedAt)) {
          _logger.info(
            '🔄 Item ${row.id} was in error queue but has been modified locally '
            '(${errorItem.updatedAt} → ${row.updatedAt}) - giving it a second chance',
          );
          errorQueue.remove(row.id);
          permanentErrorIds.remove(
            row.id,
          ); // Also remove from permanent tracking
          // Also clear its retry counter to start fresh
          final backendTable = _backendTables[syncable]!;
          final retryKey = '$backendTable:${row.id}';
          _retryCounters.remove(retryKey);
        } else {
          // Same version still in error queue, skip it
          _logger.fine(
            '⏭️ Skipping item ${row.id} - still in error queue (unmodified)',
          );
          continue;
        }
      }

      outQueue[row.id] = row;
      hasNewItems = true;
    }

    // ✨ ADAPTIVE SYNC: Detect changes and potentially wake up the loop
    if (hasNewItems) {
      // Update the last change timestamp
      _lastChangeDetected = DateTime.now();

      // Always trigger immediate sync when local changes are detected
      // This ensures tests and real-world usage get fast sync response
      print('⚡ [Syncable] Local changes detected - triggering immediate sync');
      _triggerImmediateSync();
    }
  }

  /// 🔴 NEW: Cleanup error queues to prevent memory leak
  ///
  /// Error items are already persisted in Dead Letter Queue (SQLite).
  /// We can safely clear them from RAM since they're not actively retrying.
  /// Also cleans retry counters for cleaned items.
  ///
  /// Note: We do NOT reset circuit breakers here. Circuit breakers manage
  /// their own state and auto-reset after 2 minutes. Resetting them during
  /// cleanup could cause issues if network errors are still ongoing in outQueue.
  void _cleanupErrorQueues() {
    try {
      int totalCleared = 0;
      int totalRetryCountersCleared = 0;

      for (final syncable in _syncables) {
        final backendTable = _backendTables[syncable]!;
        final errorQueue = _errorQueues[syncable];

        if (errorQueue != null && errorQueue.isNotEmpty) {
          // Clean retry counters for items in error queue
          for (final itemId in errorQueue.keys) {
            final retryKey = '$backendTable:$itemId';
            if (_retryCounters.remove(retryKey) != null) {
              totalRetryCountersCleared++;
            }
          }

          final count = errorQueue.length;
          errorQueue.clear();
          totalCleared += count;

          // 🔴 FIXED: Do NOT reset circuit breaker here
          // Circuit breaker has its own auto-reset logic (2 minutes)
          // Resetting it here could interfere with network error handling
        }
      }

      if (totalCleared > 0) {
        _logger.info(
          '🧹 Cleaned $totalCleared items from error queues and '
          '$totalRetryCountersCleared retry counters (persisted in DLQ)',
        );
      }
    } catch (e, s) {
      _logger.warning('Failed to cleanup error queues: $e\n$s');
    }
  }

  void _maybeSubscribeToBackendChanges() {
    final otherDevicesActive = _otherDevicesActive();

    if (!_syncingEnabled || !otherDevicesActive) {
      // Unsubscribe from all existing channels
      for (final subscription in _backendSubscriptions.values) {
        subscription.unsubscribe();
      }
      _backendSubscriptions.clear();

      String reason;
      if (!__syncingEnabled) {
        reason = 'syncing is disabled';
      } else if (userId.isEmpty) {
        reason = 'the user ID is empty';
      } else if (!otherDevicesActive) {
        reason = 'no other devices are active';
      } else {
        reason = '... good question. Please file an issue';
      }

      _logger.warning('Not subscribed to backend changes because $reason');
      return;
    }

    if (_backendSubscriptions.isNotEmpty) {
      return; // Already subscribed
    }

    // Create a dedicated channel for each table
    for (final syncable in _syncables) {
      final tableName = _backendTables[syncable]!;
      final channelName = 'sync_$tableName';

      _logger.info('Creating Realtime subscription for table: $tableName');

      final channel = _supabaseClient.channel(channelName);

      channel.onPostgresChanges(
        schema: publicSchema,
        table: tableName,
        event: PostgresChangeEvent.all,
        callback: (p) {
          if (_disposed) {
            return;
          }

          if (p.newRecord.isNotEmpty) {
            try {
              final item = _fromJsons[syncable]!(p.newRecord);
              final timestamp = DateTime.now().millisecondsSinceEpoch;
              print(
                '🔔 [Syncable] REALTIME [$timestamp]: Received item ${item.id} for ${syncable.toString()}',
              );

              _inQueues[syncable]!.add(item);
              print(
                '🔔 [Syncable] REALTIME: Queue size after add: ${_inQueues[syncable]!.length}',
              );

              if (_enableDetailedEvents) {
                _incomingSources[syncable]![item.id] = SyncEventSource.realtime;
              }

              // ⚡ NOUVEAU : Traiter immédiatement au lieu d'attendre le sync loop
              // Utilise unawaited pour ne pas bloquer le callback Realtime
              _processIncomingImmediate(syncable)
                  .then((_) {
                    final endTimestamp = DateTime.now().millisecondsSinceEpoch;
                    final latency = endTimestamp - timestamp;
                    print('✅ [Syncable] REALTIME: Processed in ${latency}ms');
                  })
                  .catchError((e, stackTrace) {
                    _logger.severe(
                      'Error in immediate processing for $tableName: $e',
                      e,
                      stackTrace as StackTrace?,
                    );
                  });
            } catch (e, stack) {
              _logger.severe(
                'Error processing Realtime event for $tableName: $e',
                e,
                stack,
              );
            }
          }
        },
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: userIdKey,
          value: _userId,
        ),
      );

      // Subscribe to the channel
      channel.subscribe((status, error) {
        if (error != null) {
          _logger.severe('Realtime subscription error for $tableName: $error');
        } else if (status == RealtimeSubscribeStatus.subscribed) {
          _logger.info('Realtime subscription active for $tableName');
        }
      });

      // Store the channel for later cleanup
      _backendSubscriptions[tableName] = channel;
    }

    _logger.info(
      'Subscribed to backend changes for ${_syncables.length} tables',
    );
  }

  /// Syncs all tables registered with the sync manager.
  ///
  /// This method is called automatically when the sync manager is started,
  /// or when dependencies change (e.g. user ID, last active time of other
  /// devices, ...).
  ///
  /// It can also be called manually to force a sync (still requires syncing
  /// to be enabled via [enableSync]).
  Future<void> syncTables() async {
    await _syncTables('Manual sync');
  }

  /// Process all pending incoming data immediately.
  ///
  /// This method processes any data that has been fetched from the backend
  /// but not yet written to the local database. This is useful for ensuring
  /// data is immediately available in the UI after a sync operation.
  ///
  /// Normally, incoming data is processed in the main sync loop which runs
  /// at regular intervals. This method allows you to bypass that wait.
  Future<void> processIncomingImmediately() async {
    if (!__syncingEnabled) {
      _logger.warning('Cannot process incoming data - syncing is disabled');
      return;
    }

    if (userId.isEmpty) {
      _logger.warning('Cannot process incoming data - user ID is empty');
      return;
    }

    _logger.info('Processing incoming data immediately');

    // Process all pending incoming data for each syncable
    for (final syncable in _syncables) {
      await _processIncoming(syncable);
    }

    _logger.info('Immediate incoming data processing complete');
  }

  Future<void> _syncTables(String reason) async {
    print('🎯 [Syncable] _syncTables called - reason: $reason');

    if (!__syncingEnabled) {
      print('❌ [Syncable] _syncTables aborted - syncing disabled');
      _logger.warning('Tables not getting synced because syncing is disabled');
      return;
    }

    if (userId.isEmpty) {
      print('❌ [Syncable] _syncTables aborted - userId empty');
      _logger.warning('Tables not getting synced because user ID is empty');
      return;
    }

    _logger.info('Syncing all tables. Reason: $reason');

    // Set sync in progress and notify listeners
    _setSyncInProgress(true);

    try {
      // Emit sync started events (only if detailed events are enabled)
      if (_enableDetailedEvents) {
        for (final syncable in _syncables) {
          if (_onSyncStarted != null) {
            final event = SyncStartedEvent(
              syncableType: syncable,
              source: SyncEventSource.fullSync,
              timestamp: DateTime.now().toUtc(),
              reason: reason,
            );
            _onSyncStarted(event);
          }
        }
      }

      // Track initial queue sizes to detect if items were added during sync
      final initialQueueSizes = <Type, int>{};
      for (final syncable in _syncables) {
        initialQueueSizes[syncable] = _inQueues[syncable]!.length;
      }

      for (final syncable in _syncables) {
        await _syncTable(syncable);
      }

      // Emit fallback sync completed events for tables that didn't get any new items
      // Real events with statistics are emitted in _processIncoming
      if (_enableDetailedEvents) {
        for (final syncable in _syncables) {
          final initialSize = initialQueueSizes[syncable]!;
          final currentSize = _inQueues[syncable]!.length;

          // Only emit fallback event if no items were added during sync
          if (currentSize == initialSize && _onSyncCompleted != null) {
            final event = SyncCompletedEvent(
              syncableType: syncable,
              source: SyncEventSource.fullSync,
              timestamp: DateTime.now().toUtc(),
              itemsReceived: 0,
              itemsUpdated: 0,
              itemsDeleted: 0,
            );
            _onSyncCompleted(event);
          }
        }
      }

      _nFullSyncs++;
    } finally {
      // Clear sync in progress and notify listeners
      _setSyncInProgress(false);
    }
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
    final backendItems = await _fetchBackendItemMetadata(syncable);

    final itemsToPull = _getItemsToPullFromBackend(
      backendItems,
      localItemsUpdatedAt,
    );

    if (itemsToPull.isNotEmpty) {
      _logger.info(
        "Syncing ${itemsToPull.length} items from backend table '${_backendTables[syncable]}'",
      );
    }

    // Use batches because all the UUIDs make the URI become too long otherwise.
    for (final batch in itemsToPull.slices(100)) {
      if (!_syncingEnabled) return;

      try {
        final pulledBatch = await _supabaseClient
            .from(_backendTables[syncable]!)
            .select()
            .eq(userIdKey, _userId)
            .inFilter(idKey, batch)
            .then((data) => data.map(_fromJsons[syncable]!));

        print(
          '📦 [Syncable] Adding ${pulledBatch.length} items to queue for ${syncable.toString()}',
        );
        _inQueues[syncable]!.addAll(pulledBatch);
        print(
          '📦 [Syncable] Queue size after add: ${_inQueues[syncable]!.length} for ${syncable.toString()}',
        );
        // Mark these as full sync items (only if detailed events are enabled)
        if (_enableDetailedEvents) {
          for (final item in pulledBatch) {
            _incomingSources[syncable]![item.id] = SyncEventSource.fullSync;
          }
        }
      } on SocketException catch (e) {
        _logger.warning(
          'Network error during item pull for ${_backendTables[syncable]}: ${e.message}',
        );
        break; // Exit loop on network error
      } on HttpException catch (e) {
        _logger.warning(
          'HTTP error during item pull for ${_backendTables[syncable]}: ${e.message}',
        );
        break; // Exit loop on HTTP error
      } catch (e) {
        _logger.severe(
          'Unexpected error during item pull for ${_backendTables[syncable]}: $e',
        );
        break; // Exit loop on any other error
      }
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

  /// Quick connectivity check to prevent network calls when offline
  Future<bool> _hasNetworkConnectivity() async {
    try {
      final result = await InternetAddress.lookup(
        'google.com',
      ).timeout(const Duration(seconds: 2));
      return result.isNotEmpty && result[0].rawAddress.isNotEmpty;
    } on SocketException catch (_) {
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Retrieves the IDs and `lastUpdatedAt` timestamps for all rows of a
  /// syncable in the backend. These can be used to determine which items need
  /// to be synced from the backend.
  Future<List<Map<String, dynamic>>> _fetchBackendItemMetadata(
    Type syncable,
  ) async {
    // 🛡️ OFFLINE PROTECTION: Check network connectivity before making requests
    // This prevents ClientSocketException crashes when offline
    final hasNetwork = await _hasNetworkConnectivity();
    if (!hasNetwork) {
      _logger.warning(
        'Skipping backend metadata fetch for ${_backendTables[syncable]} - '
        'no network connectivity detected',
      );
      return []; // Return empty list instead of crashing
    }

    final List<Map<String, dynamic>> backendItems = [];

    int offset = 0;
    bool hasMore = true;

    while (hasMore && _syncingEnabled) {
      try {
        final batch = await _supabaseClient
            .from(_backendTables[syncable]!)
            .select('$idKey,$updatedAtKey')
            .eq(userIdKey, _userId)
            .range(offset, offset + _maxRows - 1)
            // Use consistent ordering to prevent duplicates
            .order(idKey, ascending: true);

        backendItems.addAll(batch);
        hasMore = batch.length == _maxRows;
        offset += _maxRows;

        if (batch.isNotEmpty) {
          _logger.info(
            'Fetched batch of ${batch.length} metadata items for table '
            "'${_backendTables[syncable]!}', total so far: ${backendItems.length}",
          );
        }
      } on SocketException catch (e) {
        _logger.warning(
          'Network error during metadata fetch for ${_backendTables[syncable]}: ${e.message}',
        );
        break; // Exit loop on network error to prevent crashes
      } on HttpException catch (e) {
        _logger.warning(
          'HTTP error during metadata fetch for ${_backendTables[syncable]}: ${e.message}',
        );
        break; // Exit loop on HTTP error
      } catch (e) {
        _logger.severe(
          'Unexpected error during metadata fetch for ${_backendTables[syncable]}: $e',
        );
        break; // Exit loop on any other error
      }
    }

    return backendItems;
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
    final errorQueue = _errorQueues[syncable]!;
    final backendTable = _backendTables[syncable]!;
    final sentItems = _sentItems[syncable]!;
    final circuitBreaker = _circuitBreakers[syncable]!;

    // 🔴 NEW: Check circuit breaker before attempting sync
    if (circuitBreaker.isOpen) {
      _logger.warning(
        '🚫 Circuit breaker OPEN for $backendTable - skipping sync '
        '(${circuitBreaker.consecutiveNetworkErrors} consecutive network errors)',
      );
      return; // Skip this table entirely when circuit is open
    }

    if (outQueue.isEmpty) return;

    _logger.info(
      '📤 Processing ${outQueue.length} outgoing items for $backendTable',
    );

    // 🔴 NEW: Process items one by one to avoid blocking entire queue on single error
    final itemsToProcess = outQueue.values.toList();

    for (final item in itemsToProcess) {
      if (!_syncingEnabled) break;
      if (item.userId != _userId) continue; // Skip items from other users

      final retryKey = '$backendTable:${item.id}';
      final retryCount = _retryCounters[retryKey] ?? 0;

      // 🔴 NEW: Skip items that are in error queue (application errors)
      if (errorQueue.containsKey(item.id)) {
        _logger.fine('⏭️ Skipping item ${item.id} - already in error queue');
        continue;
      }

      try {
        // Try to upsert this single item
        await _supabaseClient.from(backendTable).upsert([
          item.toJson(),
        ], onConflict: idKey);

        // ✅ SUCCESS: Remove from queue and reset counters
        outQueue.remove(item.id);
        _retryCounters.remove(retryKey);
        circuitBreaker.recordSuccess(); // Reset circuit breaker on success

        sentItems.add(item);
        _nSyncedToBackend[syncable] = nSyncedToBackend(syncable) + 1;

        // Update timestamp
        if (_lastPushedTimestamp(syncable) == null ||
            item.updatedAt.isAfter(_lastPushedTimestamp(syncable)!)) {
          await _updateLastPushedTimestamp(syncable, item.updatedAt);
        }

        _logger.fine('✅ Successfully synced item ${item.id} to $backendTable');
      } catch (e, stackTrace) {
        // 🔴 NEW: Classify the error
        final errorType = SyncErrorClassifier.classify(e);

        _logger.warning(
          '⚠️ Error syncing item ${item.id} to $backendTable '
          '(retry #$retryCount, type: $errorType): $e',
        );

        if (errorType == SyncErrorType.network) {
          // ============ NETWORK ERROR ============
          // Keep in queue, retry indefinitely, don't block other items
          // 🔴 NEW: Cap retry counter to prevent overflow
          _retryCounters[retryKey] = (retryCount + 1).clamp(0, _maxRetryCount);
          circuitBreaker.recordNetworkError(
            onBreadcrumb: _onSyncBreadcrumb,
            logger: _logger,
          );

          _logger.info(
            '🌐 Network error for item ${item.id} - keeping in queue (retry #${retryCount + 1})',
          );

          // ⚠️ CRITICAL: Use continue, NOT break!
          // This allows processing other items even if one fails
          continue;
        } else {
          // ============ APPLICATION ERROR ============
          // Move to error queue after N retries
          // 🔴 NEW: Cap retry counter to prevent overflow
          _retryCounters[retryKey] = (retryCount + 1).clamp(0, _maxRetryCount);

          if (retryCount >= 2) {
            // 3 total attempts (0, 1, 2)
            // Move to error queue
            errorQueue[item.id] = item;
            outQueue.remove(item.id);
            _retryCounters.remove(retryKey);

            // 🔴 NEW: Track permanently to prevent re-injection after cleanup
            final permanentErrorIds = _permanentErrorItemIds[syncable]!;
            permanentErrorIds.add(item.id);

            _logger.severe(
              '🔴 APPLICATION ERROR for item ${item.id} after ${retryCount + 1} attempts - '
              'moved to error queue and permanent error tracking. Error: $e\n'
              'Stack trace: $stackTrace',
            );

            // 🔴 NEW: Save to Dead Letter Queue (SQLite)
            if (_deadLetterQueue != null) {
              await _deadLetterQueue!.saveFailedItem(
                tableName: backendTable,
                itemId: item.id,
                itemJson: item.toJson(),
                errorType: errorType.toString(),
                errorMessage: e.toString(),
                stackTrace: stackTrace.toString(),
                retryCount: retryCount + 1,
              );
            } else {
              _logger.warning(
                '⚠️ Dead Letter Queue not initialized - error not persisted to DB',
              );
            }

            // 🔴 Breadcrumb: Item moved to DLQ
            try {
              _onSyncBreadcrumb?.call(
                message:
                    'Item moved to Dead Letter Queue after ${retryCount + 1} failed attempts',
                category: 'sync',
                level: 'error',
                data: {
                  'table': backendTable,
                  'item_id': item.id,
                  'error_type': errorType.toString(),
                  'retry_count': retryCount + 1,
                },
              );
            } catch (callbackError, callbackStack) {
              _logger.warning(
                'Error in onSyncBreadcrumb callback: $callbackError\n$callbackStack',
              );
            }

            // 🔴 NEW: Notify monitoring system (Sentry) via callback
            // Only notify for application errors (not network errors)
            try {
              _onDLQError?.call(
                tableName: backendTable,
                itemId: item.id,
                itemJson: item.toJson(),
                errorType: errorType.toString(),
                errorMessage: e.toString(),
                stackTrace: stackTrace.toString(),
                retryCount: retryCount + 1,
              );
            } catch (callbackError, callbackStack) {
              _logger.severe(
                'Error in onDLQError callback: $callbackError\n$callbackStack',
              );
            }
          } else {
            _logger.warning(
              '⚠️ Application error for item ${item.id} - will retry (attempt ${retryCount + 1}/3)',
            );
          }

          // ⚠️ CRITICAL: Use continue, NOT break!
          continue;
        }
      }
    }

    // Log final status
    if (outQueue.isNotEmpty) {
      _logger.info(
        '📊 $backendTable: ${outQueue.length} items remaining in queue, '
        '${errorQueue.length} in error queue',
      );
    }
  }

  Future<void> _processIncoming(Type syncable) async {
    final inQueue = _inQueues[syncable]!;
    final backendTable = _backendTables[syncable]!;

    if (inQueue.isEmpty) return;

    _logger.fine(
      '📥 Processing ${inQueue.length} incoming items for $backendTable',
    );

    final sentItems = _sentItems[syncable]!;
    final receivedItems = _receivedItems[syncable]!;

    final itemsToWrite = <String, Syncable>{};
    var syncSource = SyncEventSource.fullSync; // Default

    for (final item in inQueue) {
      // Skip only if already received from backend
      if (receivedItems.contains(item)) {
        _logger.fine('⏭️ Skipping already received item: ${item.id}');
        continue;
      }

      // Log if item was sent locally but is now being received from backend
      if (sentItems.contains(item)) {
        _logger.fine(
          '🔄 Processing server confirmation for locally sent item: ${item.id}',
        );
      } else {
        _logger.fine('✅ Adding new item from backend: ${item.id}');
      }

      itemsToWrite[item.id] = item;

      // Use the first item's source as the batch source (only if detailed events are enabled)
      if (_enableDetailedEvents && itemsToWrite.length == 1) {
        final incomingSources = _incomingSources[syncable]!;
        syncSource = incomingSources[item.id] ?? SyncEventSource.fullSync;
      }
    }

    // Clear queue BEFORE attempting writes
    // If writes fail, items will need to be re-fetched from backend
    inQueue.clear();

    // Clean up source tracking for processed items (only if detailed events are enabled)
    if (_enableDetailedEvents) {
      final incomingSources = _incomingSources[syncable]!;
      for (final itemId in itemsToWrite.keys) {
        incomingSources.remove(itemId);
      }
    }

    if (itemsToWrite.isEmpty) return;

    // 🔴 NEW: Try to write items with error handling
    try {
      final writeStats = await _batchWriteIncoming(syncable, itemsToWrite);

      receivedItems.addAll(itemsToWrite.values);
      _nSyncedFromBackend[syncable] =
          nSyncedFromBackend(syncable) + itemsToWrite.length;

      _logger.info(
        '✅ Successfully wrote ${itemsToWrite.length} items from backend to local DB '
        '(${writeStats.itemsInserted} inserted, ${writeStats.itemsUpdated} updated)',
      );

      // Emit sync completed event with real statistics (only if detailed events are enabled)
      if (_enableDetailedEvents && _onSyncCompleted != null) {
        final event = SyncCompletedEvent(
          syncableType: syncable,
          source: syncSource,
          timestamp: DateTime.now().toUtc(),
          itemsReceived: writeStats.itemsInserted,
          itemsUpdated: writeStats.itemsUpdated,
          itemsDeleted: 0, // Not implemented yet
        );
        _onSyncCompleted(event);
      }
    } catch (e, stackTrace) {
      // 🔴 NEW: Handle errors during local database writes
      final errorType = SyncErrorClassifier.classify(e);

      _logger.severe(
        '❌ Error writing ${itemsToWrite.length} items to local DB for $backendTable '
        '(type: $errorType): $e\n'
        'Stack trace: $stackTrace',
      );

      // For incoming data errors, we log but don't retry automatically
      // The data will be re-fetched on the next full sync
      // This is safer than risking data corruption or infinite loops

      if (errorType == SyncErrorType.application) {
        _logger.severe(
          '🔴 APPLICATION ERROR writing incoming data - this may indicate '
          'database corruption or schema mismatch. Items will be re-fetched on next sync.',
        );
        // TODO: Send Sentry alert in Phase 2
      }
    }
  }

  /// Processes incoming items immediately for a specific syncable type.
  ///
  /// This method is called when items arrive via Realtime subscriptions to
  /// provide instant UI updates instead of waiting for the next sync loop iteration.
  ///
  /// Unlike [_processIncoming], this only processes items for one syncable type
  /// and is designed to be called asynchronously without blocking the Realtime callback.
  Future<void> _processIncomingImmediate(Type syncable) async {
    if (!_syncingEnabled) {
      print('⚠️ [Syncable] Skipping immediate processing - syncing disabled');
      return;
    }

    print(
      '⚡ [Syncable] IMMEDIATE processing triggered for ${syncable.toString()}',
    );

    // Process this specific syncable immediately
    await _processIncoming(syncable);

    print(
      '✅ [Syncable] IMMEDIATE processing completed for ${syncable.toString()}',
    );
  }

  // ============= ADAPTIVE SYNC HELPER METHODS =============

  /// Determines the current sync mode based on the time since last change.
  ///
  /// - ACTIVE: Last change < 10 seconds (sync every 5s)
  /// - RECENT: Last change between 10s and 2 minutes (sync every 15s)
  /// - IDLE: No change for > 2 minutes (sync every 30s)
  SyncMode _getCurrentMode() {
    if (_lastChangeDetected == null) {
      return SyncMode.idle;
    }

    final timeSinceLastChange = DateTime.now().difference(_lastChangeDetected!);

    if (timeSinceLastChange < const Duration(seconds: 10)) {
      return SyncMode.active;
    } else if (timeSinceLastChange < const Duration(minutes: 2)) {
      return SyncMode.recent;
    } else {
      return SyncMode.idle;
    }
  }

  /// Returns the sync interval for the given mode.
  ///
  /// If a custom syncInterval was provided (not the default 1s), it will be used
  /// instead of the adaptive intervals. This ensures backward compatibility with
  /// tests and allows users to override the adaptive behavior.
  Duration _getIntervalForMode(SyncMode mode) {
    // Use custom interval if explicitly provided (not the default)
    if (_syncInterval != const Duration(seconds: 1)) {
      return _syncInterval;
    }

    // Otherwise use adaptive intervals based on activity
    switch (mode) {
      case SyncMode.active:
        return const Duration(seconds: 5);
      case SyncMode.recent:
        return const Duration(seconds: 15);
      case SyncMode.idle:
        return const Duration(seconds: 30);
    }
  }

  /// Triggers an immediate sync by completing the sync trigger.
  ///
  /// This wakes up the sync loop before the normal interval expires,
  /// allowing for faster sync when changes are detected.
  void _triggerImmediateSync() {
    if (_syncTrigger != null && !_syncTrigger!.isCompleted) {
      _syncTrigger!.complete();
    }
  }

  Future<WriteStats> _batchWriteIncoming<S extends Syncable>(
    Type syncable,
    Map<String, S> incomingItems,
  ) async {
    if (incomingItems.isEmpty) {
      return const WriteStats(itemsInserted: 0, itemsUpdated: 0);
    }

    final table = _localTables[syncable]! as TableInfo<SyncableTable, S>;

    final existingItems =
        await (_localDb.select(
          table,
        )..where((tbl) => tbl.id.isIn(incomingItems.keys))).get().then(
          (items) =>
              Map.fromEntries(items.map((i) => MapEntry(i.id, i.updatedAt))),
        );

    final itemsToInsert = <UpdateCompanion<Syncable>>[];
    final itemsToReplace = <UpdateCompanion<Syncable>>[];

    for (final incomingItem in incomingItems.values) {
      final existingUpdatedAt = existingItems[incomingItem.id];
      if (existingUpdatedAt == null) {
        print('🔧 [Syncable] Inserting new item: ${incomingItem.id}');
        itemsToInsert.add(incomingItem.toCompanion());
      } else if (incomingItem.updatedAt.isAfter(existingUpdatedAt)) {
        print(
          '🔧 [Syncable] Updating item: ${incomingItem.id} (${incomingItem.updatedAt} > $existingUpdatedAt)',
        );
        itemsToReplace.add(incomingItem.toCompanion());
      } else {
        print(
          '❌ [Syncable] SKIPPING item: ${incomingItem.id} - incoming: ${incomingItem.updatedAt}, existing: $existingUpdatedAt',
        );
      }
    }

    await _localDb.batch((batch) {
      batch.insertAll(table, itemsToInsert);
      batch.replaceAll(table, itemsToReplace);
    });

    return WriteStats(
      itemsInserted: itemsToInsert.length,
      itemsUpdated: itemsToReplace.length,
    );
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

  String _keyForPersistentStorage(TimestampType type, Type syncable) {
    return 'syncable_${userId}_${type.name}_${_localTables[syncable]!.actualTableName}';
  }

  bool _otherDevicesActive() {
    // Assume other devices are active if we don't have a timestamp for the last
    // time they were active.
    if (lastTimeOtherDeviceWasActive == null) return true;
    return DateTime.now().difference(lastTimeOtherDeviceWasActive!) <
        _devicesConsideredInactiveAfter;
  }

  /// Clears all internal sync state collections to ensure a clean sync state.
  ///
  /// This should be called during user authentication changes to prevent
  /// newly synchronized items from being treated as "already processed"
  /// due to persistent state from previous sync sessions.
  void clearSyncState() {
    _logger.info('Clearing sync state collections for clean authentication');

    // Clear tracking collections for all syncable types
    for (final syncable in _syncables) {
      _inQueues[syncable]?.clear();
      _outQueues[syncable]?.clear();
      _incomingSources[syncable]?.clear();
      _sentItems[syncable]?.clear();
      _receivedItems[syncable]?.clear();

      // 🔴 NEW: Clear error management structures
      _errorQueues[syncable]?.clear();
      _permanentErrorItemIds[syncable]?.clear();
      _circuitBreakers[syncable]?.reset();
    }

    // Reset sync counters
    _nSyncedToBackend.clear();
    _nSyncedFromBackend.clear();

    // 🔴 NEW: Clear retry counters
    _retryCounters.clear();

    _logger.info(
      'Sync state cleared successfully (including error queues, permanent error tracking, and retry counters)',
    );
  }
}

typedef CompanionConstructor =
    Object Function({
      Value<int> rowid,
      Value<String> id,
      Value<String?> userId,
      Value<DateTime> updatedAt,
      Value<bool> deleted,
    });

enum TimestampType {
  lastSyncFromBackend('lastSyncFromBackend'),
  lastSyncToBackend('lastSyncToBackend');

  const TimestampType(this.name);
  final String name;
}

/// Statistics returned by batch write operations.
class WriteStats {
  const WriteStats({required this.itemsInserted, required this.itemsUpdated});

  final int itemsInserted;
  final int itemsUpdated;
}
