import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'recording capability is independent of facade and other capabilities',
    () {
      final Object control = _RecordingContractOnly();
      expect(control, isA<ActivityRecordingControl>());
      expect(control, isNot(isA<EixamConnectSdk>()));
      expect(control, isNot(isA<ActivitySessionControl>()));
      expect(control, isNot(isA<ActivityAvailabilityControl>()));
      expect(control, isNot(isA<TrackingRepository>()));
    },
  );

  test(
    'existing facade/session/availability doubles need no recording capability',
    () {
      final EixamConnectSdk sdk = _LegacySdk();
      final ActivitySessionControl session = _ExistingSessionControl();
      final ActivityAvailabilityControl availability =
          _ExistingAvailabilityControl();
      expect(sdk, isNot(isA<ActivityRecordingControl>()));
      expect(session, isNot(isA<ActivityRecordingControl>()));
      expect(availability, isNot(isA<ActivityRecordingControl>()));
    },
  );

  test(
    'exports exact independent command and known-ID route-read signatures',
    () {
      final ActivityRecordingControl control = _RecordingContractOnly();
      final Future<SdkActivityRecording?> Function() active =
          control.getActiveActivityRecording;
      final Stream<SdkActivityRecording?> Function() watch =
          control.watchActiveActivityRecording;
      final Future<SdkActivityRecording> Function({
        required SdkActivitySession activitySession,
        String? deviceIdentity,
      })
      start = control.startActivityRecording;
      final Future<SdkActivityRecording> Function({
        required String recordingId,
        required String deviceIdentity,
      })
      bind = control.bindActivityRecordingDevice;
      final Future<SdkActivityRecording> Function({required String recordingId})
      recover = control.recoverActivityRecordingHistory;
      final Future<SdkActivityRecording> Function({
        required String recordingId,
        DateTime? endedAt,
      })
      finish = control.finishActivityRecording;
      final Future<SdkActivityRecording?> Function({
        required String recordingId,
      })
      known = control.getActivityRecording;
      final Stream<SdkActivityRoutePage> Function({
        required String recordingId,
        DateTime? fromInclusive,
        int? expectedRouteRevision,
        int pageSize,
      })
      route = control.readActivityRecordingRoute;
      expect([
        active,
        watch,
        start,
        bind,
        recover,
        finish,
        known,
        route,
      ], everyElement(isA<Function>()));
    },
  );

  test(
    'recording error preserves code/message without expanding sealed errors',
    () {
      const error = ActivityRecordingException(
        'E_RECORDING_ROUTE_REVISION_CHANGED',
        'Read a fresh recording revision.',
      );
      expect(error, isA<Exception>());
      expect(error, isNot(isA<EixamSdkException>()));
      expect(error.code, 'E_RECORDING_ROUTE_REVISION_CHANGED');
      expect(error.message, 'Read a fresh recording revision.');
      expect(
        error.toString(),
        'ActivityRecordingException(code: E_RECORDING_ROUTE_REVISION_CHANGED, '
        'message: Read a fresh recording revision.)',
      );
    },
  );
}

// Signature-only doubles: no commands run and no storage behavior is simulated.
class _RecordingContractOnly implements ActivityRecordingControl {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _LegacySdk implements EixamConnectSdk {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ExistingSessionControl implements ActivitySessionControl {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ExistingAvailabilityControl implements ActivityAvailabilityControl {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
