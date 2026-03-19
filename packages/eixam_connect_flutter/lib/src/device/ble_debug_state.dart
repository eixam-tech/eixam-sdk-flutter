import 'ble_adapter_state.dart';
import 'ble_connection_status.dart';
import 'ble_debug_event.dart';
import 'ble_scan_result.dart';

class BleDebugState {
  const BleDebugState({
    this.adapterState = BleAdapterState.unknown,
    this.selectedDeviceId,
    this.eixamServiceFound = false,
    this.telFound = false,
    this.sosFound = false,
    this.inetFound = false,
    this.cmdFound = false,
    this.telNotifySubscribed = false,
    this.sosNotifySubscribed = false,
    this.commandWriterReady = false,
    this.lastCommandSent,
    this.lastWriteTargetCharacteristic,
    this.lastWriteResult,
    this.lastWriteAt,
    this.lastWriteError,
    this.lastPacketReceived,
    this.discoveredServices = const <String>[],
    this.scanResults = const <BleScanResult>[],
    this.isScanning = false,
    this.connectionStatus = BleConnectionStatus.idle,
    this.connectionError,
    this.events = const <BleDebugEvent>[],
  });

  final BleAdapterState adapterState;
  final String? selectedDeviceId;
  final bool eixamServiceFound;
  final bool telFound;
  final bool sosFound;
  final bool inetFound;
  final bool cmdFound;
  final bool telNotifySubscribed;
  final bool sosNotifySubscribed;
  final bool commandWriterReady;
  final String? lastCommandSent;
  final String? lastWriteTargetCharacteristic;
  final String? lastWriteResult;
  final DateTime? lastWriteAt;
  final String? lastWriteError;
  final String? lastPacketReceived;
  final List<String> discoveredServices;
  final List<BleScanResult> scanResults;
  final bool isScanning;
  final BleConnectionStatus connectionStatus;
  final String? connectionError;
  final List<BleDebugEvent> events;

  BleDebugState copyWith({
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
    List<BleDebugEvent>? events,
  }) {
    return BleDebugState(
      adapterState: adapterState ?? this.adapterState,
      selectedDeviceId: selectedDeviceId ?? this.selectedDeviceId,
      eixamServiceFound: eixamServiceFound ?? this.eixamServiceFound,
      telFound: telFound ?? this.telFound,
      sosFound: sosFound ?? this.sosFound,
      inetFound: inetFound ?? this.inetFound,
      cmdFound: cmdFound ?? this.cmdFound,
      telNotifySubscribed: telNotifySubscribed ?? this.telNotifySubscribed,
      sosNotifySubscribed: sosNotifySubscribed ?? this.sosNotifySubscribed,
      commandWriterReady: commandWriterReady ?? this.commandWriterReady,
      lastCommandSent: lastCommandSent ?? this.lastCommandSent,
      lastWriteTargetCharacteristic:
          lastWriteTargetCharacteristic ?? this.lastWriteTargetCharacteristic,
      lastWriteResult: lastWriteResult ?? this.lastWriteResult,
      lastWriteAt: lastWriteAt ?? this.lastWriteAt,
      lastWriteError: lastWriteError ?? this.lastWriteError,
      lastPacketReceived: lastPacketReceived ?? this.lastPacketReceived,
      discoveredServices: discoveredServices ?? this.discoveredServices,
      scanResults: scanResults ?? this.scanResults,
      isScanning: isScanning ?? this.isScanning,
      connectionStatus: connectionStatus ?? this.connectionStatus,
      connectionError: connectionError ?? this.connectionError,
      events: events ?? this.events,
    );
  }
}
