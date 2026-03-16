sealed class EixamSdkEvent {
  final DateTime timestamp;
  EixamSdkEvent({DateTime? timestamp}) : timestamp = timestamp ?? DateTime.now();
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
