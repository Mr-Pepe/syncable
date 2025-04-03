import 'package:drift/drift.dart';

abstract class SyncableTable implements Table {
  TextColumn get id;
  TextColumn get userId;
  DateTimeColumn get updatedAt;
  BoolColumn get deleted;
}
