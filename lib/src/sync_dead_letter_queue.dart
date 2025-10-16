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
        INSERT OR REPLACE INTO sync_dead_letter_queue (
          id, table_name, item_json, error_type, error_message,
          retry_count, first_error_at, last_error_at, last_stack_trace, status
        ) VALUES (?, ?, ?, ?, ?, ?,
          COALESCE((SELECT first_error_at FROM sync_dead_letter_queue WHERE id = ?), ?),
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
      final result = await _database.customSelect(
        '''
        SELECT id, table_name, item_json, error_type, error_message,
               retry_count, first_error_at, last_error_at, last_stack_trace, status
        FROM sync_dead_letter_queue
        WHERE status = 'pending'
        ORDER BY last_error_at DESC
        ''',
      ).get();

      return result.map((row) => DeadLetterItem.fromRow(row)).toList();
    } catch (e, s) {
      _logger.severe('Failed to retrieve pending DLQ items: $e\n$s');
      return [];
    }
  }

  /// Gets count of pending items.
  Future<int> getPendingCount() async {
    try {
      final result = await _database.customSelect(
        'SELECT COUNT(*) as count FROM sync_dead_letter_queue WHERE status = \'pending\'',
      ).getSingle();

      return result.read<int>('count');
    } catch (e) {
      _logger.severe('Failed to get pending DLQ count: $e');
      return 0;
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
