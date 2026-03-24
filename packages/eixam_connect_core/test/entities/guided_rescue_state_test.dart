import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:test/test.dart';

void main() {
  group('GuidedRescueState', () {
    test('unsupported state has no runtime support and no actions', () {
      const state = GuidedRescueState.unsupported();

      expect(state.hasRuntimeSupport, isFalse);
      expect(state.availableActions, isEmpty);
      expect(state.hasSession, isFalse);
    });

    test('reports session and action availability from the public model', () {
      const state = GuidedRescueState(
        hasRuntimeSupport: true,
        availableActions: <GuidedRescueAction>{
          GuidedRescueAction.requestStatus,
          GuidedRescueAction.buzzerOn,
        },
        targetNodeId: 0x1001,
        rescueNodeId: 0x2002,
      );

      expect(state.hasSession, isTrue);
      expect(state.canRun(GuidedRescueAction.requestStatus), isTrue);
      expect(state.canRun(GuidedRescueAction.acknowledgeSos), isFalse);
    });

    test('copyWith can clear the last error without losing session data', () {
      final state = GuidedRescueState(
        hasRuntimeSupport: true,
        availableActions: const <GuidedRescueAction>{},
        targetNodeId: 0x1001,
        rescueNodeId: 0x2002,
        lastError: 'boom',
      );

      final cleared = state.copyWith(clearLastError: true);

      expect(cleared.targetNodeId, 0x1001);
      expect(cleared.rescueNodeId, 0x2002);
      expect(cleared.lastError, isNull);
    });
  });
}
