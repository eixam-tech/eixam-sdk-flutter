enum PreferredDeviceReconnectResultStatus {
  connected,
  reconnecting,
  noKnownDevice,
  bluetoothOff,
  permissionMissing,
  failed,
  exhausted,
}

class PreferredDeviceReconnectResult {
  const PreferredDeviceReconnectResult({
    required this.status,
    this.reason,
  });

  const PreferredDeviceReconnectResult.connected({String? reason})
      : this(
          status: PreferredDeviceReconnectResultStatus.connected,
          reason: reason,
        );

  const PreferredDeviceReconnectResult.reconnecting({String? reason})
      : this(
          status: PreferredDeviceReconnectResultStatus.reconnecting,
          reason: reason,
        );

  const PreferredDeviceReconnectResult.noKnownDevice({String? reason})
      : this(
          status: PreferredDeviceReconnectResultStatus.noKnownDevice,
          reason: reason,
        );

  const PreferredDeviceReconnectResult.bluetoothOff({String? reason})
      : this(
          status: PreferredDeviceReconnectResultStatus.bluetoothOff,
          reason: reason,
        );

  const PreferredDeviceReconnectResult.permissionMissing({String? reason})
      : this(
          status: PreferredDeviceReconnectResultStatus.permissionMissing,
          reason: reason,
        );

  const PreferredDeviceReconnectResult.failed({String? reason})
      : this(
          status: PreferredDeviceReconnectResultStatus.failed,
          reason: reason,
        );

  const PreferredDeviceReconnectResult.exhausted({String? reason})
      : this(
          status: PreferredDeviceReconnectResultStatus.exhausted,
          reason: reason,
        );

  final PreferredDeviceReconnectResultStatus status;
  final String? reason;

  bool get connected =>
      status == PreferredDeviceReconnectResultStatus.connected;

  bool get reconnecting =>
      status == PreferredDeviceReconnectResultStatus.reconnecting;

  bool get blocked =>
      status == PreferredDeviceReconnectResultStatus.bluetoothOff ||
      status == PreferredDeviceReconnectResultStatus.permissionMissing;

  bool get terminal =>
      status == PreferredDeviceReconnectResultStatus.noKnownDevice ||
      status == PreferredDeviceReconnectResultStatus.exhausted;
}
