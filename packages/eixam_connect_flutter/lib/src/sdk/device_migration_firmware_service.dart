import 'package:eixam_connect_core/eixam_connect_core.dart';

typedef FirmwareDfuStatusRefreshHook =
    Future<DeviceStatus> Function({
      required String deviceId,
      required int attempt,
      required String targetVersion,
    });

abstract interface class DeviceMigrationFirmwareService {
  Future<FirmwareUpdateSession?> getActiveMigrationFirmwareUpdate();

  Future<FirmwareUpdateSession?> inspectMigrationPhysicalRecovery();

  Future<FirmwareUpdateSession?> verifyRecoveredMigrationFirmware({
    required DeviceStatus verifiedStatus,
  });

  Future<FirmwareRelease?> resolveMigrationRelease({
    required String hardwareModel,
  });

  Future<FirmwareUpdateSession> startMigrationFirmwareUpdate({
    required DeviceStatus sourceStatus,
    required FirmwareRelease release,
    required FirmwareDfuStatusRefreshHook postMigrationStatusRefresh,
    FirmwareUpdatePolicy policy = const FirmwareUpdatePolicy(),
  });

  Stream<FirmwareUpdateProgress> watchMigrationFirmwareProgress({
    required String deviceId,
  });

  Future<FirmwareUpdateSession> recoverMigrationFirmwareUpdate({
    required String bootloaderDeviceId,
    required String releaseId,
    required String targetVersion,
  });
}
