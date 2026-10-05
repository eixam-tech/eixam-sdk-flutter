import 'dart:async';

import 'package:eixam_connect_flutter/src/device/ble_debug_registry.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_protocol.dart';
import 'package:eixam_connect_flutter/src/device/real_ble_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'a reset while discovery is pending rejects the obsolete service tree',
    () async {
      final resets = StreamController<void>.broadcast(sync: true);
      final discovery = Completer<List<BluetoothService>>();
      final started = Completer<void>();
      final client = RealBleClient(
        serviceResetProvider: (_) => resets.stream,
        serviceDiscoverer: (_) {
          started.complete();
          return discovery.future;
        },
      );
      addTearDown(resets.close);
      const id = 'B748445B-FDEA-2426-48F1-FD1A086627FA';
      final pending = client.isEixamCompatible(id);
      await started.future;
      final rejected = expectLater(pending, throwsA(isA<Exception>()));
      resets.add(null);
      discovery.complete([_service(true)]);
      await rejected;
      expect(
        client.transportObservation(id).commandCharacteristicPresent,
        isFalse,
      );
    },
  );

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    test(
      '$platform invalidates EA04 and normally rediscovers the affected device',
      () async {
        debugDefaultTargetPlatformOverride = platform;
        final resets = StreamController<void>.broadcast(sync: true);
        var cmdPresent = true;
        var discoveries = 0;
        final client = RealBleClient(
          serviceResetProvider: (_) => resets.stream,
          serviceDiscoverer: (_) async {
            discoveries++;
            return [_service(cmdPresent)];
          },
        );
        final resetEvents = <String>[];
        final sub = client.serviceResets.listen(resetEvents.add);
        addTearDown(() async {
          debugDefaultTargetPlatformOverride = null;
          await sub.cancel();
          await resets.close();
          BleDebugRegistry.instance.reset();
        });
        const id = 'B748445B-FDEA-2426-48F1-FD1A086627FA';
        expect(await client.isEixamCompatible(id), isTrue);
        expect(
          client.transportObservation(id).commandCharacteristicPresent,
          isTrue,
        );
        expect(await client.isEixamCompatible(id), isTrue);
        expect(discoveries, 1);
        cmdPresent = false;
        resets.add(null);
        expect(resetEvents, [id]);
        expect(
          client.transportObservation(id).commandCharacteristicPresent,
          isFalse,
        );
        expect(client.transportObservation(id).servicePresent, isFalse);
        expect(await client.isEixamCompatible(id), isTrue);
        expect(discoveries, 2);
        expect(
          client.transportObservation(id).commandCharacteristicPresent,
          isFalse,
        );
        cmdPresent = true;
        resets.add(null);
        expect(await client.isEixamCompatible(id), isTrue);
        expect(
          client.transportObservation(id).commandCharacteristicPresent,
          isTrue,
        );
      },
    );
  }
}

BluetoothService _service(bool cmdPresent) => BluetoothService.fromProto(
  BmBluetoothService(
    remoteId: const DeviceIdentifier('B748445B-FDEA-2426-48F1-FD1A086627FA'),
    primaryServiceUuid: null,
    serviceUuid: Guid(EixamBleProtocol.serviceUuid),
    characteristics:
        [
              EixamBleProtocol.telNotifyCharacteristicUuid,
              EixamBleProtocol.sosNotifyCharacteristicUuid,
              EixamBleProtocol.inetWriteCharacteristicUuid,
              if (cmdPresent) EixamBleProtocol.cmdWriteCharacteristicUuid,
            ]
            .map(
              (uuid) => BmBluetoothCharacteristic.fromMap({
                'remote_id': 'B748445B-FDEA-2426-48F1-FD1A086627FA',
                'service_uuid': EixamBleProtocol.serviceUuid,
                'characteristic_uuid': uuid,
                'instance_id': 0,
                'descriptors': <dynamic>[],
                'properties': <String, int>{'read': 1, 'write': 1},
              }),
            )
            .toList(),
  ),
);
