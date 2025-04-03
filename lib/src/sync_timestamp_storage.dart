abstract class SyncTimestampStorage {
  Future<void> setSyncTimestamp(String key, DateTime timestamp);

  DateTime? getSyncTimestamp(String key);
}
