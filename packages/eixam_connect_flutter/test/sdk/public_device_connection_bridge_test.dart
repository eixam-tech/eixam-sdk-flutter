import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/sdk/public_device_connection_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native-ready GATT is the canonical connection authority', () {
    final projection = projectDeviceConnection(
      flutterRepositoryConnected: false,
      nativeOwnerDeclared: true,
      nativeOwnerReady: true,
      nativeGattConnected: true,
      sameDeviceIdentity: true,
    );

    expect(projection.visibleConnected, isTrue);
    expect(projection.falseDisconnectBlocked, isTrue);
    expect(
      projection.reason,
      DeviceConnectionProjectionReason.authoritativeNativeConnection,
    );
  });

  test('real native GATT disconnect is visible immediately', () {
    final projection = projectDeviceConnection(
      flutterRepositoryConnected: false,
      nativeOwnerDeclared: true,
      nativeOwnerReady: false,
      nativeGattConnected: false,
      sameDeviceIdentity: true,
    );

    expect(projection.visibleConnected, isFalse);
    expect(projection.falseDisconnectBlocked, isFalse);
    expect(
      projection.reason,
      DeviceConnectionProjectionReason.nativeGattDisconnected,
    );
  });

  test('retained same native session preserves a preparing transition', () {
    final projection = projectDeviceConnection(
      flutterRepositoryConnected: false,
      nativeOwnerDeclared: true,
      nativeOwnerReady: false,
      nativeGattConnected: true,
      sameDeviceIdentity: true,
      nativeConnectionContinuityProven: true,
    );

    expect(projection.visibleConnected, isTrue);
    expect(projection.falseDisconnectBlocked, isTrue);
    expect(
      projection.reason,
      DeviceConnectionProjectionReason.sameNativeSessionContinuity,
    );
  });

  test('cold native preparing state has no connection continuity', () {
    final projection = projectDeviceConnection(
      flutterRepositoryConnected: false,
      nativeOwnerDeclared: true,
      nativeOwnerReady: false,
      nativeGattConnected: true,
      sameDeviceIdentity: true,
    );

    expect(projection.visibleConnected, isFalse);
    expect(
      projection.reason,
      DeviceConnectionProjectionReason.nativeOwnerNotReady,
    );
  });

  test('continuity proof cannot hide native GATT loss', () {
    final projection = projectDeviceConnection(
      flutterRepositoryConnected: false,
      nativeOwnerDeclared: true,
      nativeOwnerReady: false,
      nativeGattConnected: false,
      sameDeviceIdentity: true,
      nativeConnectionContinuityProven: true,
    );

    expect(projection.visibleConnected, isFalse);
    expect(
      projection.reason,
      DeviceConnectionProjectionReason.nativeGattDisconnected,
    );
  });

  test('continuity proof cannot hide a physical identity change', () {
    final projection = projectDeviceConnection(
      flutterRepositoryConnected: false,
      nativeOwnerDeclared: true,
      nativeOwnerReady: false,
      nativeGattConnected: true,
      sameDeviceIdentity: false,
      nativeConnectionContinuityProven: true,
    );

    expect(projection.visibleConnected, isFalse);
    expect(
      projection.reason,
      DeviceConnectionProjectionReason.nativeIdentityMismatch,
    );
  });

  test('native identity mismatch cannot mask a real disconnect', () {
    final projection = projectDeviceConnection(
      flutterRepositoryConnected: false,
      nativeOwnerDeclared: true,
      nativeOwnerReady: true,
      nativeGattConnected: true,
      sameDeviceIdentity: false,
    );

    expect(projection.visibleConnected, isFalse);
    expect(projection.falseDisconnectBlocked, isFalse);
    expect(
      projection.reason,
      DeviceConnectionProjectionReason.nativeIdentityMismatch,
    );
  });

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

  test(
    'does not bridge when Flutter is already connected or native is dark',
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
    },
  );
}
