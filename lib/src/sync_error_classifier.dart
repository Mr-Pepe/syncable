import 'dart:async';
import 'dart:io';
import 'package:supabase/supabase.dart';

/// Synchronization error type
enum SyncErrorType {
  /// Network error (no connection, timeout, backend down)
  /// These errors should be retried indefinitely
  network,

  /// Application error (validation, permissions, corrupted data)
  /// These errors should be moved to an error queue after N attempts
  application,
}

/// Synchronization error classification
///
/// This class distinguishes between network errors (temporary, retry indefinitely)
/// and application errors (bugs, validation, handle manually).
class SyncErrorClassifier {
  /// Classifies an error as network or application type
  ///
  /// Network errors:
  /// - SocketException
  /// - HttpException (connection timeout, refused, etc.)
  /// - ClientException with network message
  /// - HTTP status codes: 502, 503, 504 (backend down)
  /// - Timeout exceptions
  ///
  /// Application errors:
  /// - HTTP status codes: 400, 422 (validation)
  /// - HTTP status codes: 403, 401 (permissions)
  /// - HTTP status codes: 500 with non-network message
  /// - FormatException (JSON parsing)
  /// - DatabaseException (local constraints)
  static SyncErrorType classify(Object error) {
    // 1. Obvious network errors
    if (error is SocketException) {
      return SyncErrorType.network;
    }

    if (error is HttpException) {
      return SyncErrorType.network;
    }

    // 2. Timeout = network
    if (error is TimeoutException) {
      return SyncErrorType.network;
    }

    // 3. Supabase exceptions
    if (error is PostgrestException) {
      return _classifyPostgrestException(error);
    }

    // 4. Error message analysis
    final errorMessage = error.toString().toLowerCase();

    // Network error patterns
    if (_isNetworkErrorMessage(errorMessage)) {
      return SyncErrorType.network;
    }

    // 5. By default, consider as application error
    // (safer to have a false positive application error than to block indefinitely)
    return SyncErrorType.application;
  }

  /// Classifies a Supabase/Postgrest exception
  static SyncErrorType _classifyPostgrestException(PostgrestException error) {
    final code = error.code;
    final message = error.message.toLowerCase();

    // Network status codes
    if (code == '502' || code == '503' || code == '504') {
      return SyncErrorType.network;
    }

    // Application status codes
    if (code == '400' || code == '422' || code == '401' || code == '403') {
      return SyncErrorType.application;
    }

    // Message analysis for 500
    if (code == '500') {
      if (_isNetworkErrorMessage(message)) {
        return SyncErrorType.network;
      }
      return SyncErrorType.application;
    }

    // Specific network messages
    if (_isNetworkErrorMessage(message)) {
      return SyncErrorType.network;
    }

    // Default for Postgrest errors: application
    return SyncErrorType.application;
  }

  /// Detects if an error message indicates a network problem
  static bool _isNetworkErrorMessage(String message) {
    final networkPatterns = [
      'network',
      'connection',
      'timeout',
      'unreachable',
      'refused',
      'socket',
      'dns',
      'host',
      'internet',
      'offline',
      'no connection',
      'could not connect',
      'failed to connect',
      'connection lost',
      'connection reset',
      'connection closed',
      'network is unreachable',
      'no route to host',
      'broken pipe',
      'connection timed out',
      'software caused connection abort',
    ];

    for (final pattern in networkPatterns) {
      if (message.contains(pattern)) {
        return true;
      }
    }

    return false;
  }

  /// Gets a user-readable error message
  static String getUserFriendlyMessage(Object error, SyncErrorType type) {
    if (type == SyncErrorType.network) {
      return 'Network connection problem. Synchronization will resume automatically.';
    }

    // Application error
    if (error is PostgrestException) {
      switch (error.code) {
        case '400':
        case '422':
          return 'Invalid data. Please verify your changes.';
        case '401':
        case '403':
          return 'Access denied. Check your permissions.';
        default:
          return 'Synchronization error. The administrator has been notified.';
      }
    }

    return 'Synchronization error. The administrator has been notified.';
  }

  /// Gets a technical message for logs
  static String getTechnicalMessage(Object error, StackTrace? stackTrace) {
    final buffer = StringBuffer();

    buffer.writeln('Error Type: ${error.runtimeType}');
    buffer.writeln('Error: $error');

    if (error is PostgrestException) {
      buffer.writeln('Code: ${error.code}');
      buffer.writeln('Message: ${error.message}');
      if (error.details != null) {
        buffer.writeln('Details: ${error.details}');
      }
      if (error.hint != null) {
        buffer.writeln('Hint: ${error.hint}');
      }
    }

    if (stackTrace != null) {
      buffer.writeln('Stack Trace:');
      buffer.writeln(stackTrace.toString());
    }

    return buffer.toString();
  }
}
