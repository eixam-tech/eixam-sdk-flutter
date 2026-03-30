import 'dart:async';

import 'package:eixam_connect_core/src/enums/realtime_connection_state.dart';
import 'package:eixam_connect_core/src/events/realtime_event.dart';
import 'package:eixam_connect_core/src/interfaces/realtime_client.dart';

/// Production-safe placeholder until the MQTT realtime transport is implemented.
class DisabledRealtimeClient implements RealtimeClient {
  final StreamController<RealtimeConnectionState> _connectionController =
      StreamController<RealtimeConnectionState>.broadcast();
  final StreamController<RealtimeEvent> _eventsController =
      StreamController<RealtimeEvent>.broadcast();

  @override
  Future<void> connect() async {
    _connectionController.add(RealtimeConnectionState.disconnected);
  }

  @override
  Future<void> disconnect() async {
    _connectionController.add(RealtimeConnectionState.disconnected);
  }

  @override
  Stream<RealtimeConnectionState> watchConnectionState() =>
      _connectionController.stream;

  @override
  Stream<RealtimeEvent> watchEvents() => _eventsController.stream;

  Future<void> dispose() async {
    await _connectionController.close();
    await _eventsController.close();
  }
}
