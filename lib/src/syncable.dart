import 'package:drift/drift.dart';

/// An entity that can be synchronized between a local database and the backend.
abstract class Syncable {
  String get id;
  String? get userId;
  DateTime get updatedAt;
  bool get deleted;

  /// Converts this object to a JSON representation to send it to the backend.
  Map<String, dynamic> toJson();

  /// Converts this object to a Drift companion object to write to the local
  /// database.
  UpdateCompanion<Syncable> toCompanion();
}
