import 'dart:async';

import 'package:eixam_connect_core/src/enums/realtime_connection_state.dart';
import 'package:eixam_connect_core/src/events/realtime_event.dart';

/// Defines the contract for realtime connectivity used by the SDK.
///
/// Implementations may use WebSocket, MQTT, SSE or another bidirectional
/// backend-connected transport.
abstract class RealtimeClient {
  Future<void> connect();

  Future<void> disconnect();

  Stream<RealtimeConnectionState> watchConnectionState();

  Stream<RealtimeEvent> watchEvents();
}
