import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/device/ble_adapter_state.dart';
import 'package:eixam_connect_flutter/src/device/ble_client.dart';
import 'package:eixam_connect_flutter/src/device/ble_debug_registry.dart';
import 'package:eixam_connect_flutter/src/device/ble_scan_result.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_protocol.dart';
import 'package:eixam_connect_flutter/src/device/meshtastic_ble_protocol.dart';
import 'package:eixam_connect_flutter/src/sdk/tag_pairing_code_correlator.dart';
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

  test(
    'iOS QR discovers connected stock and still requires inspection',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final target = _SystemDevice('target-uuid', 'Meshtastic_756e');
      final control = _SystemDevice('control-uuid', 'Meshtastic_1aa8');
      final client = _buildRealBleClient(
        systemDevicesProvider: (services) async =>
            services.single == Guid(MeshtasticBleProtocol.serviceUuid)
            ? [control, target]
            : [],
      );
      await client.initialize();
      final found = await client.scan(timeout: Duration.zero);
      final match = TagPairingCodeCorrelator.find(
        'N693756E',
        found.map((r) => r.toPublic()),
      );
      expect(match.state, TagPairingCodeMatchState.inspectionRequired);
      expect(match.candidate?.deviceId, 'target-uuid');
      expect(match.candidate?.canonicalHardwareId, isNull);
      expect(
        found
            .singleWhere((r) => r.deviceId == 'target-uuid')
            .advertisedLocalName,
        isNull,
      );
    },
  );

  test('connected Eixam runtime and unrelated devices are not stock', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final current = _SystemDevice('current', 'Meshtastic_756e');
    final client = _buildRealBleClient(
      systemDevicesProvider: (services) async =>
          services.single == Guid(MeshtasticBleProtocol.serviceUuid)
          ? [current, _SystemDevice('headphones', 'Headphones')]
          : [current],
    );
    await client.initialize();
    expect(await client.scan(timeout: Duration.zero), isEmpty);
  });

  test(
    'Android queries connected candidates once without trusting UUID filter',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      var calls = 0;
      final client = _buildRealBleClient(
        systemDevicesProvider: (_) async {
          calls++;
          return [
            _SystemDevice('E9:B4:55:93:75:6E', 'Meshtastic_756e'),
            _SystemDevice('control', 'Meshtastic_1aa8'),
            _SystemDevice('unrelated', 'Headphones'),
            _SystemDevice('similar', 'Meshtastic_756e_extra'),
          ];
        },
      );
      await client.initialize();
      final found = await client.scan(timeout: Duration.zero);
      expect(calls, 1);
      expect(found, hasLength(2));
      final match = TagPairingCodeCorrelator.find(
        'N693756E',
        found.map((r) => r.toPublic()),
      );
      expect(match.state, TagPairingCodeMatchState.inspectionRequired);
      expect(match.candidate?.deviceId, 'E9:B4:55:93:75:6E');
      expect(match.candidate?.canonicalHardwareId, isNull);
      final target = found.singleWhere(
        (r) => r.deviceId == 'E9:B4:55:93:75:6E',
      );
      expect(target.advertisedLocalName, isNull);
      expect(target.advertisedServiceUuids, isEmpty);
    },
  );

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    test('F12: an overlapping scan does not cancel an older scan', () async {
      debugDefaultTargetPlatformOverride = platform;
      final entered = Completer<void>();
      final pending = Completer<List<BluetoothDevice>>();
      var calls = 0;
      final client = _buildRealBleClient(
        systemDevicesProvider: (_) async {
          if (calls++ == 0) {
            entered.complete();
            return pending.future;
          }
          return [];
        },
      );
      await client.initialize();
      final old = client.scan(timeout: Duration.zero);
      await entered.future;
      expect(await client.scan(timeout: Duration.zero), isEmpty);
      pending.complete([_SystemDevice('old', 'Meshtastic_756e')]);
      expect((await old).single.deviceId, 'old');
    });

    test('F12: the late watcher scan and a discovery scan share one native '
        'scan and both see the stock TAG', () async {
      debugDefaultTargetPlatformOverride = platform;
      final events = StreamController<List<ScanResult>>.broadcast(sync: true);
      addTearDown(events.close);
      var starts = 0;
      var stops = 0;
      final client = _buildRealBleClient(
        scanResultsProvider: () => events.stream,
        startScan: (_) async => starts++,
        stopScan: () async => stops++,
      );
      await client.initialize();
      // Watcher scan (8 s in production) is running.
      final watcher = client.scan(timeout: const Duration(milliseconds: 80));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      // The stock TAG is reported once per native session, before the
      // discovery poll starts (iOS / no continuousUpdates).
      events.add([_stockTagAdvert()]);
      final discovery = client.scan(timeout: const Duration(milliseconds: 20));
      final discovered = await discovery;
      expect(discovered.single.deviceId, 'stock-tag');
      expect(
        discovered.single.toPublic().pairingDisplayCategory,
        EixamPairingDisplayCategory.legacyOrStock,
      );
      expect(stops, 0, reason: 'the watcher still owns the native scan');
      expect((await watcher).single.deviceId, 'stock-tag');
      expect(starts, 1);
      expect(stops, 1);
    });

    test('F12: a later caller outside the native window extends it', () async {
      debugDefaultTargetPlatformOverride = platform;
      const ms = Duration(milliseconds: 1);
      final windows = <Duration>[];
      var stops = 0;
      final client = _buildRealBleClient(
        minNativeScanWindow: ms * 100,
        startScan: (window) async => windows.add(window),
        stopScan: () async => stops++,
      );
      await client.initialize();
      final first = client.scan(timeout: ms * 40);
      await Future<void>.delayed(ms * 20);
      // 20 + 40 ms still fits the first 100 ms native window: joined.
      final second = client.scan(timeout: ms * 40);
      await first;
      expect(windows, [ms * 100]);
      expect(stops, 0, reason: 'the second caller still scans');
      // Ends after the window: one restart extends the native scan.
      final third = client.scan(timeout: ms * 150);
      await Future<void>.delayed(ms * 5);
      expect(windows, [ms * 100, ms * 150]);
      await second;
      expect(stops, 0);
      await third;
      expect(stops, 1);
    });

    test(
      'F13: adverts received for another caller are kept as sightings',
      () async {
        debugDefaultTargetPlatformOverride = platform;
        final events = StreamController<List<ScanResult>>.broadcast(sync: true);
        addTearDown(events.close);
        final client = _buildRealBleClient(
          scanResultsProvider: () => events.stream,
        );
        await client.initialize();
        final before = DateTime.now().subtract(const Duration(seconds: 1));
        final scan = client.scan(timeout: const Duration(milliseconds: 20));
        await Future<void>.delayed(const Duration(milliseconds: 5));
        events.add([
          _nativeScanResult(
            deviceId: 'tag',
            observedAt: DateTime.now(),
            name: 'AdaDFU',
            services: [Guid('00001530-1212-efde-1523-785feabcd123')],
          ),
        ]);
        expect((await scan).single.deviceId, 'tag');
        final seen = client.advertisementsSince(before);
        expect(seen.single.deviceId, 'tag');
        expect(seen.single.toPublic().isDfuBootloader, isTrue);
        expect(
          client.advertisementsSince(
            DateTime.now().add(const Duration(seconds: 1)),
          ),
          isEmpty,
        );
      },
    );

    test('fresh advertisement wins over a conflicting system name', () async {
      debugDefaultTargetPlatformOverride = platform;
      final events = StreamController<List<ScanResult>>.broadcast(sync: true);
      addTearDown(events.close);
      final client = _buildRealBleClient(
        systemDevicesProvider: (_) async => [
          _SystemDevice('same', 'Meshtastic_756e'),
        ],
        scanResultsProvider: () => events.stream,
        startScan: (_) async => events.add([
          _nativeScanResult(
            deviceId: 'same',
            observedAt: DateTime.now(),
            name: 'EIXAM_A693756E',
            services: [Guid(EixamBleProtocol.serviceUuid)],
          ),
        ]),
      );
      await client.initialize();
      final result = (await client.scan(timeout: Duration.zero)).single;
      expect(result.name, 'EIXAM_A693756E');
      expect(result.brandClassification, BleDiscoveredDeviceBrand.eixam);
      expect(result.advertisedLocalName, 'EIXAM_A693756E');
    });

    test('system discovery error preserves fresh advertisements', () async {
      debugDefaultTargetPlatformOverride = platform;
      final events = StreamController<List<ScanResult>>.broadcast(sync: true);
      addTearDown(events.close);
      final client = _buildRealBleClient(
        systemDevicesProvider: (_) async => throw StateError('unavailable'),
        scanResultsProvider: () => events.stream,
        startScan: (_) async => events.add([
          _nativeScanResult(deviceId: 'fresh', observedAt: DateTime.now()),
        ]),
      );
      await client.initialize();
      expect(
        (await client.scan(timeout: Duration.zero)).single.deviceId,
        'fresh',
      );
    });
  }
  test(
    'lazy client registry scanner initializes and reaches delegate scan',
    () async {
      final delegate = _FakeBleClient();
      LazyInitializingBleClient(delegate);

      final results = await BleDebugRegistry.instance.startScan();

      expect(delegate.initializeCalls, 1);
      expect(delegate.scanCalls, 1);
      expect(results.single.deviceId, 'native-scan-device');
    },
  );

  test(
    'iOS poweredOn supported unknown scanner reaches native start call',
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
    },
  );

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
    expect(logs, contains('SDK_DISCOVERY_PRECHECK_BLOCKED reason=unsupported'));
  });

  test(
    'native startScan E_BLE_SCANNER_NOT_READY maps to typed exception',
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
    },
  );

  test('new scan rejects a replayed result from an older scan', () async {
    final staleResult = _nativeScanResult(
      deviceId: 'AA:BB:CC:DD:EE:01',
      observedAt: DateTime.now().subtract(const Duration(seconds: 1)),
    );
    final client = _buildRealBleClient(
      scanResultsProvider: () =>
          Stream<List<ScanResult>>.value(<ScanResult>[staleResult]),
    );

    await client.initialize();
    final results = await client.scan(timeout: Duration.zero);

    expect(results, isEmpty);
    expect(
      BleDebugRegistry.instance.currentState.events.map(
        (event) => event.message,
      ),
      contains('BLE_SCAN_RESULT_REJECTED reason=stale_generation generation=1'),
    );
  });

  test('new scan accepts a fresh result and preserves its timestamp', () async {
    final scanResults = StreamController<List<ScanResult>>.broadcast(
      sync: true,
    );
    late final DateTime observedAt;
    final client = _buildRealBleClient(
      scanResultsProvider: () => scanResults.stream,
      startScan: (_) async {
        observedAt = DateTime.now();
        scanResults.add(<ScanResult>[
          _nativeScanResult(
            deviceId: 'AA:BB:CC:DD:EE:02',
            observedAt: observedAt,
          ),
        ]);
      },
    );
    addTearDown(scanResults.close);

    await client.initialize();
    final results = await client.scan(timeout: Duration.zero);

    expect(results, hasLength(1));
    expect(results.single.deviceId, 'AA:BB:CC:DD:EE:02');
    expect(results.single.discoveredAt, observedAt);
  });

  test(
    'fresh iOS local-name and service evidence reaches QR correlation',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final scans = StreamController<List<ScanResult>>.broadcast(sync: true);
      addTearDown(scans.close);
      const handle = 'B748445B-FDEA-2426-48F1-FD1A086627FA';
      final client = _buildRealBleClient(
        scanResultsProvider: () => scans.stream,
        startScan: (_) async {
          scans.add([
            _nativeScanResult(
              deviceId: handle,
              observedAt: DateTime.now(),
              name: 'eixam_a693756e',
              services: [Guid(EixamBleProtocol.serviceUuid)],
            ),
          ]);
        },
      );
      await client.initialize();
      final result = (await client.scan(
        timeout: Duration.zero,
      )).single.toPublic();
      expect(result.canonicalHardwareId, isNull);
      expect(result.advertisedEixamIdentity, 'EIXAM_A693756E');
      final match = TagPairingCodeCorrelator.verifyCurrentDiscovery(
        TagPairingCodeCorrelator.find('N693756E', [result]),
      );
      expect(match.state, TagPairingCodeMatchState.matched);
      expect(match.candidate!.deviceId, handle);
    },
  );

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

  group('iOS stale bond detection is language independent', () {
    String? codeOf(Object error) =>
        RealBleClient.mapConnectionFailureForTesting(error)?.code;
    const staleBond = DeviceException.bleIosPairingInformationRemovedCode;

    for (final description in <String?>[
      'El periférico ha eliminado la información de emparejamiento',
      "El perifèric ha eliminat la informació d'aparellament",
      null,
    ]) {
      test('connect code 14 maps with description "$description"', () {
        expect(
          codeOf(
            FlutterBluePlusException(
              ErrorPlatform.apple,
              'connect',
              14,
              description,
            ),
          ),
          staleBond,
        );
      });
    }

    test('wrapped connect error with localized text maps by code', () {
      final wrapped = StateError(
        FlutterBluePlusException(
          ErrorPlatform.apple,
          'connect',
          14,
          'El periférico ha eliminado la información de emparejamiento',
        ).toString(),
      );
      expect(codeOf(wrapped), staleBond);
    });

    test('English description fallback still maps other operations', () {
      expect(
        codeOf(
          FlutterBluePlusException(
            ErrorPlatform.apple,
            'discoverServices',
            14,
            'Peer removed pairing information.',
          ),
        ),
        staleBond,
      );
      expect(
        codeOf(StateError('apple-code: 14 Peer removed pairing information')),
        staleBond,
      );
    });

    test('unrelated errors are not matched', () {
      final unrelated = <Object>[
        // CBATTError code 14 ("unlikely error") outside connect.
        FlutterBluePlusException(
          ErrorPlatform.apple,
          'setNotifyValue',
          14,
          'Error poco probable',
        ),
        FlutterBluePlusException(
          ErrorPlatform.apple,
          'readCharacteristic',
          14,
          'Unlikely error',
        ),
        // Same code on other platforms.
        FlutterBluePlusException(ErrorPlatform.android, 'connect', 14, null),
        FlutterBluePlusException(ErrorPlatform.fbp, 'connect', 14, null),
        // Other apple connect codes.
        FlutterBluePlusException(ErrorPlatform.apple, 'connect', 6, null),
        FlutterBluePlusException(ErrorPlatform.apple, 'connect', 15, null),
        StateError('apple-code: 14 something else'),
        StateError('connect failed'),
      ];
      for (final error in unrelated) {
        expect(codeOf(error), isNull, reason: '$error');
      }
    });
  });
}

RealBleClient _buildRealBleClient({
  bool supported = true,
  bool Function()? supportedProvider,
  BluetoothAdapterState adapterState = BluetoothAdapterState.on,
  bool isScanning = false,
  Stream<List<ScanResult>> Function()? scanResultsProvider,
  NativeBleStartScan? startScan,
  NativeBleStopScan? stopScan,
  Duration minNativeScanWindow = const Duration(seconds: 20),
  Future<List<BluetoothDevice>> Function(List<Guid>)? systemDevicesProvider,
}) {
  return RealBleClient(
    minNativeScanWindow: minNativeScanWindow,
    isSupportedProvider: () async => supportedProvider?.call() ?? supported,
    adapterStateProvider: () => adapterState,
    isScanningProvider: () => isScanning,
    adapterStateStreamProvider: () =>
        Stream<BluetoothAdapterState>.value(adapterState),
    scanResultsProvider:
        scanResultsProvider ?? () => const Stream<List<ScanResult>>.empty(),
    startScan: startScan ?? (_) async {},
    stopScan: stopScan ?? () async {},
    systemDevicesProvider: systemDevicesProvider ?? (_) async => [],
  );
}

final class _SystemDevice extends BluetoothDevice {
  _SystemDevice(super.remoteId, this.savedName) : super.fromId();
  final String savedName;
  @override
  String get platformName => savedName;
}

ScanResult _stockTagAdvert() => _nativeScanResult(
  deviceId: 'stock-tag',
  observedAt: DateTime.now(),
  name: '756E_756e',
  services: [Guid('6ba1b218-15a8-461f-9fa8-5dcae273eafd')],
);

ScanResult _nativeScanResult({
  required String deviceId,
  required DateTime observedAt,
  String name = 'EIXAM TAG',
  List<Guid> services = const [],
}) {
  return ScanResult(
    device: BluetoothDevice.fromId(deviceId),
    advertisementData: AdvertisementData(
      advName: name,
      txPowerLevel: null,
      appearance: null,
      connectable: true,
      manufacturerData: const <int, List<int>>{},
      serviceData: const <Guid, List<int>>{},
      serviceUuids: services,
    ),
    rssi: -55,
    timeStamp: observedAt,
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
