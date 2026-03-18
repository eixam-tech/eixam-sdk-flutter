import 'ble_adapter_state.dart';
import 'ble_debug_event.dart';

class BleDebugState {
  const BleDebugState({
    this.adapterState = BleAdapterState.unknown,
    this.selectedDeviceId,
    this.eixamServiceFound = false,
    this.telNotifySubscribed = false,
    this.sosNotifySubscribed = false,
    this.commandWriterReady = false,
    this.lastCommandSent,
    this.lastPacketReceived,
    this.discoveredServices = const <String>[],
    this.events = const <BleDebugEvent>[],
  });

  final BleAdapterState adapterState;
  final String? selectedDeviceId;
  final bool eixamServiceFound;
  final bool telNotifySubscribed;
  final bool sosNotifySubscribed;
  final bool commandWriterReady;
  final String? lastCommandSent;
  final String? lastPacketReceived;
  final List<String> discoveredServices;
  final List<BleDebugEvent> events;

  BleDebugState copyWith({
    BleAdapterState? adapterState,
    String? selectedDeviceId,
    bool? eixamServiceFound,
    bool? telNotifySubscribed,
    bool? sosNotifySubscribed,
    bool? commandWriterReady,
    String? lastCommandSent,
    String? lastPacketReceived,
    List<String>? discoveredServices,
    List<BleDebugEvent>? events,
  }) {
    return BleDebugState(
      adapterState: adapterState ?? this.adapterState,
      selectedDeviceId: selectedDeviceId ?? this.selectedDeviceId,
      eixamServiceFound: eixamServiceFound ?? this.eixamServiceFound,
      telNotifySubscribed: telNotifySubscribed ?? this.telNotifySubscribed,
      sosNotifySubscribed: sosNotifySubscribed ?? this.sosNotifySubscribed,
      commandWriterReady: commandWriterReady ?? this.commandWriterReady,
      lastCommandSent: lastCommandSent ?? this.lastCommandSent,
      lastPacketReceived: lastPacketReceived ?? this.lastPacketReceived,
      discoveredServices: discoveredServices ?? this.discoveredServices,
      events: events ?? this.events,
    );
  }
}
