import 'ble_adapter_state.dart';
import 'ble_scan_result.dart';

/// Abstraction over the BLE stack used by the device runtime provider.
///
/// A future production implementation can wrap `flutter_blue_plus` or any
/// platform-specific API while keeping the repository and controller layers
/// stable.
abstract class BleClient {
  Future<void> initialize();
  Future<BleAdapterState> getAdapterState();
  Stream<BleAdapterState> watchAdapterState();

  Future<List<BleScanResult>> scan({Duration timeout = const Duration(seconds: 4)});
  Future<void> connect(String deviceId);
  Future<void> disconnect(String deviceId);
  Future<bool> isConnected(String deviceId);

  Future<int?> readBatteryLevel(String deviceId);
  Future<int?> readSignalQuality(String deviceId);
  Future<String?> readFirmwareVersion(String deviceId);
}
