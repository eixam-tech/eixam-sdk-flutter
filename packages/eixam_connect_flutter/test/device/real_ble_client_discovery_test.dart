import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/device/ble_adapter_state.dart';
import 'package:eixam_connect_flutter/src/device/ble_client.dart';
import 'package:eixam_connect_flutter/src/device/ble_debug_registry.dart';
import 'package:eixam_connect_flutter/src/device/ble_scan_result.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_command.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_notification.dart';
import 'package:eixam_connect_flutter/src/device/lazy_initializing_ble_client.dart';
import 'package:eixam_connect_flutter/src/device/real_ble_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    BleDebugRegistry.instance.reset();
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    BleDebugRegistry.instance.reset();
  });

  test('lazy client registry scanner initializes and reaches delegate scan',
      () async {
    final delegate = _FakeBleClient();
    LazyInitializingBleClient(delegate);

    final results = await BleDebugRegistry.instance.startScan();

    expect(delegate.initializeCalls, 1);
    expect(delegate.scanCalls, 1);
    expect(results.single.deviceId, 'native-scan-device');
  });

  test('iOS poweredOn supported unknown scanner reaches native start call',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    var startScanCalls = 0;
    final logs = <String>[];
    final previousDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) {
        logs.add(message);
      }
    };
    final client = _buildRealBleClient(
      startScan: (_) async {
        startScanCalls += 1;
      },
    );
    addTearDown(() {
      debugPrint = previousDebugPrint;
    });

    await client.initialize();
    await client.scan(timeout: Duration.zero);

    expect(startScanCalls, 1);
    expect(
      logs,
      contains(
        'SDK_DISCOVERY_START_ENTRY source=ble_client_scan platform=ios',
      ),
    );
    expect(
      logs,
      contains(
        'SDK_DISCOVERY_PRECHECK '
        'adapterState=poweredOn supported=true scannerReady=unknown',
      ),
    );
    expect(
      logs,
      contains(
        'SDK_DISCOVERY_PRECHECK_ALLOW_UNKNOWN '
        'reason=adapter_powered_on_supported',
      ),
    );
    expect(logs, contains('SDK_DISCOVERY_NATIVE_START_SCAN_CALL_BEGIN'));
    expect(logs, contains('SDK_DISCOVERY_NATIVE_START_SCAN_CALL_DONE'));
    expect(
      logs.where((log) => log.contains('SDK_DISCOVERY_PRECHECK_BLOCKED')),
      isEmpty,
    );
  });

  test('iOS adapter not powered blocks before native start', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    var startScanCalls = 0;
    final logs = <String>[];
    final previousDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) {
        logs.add(message);
      }
    };
    final client = _buildRealBleClient(
      adapterState: BluetoothAdapterState.off,
      startScan: (_) async {
        startScanCalls += 1;
      },
    );
    addTearDown(() {
      debugPrint = previousDebugPrint;
    });

    await client.initialize();
    await expectLater(
      client.scan(timeout: Duration.zero),
      throwsA(
        isA<DeviceException>().having(
          (error) => error.code,
          'code',
          'E_BLE_SCANNER_NOT_READY',
        ),
      ),
    );

    expect(startScanCalls, 0);
    expect(
      logs,
      contains(
        'SDK_DISCOVERY_PRECHECK '
        'adapterState=poweredOff supported=true scannerReady=false',
      ),
    );
    expect(
      logs,
      contains('SDK_DISCOVERY_PRECHECK_BLOCKED reason=adapter_not_powered_on'),
    );
    expect(
      logs.where(
        (log) => log.contains('SDK_DISCOVERY_NATIVE_START_SCAN_CALL_BEGIN'),
      ),
      isEmpty,
    );
  });

  test('iOS unsupported blocks before native start', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    var startScanCalls = 0;
    var supported = true;
    final logs = <String>[];
    final previousDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) {
        logs.add(message);
      }
    };
    final client = _buildRealBleClient(
      supportedProvider: () => supported,
      startScan: (_) async {
        startScanCalls += 1;
      },
    );
    addTearDown(() {
      debugPrint = previousDebugPrint;
    });

    await client.initialize();
    supported = false;
    await expectLater(
      client.scan(timeout: Duration.zero),
      throwsA(
        isA<DeviceException>().having(
          (error) => error.code,
          'code',
          'E_BLE_SCANNER_NOT_READY',
        ),
      ),
    );

    expect(startScanCalls, 0);
    expect(
      logs,
      contains(
        'SDK_DISCOVERY_PRECHECK '
        'adapterState=poweredOn supported=false scannerReady=false',
      ),
    );
    expect(
      logs,
      contains('SDK_DISCOVERY_PRECHECK_BLOCKED reason=unsupported'),
    );
  });

  test('native startScan E_BLE_SCANNER_NOT_READY maps to typed exception',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final logs = <String>[];
    final previousDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) {
        logs.add(message);
      }
    };
    final client = _buildRealBleClient(
      startScan: (_) async {
        throw StateError('E_BLE_SCANNER_NOT_READY');
      },
    );
    addTearDown(() {
      debugPrint = previousDebugPrint;
    });

    await client.initialize();
    await expectLater(
      client.scan(timeout: Duration.zero),
      throwsA(
        isA<DeviceException>().having(
          (error) => error.code,
          'code',
          'E_BLE_SCANNER_NOT_READY',
        ),
      ),
    );

    expect(logs, contains('SDK_DISCOVERY_NATIVE_START_SCAN_CALL_BEGIN'));
    expect(
      logs,
      contains(
        'SDK_DISCOVERY_NATIVE_START_SCAN_CALL_FAILED '
        'error_category=invalid_state',
      ),
    );
    expect(
      logs,
      contains(
        'SDK_DISCOVERY_ERROR_ORIGIN '
        'origin=flutter_blue_plus_native '
        'error_category=invalid_state',
      ),
    );
  });

  test('iOS apple-code 14 connect failure maps to typed exception', () {
    final mapped = RealBleClient.mapConnectionFailureForTesting(
      FlutterBluePlusException(
        ErrorPlatform.apple,
        'connect',
        14,
        'Peer removed pairing information',
      ),
    );

    expect(mapped, isNotNull);
    expect(mapped?.code, DeviceException.bleIosPairingInformationRemovedCode);
    expect(mapped?.message, contains('apple-code: 14'));
    expect(mapped?.message, contains('Peer removed pairing information'));
  });

  test('generic connect failure is not remapped', () {
    final mapped = RealBleClient.mapConnectionFailureForTesting(
      FlutterBluePlusException(
        ErrorPlatform.apple,
        'connect',
        7,
        'Connection timeout',
      ),
    );

    expect(mapped, isNull);
  });
}

RealBleClient _buildRealBleClient({
  bool supported = true,
  bool Function()? supportedProvider,
  BluetoothAdapterState adapterState = BluetoothAdapterState.on,
  bool isScanning = false,
  NativeBleStartScan? startScan,
}) {
  return RealBleClient(
    isSupportedProvider: () async => supportedProvider?.call() ?? supported,
    adapterStateProvider: () => adapterState,
    isScanningProvider: () => isScanning,
    adapterStateStreamProvider: () => Stream<BluetoothAdapterState>.value(
      adapterState,
    ),
    scanResultsProvider: () => const Stream<List<ScanResult>>.empty(),
    startScan: startScan ?? (_) async {},
    stopScan: () async {},
  );
}

final class _FakeBleClient implements BleClient {
  var initializeCalls = 0;
  var scanCalls = 0;

  @override
  Future<void> initialize() async {
    initializeCalls += 1;
  }

  @override
  Future<List<BleScanResult>> scan({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    scanCalls += 1;
    return <BleScanResult>[
      BleScanResult(
        deviceId: 'native-scan-device',
        name: 'EIXAM Native',
        rssi: -50,
        connectable: true,
        advertisedServiceUuids: const <String>[],
        discoveredAt: DateTime(2026, 1, 1),
      ),
    ];
  }

  @override
  Future<void> connect(String deviceId) async {}

  @override
  Future<void> disconnect(String deviceId) async {}

  @override
  Future<BleAdapterState> getAdapterState() async => BleAdapterState.poweredOn;

  @override
  Future<bool> hasSystemAssociation(String deviceId) async => false;

  @override
  Future<bool> isConnected(String deviceId) async => false;

  @override
  Future<bool> isEixamCompatible(String deviceId) async => false;

  @override
  Future<int?> readBatteryLevel(String deviceId) async => null;

  @override
  Future<String?> readFirmwareVersion(String deviceId) async => null;

  @override
  Future<int?> readSignalQuality(String deviceId) async => null;

  @override
  Future<bool> removeSystemAssociation(String deviceId) async => false;

  @override
  Future<List<BleScanResult>> listSystemAssociatedDevices() async =>
      const <BleScanResult>[];

  @override
  Future<Stream<EixamBleNotification>> subscribeEixamNotifications(
    String deviceId,
  ) async {
    return const Stream<EixamBleNotification>.empty();
  }

  @override
  Stream<BleAdapterState> watchAdapterState() {
    return const Stream<BleAdapterState>.empty();
  }

  @override
  Stream<bool> watchConnection(String deviceId) {
    return const Stream<bool>.empty();
  }

  @override
  Future<void> writeDeviceCommand(
    String deviceId,
    EixamDeviceCommand command,
  ) async {}
}
