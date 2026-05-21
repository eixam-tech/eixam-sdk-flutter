import '../entities/remote_relay_sos_snapshot.dart';

sealed class EixamSdkEvent {
  final DateTime timestamp;
  EixamSdkEvent({DateTime? timestamp})
      : timestamp = timestamp ?? DateTime.now();
}

class SOSTriggeredEvent extends EixamSdkEvent {
  final String incidentId;
  SOSTriggeredEvent(this.incidentId);
}

class SOSCancelledEvent extends EixamSdkEvent {
  final String incidentId;
  SOSCancelledEvent(this.incidentId);
}

class PositionUpdatedEvent extends EixamSdkEvent {
  PositionUpdatedEvent();
}

class DeviceDisconnectedEvent extends EixamSdkEvent {
  final String deviceId;
  DeviceDisconnectedEvent(this.deviceId);
}

class DeathManScheduledEvent extends EixamSdkEvent {
  final String planId;
  DeathManScheduledEvent(this.planId);
}

class DeathManStatusChangedEvent extends EixamSdkEvent {
  final String planId;
  final String status;
  DeathManStatusChangedEvent(this.planId, this.status);
}

class DeathManEscalatedEvent extends EixamSdkEvent {
  final String planId;
  DeathManEscalatedEvent(this.planId);
}

class RemoteRelaySosObservedEvent extends EixamSdkEvent {
  final RemoteRelaySosSnapshot snapshot;
  RemoteRelaySosObservedEvent(this.snapshot);
}

enum RemoteRelaySosBackendHandoffStatus { submitted, skipped, failed }

class RemoteRelaySosBackendHandoffResultEvent extends EixamSdkEvent {
  final RemoteRelaySosSnapshot snapshot;
  final RemoteRelaySosBackendHandoffStatus status;
  final String? deviceId;
  final int? statusCode;
  final String? incidentId;
  final String? reason;
  final String? errorMessage;
  final bool ackRelaySent;
  final String? ackRelayErrorMessage;

  RemoteRelaySosBackendHandoffResultEvent({
    required this.snapshot,
    required this.status,
    this.deviceId,
    this.statusCode,
    this.incidentId,
    this.reason,
    this.errorMessage,
    this.ackRelaySent = false,
    this.ackRelayErrorMessage,
  });
}

class RemoteRelaySosCancelHandoffResultEvent extends EixamSdkEvent {
  final int originatorNodeId;
  final int? relayNodeId;
  final String? deviceId;
  final RemoteRelaySosBackendHandoffStatus status;
  final String? reason;
  final String? errorMessage;
  final DateTime receivedAt;

  RemoteRelaySosCancelHandoffResultEvent({
    required this.originatorNodeId,
    required this.deviceId,
    required this.status,
    required this.receivedAt,
    this.relayNodeId,
    this.reason,
    this.errorMessage,
  });
}
