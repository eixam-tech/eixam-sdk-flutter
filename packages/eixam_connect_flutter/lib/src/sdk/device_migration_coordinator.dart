import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../device/ble_client.dart';
import '../device/ble_scan_result.dart';
import '../device/canonical_hardware_id.dart';
import '../device/meshtastic_metadata_probe.dart';
import 'device_migration_firmware_service.dart';

final class DeviceMigrationCoordinator {
  DeviceMigrationCoordinator({
    required this.bleClient,
    required this.metadataProbe,
    required this.firmwareUpdates,
    this.rediscoveryTimeout = const Duration(seconds: 12),
  });

  static const int wisMeshTagHardwareModel = 105;
  static const String eixamFirmwareCatalogModel = 'EIXAM R1';
  static const String ambiguousDeviceCode = 'ambiguousPostMigrationDevice';

  final BleClient bleClient;
  final MeshtasticMetadataProbe metadataProbe;
  final DeviceMigrationFirmwareService firmwareUpdates;
  final Duration rediscoveryTimeout;

  BleScanResult? _verifiedMigratedDevice;

  Future<DeviceMigrationCandidate> inspect({
    required String deviceId,
    String? advertisedName,
  }) async {
    final normalized = deviceId.trim();
    if (normalized.isEmpty) {
      return _unableCandidate(
        deviceId: normalized,
        advertisedName: advertisedName,
        code: 'missingDeviceId',
      );
    }
    try {
      final probe = await metadataProbe.inspect(normalized);
      final model = probe.hardwareModel;
      final identity = _strongestIdentity(
        deviceId: normalized,
        hardwareMac: probe.hardwareMac,
        nodeNumber: probe.nodeNumber,
      );
      return DeviceMigrationCandidate(
        deviceId: normalized,
        advertisedName: advertisedName,
        compatibility: model == 0
            ? DeviceMigrationCompatibility.unableToVerify
            : model == wisMeshTagHardwareModel
            ? DeviceMigrationCompatibility.compatible
            : DeviceMigrationCompatibility.unsupportedHardware,
        sourceHardwareModel: model == 0 ? null : model,
        sourceFirmwareVersion: probe.firmwareVersion,
        stableIdentity: identity.$1,
        identityKind: identity.$2,
        sourceNodeNumber: probe.nodeNumber,
        batteryPercentage: probe.batteryPercentage,
        detailCode: model == 0 ? 'hardwareModelUnset' : null,
        inspectedAt: DateTime.now(),
      );
    } catch (_) {
      return _unableCandidate(
        deviceId: normalized,
        advertisedName: advertisedName,
        code: 'hardwareVerificationFailed',
      );
    }
  }

  Future<DeviceMigrationResult> migrate(
    DeviceMigrationCandidate candidate,
  ) async {
    if (!candidate.isCompatible ||
        candidate.sourceHardwareModel != wisMeshTagHardwareModel) {
      return _blocked(candidate, 'migrationCandidateNotCompatible');
    }

    // Never trust a caller-constructed or stale candidate. The exact selected
    // platform ID is probed again immediately before artifact selection.
    final revalidated = await inspect(
      deviceId: candidate.deviceId,
      advertisedName: candidate.advertisedName,
    );
    if (!revalidated.isCompatible ||
        revalidated.sourceHardwareModel != wisMeshTagHardwareModel) {
      return _blocked(revalidated, 'migrationRevalidationFailed');
    }
    if (!_samePreMigrationIdentity(candidate, revalidated)) {
      return _blocked(revalidated, 'migrationIdentityChanged');
    }

    FirmwareRelease? release;
    try {
      release = await firmwareUpdates.resolveMigrationRelease(
        hardwareModel: eixamFirmwareCatalogModel,
      );
    } catch (_) {
      return _blocked(revalidated, 'migrationArtifactUnavailable');
    }
    if (release == null) {
      return _blocked(revalidated, 'migrationArtifactUnavailable');
    }

    _verifiedMigratedDevice = null;
    final sourceStatus = DeviceStatus(
      deviceId: revalidated.deviceId,
      nodeId: revalidated.sourceNodeNumber,
      canonicalHardwareId: normalizeCanonicalHardwareId(
        revalidated.stableIdentity,
      ),
      deviceAlias: revalidated.advertisedName,
      model: eixamFirmwareCatalogModel,
      paired: true,
      activated: false,
      connected: true,
      batteryPercent: revalidated.batteryPercentage,
      firmwareVersion: revalidated.sourceFirmwareVersion ?? 'stock-meshtastic',
    );
    final session = await firmwareUpdates.startMigrationFirmwareUpdate(
      sourceStatus: sourceStatus,
      release: release,
      policy: const FirmwareUpdatePolicy(
        supportedHardwareModels: <String>[eixamFirmwareCatalogModel],
        requireKnownDeviceBattery: false,
      ),
      postMigrationStatusRefresh:
          ({required deviceId, required attempt, required targetVersion}) =>
              _rediscoverAndVerify(
                candidate: revalidated,
                targetVersion: targetVersion,
              ),
    );

    if (session.state == FirmwareUpdateState.completed &&
        _verifiedMigratedDevice != null) {
      return DeviceMigrationResult(
        outcome: DeviceMigrationOutcome.completed,
        candidate: revalidated,
        firmwareSession: session,
        migratedDevice: _verifiedMigratedDevice!.toPublic(),
      );
    }
    final ambiguous = session.failureCode == ambiguousDeviceCode;
    return DeviceMigrationResult(
      outcome: ambiguous
          ? DeviceMigrationOutcome.ambiguousPostMigrationDevice
          : session.state == FirmwareUpdateState.recoveryRequired
          ? DeviceMigrationOutcome.recoveryRequired
          : session.state == FirmwareUpdateState.blocked
          ? DeviceMigrationOutcome.blocked
          : DeviceMigrationOutcome.failed,
      candidate: revalidated,
      firmwareSession: session,
      failureCode: session.failureCode,
      failureMessage: session.failureMessage,
    );
  }

  Future<DeviceStatus> _rediscoverAndVerify({
    required DeviceMigrationCandidate candidate,
    required String targetVersion,
  }) async {
    final scans = await bleClient.scan(timeout: rediscoveryTimeout);
    final eixam = scans.where(_looksLikeEixam).toList(growable: false);
    final matches = eixam
        .where((scan) => _stronglyMatches(candidate, scan))
        .toList(growable: false);
    if (matches.length > 1 || (matches.isEmpty && eixam.length > 1)) {
      throw const FirmwareUpdateException(
        ambiguousDeviceCode,
        'Multiple Eixam devices were visible and identity was ambiguous.',
        requiresRecovery: false,
      );
    }
    if (matches.isEmpty) {
      return _disconnectedStatus(candidate.deviceId);
    }

    final match = matches.single;
    try {
      await bleClient.connect(match.deviceId);
      if (!await bleClient.isEixamCompatible(match.deviceId)) {
        throw const FirmwareUpdateException(
          'postMigrationGattIncompatible',
          'The migrated device did not expose the required Eixam GATT API.',
          requiresRecovery: false,
        );
      }
      final installed = await bleClient.readFirmwareVersion(match.deviceId);
      _verifiedMigratedDevice = match;
      return DeviceStatus(
        deviceId: match.deviceId,
        canonicalHardwareId: match.canonicalHardwareId,
        deviceAlias: match.name,
        model: eixamFirmwareCatalogModel,
        paired: true,
        activated: false,
        connected: true,
        firmwareVersion: installed,
      );
    } on FirmwareUpdateException {
      rethrow;
    } catch (_) {
      return _disconnectedStatus(match.deviceId);
    }
  }

  DeviceStatus _disconnectedStatus(String deviceId) => DeviceStatus(
    deviceId: deviceId,
    model: eixamFirmwareCatalogModel,
    paired: false,
    activated: false,
    connected: false,
  );

  bool _looksLikeEixam(BleScanResult scan) {
    final public = scan.toPublic();
    return public.isEixamDevice && !public.isDfuBootloader;
  }

  bool _stronglyMatches(
    DeviceMigrationCandidate candidate,
    BleScanResult scan,
  ) {
    if (scan.deviceId == candidate.deviceId) return true;
    final candidateMac = normalizeCanonicalHardwareId(candidate.stableIdentity);
    final scanMac = normalizeCanonicalHardwareId(
      scan.canonicalHardwareId ?? scan.deviceId,
    );
    return candidateMac != null && scanMac == candidateMac;
  }

  bool _samePreMigrationIdentity(
    DeviceMigrationCandidate before,
    DeviceMigrationCandidate after,
  ) {
    if (before.deviceId != after.deviceId) return false;
    final beforeIdentity = before.stableIdentity?.trim();
    final afterIdentity = after.stableIdentity?.trim();
    return beforeIdentity == null ||
        beforeIdentity.isEmpty ||
        afterIdentity == null ||
        afterIdentity.isEmpty ||
        beforeIdentity == afterIdentity;
  }

  (String?, DeviceMigrationIdentityKind) _strongestIdentity({
    required String deviceId,
    required String? hardwareMac,
    required int? nodeNumber,
  }) {
    final mac =
        normalizeCanonicalHardwareId(hardwareMac) ??
        normalizeCanonicalHardwareId(deviceId);
    if (mac != null) {
      return (mac, DeviceMigrationIdentityKind.hardwareMac);
    }
    if (nodeNumber != null && nodeNumber != 0) {
      return (
        '!${nodeNumber.toRadixString(16).padLeft(8, '0')}',
        DeviceMigrationIdentityKind.meshtasticNodeNumber,
      );
    }
    if (deviceId.trim().isNotEmpty) {
      return (deviceId.trim(), DeviceMigrationIdentityKind.platformIdentifier);
    }
    return (null, DeviceMigrationIdentityKind.none);
  }

  DeviceMigrationCandidate _unableCandidate({
    required String deviceId,
    required String? advertisedName,
    required String code,
  }) => DeviceMigrationCandidate(
    deviceId: deviceId,
    advertisedName: advertisedName,
    compatibility: DeviceMigrationCompatibility.unableToVerify,
    identityKind: DeviceMigrationIdentityKind.none,
    inspectedAt: DateTime.now(),
    detailCode: code,
  );

  DeviceMigrationResult _blocked(
    DeviceMigrationCandidate candidate,
    String code,
  ) => DeviceMigrationResult(
    outcome: DeviceMigrationOutcome.blocked,
    candidate: candidate,
    failureCode: code,
  );
}
