import '../config/eixam_session.dart';
import '../enums/realtime_connection_state.dart';
import 'sdk_bridge_diagnostics.dart';

class SdkOperationalDiagnostics {
  const SdkOperationalDiagnostics({
    required this.connectionState,
    required this.bridge,
    this.session,
    this.telemetryPublishTopic,
    this.sosEventTopics = const <String>[],
    this.sosRehydrationNote,
  });

  final EixamSession? session;
  final RealtimeConnectionState connectionState;
  final String? telemetryPublishTopic;
  final List<String> sosEventTopics;
  final String? sosRehydrationNote;
  final SdkBridgeDiagnostics bridge;

  bool get hasActiveSession => session != null;

  bool get canPublishOperationally =>
      hasActiveSession && connectionState == RealtimeConnectionState.connected;

  SdkOperationalDiagnostics copyWith({
    Object? session = _unset,
    RealtimeConnectionState? connectionState,
    Object? telemetryPublishTopic = _unset,
    List<String>? sosEventTopics,
    Object? sosRehydrationNote = _unset,
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
      bridge: bridge ?? this.bridge,
    );
  }

  static const Object _unset = Object();
}
