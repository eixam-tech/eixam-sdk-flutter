import 'package:flutter/foundation.dart';

/// Log for the TAG disconnect lease, readable from logcat or the device
/// console in debug and profile builds. Silent in release builds.
///
/// Deliberately **not** written to the shared `BleDebugRegistry` ring buffer
/// (30 events): lease lines are frequent and would evict SOS and BLE
/// diagnostics that the in-app diagnostics and SOS tooling rely on. Lines carry
/// no device identifiers, aliases or coordinates.
abstract final class TagLeaseLog {
  /// Replaces printing, for tests.
  @visibleForTesting
  static void Function(String line)? debugSink;

  static void write(String message) {
    final line = '[TAG_LEASE] $message';
    final sink = debugSink;
    if (sink != null) {
      sink(line);
      return;
    }
    if (!kReleaseMode) {
      debugPrint(line);
    }
  }
}
