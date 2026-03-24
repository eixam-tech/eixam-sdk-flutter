import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';

class FakeSosRepository implements SosRepository {
  FakeSosRepository({
    SosIncident? triggerResult,
    SosIncident? cancelResult,
    SosState initialState = SosState.idle,
  })  : _triggerResult = triggerResult,
        _cancelResult = cancelResult,
        _state = initialState {
    _controller.add(_state);
  }

  final StreamController<SosState> _controller =
      StreamController<SosState>.broadcast();

  SosIncident? _triggerResult;
  SosIncident? _cancelResult;
  SosState _state;
  String? lastTriggerMessage;
  String? lastTriggerSource;
  TrackingPosition? lastTriggerPositionSnapshot;
  String? lastCancelReason;

  set triggerResult(SosIncident value) => _triggerResult = value;
  set cancelResult(SosIncident value) => _cancelResult = value;

  @override
  Future<SosIncident> triggerSos({
    String? message,
    required String triggerSource,
    TrackingPosition? positionSnapshot,
  }) async {
    lastTriggerMessage = message;
    lastTriggerSource = triggerSource;
    lastTriggerPositionSnapshot = positionSnapshot;
    final result = _triggerResult!;
    _state = result.state;
    _controller.add(_state);
    return result;
  }

  @override
  Future<SosIncident> cancelSos({String? reason}) async {
    lastCancelReason = reason;
    final result = _cancelResult!;
    _state = result.state;
    _controller.add(_state);
    return result;
  }

  @override
  Future<SosState> getSosState() async => _state;

  @override
  Stream<SosState> watchSosState() => _controller.stream;
}
