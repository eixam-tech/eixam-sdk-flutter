/// Android keeps a per-MAC GATT cache. Provision / unprovision reboot adds or
/// removes the Meshtastic Phone service, so handles shift. A cached SOS CCCD
/// then lands on a read-only Mesh characteristic and CCCD write returns
/// `GATT_WRITE_NOT_PERMITTED`.
abstract final class AndroidBleGattCache {
  static bool isStaleDescriptorWrite(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('write_not_permitted') ||
        text.contains('write not permitted') ||
        text.contains('gatt_write_not_permitted');
  }
}
