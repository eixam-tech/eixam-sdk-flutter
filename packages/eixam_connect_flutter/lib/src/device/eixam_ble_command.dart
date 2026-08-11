import '../diagnostics/security_diagnostics_redactor.dart';
import 'ble_command_criticality.dart';
import 'eixam_ble_protocol.dart';

enum BleCommandPayloadSensitivity { operational, secret }

class EixamDeviceCommand {
  factory EixamDeviceCommand.inetOk() => const EixamDeviceCommand._(
        opcode: 0x01,
        label: 'INET OK',
        bytes: <int>[0x01],
      );

  factory EixamDeviceCommand.inetLost() => const EixamDeviceCommand._(
        opcode: 0x02,
        label: 'INET LOST',
        bytes: <int>[0x02],
      );

  factory EixamDeviceCommand.positionConfirmed() => const EixamDeviceCommand._(
        opcode: 0x03,
        label: 'POS CONFIRMED',
        bytes: <int>[0x03],
      );

  factory EixamDeviceCommand.sosCancel({
    bool forceCmdCharacteristic = false,
  }) =>
      EixamDeviceCommand._(
        opcode: 0x04,
        label: 'SOS CANCEL',
        bytes: <int>[0x04],
        forceCmdCharacteristic: forceCmdCharacteristic,
      );

  factory EixamDeviceCommand.sosConfirm() => const EixamDeviceCommand._(
        opcode: 0x05,
        label: 'SOS CONFIRM',
        bytes: <int>[0x05],
      );

  factory EixamDeviceCommand.sosTriggerApp() => const EixamDeviceCommand._(
        opcode: 0x06,
        label: 'SOS TRIGGER APP',
        bytes: <int>[0x06],
      );

  factory EixamDeviceCommand.sosAck() => const EixamDeviceCommand._(
        opcode: 0x07,
        label: 'SOS ACK',
        bytes: <int>[0x07],
      );

  factory EixamDeviceCommand.sosAckRelay({required int nodeId}) {
    return EixamDeviceCommand._(
      opcode: 0x08,
      label: 'SOS ACK RELAY',
      bytes: <int>[
        0x08,
        nodeId & 0xFF,
        (nodeId >> 8) & 0xFF,
        (nodeId >> 16) & 0xFF,
        (nodeId >> 24) & 0xFF,
      ],
    );
  }

  factory EixamDeviceCommand.shutdown() => const EixamDeviceCommand._(
        opcode: 0x10,
        label: 'SHUTDOWN',
        bytes: <int>[0x10],
      );

  factory EixamDeviceCommand.notificationVolume(int volume) {
    return EixamDeviceCommand._(
      opcode: 0x11,
      label: 'BUZZER NOTIFY VOL',
      bytes: <int>[0x11, volume & 0xFF],
      forceCmdCharacteristic: true,
    );
  }

  factory EixamDeviceCommand.sosVolume(int volume) {
    return EixamDeviceCommand._(
      opcode: 0x12,
      label: 'BUZZER SOS VOL',
      bytes: <int>[0x12, volume & 0xFF],
      forceCmdCharacteristic: true,
    );
  }

  factory EixamDeviceCommand.reboot() => const EixamDeviceCommand._(
        opcode: 0x22,
        label: 'REBOOT',
        bytes: <int>[0x22],
        forceCmdCharacteristic: true,
      );

  factory EixamDeviceCommand.getDeviceStatus() => const EixamDeviceCommand._(
        opcode: 0x23,
        label: 'GET DEVICE STATUS',
        bytes: <int>[0x23],
        forceCmdCharacteristic: true,
      );

  /// Provisions the device LoRa region (legal per-country radio config).
  /// Payload `[0x20, regionCode]` where `regionCode` is a Meshtastic
  /// `RegionCode` byte. The device persists it and applies it on reboot.
  factory EixamDeviceCommand.setRegion(int regionCode) => EixamDeviceCommand._(
        opcode: 0x20,
        label: 'PROVISION REGION',
        bytes: <int>[0x20, regionCode & 0xFF],
        forceCmdCharacteristic: true,
      );
  const EixamDeviceCommand._({
    required this.opcode,
    required this.label,
    required this.bytes,
    this.forceCmdCharacteristic = false,
    // Reserved for a source-certified future secret-bearing command.
    // ignore: unused_element_parameter
    this.payloadSensitivity = BleCommandPayloadSensitivity.operational,
  });

  final int opcode;
  final String label;
  final List<int> bytes;
  final bool forceCmdCharacteristic;
  final BleCommandPayloadSensitivity payloadSensitivity;

  List<int> encode() => List<int>.unmodifiable(bytes);

  BleCommandCriticality get criticality {
    return switch (opcode) {
      0x04 || 0x06 || 0x10 || 0x20 || 0x22 => BleCommandCriticality.critical,
      _ => BleCommandCriticality.nonCritical,
    };
  }

  bool get isCritical => criticality == BleCommandCriticality.critical;

  bool get usesCmdCharacteristic =>
      forceCmdCharacteristic ||
      encode().length > EixamBleProtocol.inetMaxPayloadLength;

  String get targetCharacteristicUuid => usesCmdCharacteristic
      ? EixamBleProtocol.cmdWriteCharacteristicUuid
      : EixamBleProtocol.inetWriteCharacteristicUuid;

  String get encodedHex => EixamBleProtocol.hex(encode());

  /// Diagnostic representation of the payload. A future secret-bearing
  /// command must set [payloadSensitivity] to `secret`; its bytes will then be
  /// suppressed even in verbose diagnostics.
  String get diagnosticPayload =>
      SecurityDiagnosticsRedactor.formatBleCommandPayloadForDiagnostics(
        payloadSensitivity == BleCommandPayloadSensitivity.secret
            ? null
            : encodedHex,
        containsSecret:
            payloadSensitivity == BleCommandPayloadSensitivity.secret,
      );
}
