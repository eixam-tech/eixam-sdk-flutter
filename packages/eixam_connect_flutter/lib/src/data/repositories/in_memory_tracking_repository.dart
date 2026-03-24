import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';

class InMemoryTrackingRepository implements TrackingRepository {
  final StreamController<TrackingPosition> _positionsController =
      StreamController.broadcast();
  final StreamController<TrackingState> _stateController =
      StreamController.broadcast();

  TrackingPosition? _lastPosition;
  TrackingState _state = TrackingState.idle;

  @override
  Future<TrackingPosition?> getCurrentPosition() async => _lastPosition;

  @override
  Future<TrackingState> getTrackingState() async => _state;

  @override
  Future<void> startTracking() async {
    _state = TrackingState.tracking;
    _stateController.add(_state);
  }

  @override
  Future<void> stopTracking() async {
    _state = TrackingState.idle;
    _stateController.add(_state);
  }

  @override
  Stream<TrackingPosition> watchPositions() => _positionsController.stream;

  @override
  Stream<TrackingState> watchTrackingState() async* {
    yield _state;
    yield* _stateController.stream;
  }
}
