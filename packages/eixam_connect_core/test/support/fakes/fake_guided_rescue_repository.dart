import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';

class FakeGuidedRescueRepository implements GuidedRescueRepository {
  FakeGuidedRescueRepository({
    GuidedRescueState? initialState,
  }) : _state = initialState ?? const GuidedRescueState.unsupported();

  final StreamController<GuidedRescueState> _controller =
      StreamController<GuidedRescueState>.broadcast();

  GuidedRescueState _state;
  int requestStatusCallCount = 0;
  int requestPositionCallCount = 0;
  int acknowledgeSosCallCount = 0;
  int enableBuzzerCallCount = 0;
  int disableBuzzerCallCount = 0;
  int clearSessionCallCount = 0;

  @override
  Future<GuidedRescueState> getGuidedRescueState() async => _state;

  @override
  Stream<GuidedRescueState> watchGuidedRescueState() => _controller.stream;

  @override
  Future<GuidedRescueState> setGuidedRescueSession({
    required int targetNodeId,
    required int rescueNodeId,
  }) async {
    _state = _state.copyWith(
      targetNodeId: targetNodeId,
      rescueNodeId: rescueNodeId,
      lastUpdatedAt: DateTime.utc(2026, 1, 1, 12),
      clearLastError: true,
    );
    _controller.add(_state);
    return _state;
  }

  @override
  Future<void> clearGuidedRescueSession() async {
    clearSessionCallCount++;
    _state = const GuidedRescueState.unsupported();
    _controller.add(_state);
  }

  @override
  Future<void> requestGuidedRescuePosition() async {
    requestPositionCallCount++;
  }

  @override
  Future<void> acknowledgeGuidedRescueSos() async {
    acknowledgeSosCallCount++;
  }

  @override
  Future<void> enableGuidedRescueBuzzer() async {
    enableBuzzerCallCount++;
  }

  @override
  Future<void> disableGuidedRescueBuzzer() async {
    disableBuzzerCallCount++;
  }

  @override
  Future<void> requestGuidedRescueStatus() async {
    requestStatusCallCount++;
  }
}
