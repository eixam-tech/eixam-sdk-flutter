import 'package:eixam_connect_flutter/src/device/eixam_ble_mesh_port_inference.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('inferMeshPortForLiveNotification', () {
    test('preserves explicit mesh port metadata', () {
      expect(
        inferMeshPortForLiveNotification(
          channel: EixamBleChannel.tel,
          payload: const <int>[0x78, 0x56, 0x34, 0x12],
          explicitMeshPort: EixamBleProtocol.clusterMeshPort,
        ),
        EixamBleProtocol.clusterMeshPort,
      );
    });

    test('infers cluster port for unique cluster control payloads', () {
      expect(
        inferMeshPortForLiveNotification(
          channel: EixamBleChannel.tel,
          payload: const <int>[0xC0, 0x34, 0x12],
        ),
        EixamBleProtocol.clusterMeshPort,
      );
      expect(
        inferMeshPortForLiveNotification(
          channel: EixamBleChannel.tel,
          payload: const <int>[
            0xC1,
            0x34,
            0x12,
            0x78,
            0x56,
            0x34,
            0x12,
            0x01,
            0x02,
            0x03,
            0x04,
            0x05,
            0x06,
            0x87,
            0x65,
          ],
        ),
        EixamBleProtocol.clusterMeshPort,
      );
    });

    test('infers tel port for unique TEL-plane payloads', () {
      expect(
        inferMeshPortForLiveNotification(
          channel: EixamBleChannel.tel,
          payload: const <int>[0xD0, 0x1B, 0x00, 0x00, 0x00],
        ),
        EixamBleProtocol.telMeshPort,
      );
      expect(
        inferMeshPortForLiveNotification(
          channel: EixamBleChannel.tel,
          payload: const <int>[0xD3, 0x01],
        ),
        EixamBleProtocol.telMeshPort,
      );
      expect(
        inferMeshPortForLiveNotification(
          channel: EixamBleChannel.tel,
          payload: const <int>[
            0x34,
            0x12,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x40,
          ],
        ),
        EixamBleProtocol.telMeshPort,
      );
      expect(
        inferMeshPortForLiveNotification(
          channel: EixamBleChannel.tel,
          payload: const <int>[
            0x34,
            0x12,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x00,
            0x20,
            0x40,
          ],
        ),
        isNull,
      );
    });
  });
}
