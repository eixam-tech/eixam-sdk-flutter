import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/sdk/public_device_connection_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('does not bridge a Flutter-owned GATT drop', () {
    expect(
      shouldBridgeProtectionBleConnection(
        rawConnected: false,
        bleOwner: ProtectionBleOwner.flutter,
        protectionReportsLiveConnection: true,
        belongsToKnownDevice: true,
      ),
      isFalse,
    );
  });

  test('bridges when native protection owns a live radio', () {
    expect(
      shouldBridgeProtectionBleConnection(
        rawConnected: false,
        bleOwner: ProtectionBleOwner.androidService,
        protectionReportsLiveConnection: true,
        belongsToKnownDevice: true,
      ),
      isTrue,
    );
    expect(
      shouldBridgeProtectionBleConnection(
        rawConnected: false,
        bleOwner: ProtectionBleOwner.iosPlugin,
        protectionReportsLiveConnection: true,
        belongsToKnownDevice: true,
      ),
      isTrue,
    );
  });

  test('does not bridge when Flutter is already connected or native is dark',
      () {
    expect(
      shouldBridgeProtectionBleConnection(
        rawConnected: true,
        bleOwner: ProtectionBleOwner.androidService,
        protectionReportsLiveConnection: true,
        belongsToKnownDevice: true,
      ),
      isFalse,
    );
    expect(
      shouldBridgeProtectionBleConnection(
        rawConnected: false,
        bleOwner: ProtectionBleOwner.androidService,
        protectionReportsLiveConnection: false,
        belongsToKnownDevice: true,
      ),
      isFalse,
    );
    expect(
      shouldBridgeProtectionBleConnection(
        rawConnected: false,
        bleOwner: ProtectionBleOwner.androidService,
        protectionReportsLiveConnection: true,
        belongsToKnownDevice: false,
      ),
      isFalse,
    );
  });
}
