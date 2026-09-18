import 'package:eixam_connect_core/eixam_connect_core.dart';

typedef FirmwareDfuStatusRefreshHook =
    Future<DeviceStatus> Function({
      required String deviceId,
      required int attempt,
      required String targetVersion,
    });

abstract interface class DeviceMigrationFirmwareService {
  Future<FirmwareRelease?> resolveMigrationRelease({
    required String hardwareModel,
  });

  Future<FirmwareUpdateSession> startMigrationFirmwareUpdate({
    required DeviceStatus sourceStatus,
    required FirmwareRelease release,
    required FirmwareDfuStatusRefreshHook postMigrationStatusRefresh,
    FirmwareUpdatePolicy policy = const FirmwareUpdatePolicy(),
  });
}
