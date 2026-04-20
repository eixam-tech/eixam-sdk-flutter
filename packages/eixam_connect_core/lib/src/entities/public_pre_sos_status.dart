import '../enums/device_sos_transition_source.dart';

class PublicPreSosStatus {
  const PublicPreSosStatus({
    required this.active,
    required this.startedAt,
    required this.expectedActivationAt,
    required this.remainingSeconds,
    required this.mirroredOnDevice,
    required this.origin,
  });

  final bool active;
  final DateTime startedAt;
  final DateTime expectedActivationAt;
  final int remainingSeconds;
  final bool mirroredOnDevice;
  final DeviceSosTransitionSource? origin;
}
