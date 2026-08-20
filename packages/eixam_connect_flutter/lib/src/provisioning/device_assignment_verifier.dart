import 'package:eixam_connect_core/eixam_connect_core.dart';

abstract interface class DeviceAssignmentVerifier {
  Future<bool> verifyAssignment({required int nodeId});
}

abstract interface class DeviceAssignmentCreator {
  Future<bool> createAssignment({
    required int nodeId,
    required String firmwareVersion,
    required String hardwareModel,
    required DateTime pairedAt,
  });
}

final class RegisteredDeviceAssignmentVerifier
    implements DeviceAssignmentVerifier {
  const RegisteredDeviceAssignmentVerifier({
    required this.repository,
    this.onAssignmentVerified,
  });

  final SdkDeviceRegistryRepository repository;
  final void Function(int nodeId)? onAssignmentVerified;

  @override
  Future<bool> verifyAssignment({required int nodeId}) async {
    final canonicalHardwareId = nodeId.toString();
    final devices = await repository.listRegisteredDevices();
    final matched = devices.any(
      (device) => device.hardwareId == canonicalHardwareId,
    );
    if (matched) {
      onAssignmentVerified?.call(nodeId);
    }
    return matched;
  }
}

final class RegisteredDeviceAssignmentCreator
    implements DeviceAssignmentCreator {
  const RegisteredDeviceAssignmentCreator({required this.repository});

  final SdkDeviceRegistryRepository repository;

  @override
  Future<bool> createAssignment({
    required int nodeId,
    required String firmwareVersion,
    required String hardwareModel,
    required DateTime pairedAt,
  }) async {
    final canonicalHardwareId = nodeId.toString();
    final registered = await repository.upsertRegisteredDevice(
      hardwareId: canonicalHardwareId,
      firmwareVersion: firmwareVersion,
      hardwareModel: hardwareModel,
      pairedAt: pairedAt,
    );
    return registered.hardwareId == canonicalHardwareId;
  }
}
