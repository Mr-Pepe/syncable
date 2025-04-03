import 'dart:convert';

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart' as drift_native;
import 'package:http/http.dart';
import 'package:mockito/mockito.dart';
import 'package:supabase/supabase.dart';
import 'package:syncable/src/supabase_names.dart';
import 'package:syncable/syncable.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'utils/test_database.dart';
import 'utils/test_mocks.mocks.dart';
import 'utils/test_supabase_names.dart';
import 'utils/wait_for_function_to_pass.dart';

class TimestampStorage extends SyncTimestampStorage {
  final Map<String, DateTime> _timestamps = {};

  @override
  Future<void> setSyncTimestamp(String key, DateTime timestamp) async {
    _timestamps[key] = timestamp;
  }

  @override
  DateTime? getSyncTimestamp(String key) {
    return _timestamps[key];
  }
}

void main() {
  late TestDatabase testDb;

  late MockSupabaseClient mockSupabaseClient;
  late MockSupabaseQueryBuilder mockQueryBuilder;
  late MockClient mockHttpClient;

  setUp(() async {
    testDb = TestDatabase(
      drift.DatabaseConnection(
        drift_native.NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      ),
    );

    // Set up mocks for Supabase to allow upserting things
    mockSupabaseClient = MockSupabaseClient();
    mockQueryBuilder = MockSupabaseQueryBuilder();
    mockHttpClient = MockClient();

    when(mockSupabaseClient.from(itemsTable))
        .thenAnswer((_) => mockQueryBuilder);
    when(mockQueryBuilder.upsert(any, onConflict: anyNamed('onConflict')))
        .thenAnswer(
      (_) => PostgrestFilterBuilder(
        PostgrestBuilder(
          url: Uri(),
          // ignore: prefer_const_literals_to_create_immutables
          headers: {},
          method: 'POST',
          httpClient: mockHttpClient,
        ),
      ),
    );
    when(
      mockHttpClient.post(
        any,
        headers: anyNamed('headers'),
        body: anyNamed('body'),
      ),
    ).thenAnswer(
      (_) async => Response(
        jsonEncode([
          {idKey: 'abc'},
        ]),
        200,
        request: Request('POST', Uri()),
      ),
    );
    when(mockQueryBuilder.select(any)).thenAnswer(
      (_) => PostgrestFilterBuilder(
        PostgrestBuilder(
          url: Uri(),
          // ignore: prefer_const_literals_to_create_immutables
          headers: {},
          method: 'GET',
          httpClient: mockHttpClient,
        ),
      ),
    );
    when(
      mockHttpClient.get(
        any,
        headers: anyNamed('headers'),
      ),
    ).thenAnswer(
      (_) async => Response(
        jsonEncode([]),
        200,
        request: Request('GET', Uri()),
      ),
    );

    // Set up mocks for Supabase to allow listening to changes in the database
    final mockRealtimeChannel = MockRealtimeChannel();
    when(mockSupabaseClient.channel(any)).thenReturn(mockRealtimeChannel);
    when(
      mockRealtimeChannel.onPostgresChanges(
        schema: anyNamed('schema'),
        table: anyNamed('table'),
        event: anyNamed('event'),
        callback: anyNamed('callback'),
      ),
    ).thenReturn(mockRealtimeChannel);
    when(mockRealtimeChannel.subscribe())
        .thenAnswer((_) => mockRealtimeChannel);
  });

  tearDown(() async {
    await testDb.close();
  });

  test('Newly created items get sent to backend', () async {
    final syncManager = SyncManager(
      localDatabase: testDb,
      supabaseClient: mockSupabaseClient,
      syncInterval: const Duration(milliseconds: 1),
    );

    syncManager.registerSyncable<Item>(
      backendTable: itemsTable,
      fromJson: Item.fromJson,
      companionConstructor: ItemsCompanion.new,
    );

    final userId = const Uuid().v4();

    syncManager.enableSync();
    syncManager.setUserId(userId);

    expect(syncManager.nSyncedToBackend(Item), 0);

    final rowId = await testDb.into(testDb.items).insert(
          ItemsCompanion(
            userId: drift.Value(userId),
            updatedAt: drift.Value(DateTime.now()),
            deleted: const drift.Value(false),
            name: const drift.Value('Test Item'),
          ),
        );

    final item = await (testDb.select(testDb.items)
          ..where((tbl) => tbl.rowId.equals(rowId)))
        .getSingle();

    await waitForFunctionToPass(() async {
      expect(syncManager.nSyncedToBackend(Item), 1);
    });

    verify(
      mockQueryBuilder.upsert(
        [item.toJson()],
        onConflict: anyNamed('onConflict'),
      ),
    ).called(1);
  });

  test('Only subscribes to backend changes if other devices are active',
      () async {
    final syncManager = SyncManager<TestDatabase>(
      localDatabase: testDb,
      supabaseClient: mockSupabaseClient,
      syncInterval: const Duration(milliseconds: 1),
      otherDevicesConsideredInactiveAfter: const Duration(seconds: 1),
    );

    syncManager.registerSyncable<Item>(
      backendTable: itemsTable,
      fromJson: Item.fromJson,
      companionConstructor: ItemsCompanion.new,
    );

    syncManager.setUserId(const Uuid().v4());
    syncManager.enableSync();

    // Switch device presence back and forth to make sure that the subscription
    // gets added and removed as a response

    syncManager.setLastTimeOtherDeviceWasActive(DateTime.now().toUtc());
    await waitForFunctionToPass(() async {
      expect(syncManager.isSubscribedToBackend, isTrue);
    });

    syncManager.setLastTimeOtherDeviceWasActive(
      DateTime.now().subtract(const Duration(seconds: 2)).toUtc(),
    );
    await waitForFunctionToPass(() async {
      expect(syncManager.isSubscribedToBackend, isFalse);
    });

    syncManager.setLastTimeOtherDeviceWasActive(null);
    await waitForFunctionToPass(() async {
      expect(syncManager.isSubscribedToBackend, isTrue);
    });

    syncManager.setLastTimeOtherDeviceWasActive(
      DateTime.now().subtract(const Duration(seconds: 2)).toUtc(),
    );
    await waitForFunctionToPass(() async {
      expect(syncManager.isSubscribedToBackend, isFalse);
    });

    syncManager.setLastTimeOtherDeviceWasActive(DateTime.now().toUtc());
    await waitForFunctionToPass(() async {
      expect(syncManager.isSubscribedToBackend, isTrue);
    });
  });

  test('Skips explicit sync to backend if unnecessary due to sync timestamps',
      () async {
    final syncManager = SyncManager<TestDatabase>(
      localDatabase: testDb,
      supabaseClient: mockSupabaseClient,
      syncInterval: const Duration(milliseconds: 1),
      otherDevicesConsideredInactiveAfter: const Duration(seconds: 1),
      syncTimestampStorage: TimestampStorage(),
    );

    syncManager.registerSyncable<Item>(
      backendTable: itemsTable,
      fromJson: Item.fromJson,
      companionConstructor: ItemsCompanion.new,
    );

    expect(syncManager.nSyncedFromBackend(Item), 0);

    syncManager.setUserId(const Uuid().v4());
    syncManager.enableSync();

    final itemRowId = await testDb.into(testDb.items).insert(
          ItemsCompanion(
            userId: drift.Value(syncManager.userId),
            updatedAt: drift.Value(DateTime.now()),
            deleted: const drift.Value(false),
            name: const drift.Value('Local item 1'),
          ),
        );

    await waitForFunctionToPass(() async {
      expect(syncManager.nFullSyncs, 1);
      expect(syncManager.nSyncedToBackend(Item), 1);
    });

    await syncManager.syncTables();

    // Check that the item was not sent again despite explicit sync
    expect(syncManager.nFullSyncs, 2);
    expect(syncManager.isSyncingToBackend, isFalse);
    expect(syncManager.nSyncedToBackend(Item), 1);

    // Update the item to trigger a sync
    await (testDb.update(testDb.items)..where((i) => i.rowId.equals(itemRowId)))
        .write(
      ItemsCompanion(
        updatedAt: drift.Value(DateTime.now()),
      ),
    );

    await waitForFunctionToPass(() async {
      expect(syncManager.nSyncedToBackend(Item), 2);
    });
  });

  test('Skips explicit sync from backend if unnecessary due to sync timestamps',
      () async {
    final syncManager = SyncManager<TestDatabase>(
      localDatabase: testDb,
      supabaseClient: mockSupabaseClient,
      syncInterval: const Duration(milliseconds: 1),
      otherDevicesConsideredInactiveAfter: const Duration(seconds: 1),
      syncTimestampStorage: TimestampStorage(),
    );

    syncManager.registerSyncable<Item>(
      backendTable: itemsTable,
      fromJson: Item.fromJson,
      companionConstructor: ItemsCompanion.new,
    );

    syncManager.setUserId(const Uuid().v4());
    syncManager.enableSync();

    expect(syncManager.nSyncedFromBackend(Item), 0);

    final backendItem1 = Item(
      id: const Uuid().v4(),
      userId: syncManager.userId,
      updatedAt: DateTime.now(),
      deleted: false,
      name: 'Backend item 1',
    );

    when(mockHttpClient.get(any, headers: anyNamed('headers'))).thenAnswer(
      (_) async => Response(
        jsonEncode([backendItem1.toJson()]),
        200,
        request: Request('GET', Uri()),
      ),
    );

    await waitForFunctionToPass(() async {
      expect(syncManager.nFullSyncs, 1);
      expect(syncManager.nSyncedFromBackend(Item), 1);
    });

    await syncManager.syncTables();

    // Check that the item was pulled again despite explicit sync
    expect(syncManager.nFullSyncs, 2);
    expect(syncManager.isSyncingFromBackend, isFalse);
    expect(syncManager.nSyncedFromBackend(Item), 1);

    final backendItem2 = Item(
      id: const Uuid().v4(),
      userId: syncManager.userId,
      updatedAt: DateTime.now(),
      deleted: false,
      name: 'Backend item 2',
    );

    when(mockHttpClient.get(any, headers: anyNamed('headers'))).thenAnswer(
      (_) async => Response(
        jsonEncode([backendItem1.toJson(), backendItem2.toJson()]),
        200,
        request: Request('GET', Uri()),
      ),
    );

    // Setting a timestamp far in the past for the last time a device was active
    // must prevent a new sync
    syncManager.setLastTimeOtherDeviceWasActive(
      DateTime.now().subtract(const Duration(days: 2)).toUtc(),
    );

    await waitForFunctionToPass(() async {
      // Check that the item was pulled again despite explicit sync
      expect(syncManager.nFullSyncs, 3);
      expect(syncManager.isSyncingFromBackend, isFalse);
      expect(syncManager.nSyncedFromBackend(Item), 1);
    });

    // Setting a timestamp now for the last time a device was active
    // must trigger a new sync
    syncManager.setLastTimeOtherDeviceWasActive(DateTime.now().toUtc());
    await waitForFunctionToPass(() async {
      expect(syncManager.nFullSyncs, 4);
      expect(syncManager.isSyncingFromBackend, isFalse);
      expect(syncManager.nSyncedFromBackend(Item), 2);
    });
  });

  test('Items received from backend are not sent back', () async {
    final syncManager = SyncManager<TestDatabase>(
      localDatabase: testDb,
      supabaseClient: mockSupabaseClient,
      syncInterval: const Duration(milliseconds: 1),
      otherDevicesConsideredInactiveAfter: const Duration(seconds: 1),
    );

    syncManager.registerSyncable<Item>(
      backendTable: itemsTable,
      fromJson: Item.fromJson,
      companionConstructor: ItemsCompanion.new,
    );

    syncManager.setUserId(const Uuid().v4());
    final backendItem1 = Item(
      id: const Uuid().v4(),
      userId: syncManager.userId,
      updatedAt: DateTime.now(),
      deleted: false,
      name: 'Backend item 1',
    );

    when(mockHttpClient.get(any, headers: anyNamed('headers'))).thenAnswer(
      (_) async => Response(
        jsonEncode([backendItem1.toJson()]),
        200,
        request: Request('GET', Uri()),
      ),
    );

    syncManager.enableSync();

    for (final _ in List.generate(10, (_) => 0)) {
      expect(syncManager.isSyncingToBackend, isFalse);
      await Future.delayed(Duration.zero);
    }
  });

  test('Fill missing user ID for local tables', () async {
    final syncManager = SyncManager<TestDatabase>(
      localDatabase: testDb,
      supabaseClient: mockSupabaseClient,
      syncInterval: const Duration(milliseconds: 1),
    );

    syncManager.registerSyncable<Item>(
      backendTable: itemsTable,
      fromJson: Item.fromJson,
      companionConstructor: ItemsCompanion.new,
    );

    await testDb.into(testDb.items).insert(
          ItemsCompanion(
            updatedAt: drift.Value(DateTime.now()),
            name: const drift.Value('Test Item'),
          ),
        );

    expect((await testDb.select(testDb.items).getSingle()).userId, isNull);

    final userId = const Uuid().v4();
    syncManager.setUserId(userId);
    await syncManager.fillMissingUserIdForLocalTables();

    expect((await testDb.select(testDb.items).getSingle()).userId, userId);

    syncManager.enableSync();

    await waitForFunctionToPass(() async {
      expect(syncManager.nSyncedToBackend(Item), 1);
    });
  });

  test(
      'Trying to fill missing user IDs without first setting a user ID does not crash',
      () async {
    final syncManager = SyncManager<TestDatabase>(
      localDatabase: testDb,
      supabaseClient: mockSupabaseClient,
      syncInterval: const Duration(milliseconds: 1),
    );

    syncManager.registerSyncable<Item>(
      backendTable: itemsTable,
      fromJson: Item.fromJson,
      companionConstructor: ItemsCompanion.new,
    );

    await testDb.into(testDb.items).insert(
          ItemsCompanion(
            updatedAt: drift.Value(DateTime.now()),
            name: const drift.Value('Test Item'),
          ),
        );

    expect((await testDb.select(testDb.items).getSingle()).userId, isNull);

    await syncManager.fillMissingUserIdForLocalTables();

    expect((await testDb.select(testDb.items).getSingle()).userId, isNull);
  });

  test('Enabling syncing without registering syncables raises exception', () {
    final syncManager = SyncManager<TestDatabase>(
      localDatabase: testDb,
      supabaseClient: mockSupabaseClient,
      syncInterval: const Duration(milliseconds: 1),
    );

    expect(
      () => syncManager.enableSync(),
      throwsException,
    );
  });

  test('Registering syncable without generic parameter raises exception', () {
    final syncManager = SyncManager<TestDatabase>(
      localDatabase: testDb,
      supabaseClient: mockSupabaseClient,
      syncInterval: const Duration(milliseconds: 1),
    );
    expect(
      () => syncManager.registerSyncable(
        backendTable: itemsTable,
        fromJson: Item.fromJson,
        companionConstructor: ItemsCompanion.new,
      ),
      throwsException,
    );
  });

  test('Registering syncable after starting sync raises exception', () {
    final syncManager = SyncManager<TestDatabase>(
      localDatabase: testDb,
      supabaseClient: mockSupabaseClient,
      syncInterval: const Duration(milliseconds: 1),
    );

    syncManager.registerSyncable<Item>(
      backendTable: itemsTable,
      fromJson: Item.fromJson,
      companionConstructor: ItemsCompanion.new,
    );

    syncManager.enableSync();

    expect(
      () => syncManager.registerSyncable<Item>(
        backendTable: itemsTable,
        fromJson: Item.fromJson,
        companionConstructor: ItemsCompanion.new,
      ),
      throwsException,
    );
  });

  test('Exposes registered syncables', () {
    final syncManager = SyncManager<TestDatabase>(
      localDatabase: testDb,
      supabaseClient: mockSupabaseClient,
      syncInterval: const Duration(milliseconds: 1),
    );

    syncManager.registerSyncable<Item>(
      backendTable: itemsTable,
      fromJson: Item.fromJson,
      companionConstructor: ItemsCompanion.new,
    );

    expect(syncManager.syncables, equals([Item]));
  });
}
