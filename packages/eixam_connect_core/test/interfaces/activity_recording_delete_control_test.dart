import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:test/test.dart';

void main() {
  test('deletion is an independent optional capability', () {
    final Object deletion = _Deletion();
    expect(deletion, isA<ActivityRecordingDeleteControl>());
    expect(deletion, isNot(isA<EixamConnectSdk>()));
    expect(deletion, isNot(isA<ActivityRecordingControl>()));
    expect(deletion, isNot(isA<ActivityRecordingHistoryControl>()));
    final Object legacy = _Legacy();
    expect(legacy, isNot(isA<ActivityRecordingDeleteControl>()));
    final Future<void> Function({required String recordingId}) delete =
        (deletion as ActivityRecordingDeleteControl)
            .deleteFinishedActivityRecording;
    expect(delete, isA<Function>());
  });
}

class _Deletion implements ActivityRecordingDeleteControl {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Legacy
    implements
        EixamConnectSdk,
        ActivityRecordingControl,
        ActivityRecordingHistoryControl {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
