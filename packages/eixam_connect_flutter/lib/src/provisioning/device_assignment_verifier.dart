import 'package:eixam_connect_core/eixam_connect_core.dart';

bool registeredHardwareIdMatchesNodeId(String hardwareId, int nodeId) {
  final trimmed = hardwareId.trim();
  if (trimmed.isEmpty) {
    return false;
  }
  if (trimmed == nodeId.toString()) {
    return true;
  }
  return int.tryParse(trimmed, radix: 10) == nodeId;
}

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
    final devices = await repository.listRegisteredDevices();
    final matched = devices.any(
      (device) => registeredHardwareIdMatchesNodeId(device.hardwareId, nodeId),
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
    return registeredHardwareIdMatchesNodeId(registered.hardwareId, nodeId);
  }
}
