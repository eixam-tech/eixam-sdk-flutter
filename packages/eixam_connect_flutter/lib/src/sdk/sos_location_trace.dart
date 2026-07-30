import 'package:flutter/foundation.dart';

import '../device/ble_debug_registry.dart';

const bool sosLocationTraceEnabled = kDebugMode &&
    bool.fromEnvironment(
      'EIXAM_SOS_LOCATION_TRACE',
      defaultValue: false,
    );

/// Temporary, privacy-safe device-console trace for the SOS location cutover.
///
/// Callers must provide bounded state metadata only. Coordinates, identifiers,
/// payloads, credentials, user data, and exception text are forbidden.
abstract final class SosLocationTrace {
  static void emit(String event, [Map<String, Object?> fields = const {}]) {
    if (!sosLocationTraceEnabled) {
      return;
    }
    try {
      final attributes = fields.entries
          .map((entry) => '${entry.key}=${entry.value ?? 'none'}')
          .join(' ');
      safeSdkDebugPrint(
        attributes.isEmpty
            ? 'EIXAM_SOS_LOC event=$event'
            : 'EIXAM_SOS_LOC event=$event $attributes',
      );
    } catch (_) {
      // Diagnostics must never affect SOS ownership or telemetry behavior.
    }
  }
}
