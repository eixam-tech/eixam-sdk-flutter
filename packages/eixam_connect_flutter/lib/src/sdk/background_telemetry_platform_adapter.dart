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
  });

  factory BackgroundTelemetryDiagnostics.fromJson(Map<dynamic, dynamic> json) {
    final lastAtMs = json['lastBackgroundTelemetryAt'];
    return BackgroundTelemetryDiagnostics(
      enabled: json['backgroundTelemetryEnabled'] == true,
      serviceRunning: json['androidForegroundServiceRunning'] == true,
      permissionStatus:
          (json['backgroundPermissionStatus'] as String?) ?? 'unknown',
      lastTelemetryAt: lastAtMs is num
          ? DateTime.fromMillisecondsSinceEpoch(
              lastAtMs.toInt(),
              isUtc: true,
            )
          : null,
      lastTelemetryError: json['lastBackgroundTelemetryError'] as String?,
      lastLocationMode: json['lastBackgroundLocationMode'] as String?,
      activeLocationRequest: json['activeLocationRequest'] == true,
    );
  }

  final bool enabled;
  final bool serviceRunning;
  final String permissionStatus;
  final DateTime? lastTelemetryAt;
  final String? lastTelemetryError;
  final String? lastLocationMode;
  final bool activeLocationRequest;
}

abstract class BackgroundTelemetryPlatformAdapter {
  Future<void> startBackgroundTelemetry(
      BackgroundTelemetryStartRequest request);
  Future<void> updateBackgroundTelemetry({
    required bool sosOpen,
    String? deviceId,
    SdkDeviceBatterySnapshot? deviceBattery,
    SdkCoverageSnapshot? deviceCoverage,
  });
  Future<void> stopBackgroundTelemetry();
  Future<BackgroundTelemetryDiagnostics> getBackgroundTelemetryDiagnostics();
}

class AndroidBackgroundTelemetryPlatformAdapter
    implements BackgroundTelemetryPlatformAdapter {
  AndroidBackgroundTelemetryPlatformAdapter({MethodChannel? methodChannel})
      : _methodChannel =
            methodChannel ?? const MethodChannel(_methodChannelName);

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
    return _methodChannel.invokeMethod<void>(
      'updateBackgroundTelemetry',
      <String, dynamic>{
        'sosOpen': sosOpen,
        'deviceId': deviceId,
        'deviceBattery': deviceBattery?.toJson(),
        'deviceCoverage': deviceCoverage?.toJson(),
      },
    );
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
}
