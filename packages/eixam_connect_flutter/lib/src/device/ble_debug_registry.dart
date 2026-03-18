import 'dart:async';

import 'ble_adapter_state.dart';
import 'ble_debug_event.dart';
import 'ble_debug_state.dart';

typedef BleCommandWriter = Future<void> Function(List<int> data);

class BleDebugRegistry {
  BleDebugRegistry._();

  static final BleDebugRegistry instance = BleDebugRegistry._();

  final StreamController<BleDebugState> _controller =
      StreamController<BleDebugState>.broadcast();

  BleDebugState _state = const BleDebugState();
  BleCommandWriter? _commandWriter;

  Stream<BleDebugState> watch() => _controller.stream;

  BleDebugState get currentState => _state;

  void reset() {
    _commandWriter = null;
    _state = const BleDebugState();
    _controller.add(_state);
  }

  void update({
    BleAdapterState? adapterState,
    String? selectedDeviceId,
    bool? eixamServiceFound,
    bool? telNotifySubscribed,
    bool? sosNotifySubscribed,
    bool? commandWriterReady,
    String? lastCommandSent,
    String? lastPacketReceived,
    List<String>? discoveredServices,
  }) {
    _state = _state.copyWith(
      adapterState: adapterState,
      selectedDeviceId: selectedDeviceId,
      eixamServiceFound: eixamServiceFound,
      telNotifySubscribed: telNotifySubscribed,
      sosNotifySubscribed: sosNotifySubscribed,
      commandWriterReady: commandWriterReady,
      lastCommandSent: lastCommandSent,
      lastPacketReceived: lastPacketReceived,
      discoveredServices: discoveredServices,
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

  Future<void> sendCommand(List<int> data) async {
    final writer = _commandWriter;
    if (writer == null) {
      throw StateError('BLE command channel is not ready.');
    }
    await writer(data);
  }
}
