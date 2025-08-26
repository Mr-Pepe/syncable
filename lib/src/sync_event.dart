/// The source of a sync event.
enum SyncEventSource {
  /// Data received from a realtime subscription to the backend.
  realtime,

  /// Data received from a full sync with the backend.
  fullSync,
}

/// The type of sync event.
enum SyncEventType {
  /// A sync operation started.
  syncStarted,

  /// A sync operation completed.
  syncCompleted,
}

/// An event that occurs during data synchronization.
abstract class SyncEvent {
  const SyncEvent({
    required this.type,
    required this.syncableType,
    required this.source,
    required this.timestamp,
  });

  /// The type of sync event.
  final SyncEventType type;

  /// The type of syncable that was affected.
  final Type syncableType;

  /// The source of the sync event.
  final SyncEventSource source;

  /// When the event occurred.
  final DateTime timestamp;
}

/// An event for when a sync operation starts.
class SyncStartedEvent extends SyncEvent {
  const SyncStartedEvent({
    required super.syncableType,
    required super.source,
    required super.timestamp,
    required this.reason,
  }) : super(type: SyncEventType.syncStarted);

  /// The reason why the sync started.
  final String reason;
}

/// An event for when a sync operation completes.
class SyncCompletedEvent extends SyncEvent {
  const SyncCompletedEvent({
    required super.syncableType,
    required super.source,
    required super.timestamp,
    required this.itemsReceived,
    required this.itemsUpdated,
    required this.itemsDeleted,
  }) : super(type: SyncEventType.syncCompleted);

  /// The number of items that were received (inserted) during this sync.
  final int itemsReceived;

  /// The number of items that were updated during this sync.
  final int itemsUpdated;

  /// The number of items that were deleted during this sync.
  final int itemsDeleted;

  /// The total number of items processed during this sync.
  int get totalItemsProcessed => itemsReceived + itemsUpdated + itemsDeleted;
}

/// Callback function for sync events.
typedef SyncEventCallback = void Function(SyncEvent event);

/// Callback function specifically for sync started events.
typedef SyncStartedEventCallback = void Function(SyncStartedEvent event);

/// Callback function specifically for sync completed events.
typedef SyncCompletedEventCallback = void Function(SyncCompletedEvent event);
