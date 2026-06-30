import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';

class InMemoryTrackingRepository implements TrackingRepository {
  InMemoryTrackingRepository({
    TrackingPosition? initialPosition,
    TrackingState initialState = TrackingState.idle,
  })  : _lastPosition = initialPosition,
        _state = initialState;

  final StreamController<TrackingPosition> _positionsController =
      StreamController.broadcast();
  final StreamController<TrackingState> _stateController =
      StreamController.broadcast();

  final TrackingPosition? _lastPosition;
  TrackingState _state = TrackingState.idle;
  bool _disposed = false;

  @override
  Future<TrackingPosition?> getCurrentPosition() async => _lastPosition;

  @override
  Future<TrackingState> getTrackingState() async => _state;

  @override
  Future<void> startTracking() async {
    if (_disposed) return;
    _state = TrackingState.tracking;
    _stateController.add(_state);
  }

  @override
  Future<void> stopTracking() async {
    if (_disposed) return;
    _state = TrackingState.idle;
    _stateController.add(_state);
  }

  @override
  Stream<TrackingPosition> watchPositions() async* {
    if (_disposed) return;
    final current = _lastPosition;
    if (current != null) {
      yield current;
    }
    if (_disposed) return;
    yield* _positionsController.stream;
  }

  @override
  Stream<TrackingState> watchTrackingState() async* {
    if (_disposed) return;
    yield _state;
    if (_disposed) return;
    yield* _stateController.stream;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _positionsController.close();
    await _stateController.close();
  }
}
