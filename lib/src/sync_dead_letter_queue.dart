import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:logging/logging.dart';

/// Dead Letter Queue for sync errors that cannot be automatically resolved.
///
/// Items are moved here after multiple failed sync attempts (application errors).
/// Provides persistence and allows manual intervention via admin UI.
class SyncDeadLetterQueue {
  SyncDeadLetterQueue(this._database);

  final GeneratedDatabase _database;
  final _logger = Logger('SyncDeadLetterQueue');

  /// Saves a failed sync item to the dead letter queue.
  Future<void> saveFailedItem({
    required String tableName,
    required String itemId,
    required Map<String, dynamic> itemJson,
    required String errorType,
    required String errorMessage,
    String? stackTrace,
    required int retryCount,
  }) async {
    try {
      final now = DateTime.now().millisecondsSinceEpoch;

      await _database.customInsert(
        '''
        INSERT OR REPLACE INTO sync_dead_letter_queue_table (
          id, table_name, item_json, error_type, error_message,
          retry_count, first_error_at, last_error_at, last_stack_trace, status
        ) VALUES (?, ?, ?, ?, ?, ?,
          COALESCE((SELECT first_error_at FROM sync_dead_letter_queue_table WHERE id = ?), ?),
          ?, ?, 'pending')
        ''',
        variables: [
          Variable.withString('${tableName}__$itemId'),
          Variable.withString(tableName),
          Variable.withString(jsonEncode(itemJson)),
          Variable.withString(errorType),
          Variable.withString(errorMessage),
          Variable.withInt(retryCount),
          Variable.withString('${tableName}__$itemId'),
          Variable.withInt(now),
          Variable.withInt(now),
          Variable.withString(stackTrace ?? ''),
        ],
      );

      _logger.info('Saved failed item to DLQ: $tableName/$itemId');
    } catch (e, s) {
      _logger.severe('Failed to save item to dead letter queue: $e\n$s');
    }
  }

  /// Retrieves all pending items from the dead letter queue.
  Future<List<DeadLetterItem>> getPendingItems() async {
    try {
      final result = await _database.customSelect('''
        SELECT id, table_name, item_json, error_type, error_message,
               retry_count, first_error_at, last_error_at, last_stack_trace, status
        FROM sync_dead_letter_queue_table
        WHERE status = 'pending'
        ORDER BY last_error_at DESC
        ''').get();

      return result.map((row) => DeadLetterItem.fromRow(row)).toList();
    } catch (e, s) {
      _logger.severe('Failed to retrieve pending DLQ items: $e\n$s');
      return [];
    }
  }

  /// Gets count of pending items.
  Future<int> getPendingCount() async {
    try {
      final result = await _database
          .customSelect(
            'SELECT COUNT(*) as count FROM sync_dead_letter_queue_table WHERE status = \'pending\'',
          )
          .getSingle();

      return result.read<int>('count');
    } catch (e) {
      _logger.severe('Failed to get pending DLQ count: $e');
      return 0;
    }
  }

  /// Retrieves a failed item's JSON data for retry.
  ///
  /// ⚠️ IMPORTANT: Does NOT remove the item from DLQ.
  /// The caller (SyncService) must call deleteItem() after successful retry
  /// to avoid losing data if the retry fails.
  ///
  /// Returns the parsed item data to be re-queued by the caller.
  Future<Map<String, dynamic>?> retryItem(String itemId) async {
    try {
      // Retrieve item without deleting it
      final result = await _database.customSelect('''
        SELECT item_json FROM sync_dead_letter_queue_table WHERE id = ?
      ''', variables: [Variable.withString(itemId)]).getSingleOrNull();

      if (result == null) {
        _logger.warning('DLQ item not found for retry: $itemId');
        return null;
      }

      final itemJson = jsonDecode(result.read<String>('item_json')) as Map<String, dynamic>;

      _logger.info('Retrieved DLQ item for retry: $itemId');
      return itemJson;
    } catch (e, s) {
      _logger.severe('Failed to retrieve DLQ item for retry: $e\n$s');
      return null;
    }
  }

  /// Marks an item as ignored (status = 'ignored').
  /// The item stays in DLQ but won't be shown in pending list.
  Future<bool> ignoreItem(String itemId) async {
    try {
      await _database.customUpdate(
        'UPDATE sync_dead_letter_queue_table SET status = ? WHERE id = ?',
        variables: [
          Variable.withString('ignored'),
          Variable.withString(itemId),
        ],
      );

      _logger.info('Ignored DLQ item: $itemId');
      return true;
    } catch (e, s) {
      _logger.severe('Failed to ignore DLQ item: $e\n$s');
      return false;
    }
  }

  /// Permanently deletes an item from DLQ.
  /// Use this when the error is understood and the item should be discarded.
  Future<bool> deleteItem(String itemId) async {
    try {
      await _database.customStatement(
        'DELETE FROM sync_dead_letter_queue_table WHERE id = ?',
        [itemId], // customStatement expects raw values, not Variable<T>
      );

      _logger.info('Deleted DLQ item: $itemId');
      return true;
    } catch (e, s) {
      _logger.severe('Failed to delete DLQ item: $e\n$s');
      return false;
    }
  }
}

/// Represents an item in the dead letter queue.
class DeadLetterItem {
  const DeadLetterItem({
    required this.id,
    required this.tableName,
    required this.itemJson,
    required this.errorType,
    required this.errorMessage,
    required this.retryCount,
    required this.firstErrorAt,
    required this.lastErrorAt,
    this.lastStackTrace,
    required this.status,
  });

  final String id;
  final String tableName;
  final String itemJson;
  final String errorType;
  final String errorMessage;
  final int retryCount;
  final DateTime firstErrorAt;
  final DateTime lastErrorAt;
  final String? lastStackTrace;
  final String status;

  factory DeadLetterItem.fromRow(QueryRow row) {
    return DeadLetterItem(
      id: row.read<String>('id'),
      tableName: row.read<String>('table_name'),
      itemJson: row.read<String>('item_json'),
      errorType: row.read<String>('error_type'),
      errorMessage: row.read<String>('error_message'),
      retryCount: row.read<int>('retry_count'),
      firstErrorAt: DateTime.fromMillisecondsSinceEpoch(
        row.read<int>('first_error_at'),
      ),
      lastErrorAt: DateTime.fromMillisecondsSinceEpoch(
        row.read<int>('last_error_at'),
      ),
      lastStackTrace: row.readNullable<String>('last_stack_trace'),
      status: row.read<String>('status'),
    );
  }
}
