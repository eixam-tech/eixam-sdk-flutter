import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:test/test.dart';

import '../support/fakes/fake_guided_rescue_repository.dart';

void main() {
  group('Guided Rescue use cases', () {
    test('get state and set session delegate to the repository', () async {
      final repository = FakeGuidedRescueRepository(
        initialState: const GuidedRescueState.unsupported(),
      );
      final getState = GetGuidedRescueStateUseCase(repository);
      final setSession = SetGuidedRescueSessionUseCase(repository);

      expect((await getState()).hasRuntimeSupport, isFalse);

      final configured = await setSession(
        targetNodeId: 0x1001,
        rescueNodeId: 0x2002,
      );

      expect(configured.targetNodeId, 0x1001);
      expect(configured.rescueNodeId, 0x2002);
    });

    test('request position, request status, acknowledge, and buzzer actions delegate', () async {
      final repository = FakeGuidedRescueRepository();

      await RequestGuidedRescuePositionUseCase(repository)();
      await RequestGuidedRescueStatusUseCase(repository)();
      await AcknowledgeGuidedRescueSosUseCase(repository)();
      await EnableGuidedRescueBuzzerUseCase(repository)();
      await DisableGuidedRescueBuzzerUseCase(repository)();

      expect(repository.requestPositionCallCount, 1);
      expect(repository.requestStatusCallCount, 1);
      expect(repository.acknowledgeSosCallCount, 1);
      expect(repository.enableBuzzerCallCount, 1);
      expect(repository.disableBuzzerCallCount, 1);
    });
  });
}
