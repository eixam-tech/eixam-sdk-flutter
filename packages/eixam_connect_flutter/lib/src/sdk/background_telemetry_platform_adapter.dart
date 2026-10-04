import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/services.dart';

class BackgroundTelemetryStartRequest {
  const BackgroundTelemetryStartRequest({
    required this.apiBaseUrl,
    required this.session,
    required this.sosOpen,
    this.deviceId,
    this.deviceBattery,
    this.deviceCoverage,
    this.notificationTitle,
    this.notificationBody,
  });

  final String apiBaseUrl;
  final EixamSession session;
  final bool sosOpen;
  final String? deviceId;
  final SdkDeviceBatterySnapshot? deviceBattery;
  final SdkCoverageSnapshot? deviceCoverage;
  final String? notificationTitle;
  final String? notificationBody;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'apiBaseUrl': apiBaseUrl,
      'session': session.toJson(),
      'sosOpen': sosOpen,
      'deviceId': deviceId,
      'deviceBattery': deviceBattery?.toJson(),
      'deviceCoverage': deviceCoverage?.toJson(),
      'notificationTitle': notificationTitle,
      'notificationBody': notificationBody,
    };
  }
}

class BackgroundTelemetryDiagnostics {
  const BackgroundTelemetryDiagnostics({
    this.enabled = false,
    this.serviceRunning = false,
    this.permissionStatus = 'unknown',
    this.lastTelemetryAt,
    this.lastTelemetryError,
    this.lastLocationMode,
    this.activeLocationRequest = false,
    this.pendingNativeTelemetryCount = 0,
  });

  factory BackgroundTelemetryDiagnostics.fromJson(Map<dynamic, dynamic> json) {
    final lastAtMs = json['lastBackgroundTelemetryAt'];
    return BackgroundTelemetryDiagnostics(
      enabled: json['backgroundTelemetryEnabled'] == true,
      serviceRunning: json['androidForegroundServiceRunning'] == true,
      permissionStatus:
          (json['backgroundPermissionStatus'] as String?) ?? 'unknown',
      lastTelemetryAt: lastAtMs is num
          ? DateTime.fromMillisecondsSinceEpoch(lastAtMs.toInt(), isUtc: true)
          : null,
      lastTelemetryError: json['lastBackgroundTelemetryError'] as String?,
      lastLocationMode: json['lastBackgroundLocationMode'] as String?,
      activeLocationRequest: json['activeLocationRequest'] == true,
      pendingNativeTelemetryCount:
          (json['pendingNativeTelemetryCount'] as num?)?.toInt() ?? 0,
    );
  }

  final bool enabled;
  final bool serviceRunning;
  final String permissionStatus;
  final DateTime? lastTelemetryAt;
  final String? lastTelemetryError;
  final String? lastLocationMode;
  final bool activeLocationRequest;
  final int pendingNativeTelemetryCount;
}

class NativeBackgroundTelemetryItem {
  const NativeBackgroundTelemetryItem({
    required this.signature,
    required this.payload,
    required this.enqueuedAt,
    this.retryCount = 0,
    this.reason,
    this.locationMode,
    this.sosContext = false,
  });

  final String signature;
  final SdkTelemetryPayload payload;
  final DateTime enqueuedAt;
  final int retryCount;
  final String? reason;
  final String? locationMode;
  final bool sosContext;
}

abstract class BackgroundTelemetryPlatformAdapter {
  Future<void> startBackgroundTelemetry(
    BackgroundTelemetryStartRequest request,
  );
  Future<void> updateBackgroundTelemetry({
    required bool sosOpen,
    String? deviceId,
    SdkDeviceBatterySnapshot? deviceBattery,
    SdkCoverageSnapshot? deviceCoverage,
  });
  Future<void> stopBackgroundTelemetry();
  Future<BackgroundTelemetryDiagnostics> getBackgroundTelemetryDiagnostics();
  Future<List<NativeBackgroundTelemetryItem>> peekQueuedBackgroundTelemetry({
    int limit = 25,
  });
  Future<bool> ackQueuedBackgroundTelemetry(String signature);
  Future<void> markQueuedBackgroundTelemetryFlushFailed(
    String signature, {
    required String error,
  });
}

class AndroidBackgroundTelemetryPlatformAdapter
    implements BackgroundTelemetryPlatformAdapter {
  AndroidBackgroundTelemetryPlatformAdapter({MethodChannel? methodChannel})
    : _methodChannel = methodChannel ?? const MethodChannel(_methodChannelName);

  static const String _methodChannelName =
      'dev.eixam.connect_flutter/background_telemetry/methods';

  final MethodChannel _methodChannel;

  @override
  Future<void> startBackgroundTelemetry(
    BackgroundTelemetryStartRequest request,
  ) {
    return _methodChannel.invokeMethod<void>(
      'startBackgroundTelemetry',
      request.toJson(),
    );
  }

  @override
  Future<void> updateBackgroundTelemetry({
    required bool sosOpen,
    String? deviceId,
    SdkDeviceBatterySnapshot? deviceBattery,
    SdkCoverageSnapshot? deviceCoverage,
  }) {
    return _methodChannel
        .invokeMethod<void>('updateBackgroundTelemetry', <String, dynamic>{
          'sosOpen': sosOpen,
          'deviceId': deviceId,
          'deviceBattery': deviceBattery?.toJson(),
          'deviceCoverage': deviceCoverage?.toJson(),
        });
  }

  @override
  Future<void> stopBackgroundTelemetry() {
    return _methodChannel.invokeMethod<void>('stopBackgroundTelemetry');
  }

  @override
  Future<BackgroundTelemetryDiagnostics>
  getBackgroundTelemetryDiagnostics() async {
    final raw = await _methodChannel.invokeMapMethod<dynamic, dynamic>(
      'getBackgroundTelemetryDiagnostics',
    );
    return BackgroundTelemetryDiagnostics.fromJson(
      raw ?? const <dynamic, dynamic>{},
    );
  }

  @override
  Future<List<NativeBackgroundTelemetryItem>> peekQueuedBackgroundTelemetry({
    int limit = 25,
  }) async {
    final raw = await _methodChannel.invokeListMethod<dynamic>(
      'peekQueuedBackgroundTelemetry',
      <String, dynamic>{'limit': limit},
    );
    return (raw ?? const <dynamic>[])
        .map(_mapNativeTelemetryItem)
        .whereType<NativeBackgroundTelemetryItem>()
        .toList(growable: false);
  }

  @override
  Future<bool> ackQueuedBackgroundTelemetry(String signature) async {
    final acknowledged = await _methodChannel.invokeMethod<bool>(
      'ackQueuedBackgroundTelemetry',
      <String, dynamic>{'signature': signature},
    );
    return acknowledged == true;
  }

  @override
  Future<void> markQueuedBackgroundTelemetryFlushFailed(
    String signature, {
    required String error,
  }) {
    return _methodChannel.invokeMethod<void>(
      'markQueuedBackgroundTelemetryFlushFailed',
      <String, dynamic>{'signature': signature, 'error': error},
    );
  }

  NativeBackgroundTelemetryItem? _mapNativeTelemetryItem(dynamic value) {
    try {
      return _mapNativeTelemetryItemUnchecked(value);
    } catch (_) {
      // One bad queue item must not stall the rest of the flush.
      return null;
    }
  }

  NativeBackgroundTelemetryItem? _mapNativeTelemetryItemUnchecked(
    dynamic value,
  ) {
    if (value is! Map) {
      return null;
    }
    final signature = _asString(value['signature'])?.trim();
    final payloadRaw = value['payload'];
    if (signature == null || signature.isEmpty || payloadRaw is! Map) {
      return null;
    }
    final payload = _sdkTelemetryPayloadFromJson(payloadRaw);
    if (payload == null) {
      return null;
    }
    final enqueuedAtMs = value['enqueuedAt'];
    return NativeBackgroundTelemetryItem(
      signature: signature,
      payload: payload,
      enqueuedAt: enqueuedAtMs is num
          ? DateTime.fromMillisecondsSinceEpoch(
              enqueuedAtMs.toInt(),
              isUtc: true,
            )
          : DateTime.now().toUtc(),
      retryCount: (value['retryCount'] as num?)?.toInt() ?? 0,
      reason: _asString(value['reason']),
      locationMode: _asString(value['locationMode']),
      sosContext: value['sosContext'] == true,
    );
  }

  SdkTelemetryPayload? _sdkTelemetryPayloadFromJson(
    Map<dynamic, dynamic> json,
  ) {
    final timestampRaw = json['timestamp'] as String?;
    final timestamp = timestampRaw == null
        ? null
        : DateTime.tryParse(timestampRaw)?.toUtc();
    final latitude = _asDouble(json['latitude']);
    final longitude = _asDouble(json['longitude']);
    final altitude = _asDouble(json['altitude']);
    if (timestamp == null ||
        latitude == null ||
        longitude == null ||
        altitude == null) {
      return null;
    }
    return SdkTelemetryPayload(
      timestamp: timestamp,
      latitude: latitude,
      longitude: longitude,
      altitude: altitude,
      kind: _asString(json['kind']),
      eventId: _asString(json['eventId']),
      userId: _asString(json['userId']),
      deviceId: _asString(json['deviceId']),
      hardwareId: _asString(json['hardwareId']),
      identitySource: _asString(json['identitySource']),
      deviceBatterySnapshot: _deviceBatterySnapshotFromJson(
        json['deviceBattery'],
      ),
      deviceCoverageSnapshot: _coverageSnapshotFromJson(json['deviceCoverage']),
      mobileBattery: _asDouble(json['mobileBattery']),
      mobileCoverageSnapshot: _coverageSnapshotFromJson(json['mobileCoverage']),
      horizontalAccuracyMeters: finiteHorizontalAccuracyMeters(
        _asDouble(json['horizontalAccuracyMeters']),
      ),
      radio: _radioFromQueuedPayload(json),
      phoneRadioSampled: json['phoneRadio'] is Map,
    );
  }

  SdkDeviceBatterySnapshot? _deviceBatterySnapshotFromJson(Object? value) {
    if (value is! Map) {
      return null;
    }
    final rawValue = value['rawValue'];
    final range = value['range'];
    if (rawValue is! num || range is! String) {
      return null;
    }
    return SdkDeviceBatterySnapshot(rawValue: rawValue.toInt(), range: range);
  }

  SdkRadioSnapshot? _radioFromQueuedPayload(Map<dynamic, dynamic> json) {
    try {
      final reading = SdkPhoneRadioReading.tryParse(json['phoneRadio']);
      if (reading == null) {
        return null;
      }
      return mapPhoneRadio(reading);
    } catch (_) {
      // A bad radio snapshot must not drop the queued fix.
      return null;
    }
  }

  double? _asDouble(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    return null;
  }

  String? _asString(Object? value) {
    if (value is String) {
      return value;
    }
    return null;
  }

  SdkCoverageSnapshot? _coverageSnapshotFromJson(Object? value) {
    if (value is! Map) {
      return null;
    }
    final signalStrength = value['signalStrength'];
    final networkType = value['networkType'];
    final isConnected = value['isConnected'];
    if (signalStrength is! num ||
        networkType is! String ||
        isConnected is! bool) {
      return null;
    }
    return SdkCoverageSnapshot(
      signalStrength: signalStrength.toInt(),
      networkType: networkType,
      isConnected: isConnected,
    );
  }
}

class NoopBackgroundTelemetryPlatformAdapter
    implements BackgroundTelemetryPlatformAdapter {
  const NoopBackgroundTelemetryPlatformAdapter();

  @override
  Future<void> startBackgroundTelemetry(
    BackgroundTelemetryStartRequest request,
  ) async {}

  @override
  Future<void> updateBackgroundTelemetry({
    required bool sosOpen,
    String? deviceId,
    SdkDeviceBatterySnapshot? deviceBattery,
    SdkCoverageSnapshot? deviceCoverage,
  }) async {}

  @override
  Future<void> stopBackgroundTelemetry() async {}

  @override
  Future<BackgroundTelemetryDiagnostics>
  getBackgroundTelemetryDiagnostics() async {
    return const BackgroundTelemetryDiagnostics();
  }

  @override
  Future<List<NativeBackgroundTelemetryItem>> peekQueuedBackgroundTelemetry({
    int limit = 25,
  }) async {
    return const <NativeBackgroundTelemetryItem>[];
  }

  @override
  Future<bool> ackQueuedBackgroundTelemetry(String signature) async {
    return true;
  }

  @override
  Future<void> markQueuedBackgroundTelemetryFlushFailed(
    String signature, {
    required String error,
  }) async {}
}
