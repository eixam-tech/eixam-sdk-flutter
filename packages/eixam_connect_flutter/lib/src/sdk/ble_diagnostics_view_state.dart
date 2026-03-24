import '../device/ble_debug_state.dart';

class BleDiagnosticsViewState {
  const BleDiagnosticsViewState({
    required this.adapterStateLabel,
    required this.connectionStatusLabel,
    required this.compatibilityModeLabel,
    required this.lastCommandLabel,
    required this.hasScanResults,
  });

  factory BleDiagnosticsViewState.fromState(BleDebugState state) {
    final softCompatible = state.eixamServiceFound &&
        state.telFound &&
        state.sosFound &&
        state.inetFound;

    return BleDiagnosticsViewState(
      adapterStateLabel: state.adapterState.toString(),
      connectionStatusLabel: state.connectionStatus.name,
      compatibilityModeLabel: !softCompatible
          ? 'Incompatible'
          : state.cmdFound
              ? 'Full'
              : 'Soft',
      lastCommandLabel: _lastCommandLabel(state.lastCommandSent),
      hasScanResults: state.scanResults.isNotEmpty,
    );
  }

  final String adapterStateLabel;
  final String connectionStatusLabel;
  final String compatibilityModeLabel;
  final String lastCommandLabel;
  final bool hasScanResults;

  static String _lastCommandLabel(String? payloadHex) {
    if (payloadHex == null || payloadHex.trim().isEmpty) {
      return '-';
    }
    final firstToken = payloadHex.trim().split(RegExp(r'\s+')).first;
    final opcode = int.tryParse(firstToken, radix: 16);
    if (opcode == null) {
      return payloadHex;
    }

    return switch (opcode) {
      0x01 => 'INET OK',
      0x02 => 'INET LOST',
      0x03 => 'POS CONFIRMED',
      0x04 => 'SOS CANCEL / RESOLVE',
      0x05 => 'SOS CONFIRM',
      0x06 => 'SOS TRIGGER APP',
      0x07 => 'BACKEND SOS ACK',
      0x08 => 'SOS ACK RELAY',
      0x10 => 'SHUTDOWN',
      _ => '0x${opcode.toRadixString(16).padLeft(2, '0')}',
    };
  }
}
