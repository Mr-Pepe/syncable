import 'dart:async';

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart' as drift_native;
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'utils/test_database.dart';

void main() {
  late TestDatabase testDb;

  setUp(() {
    testDb = TestDatabase(
      drift.DatabaseConnection(
        drift_native.NativeDatabase.memory(),
        // closeStreamsSynchronously: true,
      ),
    );
  });

  tearDown(() async {
    await testDb.close();
  });

  test('Get item from database', () async {
    final itemId = const Uuid().v4();

    await testDb
        .into(testDb.items)
        .insert(
          ItemsCompanion(
            id: drift.Value(itemId),
            updatedAt: drift.Value(DateTime.now()),
            name: const drift.Value('Test Item'),
          ),
        );

    final item = await testDb.getItem(testDb.items, itemId);

    expect(item, isA<Item>());
    expect(item.id, itemId);
  });

  test('Clear database', () async {
    await testDb
        .into(testDb.items)
        .insert(
          ItemsCompanion(
            id: drift.Value(const Uuid().v4()),
            updatedAt: drift.Value(DateTime.now()),
            name: const drift.Value('Test Item'),
          ),
        );

    expect(await testDb.select(testDb.items).get(), isNotEmpty);

    await testDb.clear();

    expect(await testDb.select(testDb.items).get(), isEmpty);
  });

  test('Subscribe to table', () async {
    Completer<List<Item>> items = Completer();

    testDb.subscribe<Item>(
      table: testDb.items,
      filter: (row) => row.deleted.equals(false),
      onChange: (rows) {
        items.complete(rows.cast());
      },
    );

    final itemId1 = const Uuid().v4();

    await testDb
        .into(testDb.items)
        .insert(
          ItemsCompanion(
            id: drift.Value(itemId1),
            updatedAt: drift.Value(DateTime.now()),
            name: const drift.Value('Test Item 1'),
          ),
        );

    final item1 = await testDb.getItem(testDb.items, itemId1);

    expect(await items.future, equals([item1]));

    items = Completer();

    final itemId2 = const Uuid().v4();

    await testDb
        .into(testDb.items)
        .insert(
          ItemsCompanion(
            id: drift.Value(itemId2),
            updatedAt: drift.Value(DateTime.now()),
            name: const drift.Value('Test Item 2'),
          ),
        );

    final item2 = await testDb.getItem(testDb.items, itemId2);

    expect(await items.future, equals([item1, item2]));
  });

  test('Get table', () {
    expect(testDb.getTable<Item>(), isA<$ItemsTable>());
  });
}
