import 'dart:io';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_protocol.dart';
import 'package:eixam_connect_flutter/src/sdk/eixam_connect_sdk_impl.dart';
import 'package:eixam_connect_flutter/src/sdk/protection_platform_channel_mapper.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native protection UUIDs match the shared and Android wire contract', () {
    final ios = File(
      'ios/Classes/ProtectionRuntimeBridge.swift',
    ).readAsStringSync();
    final android = File(
      'android/src/main/kotlin/dev/eixam/connect/flutter/protection/ProtectionBleRuntimeOwner.kt',
    ).readAsStringSync();
    final expected = [
      EixamBleProtocol.serviceUuid,
      EixamBleProtocol.telNotifyCharacteristicUuid,
      EixamBleProtocol.sosNotifyCharacteristicUuid,
      EixamBleProtocol.inetWriteCharacteristicUuid,
      EixamBleProtocol.cmdWriteCharacteristicUuid,
    ];
    final observed = RegExp(
      r'private static let \w+Uuid = CBUUID\(string: "([^"]+)"\)',
    ).allMatches(ios).map((m) => m[1]!).toList();
    expect(observed, expected);
    for (final uuid in observed) {
      expect(android, contains('UUID.fromString("$uuid")'));
      expect(Guid(uuid), isNot(Guid(uuid.substring(uuid.length - 4))));
      expect(Guid(uuid), isNot(Guid('00000000-0000-0000-0000-00000000ea04')));
    }
    expect(
      Guid(observed.last),
      Guid(EixamBleProtocol.cmdWriteCharacteristicUuid),
    );
  });

  for (final owner in [
    ProtectionBleOwner.androidService,
    ProtectionBleOwner.iosPlugin,
  ]) {
    for (final missing in [
      'none',
      'service',
      'ea04',
      'target',
      'queue',
      'connection',
    ]) {
      test('$owner equivalent native facts, failing predicate $missing', () {
        final facts = <String, dynamic>{
          'bleOwner': owner.name,
          'serviceBleConnected': missing != 'connection',
          // Notify subscription readiness must not override a missing EA04.
          'serviceBleReady': true,
          'nativeCommandServiceReady': missing != 'service',
          'nativeCommandEa04Ready': missing != 'ea04',
          'nativeCommandIdentityReady': missing != 'target',
          'nativeCommandQueueHealthy': missing != 'queue',
          'nativeCommandReady': missing == 'none',
        };
        final mapped = owner == ProtectionBleOwner.iosPlugin
            ? mapIosProtectionPlatformSnapshot(facts)
            : mapAndroidProtectionPlatformSnapshot(facts);
        final result = evaluateNativeProtectionCommandReadiness(
          declaredOwner: mapped.bleOwner,
          serviceBleConnected: mapped.serviceBleConnected,
          serviceReady: mapped.nativeCommandServiceReady,
          cmdEa04Ready: mapped.nativeCommandEa04Ready,
          exactTargetIdentityMatch: mapped.nativeCommandIdentityReady,
          operationQueueOperational: mapped.nativeCommandQueueHealthy,
        );
        expect(result.ready, missing == 'none');
      });
    }
  }

  test('legacy iOS subscription snapshot supplies no command proof', () {
    final mapped = mapIosProtectionPlatformSnapshot({
      'bleOwner': 'iosPlugin',
      'serviceBleConnected': true,
      'serviceBleReady': true,
    });
    expect(mapped.nativeCommandServiceReady, isFalse);
    expect(mapped.nativeCommandEa04Ready, isFalse);
    expect(mapped.nativeCommandIdentityReady, isFalse);
    expect(mapped.nativeCommandReady, isFalse);
  });
}
