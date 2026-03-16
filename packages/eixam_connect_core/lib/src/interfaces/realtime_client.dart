import 'dart:async';

import 'package:eixam_connect_core/src/enums/realtime_connection_state.dart';
import 'package:eixam_connect_core/src/events/realtime_event.dart';

/// Defines the contract for realtime connectivity used by the SDK.
///
/// Implementations may use WebSocket, SSE or any other bidirectional transport.
/// For now, the SDK will start with a mock implementation and later evolve
/// towards a real backend-connected WebSocket client.
abstract class RealtimeClient {
  Future<void> connect();

  Future<void> disconnect();

  Stream<RealtimeConnectionState> watchConnectionState();

  Stream<RealtimeEvent> watchEvents();
}