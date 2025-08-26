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

void main() {
  late TestDatabase testDb;
  late MockSupabaseClient mockSupabaseClient;
  late MockSupabaseQueryBuilder mockQueryBuilder;
  late MockClient mockHttpClient;

  setUp(() {
    testDb = TestDatabase(
      drift.DatabaseConnection(
        drift_native.NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      ),
    );

    // Set up mocks for Supabase
    mockSupabaseClient = MockSupabaseClient();
    mockQueryBuilder = MockSupabaseQueryBuilder();
    mockHttpClient = MockClient();

    when(
      mockSupabaseClient.from(itemsTable),
    ).thenAnswer((_) => mockQueryBuilder);
    when(
      mockQueryBuilder.upsert(any, onConflict: anyNamed('onConflict')),
    ).thenAnswer(
      (_) => PostgrestFilterBuilder(
        PostgrestBuilder(
          url: Uri(),
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
          headers: {},
          method: 'GET',
          httpClient: mockHttpClient,
        ),
      ),
    );
    when(mockHttpClient.get(any, headers: anyNamed('headers'))).thenAnswer(
      (_) async =>
          Response(jsonEncode([]), 200, request: Request('GET', Uri())),
    );

    // Set up mocks for real-time
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
    when(
      mockRealtimeChannel.subscribe(),
    ).thenAnswer((_) => mockRealtimeChannel);
  });

  tearDown(() async {
    await testDb.close();
  });

  test('SyncManager calls onSyncStarted callback when sync begins', () async {
    final syncStartedEvents = <SyncStartedEvent>[];

    final syncManager = SyncManager(
      localDatabase: testDb,
      supabaseClient: mockSupabaseClient,
      syncInterval: const Duration(milliseconds: 1),
      onSyncStarted: (event) {
        syncStartedEvents.add(event);
      },
    );

    syncManager.registerSyncable<Item>(
      backendTable: itemsTable,
      fromJson: Item.fromJson,
      companionConstructor: ItemsCompanion.new,
    );

    final userId = const Uuid().v4();

    syncManager.enableSync();
    syncManager.setUserId(userId);

    await waitForFunctionToPass(() async {
      expect(syncStartedEvents.length, greaterThanOrEqualTo(1));
    });

    final event = syncStartedEvents.first;
    expect(event.type, equals(SyncEventType.syncStarted));
    expect(event.syncableType, equals(Item));
    expect(event.source, equals(SyncEventSource.fullSync));
    expect(event.reason, isNotEmpty);
  });

  test(
    'SyncManager calls onSyncCompleted callback when sync completes',
    () async {
      final syncCompletedEvents = <SyncCompletedEvent>[];

      final syncManager = SyncManager(
        localDatabase: testDb,
        supabaseClient: mockSupabaseClient,
        syncInterval: const Duration(milliseconds: 1),
        onSyncCompleted: (event) {
          syncCompletedEvents.add(event);
        },
      );

      syncManager.registerSyncable<Item>(
        backendTable: itemsTable,
        fromJson: Item.fromJson,
        companionConstructor: ItemsCompanion.new,
      );

      final userId = const Uuid().v4();

      syncManager.enableSync();
      syncManager.setUserId(userId);

      await waitForFunctionToPass(() async {
        expect(syncCompletedEvents.length, greaterThanOrEqualTo(1));
      });

      final event = syncCompletedEvents.first;
      expect(event.type, equals(SyncEventType.syncCompleted));
      expect(event.syncableType, equals(Item));
      expect(event.source, equals(SyncEventSource.fullSync));
    },
  );

  test('Callback parameters are correctly typed', () async {
    // Test that callback parameter types are working correctly
    SyncStartedEvent? startedEvent;
    SyncCompletedEvent? completedEvent;

    final syncManager = SyncManager(
      localDatabase: testDb,
      supabaseClient: mockSupabaseClient,
      syncInterval: const Duration(milliseconds: 1),
      onSyncStarted: (event) {
        startedEvent = event;
      },
      onSyncCompleted: (event) {
        completedEvent = event;
      },
    );

    syncManager.registerSyncable<Item>(
      backendTable: itemsTable,
      fromJson: Item.fromJson,
      companionConstructor: ItemsCompanion.new,
    );

    final userId = const Uuid().v4();

    syncManager.enableSync();
    syncManager.setUserId(userId);

    await waitForFunctionToPass(() async {
      expect(startedEvent, isNotNull);
      expect(completedEvent, isNotNull);
    });

    expect(startedEvent?.reason, isNotEmpty);
    expect(
      completedEvent?.totalItemsProcessed,
      equals(0),
    ); // No items from mock
  });

  test('Sync events contain proper timestamps', () async {
    final events = <SyncEvent>[];
    final testStartTime = DateTime.now().toUtc();

    final syncManager = SyncManager(
      localDatabase: testDb,
      supabaseClient: mockSupabaseClient,
      syncInterval: const Duration(milliseconds: 1),
      onSyncStarted: (event) => events.add(event),
      onSyncCompleted: (event) => events.add(event),
    );

    syncManager.registerSyncable<Item>(
      backendTable: itemsTable,
      fromJson: Item.fromJson,
      companionConstructor: ItemsCompanion.new,
    );

    final userId = const Uuid().v4();

    syncManager.enableSync();
    syncManager.setUserId(userId);

    await waitForFunctionToPass(() async {
      expect(events.length, greaterThanOrEqualTo(1));
    });

    for (final event in events) {
      expect(event.timestamp.isAfter(testStartTime), isTrue);
      expect(
        event.timestamp.isBefore(
          DateTime.now().toUtc().add(const Duration(seconds: 1)),
        ),
        isTrue,
      );
    }
  });
}
