import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../device/canonical_hardware_id.dart';

enum TagPairingCodeMatchState {
  invalidCode,
  unsupportedCode,
  notFound,
  ambiguous,
  inspectionRequired,
  identityUnverified,
  identityMismatch,
  unsupportedHardware,
  matched,
}

/// A read-only correlation snapshot. It never pairs, assigns or starts firmware.
/// A host must not treat [candidate] alone as a confirmed match.
final class TagPairingCodeMatch {
  const TagPairingCodeMatch._(this.state, this.code, this.candidate);

  final TagPairingCodeMatchState state;
  final TagPairingCode? code;
  final EixamBleScanResult? candidate;
}

/// Stateless policy shared by manual-acquisition adapters and future QR hosts.
/// Supply one complete, fresh discovery snapshot; RSSI and list order are ignored.
abstract final class TagPairingCodeCorrelator {
  static TagPairingCodeMatch find(
    String payload,
    Iterable<EixamBleScanResult> devices,
  ) {
    final inspection = TagPairingCode.inspect(payload);
    final code = inspection.code;
    if (code == null) {
      return TagPairingCodeMatch._(
        inspection.format == TagPairingCodeFormat.invalid
            ? TagPairingCodeMatchState.invalidCode
            : TagPairingCodeMatchState.unsupportedCode,
        null,
        null,
      );
    }
    final candidates = <String, EixamBleScanResult>{};
    for (final device in devices) {
      if (device.isDfuBootloader || !device.connectable) continue;
      final name = device.name.toUpperCase();
      final legacy =
          device.brandClassification == BleDiscoveredDeviceBrand.meshtastic &&
          name == 'MESHTASTIC_${code.legacyAdvertisingSuffix}';
      final current =
          device.brandClassification == BleDiscoveredDeviceBrand.eixam &&
          (name == 'EIXAM_A6${code.hardwareSuffix}' ||
              name == 'N6${code.hardwareSuffix}' ||
              _macMatches(code, device.canonicalHardwareId));
      if (legacy || current) candidates[device.deviceId] = device;
    }
    if (candidates.length != 1) {
      return TagPairingCodeMatch._(
        candidates.isEmpty
            ? TagPairingCodeMatchState.notFound
            : TagPairingCodeMatchState.ambiguous,
        code,
        null,
      );
    }
    return TagPairingCodeMatch._(
      TagPairingCodeMatchState.inspectionRequired,
      code,
      candidates.values.single,
    );
  }

  /// Verify only the selected peripheral using authoritative SDK inspection.
  /// No node-number derivation: firmware may replace a colliding mesh node ID.
  static TagPairingCodeMatch verifyLegacy(
    TagPairingCodeMatch lookup,
    DeviceMigrationCandidate inspected,
  ) {
    if (lookup.state != TagPairingCodeMatchState.inspectionRequired &&
        lookup.state != TagPairingCodeMatchState.matched) {
      return lookup;
    }
    final selected = lookup.candidate!;
    if (selected.brandClassification != BleDiscoveredDeviceBrand.meshtastic ||
        inspected.deviceId != selected.deviceId) {
      return _result(lookup, TagPairingCodeMatchState.identityMismatch);
    }
    if (inspected.compatibility ==
        DeviceMigrationCompatibility.unsupportedHardware) {
      return _result(lookup, TagPairingCodeMatchState.unsupportedHardware);
    }
    if (inspected.compatibility != DeviceMigrationCompatibility.compatible ||
        inspected.identityKind != DeviceMigrationIdentityKind.hardwareMac ||
        normalizeCanonicalHardwareId(inspected.stableIdentity) == null) {
      return _result(lookup, TagPairingCodeMatchState.identityUnverified);
    }
    return _result(
      lookup,
      _macMatches(lookup.code!, inspected.stableIdentity)
          ? TagPairingCodeMatchState.matched
          : TagPairingCodeMatchState.identityMismatch,
    );
  }

  /// An unrelated already-connected TAG can never satisfy a QR lookup.
  static TagPairingCodeMatch verifyCurrent(
    TagPairingCodeMatch lookup,
    DeviceStatus status,
  ) {
    if (lookup.state != TagPairingCodeMatchState.inspectionRequired &&
        lookup.state != TagPairingCodeMatchState.matched) {
      return lookup;
    }
    if (lookup.candidate!.brandClassification !=
            BleDiscoveredDeviceBrand.eixam ||
        status.deviceId != lookup.candidate!.deviceId) {
      return _result(lookup, TagPairingCodeMatchState.identityMismatch);
    }
    if (!status.connected ||
        normalizeCanonicalHardwareId(status.canonicalHardwareId) == null) {
      return _result(lookup, TagPairingCodeMatchState.identityUnverified);
    }
    return _result(
      lookup,
      _macMatches(lookup.code!, status.canonicalHardwareId)
          ? TagPairingCodeMatchState.matched
          : TagPairingCodeMatchState.identityMismatch,
    );
  }

  static TagPairingCodeMatch _result(
    TagPairingCodeMatch lookup,
    TagPairingCodeMatchState state,
  ) => TagPairingCodeMatch._(state, lookup.code, lookup.candidate);

  static bool _macMatches(TagPairingCode code, String? hardwareId) {
    final mac = normalizeCanonicalHardwareId(hardwareId);
    return mac != null && mac.replaceAll(':', '').endsWith(code.hardwareSuffix);
  }
}
