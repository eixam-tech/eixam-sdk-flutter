import '../entities/remote_relay_sos_snapshot.dart';

sealed class EixamSdkEvent {
  EixamSdkEvent({DateTime? timestamp})
      : timestamp = timestamp ?? DateTime.now();
  final DateTime timestamp;
}

class SOSTriggeredEvent extends EixamSdkEvent {
  SOSTriggeredEvent(this.incidentId);
  final String incidentId;
}

class SOSCancelledEvent extends EixamSdkEvent {
  SOSCancelledEvent(this.incidentId);
  final String incidentId;
}

class PositionUpdatedEvent extends EixamSdkEvent {
  PositionUpdatedEvent();
}

class DeviceDisconnectedEvent extends EixamSdkEvent {
  DeviceDisconnectedEvent(this.deviceId);
  final String deviceId;
}

class DeathManScheduledEvent extends EixamSdkEvent {
  DeathManScheduledEvent(this.planId);
  final String planId;
}

class DeathManStatusChangedEvent extends EixamSdkEvent {
  DeathManStatusChangedEvent(this.planId, this.status);
  final String planId;
  final String status;
}

class DeathManEscalatedEvent extends EixamSdkEvent {
  DeathManEscalatedEvent(this.planId);
  final String planId;
}

class RemoteRelaySosObservedEvent extends EixamSdkEvent {
  RemoteRelaySosObservedEvent(this.snapshot);
  final RemoteRelaySosSnapshot snapshot;
}

class RemoteRelaySosCancelledEvent extends EixamSdkEvent {

  RemoteRelaySosCancelledEvent({
    required this.originatorNodeId,
    required this.relayNodeId,
    required this.backendIncidentId,
    this.source = 'remote_lora_relay',
    this.terminal = 'cancelled',
    this.externalOnly = true,
  });
  final int originatorNodeId;
  final int? relayNodeId;
  final String? backendIncidentId;
  final String source;
  final String terminal;
  final bool externalOnly;
}

enum RemoteRelaySosBackendHandoffStatus { submitted, skipped, failed }

class RemoteRelaySosBackendHandoffResultEvent extends EixamSdkEvent {

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
  final RemoteRelaySosSnapshot snapshot;
  final RemoteRelaySosBackendHandoffStatus status;
  final String? deviceId;
  final int? statusCode;
  final String? incidentId;
  final String? reason;
  final String? errorMessage;
  final bool ackRelaySent;
  final String? ackRelayErrorMessage;
}

class RemoteRelaySosCancelHandoffResultEvent extends EixamSdkEvent {

  RemoteRelaySosCancelHandoffResultEvent({
    required this.originatorNodeId,
    required this.deviceId,
    required this.status,
    required this.receivedAt,
    this.relayNodeId,
    this.reason,
    this.errorMessage,
  });
  final int originatorNodeId;
  final int? relayNodeId;
  final String? deviceId;
  final RemoteRelaySosBackendHandoffStatus status;
  final String? reason;
  final String? errorMessage;
  final DateTime receivedAt;
}
