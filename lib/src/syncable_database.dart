import 'dart:async';

import 'package:drift/drift.dart';
import 'package:syncable/src/syncable.dart';
import 'package:syncable/src/syncable_table.dart';

mixin SyncableDatabase on GeneratedDatabase {
  final Map<
      (
        TableInfo<SyncableTable, Syncable>,
        Expression<bool> Function(SyncableTable)
      ),
      Stream<List<Syncable>>> _queryStreams = {};

  /// Retrieves a single item by its [id] from the local database [table].
  Future<T> getItem<T extends Syncable>(
    TableInfo<SyncableTable, T> table,
    String id,
  ) async {
    return await (select(table)..where((row) => row.id.equals(id))).getSingle();
  }

  /// Deletes all data from all tables.
  Future<void> clear() async {
    await transaction(() async {
      for (final table in allTables) {
        await delete(table).go();
      }
    });
  }

  /// Subscribes to [table] and listens for changes in it.
  /// On each change, rows get filtered with [filter] and then passed to
  /// [onChange].
  StreamSubscription<List<T>> subscribe<T extends Syncable>({
    required TableInfo<SyncableTable, T> table,
    required Expression<bool> Function(SyncableTable) filter,
    required void Function(List<T>) onChange,
  }) {
    if (!_queryStreams.containsKey((table, filter))) {
      final query = (select(table)
        ..where(filter)
        ..orderBy([(row) => OrderingTerm.asc(row.updatedAt)]));

      _queryStreams[(table, filter)] = query.watch();
    }

    final stream = _queryStreams[(table, filter)]! as Stream<List<T>>;

    return stream.listen((rows) {
      onChange(rows);
    });
  }

  TableInfo<SyncableTable, T> getTable<T extends Syncable>() {
    return allTables.whereType<TableInfo<SyncableTable, T>>().first;
  }
}
