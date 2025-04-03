/// Defines an interface for storing and retrieving sync timestamps.
///
/// Providing an instance of this class to a [SyncManager] can drastically
/// reduce the amount of data that needs to be synced because only changed data
/// since the last sync must be synced. Implementing a solution that persists
/// the timestamps across app restarts (e.g. via shared preferences) is
/// recommended.
abstract class SyncTimestampStorage {
  Future<void> setSyncTimestamp(String key, DateTime timestamp);

  DateTime? getSyncTimestamp(String key);
}
