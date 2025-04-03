import 'package:drift/drift.dart';

/// A Drift table that can be synchronized with a backend.
abstract class SyncableTable implements Table {
  TextColumn get id;
  TextColumn get userId;
  DateTimeColumn get updatedAt;
  BoolColumn get deleted;
}
