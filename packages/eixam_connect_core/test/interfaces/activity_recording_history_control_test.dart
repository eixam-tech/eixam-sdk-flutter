import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'history capability is optional and independent of existing controls',
    () {
      final Object history = _History();
      expect(history, isA<ActivityRecordingHistoryControl>());
      expect(history, isNot(isA<EixamConnectSdk>()));
      expect(history, isNot(isA<ActivityRecordingControl>()));
      final Object legacy = _Legacy();
      expect(legacy, isNot(isA<ActivityRecordingHistoryControl>()));
      final Future<SdkActivityRecordingHistoryPage> Function({
        int limit,
        String? cursor,
      })
      list = (history as ActivityRecordingHistoryControl)
          .listFinishedActivityRecordings;
      expect(list, isA<Function>());
    },
  );

  test('history page copies items and derives continuation consistently', () {
    final items = <SdkActivityRecording>[];
    final page = SdkActivityRecordingHistoryPage(
      items: items,
      nextCursor: 'opaque',
    );
    items.add(
      SdkActivityRecording(
        recordingId: 'id',
        activitySessionId: 'session',
        activityKey: 'test',
        activitySessionStartedAt: DateTime.utc(2026),
        recordingStartedAt: DateTime.utc(2026),
        endedAt: DateTime.utc(2026),
        phase: ActivityRecordingPhase.finished,
        inputState: ActivityRecordingInputState.unbound,
        recoveryState: ActivityRecordingRecoveryState.idle,
        routeQuality: ActivityRecordingRouteQuality.unknown,
      ),
    );
    expect(page.items, isEmpty);
    expect(() => page.items.add(items.single), throwsUnsupportedError);
    expect(page.hasMore, isTrue);
    expect(SdkActivityRecordingHistoryPage(items: []).hasMore, isFalse);
  });
}

class _History implements ActivityRecordingHistoryControl {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Legacy implements EixamConnectSdk, ActivityRecordingControl {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
