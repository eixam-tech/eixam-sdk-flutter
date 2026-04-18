import 'package:eixam_connect_core/eixam_connect_core.dart';

/// Helper serializers used by the starter SDK local persistence layer.
///
/// Domain models remain framework-agnostic in `eixam_connect_core`, so JSON
/// conversion lives in the Flutter package where storage concerns belong.
class LocalStateSerializers {
  const LocalStateSerializers._();

  static Map<String, dynamic> emergencyContactToJson(EmergencyContact contact) {
    return {
      'id': contact.id,
      'name': contact.name,
      'phone': contact.phone,
      'email': contact.email,
      'priority': contact.priority,
      'createdAt': contact.createdAt.toIso8601String(),
      'updatedAt': contact.updatedAt.toIso8601String(),
    };
  }

  static EmergencyContact emergencyContactFromJson(Map<String, dynamic> json) {
    return EmergencyContact(
      id: json['id'] as String,
      name: json['name'] as String,
      phone: json['phone'] as String,
      email: json['email'] as String,
      priority: json['priority'] as int? ?? 1,
      createdAt: json['createdAt'] == null
          ? DateTime.now().toUtc()
          : DateTime.parse(json['createdAt'] as String),
      updatedAt: json['updatedAt'] == null
          ? DateTime.now().toUtc()
          : DateTime.parse(json['updatedAt'] as String),
    );
  }

  static List<Map<String, dynamic>> emergencyContactsToJson(
      List<EmergencyContact> contacts) {
    return contacts.map(emergencyContactToJson).toList(growable: false);
  }

  static List<EmergencyContact> emergencyContactsFromJson(List<dynamic> items) {
    return items
        .whereType<Map>()
        .map(
            (item) => emergencyContactFromJson(Map<String, dynamic>.from(item)))
        .toList(growable: false);
  }

  static Map<String, dynamic> trackingPositionToJson(
      TrackingPosition position) {
    return {
      'latitude': position.latitude,
      'longitude': position.longitude,
      'altitude': position.altitude,
      'accuracy': position.accuracy,
      'speed': position.speed,
      'heading': position.heading,
      'source': position.source.name,
      'timestamp': position.timestamp.toIso8601String(),
    };
  }

  static TrackingPosition trackingPositionFromJson(Map<String, dynamic> json) {
    return TrackingPosition(
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      altitude: (json['altitude'] as num?)?.toDouble(),
      accuracy: (json['accuracy'] as num?)?.toDouble(),
      speed: (json['speed'] as num?)?.toDouble(),
      heading: (json['heading'] as num?)?.toDouble(),
      source: DeliveryMode.values.firstWhere(
        (value) => value.name == json['source'],
        orElse: () => DeliveryMode.unknown,
      ),
      timestamp: DateTime.parse(json['timestamp'] as String),
    );
  }

  static Map<String, dynamic> sosIncidentToJson(SosIncident incident) {
    return {
      'id': incident.id,
      'state': incident.state.name,
      'createdAt': incident.createdAt.toIso8601String(),
      'triggerSource': incident.triggerSource,
      'message': incident.message,
      'deliveryChannel': incident.deliveryChannel?.name,
      'positionSnapshot': incident.positionSnapshot == null
          ? null
          : trackingPositionToJson(incident.positionSnapshot!),
    };
  }

  static SosIncident sosIncidentFromJson(Map<String, dynamic> json) {
    final snapshot = json['positionSnapshot'];
    final deliveryChannelName = json['deliveryChannel'] as String?;
    return SosIncident(
      id: json['id'] as String,
      state: SosState.values.firstWhere(
        (value) => value.name == json['state'],
        orElse: () => SosState.idle,
      ),
      createdAt: DateTime.parse(json['createdAt'] as String),
      triggerSource: json['triggerSource'] as String?,
      message: json['message'] as String?,
      deliveryChannel: deliveryChannelName == null
          ? null
          : SosDeliveryChannel.values.firstWhere(
              (value) => value.name == deliveryChannelName,
              orElse: () => SosDeliveryChannel.backendOnly,
            ),
      positionSnapshot: snapshot is Map<String, dynamic>
          ? trackingPositionFromJson(snapshot)
          : null,
    );
  }

  static Map<String, dynamic> deathManPlanToJson(DeathManPlan plan) {
    return {
      'id': plan.id,
      'expectedReturnAt': plan.expectedReturnAt.toIso8601String(),
      'gracePeriodMs': plan.gracePeriod.inMilliseconds,
      'checkInWindowMs': plan.checkInWindow.inMilliseconds,
      'autoTriggerSos': plan.autoTriggerSos,
      'status': plan.status.name,
    };
  }

  static DeathManPlan deathManPlanFromJson(Map<String, dynamic> json) {
    return DeathManPlan(
      id: json['id'] as String,
      expectedReturnAt: DateTime.parse(json['expectedReturnAt'] as String),
      gracePeriod: Duration(milliseconds: json['gracePeriodMs'] as int),
      checkInWindow: Duration(milliseconds: json['checkInWindowMs'] as int),
      autoTriggerSos: json['autoTriggerSos'] as bool? ?? true,
      status: DeathManStatus.values.firstWhere(
        (value) => value.name == json['status'],
        orElse: () => DeathManStatus.scheduled,
      ),
    );
  }

  static Map<String, dynamic> deviceStatusToJson(DeviceStatus status) {
    return {
      'deviceId': status.deviceId,
      'canonicalHardwareId': status.canonicalHardwareId,
      'deviceAlias': status.deviceAlias,
      'model': status.model,
      'paired': status.paired,
      'activated': status.activated,
      'connected': status.connected,
      'batteryLevel': status.batteryLevel,
      'batteryState': status.effectiveBatteryState?.name,
      'batterySource': status.batterySource?.name,
      'firmwareVersion': status.firmwareVersion,
      'lastSeen': status.lastSeen?.toIso8601String(),
      'lastSyncedAt': status.lastSyncedAt?.toIso8601String(),
      'signalQuality': status.signalQuality,
      'lifecycleState': status.lifecycleState.name,
      'provisioningError': status.provisioningError,
    };
  }

  static DeviceStatus deviceStatusFromJson(Map<String, dynamic> json) {
    final rawBatteryLevel = json['batteryLevel'] as int?;
    final batteryStateName = json['batteryState'] as String?;
    final batterySourceName = json['batterySource'] as String?;

    DeviceBatteryLevel? batteryState;
    for (final value in DeviceBatteryLevel.values) {
      if (value.name == batteryStateName) {
        batteryState = value;
        break;
      }
    }
    batteryState ??= DeviceBatteryLevel.fromProtocolValue(rawBatteryLevel);

    DeviceBatterySource? batterySource;
    for (final value in DeviceBatterySource.values) {
      if (value.name == batterySourceName) {
        batterySource = value;
        break;
      }
    }

    return DeviceStatus(
      deviceId: json['deviceId'] as String,
      canonicalHardwareId: json['canonicalHardwareId'] as String?,
      deviceAlias: json['deviceAlias'] as String?,
      model: json['model'] as String?,
      paired: json['paired'] as bool? ?? false,
      activated: json['activated'] as bool? ?? false,
      connected: json['connected'] as bool? ?? false,
      batteryLevel: rawBatteryLevel,
      batteryState: batteryState,
      batterySource: batterySource,
      firmwareVersion: json['firmwareVersion'] as String?,
      lastSeen: json['lastSeen'] == null
          ? null
          : DateTime.parse(json['lastSeen'] as String),
      lastSyncedAt: json['lastSyncedAt'] == null
          ? null
          : DateTime.parse(json['lastSyncedAt'] as String),
      signalQuality: json['signalQuality'] as int?,
      lifecycleState: DeviceLifecycleState.values.firstWhere(
        (value) => value.name == json['lifecycleState'],
        orElse: () => DeviceLifecycleState.unpaired,
      ),
      provisioningError: json['provisioningError'] as String?,
    );
  }
}
