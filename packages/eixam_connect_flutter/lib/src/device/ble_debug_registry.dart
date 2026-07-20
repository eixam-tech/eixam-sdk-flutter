import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:flutter/foundation.dart';

import '../diagnostics/security_diagnostics_redactor.dart';
import 'ble_adapter_state.dart';
import 'ble_connection_status.dart';
import 'eixam_ble_command.dart';
import 'ble_debug_event.dart';
import 'ble_debug_state.dart';
import 'ble_scan_result.dart';

typedef BleCommandWriter = Future<void> Function(EixamDeviceCommand command);
typedef BleScanner = Future<List<BleScanResult>> Function();

class BleDebugRegistry {
  BleDebugRegistry._();

  static final BleDebugRegistry instance = BleDebugRegistry._();

  StreamController<BleDebugState> _controller =
      StreamController<BleDebugState>.broadcast();

  BleDebugState _state = const BleDebugState();
  BleCommandWriter? _commandWriter;
  BleScanner? _scanner;
  bool? _allowSensitiveDiagnosticsOverride;

  Stream<BleDebugState> watch() => _controller.stream;

  BleDebugState get currentState => _state;

  static const List<String> _consoleDiagnosticPrefixes = <String>[
    'EIXAM_SDK_BUILD_MARKER',
    'EIXAM_RECONNECT_TRACE',
    'SOS_CAPABILITY_EVAL',
    'EXTERNAL_SOS',
    'BLE_SOS_PACKET_RAW',
    'BLE_SOS_CLASSIFY_DECISION',
    'REMOTE_RELAY_CANCEL_DETECT',
    '[REMOTE_RELAY_SOS]',
    'TEL raw payload',
    'SOS raw payload',
    '[DEVICE_PRE_SOS_COUNTDOWN]',
    '[DEVICE_SOS_STATE_DECISION]',
    '[SDK_SOS_CLASSIFY]',
    'SOS_TRACE',
    '[PRE_SOS_CYCLE]',
    '[APP_PRE_SOS_START]',
    '[APP_SOS_COUNTDOWN_ZERO]',
    '[NATIVE_PRE_SOS_BACKEND]',
    '[BACKGROUND_SOS]',
    'SOS_',
    'Device SOS backend sync created incident',
    'SOS_BACKEND_PAYLOAD_FINAL',
  ];

  void reset() {
    unawaited(resetForLifecycle());
  }

  Future<void> resetForLifecycle() async {
    final previousController = _controller;
    _commandWriter = null;
    _scanner = null;
    _allowSensitiveDiagnosticsOverride = null;
    _state = const BleDebugState();
    _controller = StreamController<BleDebugState>.broadcast();
    await previousController.close();
    _controller.add(_state);
  }

  void update({
    BleAdapterState? adapterState,
    String? selectedDeviceId,
    bool? eixamServiceFound,
    bool? telFound,
    bool? sosFound,
    bool? inetFound,
    bool? cmdFound,
    bool? telNotifySubscribed,
    bool? sosNotifySubscribed,
    bool? commandWriterReady,
    String? lastCommandSent,
    String? lastWriteTargetCharacteristic,
    String? lastWriteResult,
    DateTime? lastWriteAt,
    String? lastWriteError,
    String? lastPacketReceived,
    String? lastRawNotificationChannel,
    String? lastRawNotificationCharacteristic,
    String? lastRawNotificationPayloadHex,
    DateTime? lastRawNotificationAt,
    String? lastDecodedIncomingEventType,
    String? lastDecodeOutcome,
    DateTime? lastDecodedIncomingAt,
    List<String>? discoveredServices,
    List<BleScanResult>? scanResults,
    bool? isScanning,
    BleConnectionStatus? connectionStatus,
    String? connectionError,
  }) {
    _state = _state.copyWith(
      adapterState: adapterState,
      selectedDeviceId: selectedDeviceId,
      eixamServiceFound: eixamServiceFound,
      telFound: telFound,
      sosFound: sosFound,
      inetFound: inetFound,
      cmdFound: cmdFound,
      telNotifySubscribed: telNotifySubscribed,
      sosNotifySubscribed: sosNotifySubscribed,
      commandWriterReady: commandWriterReady,
      lastCommandSent: _safeDiagnosticHexField(lastCommandSent),
      lastWriteTargetCharacteristic: lastWriteTargetCharacteristic,
      lastWriteResult: lastWriteResult,
      lastWriteAt: lastWriteAt,
      lastWriteError: lastWriteError,
      lastPacketReceived: _safeDiagnosticHexField(lastPacketReceived),
      lastRawNotificationChannel: lastRawNotificationChannel,
      lastRawNotificationCharacteristic: lastRawNotificationCharacteristic,
      lastRawNotificationPayloadHex: _safeDiagnosticHexField(
        lastRawNotificationPayloadHex,
      ),
      lastRawNotificationAt: lastRawNotificationAt,
      lastDecodedIncomingEventType: lastDecodedIncomingEventType,
      lastDecodeOutcome: lastDecodeOutcome,
      lastDecodedIncomingAt: lastDecodedIncomingAt,
      discoveredServices: discoveredServices,
      scanResults: scanResults,
      isScanning: isScanning,
      connectionStatus: connectionStatus,
      connectionError: connectionError,
    );
    _controller.add(_state);
  }

  void recordEvent(String message) {
    final safeMessage = SecurityDiagnosticsRedactor.sanitizeEventMessage(
      message,
      allowSensitive: _allowSensitiveDiagnostics,
    );
    if (kDebugMode && _shouldPrintDiagnosticEvent(safeMessage)) {
      debugPrint(safeMessage);
    }
    final events = List<BleDebugEvent>.from(_state.events)
      ..add(BleDebugEvent(timestamp: DateTime.now(), message: safeMessage));
    if (events.length > 30) {
      events.removeRange(0, events.length - 30);
    }
    _state = _state.copyWith(events: events);
    _controller.add(_state);
  }

  bool _shouldPrintDiagnosticEvent(String message) {
    return _consoleDiagnosticPrefixes.any(message.startsWith);
  }

  void recordIncomingNotification({
    required String channel,
    required String characteristic,
    required String payloadHex,
    required DateTime receivedAt,
  }) {
    final safePayload =
        SecurityDiagnosticsRedactor.formatHexPayloadForDiagnostics(
      payloadHex,
      allowSensitive: _allowSensitiveDiagnostics,
    );
    _state = _state.copyWith(
      lastPacketReceived: safePayload,
      lastRawNotificationChannel: channel,
      lastRawNotificationCharacteristic: characteristic,
      lastRawNotificationPayloadHex: safePayload,
      lastRawNotificationAt: receivedAt,
    );
    _controller.add(_state);
  }

  void recordDecodedIncomingEvent({
    required String eventType,
    required String outcome,
    required DateTime receivedAt,
  }) {
    _state = _state.copyWith(
      lastDecodedIncomingEventType: eventType,
      lastDecodeOutcome: outcome,
      lastDecodedIncomingAt: receivedAt,
    );
    _controller.add(_state);
  }

  void registerCommandWriter(BleCommandWriter writer) {
    _commandWriter = writer;
    update(commandWriterReady: true);
  }

  void clearCommandWriter() {
    _commandWriter = null;
    update(commandWriterReady: false);
  }

  void selectDevice(String deviceId) {
    update(
      selectedDeviceId: deviceId,
      connectionStatus: BleConnectionStatus.idle,
      connectionError: null,
    );
    recordEvent('Selected BLE device hardwareId=$deviceId');
  }

  void registerScanner(BleScanner scanner) {
    _scanner = scanner;
  }

  Future<List<BleScanResult>> startScan() async {
    final scanner = _scanner;
    if (scanner == null) {
      throw const DeviceException(
        'E_BLE_SCANNER_NOT_READY',
        'E_BLE_SCANNER_NOT_READY',
      );
    }
    update(isScanning: true, scanResults: const <BleScanResult>[]);
    recordEvent('Starting BLE scan');
    try {
      final results = await scanner();
      update(isScanning: false, scanResults: results);
      recordEvent('BLE scan finished with ${results.length} device(s)');
      return results;
    } catch (error) {
      update(isScanning: false);
      recordEvent('BLE scan failed: $error');
      rethrow;
    }
  }

  Future<void> sendCommand(EixamDeviceCommand command) async {
    final writer = _commandWriter;
    if (writer == null) {
      throw const DeviceException(
        'E_BLE_COMMAND_CHANNEL_NOT_READY',
        'E_BLE_COMMAND_CHANNEL_NOT_READY',
      );
    }
    await writer(command);
  }

  @visibleForTesting
  void debugSetSensitiveDiagnosticsEnabled(bool? enabled) {
    _allowSensitiveDiagnosticsOverride = enabled;
  }

  bool get _allowSensitiveDiagnostics =>
      _allowSensitiveDiagnosticsOverride ?? kDebugMode;

  String? _safeDiagnosticHexField(String? value) {
    if (value == null || _allowSensitiveDiagnostics) {
      return value;
    }
    return SecurityDiagnosticsRedactor.formatHexPayloadForDiagnostics(
      value,
      allowSensitive: false,
    );
  }
}
