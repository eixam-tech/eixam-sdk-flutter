import 'package:flutter/foundation.dart';

import '../device/ble_debug_registry.dart';

/// SOS delivery is safety-critical and must be observable in release builds
/// (QA logcat, field reports). Only fixed `SOS_OUTBOX_*`,
/// `TAG_NOTIFY_LIVENESS` and `TAG_REPAIR_RESTART_REQUIRED` codes, action
/// kinds, counters and error types are
/// logged: never identifiers, tokens, topics, payloads or locations. Lines are still sanitized by the diagnostics
/// registry.
@visibleForTesting
void Function(String line)? sdkReleaseLogSinkForTesting;

void sdkReleaseLog(String line) {
  assert(
    line.startsWith('SOS_OUTBOX_') ||
        line.startsWith('TAG_NOTIFY_LIVENESS ') ||
        line.startsWith('TAG_REPAIR_RESTART_REQUIRED '),
    'release log is SOS delivery and TAG link health only',
  );
  BleDebugRegistry.instance.recordEvent(line);
  final sink = sdkReleaseLogSinkForTesting;
  if (sink != null) {
    sink(line);
    return;
  }
  debugPrint('[EIXAM_SDK] $line');
}
