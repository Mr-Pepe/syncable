import 'dart:async';
import 'dart:io';
import 'package:supabase/supabase.dart';

/// Type d'erreur de synchronisation
enum SyncErrorType {
  /// Erreur réseau (pas de connexion, timeout, backend down)
  /// Ces erreurs doivent être retentées indéfiniment
  network,

  /// Erreur applicative (validation, permissions, données corrompues)
  /// Ces erreurs doivent être déplacées vers une queue d'erreurs après N tentatives
  application,
}

/// Classification des erreurs de synchronisation
///
/// Cette classe permet de distinguer les erreurs réseau (temporaires, à retenter indéfiniment)
/// des erreurs applicatives (bugs, validation, à traiter manuellement).
class SyncErrorClassifier {
  /// Classifie une erreur en type réseau ou applicatif
  ///
  /// Erreurs réseau :
  /// - SocketException
  /// - HttpException (connection timeout, refused, etc.)
  /// - ClientException avec message réseau
  /// - Status codes HTTP : 502, 503, 504 (backend down)
  /// - Timeout exceptions
  ///
  /// Erreurs applicatives :
  /// - Status codes HTTP : 400, 422 (validation)
  /// - Status codes HTTP : 403, 401 (permissions)
  /// - Status codes HTTP : 500 avec message non-réseau
  /// - FormatException (parsing JSON)
  /// - DatabaseException (contraintes locales)
  static SyncErrorType classify(Object error) {
    // 1. Erreurs réseau évidentes
    if (error is SocketException) {
      return SyncErrorType.network;
    }

    if (error is HttpException) {
      return SyncErrorType.network;
    }

    // 2. Timeout = réseau
    if (error is TimeoutException) {
      return SyncErrorType.network;
    }

    // 3. Supabase exceptions
    if (error is PostgrestException) {
      return _classifyPostgrestException(error);
    }

    // 4. Analyse du message d'erreur
    final errorMessage = error.toString().toLowerCase();

    // Patterns d'erreurs réseau
    if (_isNetworkErrorMessage(errorMessage)) {
      return SyncErrorType.network;
    }

    // 5. Par défaut, considérer comme erreur applicative
    // (plus sûr d'avoir un faux positif applicatif que de bloquer indéfiniment)
    return SyncErrorType.application;
  }

  /// Classifie une exception Supabase/Postgrest
  static SyncErrorType _classifyPostgrestException(PostgrestException error) {
    final code = error.code;
    final message = error.message.toLowerCase();

    // Status codes réseau
    if (code == '502' || code == '503' || code == '504') {
      return SyncErrorType.network;
    }

    // Status codes applicatifs
    if (code == '400' || code == '422' || code == '401' || code == '403') {
      return SyncErrorType.application;
    }

    // Analyse du message pour 500
    if (code == '500') {
      if (_isNetworkErrorMessage(message)) {
        return SyncErrorType.network;
      }
      return SyncErrorType.application;
    }

    // Messages spécifiques réseau
    if (_isNetworkErrorMessage(message)) {
      return SyncErrorType.network;
    }

    // Par défaut pour erreurs Postgrest : applicatif
    return SyncErrorType.application;
  }

  /// Détecte si un message d'erreur indique un problème réseau
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

  /// Obtient un message d'erreur lisible pour l'utilisateur
  static String getUserFriendlyMessage(Object error, SyncErrorType type) {
    if (type == SyncErrorType.network) {
      return 'Problème de connexion réseau. La synchronisation reprendra automatiquement.';
    }

    // Erreur applicative
    if (error is PostgrestException) {
      switch (error.code) {
        case '400':
        case '422':
          return "Données invalides. Veuillez vérifier vos modifications.";
        case '401':
        case '403':
          return "Accès refusé. Vérifiez vos permissions.";
        default:
          return 'Erreur lors de la synchronisation. L\'administrateur a été notifié.';
      }
    }

    return 'Erreur lors de la synchronisation. L\'administrateur a été notifié.';
  }

  /// Obtient un message technique pour les logs
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
