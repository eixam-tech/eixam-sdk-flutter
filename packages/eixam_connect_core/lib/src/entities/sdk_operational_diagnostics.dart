import '../config/eixam_session.dart';
import '../enums/realtime_connection_state.dart';
import '../enums/background_tracking_state.dart';
import '../enums/sos_delivery_channel.dart';
import 'device_tel_relay_rx.dart';
import 'sdk_bridge_diagnostics.dart';
import 'sdk_resolved_location.dart';

/// Partner-facing runtime snapshot for capability, relay, and bridge status.
class SdkOperationalDiagnostics {
  const SdkOperationalDiagnostics({
    required this.connectionState,
    required this.bridge,
    this.session,
    this.telemetryPublishTopic,
    this.sosEventTopics = const <String>[],
    this.sosRehydrationNote,
    this.backendSosAvailable = false,
    this.deviceSosAvailable = false,
    this.shortCommandAvailable = false,
    this.longCommandAvailable = false,
    this.lastPublicSosDeliveryChannel,
    this.lastTelRelayRx,
    this.backgroundTelemetryEnabled = false,
    this.backgroundTrackingState = BackgroundTrackingState.stopped,
    this.androidForegroundServiceRunning = false,
    this.backgroundPermissionStatus = 'unknown',
    this.lastBackgroundTelemetryAt,
    this.lastBackgroundTelemetryError,
    this.lastBackgroundLocationMode,
    this.activeBackgroundLocationRequest = false,
    this.resolvedLocation,
  });

  final EixamSession? session;
  final RealtimeConnectionState connectionState;
  final String? telemetryPublishTopic;
  final List<String> sosEventTopics;
  final String? sosRehydrationNote;
  final bool backendSosAvailable;
  final bool deviceSosAvailable;
  final bool shortCommandAvailable;
  final bool longCommandAvailable;
  final SosDeliveryChannel? lastPublicSosDeliveryChannel;

  bool get shortControlAvailable => shortCommandAvailable;
  bool get cmdAvailable => longCommandAvailable;

  /// Most recent typed BLE relay sample observed by the SDK when the payload
  /// matched a stable relay contract.
  final DeviceTelRelayRx? lastTelRelayRx;
  final bool backgroundTelemetryEnabled;
  final BackgroundTrackingState backgroundTrackingState;
  final bool androidForegroundServiceRunning;
  final String backgroundPermissionStatus;
  final DateTime? lastBackgroundTelemetryAt;
  final String? lastBackgroundTelemetryError;
  final String? lastBackgroundLocationMode;
  final bool activeBackgroundLocationRequest;
  final SdkResolvedLocation? resolvedLocation;
  final SdkBridgeDiagnostics bridge;

  bool get hasActiveSession => session != null;

  bool get canPublishOperationally =>
      hasActiveSession && connectionState == RealtimeConnectionState.connected;

  bool get canActivateSos => backendSosAvailable || deviceSosAvailable;

  SosDeliveryChannel? get currentSosCapabilityChannel {
    if (backendSosAvailable && deviceSosAvailable) {
      return SosDeliveryChannel.backendAndDevice;
    }
    if (backendSosAvailable) {
      return SosDeliveryChannel.backendOnly;
    }
    if (deviceSosAvailable) {
      return SosDeliveryChannel.deviceOnly;
    }
    return null;
  }

  String get currentSosCapabilityLabel {
    return switch (currentSosCapabilityChannel) {
      SosDeliveryChannel.backendAndDevice => 'backend + device',
      SosDeliveryChannel.backendOnly => 'backend only',
      SosDeliveryChannel.deviceOnly => 'device only',
      null => 'unavailable',
    };
  }

  SdkOperationalDiagnostics copyWith({
    Object? session = _unset,
    RealtimeConnectionState? connectionState,
    Object? telemetryPublishTopic = _unset,
    List<String>? sosEventTopics,
    Object? sosRehydrationNote = _unset,
    bool? backendSosAvailable,
    bool? deviceSosAvailable,
    bool? shortCommandAvailable,
    bool? longCommandAvailable,
    Object? lastPublicSosDeliveryChannel = _unset,
    Object? lastTelRelayRx = _unset,
    bool? backgroundTelemetryEnabled,
    BackgroundTrackingState? backgroundTrackingState,
    bool? androidForegroundServiceRunning,
    String? backgroundPermissionStatus,
    Object? lastBackgroundTelemetryAt = _unset,
    Object? lastBackgroundTelemetryError = _unset,
    Object? lastBackgroundLocationMode = _unset,
    bool? activeBackgroundLocationRequest,
    Object? resolvedLocation = _unset,
    SdkBridgeDiagnostics? bridge,
  }) {
    return SdkOperationalDiagnostics(
      session:
          identical(session, _unset) ? this.session : session as EixamSession?,
      connectionState: connectionState ?? this.connectionState,
      telemetryPublishTopic: identical(telemetryPublishTopic, _unset)
          ? this.telemetryPublishTopic
          : telemetryPublishTopic as String?,
      sosEventTopics: sosEventTopics ?? this.sosEventTopics,
      sosRehydrationNote: identical(sosRehydrationNote, _unset)
          ? this.sosRehydrationNote
          : sosRehydrationNote as String?,
      backendSosAvailable: backendSosAvailable ?? this.backendSosAvailable,
      deviceSosAvailable: deviceSosAvailable ?? this.deviceSosAvailable,
      shortCommandAvailable:
          shortCommandAvailable ?? this.shortCommandAvailable,
      longCommandAvailable: longCommandAvailable ?? this.longCommandAvailable,
      lastPublicSosDeliveryChannel:
          identical(lastPublicSosDeliveryChannel, _unset)
              ? this.lastPublicSosDeliveryChannel
              : lastPublicSosDeliveryChannel as SosDeliveryChannel?,
      lastTelRelayRx: identical(lastTelRelayRx, _unset)
          ? this.lastTelRelayRx
          : lastTelRelayRx as DeviceTelRelayRx?,
      backgroundTelemetryEnabled:
          backgroundTelemetryEnabled ?? this.backgroundTelemetryEnabled,
      backgroundTrackingState:
          backgroundTrackingState ?? this.backgroundTrackingState,
      androidForegroundServiceRunning: androidForegroundServiceRunning ??
          this.androidForegroundServiceRunning,
      backgroundPermissionStatus:
          backgroundPermissionStatus ?? this.backgroundPermissionStatus,
      lastBackgroundTelemetryAt: identical(lastBackgroundTelemetryAt, _unset)
          ? this.lastBackgroundTelemetryAt
          : lastBackgroundTelemetryAt as DateTime?,
      lastBackgroundTelemetryError:
          identical(lastBackgroundTelemetryError, _unset)
              ? this.lastBackgroundTelemetryError
              : lastBackgroundTelemetryError as String?,
      lastBackgroundLocationMode: identical(lastBackgroundLocationMode, _unset)
          ? this.lastBackgroundLocationMode
          : lastBackgroundLocationMode as String?,
      activeBackgroundLocationRequest: activeBackgroundLocationRequest ??
          this.activeBackgroundLocationRequest,
      resolvedLocation: identical(resolvedLocation, _unset)
          ? this.resolvedLocation
          : resolvedLocation as SdkResolvedLocation?,
      bridge: bridge ?? this.bridge,
    );
  }

  static const Object _unset = Object();
}
