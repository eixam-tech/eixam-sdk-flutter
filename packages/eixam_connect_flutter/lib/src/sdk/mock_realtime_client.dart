import 'dart:async';

import 'package:eixam_connect_core/src/enums/realtime_connection_state.dart';
import 'package:eixam_connect_core/src/events/realtime_event.dart';
import 'package:eixam_connect_core/src/interfaces/realtime_client.dart';

/// Mock realtime client used during SDK development.
///
/// This client simulates a connection lifecycle and allows the SDK to start
/// integrating realtime flows without depending on a real backend.
class MockRealtimeClient implements RealtimeClient {
  final StreamController<RealtimeConnectionState> _connectionStateController =
      StreamController<RealtimeConnectionState>.broadcast();

  final StreamController<RealtimeEvent> _eventsController =
      StreamController<RealtimeEvent>.broadcast();

  RealtimeConnectionState _state = RealtimeConnectionState.disconnected;

  @override
  Future<void> connect() async {
    _state = RealtimeConnectionState.connecting;
    _connectionStateController.add(_state);

    await Future<void>.delayed(const Duration(milliseconds: 300));

    _state = RealtimeConnectionState.connected;
    _connectionStateController.add(_state);

    _eventsController.add(
      RealtimeEvent(
        type: 'realtime.connected',
        timestamp: DateTime.now(),
        payload: const {
          'source': 'mock',
        },
      ),
    );
  }

  @override
  Future<void> disconnect() async {
    _state = RealtimeConnectionState.disconnected;
    _connectionStateController.add(_state);

    _eventsController.add(
      RealtimeEvent(
        type: 'realtime.disconnected',
        timestamp: DateTime.now(),
        payload: const {
          'source': 'mock',
        },
      ),
    );
  }

  @override
  Stream<RealtimeConnectionState> watchConnectionState() {
    return _connectionStateController.stream;
  }

  @override
  Stream<RealtimeEvent> watchEvents() {
    return _eventsController.stream;
  }

  Future<void> dispose() async {
    await _connectionStateController.close();
    await _eventsController.close();
  }
}