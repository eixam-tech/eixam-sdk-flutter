import 'package:eixam_connect_flutter/src/device/android_ble_gatt_cache.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('classifies Android SOS CCCD write-not-permitted as stale GATT cache',
      () {
    expect(
      AndroidBleGattCache.isStaleDescriptorWrite(
        FlutterBluePlusException(
          ErrorPlatform.android,
          'setNotifyValue',
          3,
          'GATT_WRITE_NOT_PERMITTED',
        ),
      ),
      isTrue,
    );
    expect(
      AndroidBleGattCache.isStaleDescriptorWrite(
        Exception('write not permitted'),
      ),
      isTrue,
    );
  });

  test('does not treat unrelated BLE errors as stale GATT cache', () {
    expect(
      AndroidBleGattCache.isStaleDescriptorWrite(
        FlutterBluePlusException(
          ErrorPlatform.android,
          'setNotifyValue',
          8,
          'GATT_INSUFFICIENT_AUTHORIZATION',
        ),
      ),
      isFalse,
    );
    expect(
      AndroidBleGattCache.isStaleDescriptorWrite(
          Exception('device is disconnected')),
      isFalse,
    );
  });
}
