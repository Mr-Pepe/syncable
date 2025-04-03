import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:supabase/supabase.dart';
import 'package:syncable/src/supabase_names.dart';
import 'package:syncable/syncable.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'utils/test_database.dart';
import 'utils/test_supabase_names.dart';
import 'utils/wait_for_function_to_pass.dart';

Future<QueryExecutor> getDatabaseExecutor() async {
  return NativeDatabase.createInBackground(File('test_database.sqlite'));
}

void main() {
  late TestDatabase testDb;
  final supabaseClient = SupabaseClient(
    'http://127.0.0.1:54321',
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.'
        'eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.'
        'CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0',
  );

  late SyncManager syncManager;

  setUpAll(() async {
    testDb = TestDatabase(await getDatabaseExecutor());
  });

  setUp(() async {
    await supabaseClient.auth.signOut();
    await testDb.clear();

    syncManager = SyncManager(
      localDatabase: testDb,
      supabaseClient: supabaseClient,
    );

    syncManager.registerSyncable<Item>(
      backendTable: itemsTable,
      fromJson: Item.fromJson,
      companionConstructor: ItemsCompanion.new,
    );
  });

  tearDown(() async {
    syncManager.dispose();
  });

  tearDownAll(() async {
    await supabaseClient.auth.signOut();
    await testDb.close();
  });

  test('New and modified items get synced to backend', () async {
    await supabaseClient.auth.signInAnonymously();

    final userId = supabaseClient.auth.currentUser!.id;

    syncManager.setUserId(userId);
    syncManager.enableSync();

    await testDb.into(testDb.items).insert(
          ItemsCompanion(
            userId: Value(userId),
            updatedAt: Value(DateTime.now().toUtc()),
            name: const Value('a'),
          ),
        );

    await waitForFunctionToPass(() async {
      expect(syncManager.nSyncedToBackend(Item), 1);

      final backendItems = await _getBackendItems(supabaseClient, userId);

      expect(backendItems, hasLength(1));
      expect(backendItems.first.name, 'a');
    });

    await (testDb.update(testDb.items)..where((i) => i.name.equals('a'))).write(
      ItemsCompanion(
        updatedAt: Value(DateTime.now().toUtc()),
        name: const Value('b'),
      ),
    );

    await waitForFunctionToPass(() async {
      final backendItems = await _getBackendItems(supabaseClient, userId);

      expect(backendItems, hasLength(1));
      expect(backendItems.first.name, 'b');
    });
  });

  test('Backend rejects modifications with older timestamp', () async {
    await supabaseClient.auth.signInAnonymously();

    final userId = supabaseClient.auth.currentUser!.id;

    syncManager.setUserId(userId);
    syncManager.enableSync();
    syncManager.setLastTimeOtherDeviceWasActive(
      // Set a very old timestamp to prevent the sync manager from listening
      // to backend changes
      DateTime.now().toUtc().subtract(const Duration(days: 10)),
    );

    final currentTimestamp = DateTime.now().toUtc();
    final futureTimestamp = currentTimestamp.add(const Duration(hours: 1));

    await testDb.into(testDb.items).insert(
          ItemsCompanion(
            userId: Value(userId),
            updatedAt: Value(currentTimestamp),
            name: const Value('a'),
          ),
        );

    final localItem = await testDb.select(testDb.items).getSingle();

    await waitForFunctionToPass(() async {
      expect(syncManager.nSyncedToBackend(Item), 1);
      expect(
        await _getBackendItems(supabaseClient, userId),
        hasLength(1),
      );
    });

    // Update the item in the backend with a timestamp that is in the future
    await supabaseClient.from(itemsTable).update({
      nameKey: 'c',
      updatedAtKey: futureTimestamp.toIso8601String(),
    }).eq(idKey, localItem.id);

    await waitForFunctionToPass(() async {
      final Item backendItem =
          (await _getBackendItems(supabaseClient, userId)).first;

      expect(backendItem.name, 'c');
      expect(backendItem.updatedAt, futureTimestamp);
    });

    // Update the local item with a timestamp that is in the future but before
    // the one in the backend
    await (testDb.update(testDb.items)..where((i) => i.id.equals(localItem.id)))
        .write(
      ItemsCompanion(
        updatedAt: Value(currentTimestamp.add(const Duration(minutes: 30))),
        name: const Value('b'),
      ),
    );

    // The sync manager should try to push the local item with the new timestamp
    // to the backend, but the backend should reject it because the timestamp
    // is before the one in the backend
    await waitForFunctionToPass(() async {
      expect(syncManager.nSyncedToBackend(Item), 2);
    });

    final backendItem = (await _getBackendItems(supabaseClient, userId)).first;

    expect(backendItem.name, 'c');
    expect(backendItem.updatedAt, futureTimestamp);
  });

  test('Items from backend get synced to local database', () async {
    await supabaseClient.auth.signInAnonymously();

    final userId = supabaseClient.auth.currentUser!.id;

    syncManager.setUserId(userId);
    syncManager.enableSync();

    final timestamp = DateTime.now().toUtc();

    final item = Item(
      id: const Uuid().v4(),
      userId: userId,
      updatedAt: timestamp,
      deleted: false,
      name: 'a',
    );

    // Create new item in backend
    await supabaseClient.from(itemsTable).insert(item.toJson());

    // Wait for item to sync to local database
    await waitForFunctionToPass(() async {
      expect((await testDb.getItem(testDb.items, item.id)).name, 'a');
    });

    expect(syncManager.isSubscribedToBackend, isTrue);

    // Update item in backend
    await supabaseClient.from(itemsTable).update({
      nameKey: 'b',
      updatedAtKey: DateTime.now().toUtc().toIso8601String(),
    }).eq(idKey, item.id);

    // Wait for item to sync to local database
    await waitForFunctionToPass(() async {
      expect((await testDb.getItem(testDb.items, item.id)).name, 'b');
    });
  });

  test('Local database rejects items from backend with old modification dates',
      () async {
    await supabaseClient.auth.signInAnonymously();

    final userId = supabaseClient.auth.currentUser!.id;

    syncManager.setUserId(userId);
    syncManager.enableSync();

    final timestamp = DateTime.now().toUtc();

    final item = Item(
      id: const Uuid().v4(),
      userId: userId,
      updatedAt: timestamp,
      deleted: false,
      name: 'a',
    );

    // Create new item in backend
    await supabaseClient.from(itemsTable).insert(item.toJson());

    // Wait for item to sync to local database
    await waitForFunctionToPass(() async {
      expect((await testDb.getItem(testDb.items, item.id)).name, 'a');
    });

    // Disable sync, so that we can change the local item without syncing
    // it to the backend
    syncManager.disableSync();

    // Update item in local database
    await (testDb.update(testDb.items)..where((i) => i.id.equals(item.id)))
        .write(
      ItemsCompanion(
        updatedAt: Value(timestamp.add(const Duration(hours: 1))),
        name: const Value('b'),
      ),
    );

    // Update item in backend, but with a timestamp that is older than the
    // local item's modification date
    final newTimestamp = timestamp.add(const Duration(minutes: 30));

    await supabaseClient.from(itemsTable).update({
      nameKey: 'c',
      updatedAtKey: newTimestamp.toIso8601String(),
    }).eq(idKey, item.id);

    await waitForFunctionToPass(() async {
      expect((await _getBackendItems(supabaseClient, userId)).first.name, 'c');
    });

    expect(syncManager.nFullSyncs, 1);

    // Enable sync again
    syncManager.enableSync();

    // Wait for local to process the change
    await waitForFunctionToPass(() async {
      expect(syncManager.nFullSyncs, 2);
    });

    await Future.delayed(const Duration(milliseconds: 100));

    // Check that the local item was not updated
    expect((await testDb.select(testDb.items).getSingle()).name, 'b');
  });

  test('All items get synced to backend after setting their user ID', () async {
    await supabaseClient.auth.signInAnonymously();

    final userId = supabaseClient.auth.currentUser!.id;

    syncManager.setUserId(userId);
    syncManager.enableSync();

    // Create local item without user ID
    await testDb.into(testDb.items).insert(
          ItemsCompanion(
            userId: const Value(null),
            updatedAt: Value(DateTime.now().toUtc()),
            name: const Value('a'),
          ),
        );

    syncManager.fillMissingUserIdForLocalTables();

    await waitForFunctionToPass(() async {
      expect(syncManager.nSyncedToBackend(Item), 1);

      final backendItems = await _getBackendItems(supabaseClient, userId);

      expect(backendItems, hasLength(1));
      expect(backendItems.first.name, 'a');
    });
  });
}

Future<List<Item>> _getBackendItems(
  SupabaseClient supabaseClient,
  String userId,
) async {
  final response =
      await supabaseClient.from(itemsTable).select().eq(userIdKey, userId);

  return (response as List)
      .map((item) => Item.fromJson(item as Map<String, dynamic>))
      .toList();
}
