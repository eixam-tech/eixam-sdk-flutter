import 'dart:async';

import 'ble_adapter_state.dart';
import 'ble_connection_status.dart';
import 'ble_debug_event.dart';
import 'ble_debug_state.dart';
import 'ble_scan_result.dart';

typedef BleCommandWriter = Future<void> Function(List<int> data);
typedef BleScanner = Future<List<BleScanResult>> Function();

class BleDebugRegistry {
  BleDebugRegistry._();

  static final BleDebugRegistry instance = BleDebugRegistry._();

  final StreamController<BleDebugState> _controller =
      StreamController<BleDebugState>.broadcast();

  BleDebugState _state = const BleDebugState();
  BleCommandWriter? _commandWriter;
  BleScanner? _scanner;

  Stream<BleDebugState> watch() => _controller.stream;

  BleDebugState get currentState => _state;

  void reset() {
    _commandWriter = null;
    _scanner = null;
    _state = const BleDebugState();
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
      lastCommandSent: lastCommandSent,
      lastWriteTargetCharacteristic: lastWriteTargetCharacteristic,
      lastWriteResult: lastWriteResult,
      lastWriteAt: lastWriteAt,
      lastWriteError: lastWriteError,
      lastPacketReceived: lastPacketReceived,
      discoveredServices: discoveredServices,
      scanResults: scanResults,
      isScanning: isScanning,
      connectionStatus: connectionStatus,
      connectionError: connectionError,
    );
    _controller.add(_state);
  }

  void recordEvent(String message) {
    final events = List<BleDebugEvent>.from(_state.events)
      ..add(BleDebugEvent(timestamp: DateTime.now(), message: message));
    if (events.length > 30) {
      events.removeRange(0, events.length - 30);
    }
    _state = _state.copyWith(events: events);
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
    recordEvent('Selected BLE device $deviceId');
  }

  void registerScanner(BleScanner scanner) {
    _scanner = scanner;
  }

  Future<List<BleScanResult>> startScan() async {
    final scanner = _scanner;
    if (scanner == null) {
      throw StateError('BLE scanner is not ready.');
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

  Future<void> sendCommand(List<int> data) async {
    final writer = _commandWriter;
    if (writer == null) {
      throw StateError('BLE command channel is not ready.');
    }
    await writer(data);
  }
}
