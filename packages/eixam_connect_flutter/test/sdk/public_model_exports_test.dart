import 'package:eixam_connect_flutter/eixam_connect_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('umbrella entrypoint exports documented public models', () {
    const publicTypes = <Type>[
      PreferredDeviceReconnectResult,
      PreferredDeviceReconnectResultStatus,
      SosHistoryItem,
      SosHistoryPage,
      SosHistoryTelemetry,
      SosIncidentProgress,
      SosProgressState,
      SosProgressStep,
      SosProgressStepType,
      ActivityRecordingControl,
      SdkActivityRecording,
      SdkActivityRoutePoint,
      SdkActivityRouteSegment,
      SdkActivityRouteGap,
      SdkActivityRoutePage,
      ActivityRecordingPhase,
      ActivityRecordingInputState,
      ActivityRecordingRecoveryState,
      ActivityRecordingRouteQuality,
      ActivityRecordingGapState,
      ActivityRecordingGapReason,
      ActivityRecordingIssue,
      ActivityRecordingException,
    ];

    expect(publicTypes, hasLength(23));
    expect(publicTypes.toSet(), hasLength(publicTypes.length));
  });
}
