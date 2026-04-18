import '../config/eixam_session.dart';
import 'device_tel_relay_rx.dart';
import '../enums/realtime_connection_state.dart';
import '../enums/sos_delivery_channel.dart';
import 'sdk_bridge_diagnostics.dart';

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
    this.lastPublicSosDeliveryChannel,
    this.lastTelRelayRx,
  });

  final EixamSession? session;
  final RealtimeConnectionState connectionState;
  final String? telemetryPublishTopic;
  final List<String> sosEventTopics;
  final String? sosRehydrationNote;
  final bool backendSosAvailable;
  final bool deviceSosAvailable;
  final SosDeliveryChannel? lastPublicSosDeliveryChannel;
  final DeviceTelRelayRx? lastTelRelayRx;
  final SdkBridgeDiagnostics bridge;

  bool get hasActiveSession => session != null;

  bool get canPublishOperationally =>
      hasActiveSession && connectionState == RealtimeConnectionState.connected;

  bool get canActivateSos => backendSosAvailable || deviceSosAvailable;

  SdkOperationalDiagnostics copyWith({
    Object? session = _unset,
    RealtimeConnectionState? connectionState,
    Object? telemetryPublishTopic = _unset,
    List<String>? sosEventTopics,
    Object? sosRehydrationNote = _unset,
    bool? backendSosAvailable,
    bool? deviceSosAvailable,
    Object? lastPublicSosDeliveryChannel = _unset,
    Object? lastTelRelayRx = _unset,
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
      lastPublicSosDeliveryChannel:
          identical(lastPublicSosDeliveryChannel, _unset)
              ? this.lastPublicSosDeliveryChannel
              : lastPublicSosDeliveryChannel as SosDeliveryChannel?,
      lastTelRelayRx: identical(lastTelRelayRx, _unset)
          ? this.lastTelRelayRx
          : lastTelRelayRx as DeviceTelRelayRx?,
      bridge: bridge ?? this.bridge,
    );
  }

  static const Object _unset = Object();
}
