import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SafetyOverviewController guided rescue bootstrap', () {
    test('configures a validation rescue session through the SDK', () async {
      final sdk = _FakeGuidedRescueBootstrapSdk();
      final controller = SafetyOverviewController(sdk: sdk);

      await controller.configureGuidedRescueSessionForValidation(
        targetNodeIdText: '0x1001',
        rescueNodeIdText: '8194',
      );

      expect(sdk.setGuidedRescueSessionCallCount, 1);
      expect(sdk.lastTargetNodeId, 0x1001);
      expect(sdk.lastRescueNodeId, 0x2002);
      expect(controller.guidedRescueState?.hasSession, isTrue);
      expect(controller.guidedRescueState?.targetNodeId, 0x1001);
      expect(controller.guidedRescueState?.rescueNodeId, 0x2002);
      expect(
        controller.guidedRescueState?.canRun(GuidedRescueAction.requestStatus),
        isTrue,
      );
      expect(controller.lastError, isNull);
    });

    test('surfaces invalid validation node ids without calling the SDK',
        () async {
      final sdk = _FakeGuidedRescueBootstrapSdk();
      final controller = SafetyOverviewController(sdk: sdk);

      await controller.configureGuidedRescueSessionForValidation(
        targetNodeIdText: 'abc',
        rescueNodeIdText: '0x2002',
      );

      expect(sdk.setGuidedRescueSessionCallCount, 0);
      expect(controller.guidedRescueState, isNull);
      expect(controller.lastError, contains('valid target node id'));
    });
  });
}

class _FakeGuidedRescueBootstrapSdk implements EixamConnectSdk {
  int setGuidedRescueSessionCallCount = 0;
  int? lastTargetNodeId;
  int? lastRescueNodeId;

  GuidedRescueState _state = const GuidedRescueState(
    hasRuntimeSupport: true,
    availableActions: <GuidedRescueAction>{},
    unavailableReason:
        'Configure a guided rescue session before issuing rescue commands.',
  );

  @override
  Future<GuidedRescueState> setGuidedRescueSession({
    required int targetNodeId,
    required int rescueNodeId,
  }) async {
    setGuidedRescueSessionCallCount += 1;
    lastTargetNodeId = targetNodeId;
    lastRescueNodeId = rescueNodeId;
    _state = GuidedRescueState(
      hasRuntimeSupport: true,
      targetNodeId: targetNodeId,
      rescueNodeId: rescueNodeId,
      availableActions: const <GuidedRescueAction>{
        GuidedRescueAction.requestStatus,
        GuidedRescueAction.requestPosition,
      },
      lastUpdatedAt: DateTime.utc(2026, 3, 25, 12),
    );
    return _state;
  }

  @override
  Future<GuidedRescueState> getGuidedRescueState() async => _state;

  @override
  Stream<GuidedRescueState> watchGuidedRescueState() =>
      const Stream<GuidedRescueState>.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
