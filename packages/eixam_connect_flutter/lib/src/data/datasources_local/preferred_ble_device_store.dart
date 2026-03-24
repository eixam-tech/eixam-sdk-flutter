import '../../device/preferred_ble_device.dart';
import 'shared_prefs_sdk_store.dart';

class PreferredBleDeviceStore {
  PreferredBleDeviceStore({SharedPrefsSdkStore? localStore})
      : _localStore = localStore ?? SharedPrefsSdkStore();

  static const String preferredDeviceKey = 'eixam.ble.preferred_device';
  static const String manualDisconnectRequestedKey =
      'eixam.ble.manual_disconnect_requested';

  final SharedPrefsSdkStore _localStore;

  Future<void> savePreferredDevice(PreferredBleDevice device) async {
    await _localStore.saveJson(preferredDeviceKey, device.toJson());
  }

  Future<PreferredBleDevice?> getPreferredDevice() async {
    final raw = await _localStore.readJson(preferredDeviceKey);
    return PreferredBleDevice.fromJson(raw);
  }

  Future<void> clearPreferredDevice() async {
    await _localStore.remove(preferredDeviceKey);
  }

  Future<void> saveManualDisconnectRequested(bool value) async {
    await _localStore.saveBool(manualDisconnectRequestedKey, value);
  }

  Future<bool> readManualDisconnectRequested() async {
    return await _localStore.readBool(manualDisconnectRequestedKey) ?? false;
  }
}
