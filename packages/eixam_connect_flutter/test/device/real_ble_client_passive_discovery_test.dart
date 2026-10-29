import 'dart:async';

import 'package:eixam_connect_flutter/src/device/ble_debug_registry.dart';
import 'package:eixam_connect_flutter/src/device/real_ble_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final platform = _DisconnectedDiscoveryPlatform();

  setUpAll(() async {
    FlutterBluePlusPlatform.instance = platform;
    // Initialize FBP's connection-state cache against the same native event
    // source used throughout this file.
    expect(await FlutterBluePlus.isSupported, isTrue);
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    BleDebugRegistry.instance.reset();
  });

  tearDownAll(platform.close);

  test(
    'Android passive discovery cannot reconnect after native disconnect',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      const id = 'CF:82:59:4B:1A:01';
      platform.begin(id);
      final client = RealBleClient();

      await expectLater(
        client.isEixamCompatible(id),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'E_DEVICE_DISCONNECTED',
          ),
        ),
      );
      // Observe beyond the first reconnect backoff to catch deferred work too.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(platform.discoveries, 1);
      expect(platform.connections, 0);
      expect(platform.priorities, 0);
      expect(BluetoothDevice.fromId(id).isConnected, isFalse);
      expect(client.transportObservation(id).servicePresent, isFalse);
    },
  );

  test(
    'iOS passive discovery preserves transient disconnect recovery',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      const id = '11111111-1111-1111-1111-111111111111';
      platform.begin(id);
      final client = RealBleClient();

      // The retry succeeds with an empty service tree, hence incompatible. The
      // native counters establish that it recovered through the real retry loop.
      expect(await client.isEixamCompatible(id), isFalse);
      expect(platform.discoveries, 2);
      expect(platform.connections, 1);
      expect(BluetoothDevice.fromId(id).isConnected, isTrue);
    },
  );
}

final class _DisconnectedDiscoveryPlatform extends FlutterBluePlusPlatform {
  final _connections = StreamController<BmConnectionStateResponse>.broadcast(
    sync: true,
  );
  final _discoveries = StreamController<BmDiscoverServicesResult>.broadcast(
    sync: true,
  );
  int discoveries = 0;
  int connections = 0;
  int priorities = 0;

  void begin(String id) {
    discoveries = 0;
    connections = 0;
    priorities = 0;
    _state(DeviceIdentifier(id), BmConnectionStateEnum.connected);
  }

  void _state(DeviceIdentifier id, BmConnectionStateEnum state) {
    _connections.add(
      BmConnectionStateResponse(
        remoteId: id,
        connectionState: state,
        disconnectReasonCode: null,
        disconnectReasonString: null,
      ),
    );
  }

  @override
  Stream<BmConnectionStateResponse> get onConnectionStateChanged =>
      _connections.stream;

  @override
  Stream<BmDiscoverServicesResult> get onDiscoveredServices =>
      _discoveries.stream;

  @override
  Future<bool> isSupported(BmIsSupportedRequest request) async => true;

  @override
  Future<bool> discoverServices(BmDiscoverServicesRequest request) async {
    discoveries++;
    final interrupted = discoveries == 1;
    if (interrupted) {
      _state(request.remoteId, BmConnectionStateEnum.disconnected);
    }
    // Resolve the native response listener even when the method itself fails.
    _discoveries.add(
      BmDiscoverServicesResult(
        remoteId: request.remoteId,
        services: const [],
        success: !interrupted,
        errorCode: interrupted ? 1 : 0,
        errorString: interrupted ? 'Device is disconnected' : '',
      ),
    );
    if (interrupted) throw PlatformException(code: 'E_DEVICE_DISCONNECTED');
    return true;
  }

  @override
  Future<bool> connect(BmConnectRequest request) async {
    connections++;
    _state(request.remoteId, BmConnectionStateEnum.connected);
    return true;
  }

  @override
  Future<bool> disconnect(BmDisconnectRequest request) async {
    _state(request.remoteId, BmConnectionStateEnum.disconnected);
    return false;
  }

  @override
  Future<bool> requestConnectionPriority(
    BmConnectionPriorityRequest request,
  ) async {
    priorities++;
    return true;
  }

  Future<void> close() async {
    await _connections.close();
    await _discoveries.close();
  }
}
