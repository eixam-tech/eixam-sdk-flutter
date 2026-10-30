import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/device/meshtastic_metadata_probe.dart';
import 'package:eixam_connect_flutter/src/sdk/ble_auto_reconnect_coordinator.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/preferred_ble_device_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/shared_prefs_sdk_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';

const _id = 'E9:B4:55:93:75:6E';
const _metadata = <int>[
  0x6a,
  0x0a,
  0x0a,
  0x06,
  0x32,
  0x2e,
  0x37,
  0x2e,
  0x32,
  0x36,
  0x48,
  105,
];

void main() {
  FlutterBlueMeshtasticMetadataProbe probe(
    _Transport t, {
    Duration notification = const Duration(milliseconds: 40),
    MeshtasticInspectionCancellation? cancellation,
  }) => FlutterBlueMeshtasticMetadataProbe(
    transportFactory: (_) => t,
    connectionTimeout: const Duration(milliseconds: 40),
    serviceTimeout: const Duration(milliseconds: 40),
    batteryTimeout: const Duration(milliseconds: 40),
    notificationTimeout: notification,
    requestTimeout: const Duration(milliseconds: 40),
    cancellation: cancellation,
  );

  Matcher failure(DeviceMigrationInspectionFailure f) =>
      isA<MeshtasticInspectionException>().having(
        (e) => e.failure,
        'failure',
        f,
      );

  void ios() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
  }

  test('iOS revalidation survives a retained physical link', () async {
    ios();
    final t = _Transport()
      ..android = false
      ..dropDuplicateRequests = true
      ..retainPhysicalLink = true
      ..configFrames = [_myInfo, _ownNodeInfo, _metadata];
    final p = probe(t);
    final first = await p.inspect(_id);
    final second = await p.inspect(_id);
    expect(first.hardwareModel, 105);
    expect(second.hardwareMac, _id);
    expect(second.nodeNumber, 0x5593756e);
    expect(t.requests, hasLength(2));
    expect(t.requests[0], isNot(t.requests[1]));
    expect(t.events.where((v) => v == 'security'), hasLength(2));
    expect(t.isConnected, false);
  });

  test(
    'iOS metadata waits for matching own-node identity before cleanup',
    () async {
      ios();
      final t = _Transport()
        ..android = false
        ..configFrames = [_metadata, _myInfo, _otherNodeInfo, _ownNodeInfo];
      final result = await probe(t).inspect(_id);
      expect(result.hardwareModel, 105);
      expect(result.nodeNumber, 0x5593756e);
      expect(result.hardwareMac, _id);
      expect(t.events.where((v) => v == 'read'), hasLength(4));
      expect(t.events.last, 'disconnect');
    },
  );

  test('iOS ignores metadata received before the fresh request', () async {
    ios();
    final t = _Transport()
      ..android = false
      ..emitMetadataDuringEnable = true
      ..configFrames = [_myInfo, _ownNodeInfo, _metadata];
    expect((await probe(t).inspect(_id)).hardwareModel, 105);
  });

  test(
    'iOS completion without own identity remains unable to verify',
    () async {
      ios();
      final t = _Transport()
        ..android = false
        ..configFrames = [_metadata, _myInfo, _otherNodeInfo]
        ..completeConfig = true;
      await expectLater(
        probe(t).inspect(_id),
        throwsA(failure(DeviceMigrationInspectionFailure.malformedMetadata)),
      );
      expect(t.isConnected, false);
    },
  );

  test('Android revalidation survives a retained physical link', () async {
    final t = _Transport()
      ..dropDuplicateRequests = true
      ..retainPhysicalLink = true
      ..configFrames = [_myInfo, _ownNodeInfo, _metadata];
    final first = await probe(t).inspect(_id);
    final second = await probe(t).inspect(_id);
    expect(first.hardwareMac, _id);
    expect(second.hardwareMac, _id);
    expect(second.nodeNumber, first.nodeNumber);
    expect(t.requests, hasLength(2));
    expect(t.requests[0], isNot(t.requests[1]));
    expect(t.isConnected, false);
  });

  test(
    'Android uses fresh requests without changing metadata completion',
    () async {
      final t = _Transport()..dropDuplicateRequests = true;
      expect((await probe(t).inspect(_id)).hardwareModel, 105);
      expect((await probe(t).inspect(_id)).hardwareModel, 105);
      expect(t.requests.first.first, 0x18);
      expect(t.requests.first, isNot([0x18, 0xac, 0x9e, 0x04]));
      expect(t.requests.last, isNot(t.requests.first));
    },
  );

  test(
    'fresh iOS encrypted inspection authenticates before notifications',
    () async {
      final t = _Transport()
        ..android = false
        ..requiresEncryption = true
        ..emitStaleSecurityMetadata = true;

      expect((await probe(t).inspect(_id)).hardwareModel, 105);
      expect(t.securityPrepared, true);
      expect(
        t.events.indexOf('security'),
        lessThan(t.events.indexOf('enable')),
      );
      expect(t.isConnected, false);
    },
  );

  test('security setup timeout interrupts the read before returning', () async {
    final t = _Transport()
      ..android = false
      ..pendingSecurity = Completer<void>();

    await expectLater(
      probe(t).inspect(_id),
      throwsA(failure(DeviceMigrationInspectionFailure.bondingTimedOut)),
    );
    expect(t.securitySettled, true);
    expect(t.events.contains('enable'), false);
    expect(t.events.contains('request'), false);
    expect(t.framesController.hasListener, false);
    expect(t.isConnected, false);
  });

  test('security cancellation waits for native connection cleanup', () async {
    final t = _Transport()
      ..android = false
      ..pendingSecurity = Completer<void>()
      ..cleanupGate = Completer<void>();
    final cancel = MeshtasticInspectionCancellation();
    var returned = false;
    final checked = expectLater(
      probe(
        t,
        cancellation: cancel,
      ).inspect(_id).whenComplete(() => returned = true),
      throwsA(failure(DeviceMigrationInspectionFailure.cancelled)),
    );
    await t.securing.future;
    cancel.cancel();
    await t.disconnecting.future;
    expect(returned, false);
    expect(t.events.contains('enable'), false);
    expect(t.events.contains('request'), false);
    t.cleanupGate!.complete();
    await checked;
    expect(t.securitySettled, true);
    expect(t.isConnected, false);
  });

  test(
    'SDK inspection priority remains held until transport cleanup completes',
    () async {
      SharedPreferences.setMockInitialValues({});
      final t = _Transport()
        ..pendingEnable = Completer<void>()
        ..cleanupGate = Completer<void>();
      final priority = BleAutoReconnectCoordinator(
        deviceRepository: _UnusedRepository(),
        preferredDeviceStore: PreferredBleDeviceStore(
          localStore: SharedPrefsSdkStore(),
        ),
      );
      var released = false;
      final run = priority
          .runWithCandidateInspectionPriority<MeshtasticProbeResult>(
            reason: 'test',
            selectedMarker: 'test',
            operation: () => probe(t).inspect(_id),
          )
          .whenComplete(() => released = true);
      final checked = expectLater(
        run,
        throwsA(
          failure(DeviceMigrationInspectionFailure.notificationSetupTimedOut),
        ),
      );
      await t.disconnecting.future;
      expect(released, false);
      t.cleanupGate!.complete();
      await checked;
      expect(released, true);
      await priority.dispose();
    },
  );

  test('native subscription timeout retains precise typed cause', () async {
    final t = _Transport()
      ..enableError = FlutterBluePlusException(
        ErrorPlatform.fbp,
        'setNotifyValue',
        FbpErrorCode.timeout.index,
        'timed out',
      );
    await expectLater(
      probe(t).inspect(_id),
      throwsA(
        failure(DeviceMigrationInspectionFailure.notificationSetupTimedOut),
      ),
    );
  });

  test(
    'cleanup awaits late CCCD settlement even after disconnect completes',
    () async {
      final t = _Transport()
        ..pendingEnable = Completer<void>()
        ..interruptEnable = false;
      var returned = false;
      final checked = expectLater(
        probe(t).inspect(_id).whenComplete(() => returned = true),
        throwsA(
          failure(DeviceMigrationInspectionFailure.notificationSetupTimedOut),
        ),
      );
      await t.disconnecting.future;
      await Future<void>.delayed(Duration.zero);
      expect(returned, false);
      expect(t.framesController.hasListener, false);
      t.pendingEnable!.complete();
      await checked;
      expect(t.events.contains('request'), false);
      expect(t.enableSettled, true);
    },
  );

  test('completed battery read failure remains optional', () async {
    final t = _Transport()..failAt = 'battery';
    expect((await probe(t).inspect(_id)).hardwareModel, 105);
  });

  test('inspection waits for pending bond cleanup before returning', () async {
    final t = _Transport()
      ..pendingEnable = Completer<void>()
      ..bondCleanupGate = Completer<void>();
    var returned = false;
    final checked = expectLater(
      probe(t).inspect(_id).whenComplete(() => returned = true),
      throwsA(failure(DeviceMigrationInspectionFailure.bondingTimedOut)),
    );
    await t.enabling.future;
    t.bonds.add(BluetoothBondState.bonding);
    await t.finishingBond.future;
    expect(returned, false);
    t.bondCleanupGate!.complete();
    await checked;
    expect(t.bonds.hasListener, false);
  });

  test(
    'a pre-existing bond operation is never cancelled by inspection',
    () async {
      final t = _Transport()..initialBond = BluetoothBondState.bonding;
      await expectLater(
        probe(t).inspect(_id),
        throwsA(
          failure(DeviceMigrationInspectionFailure.connectionAlreadyOwned),
        ),
      );
      expect(t.events, isEmpty);
      expect(t.bonds.hasListener, false);
    },
  );

  test(
    'bonding stage deadline is independent of metadata response deadline',
    () async {
      final t = _Transport()..pendingEnable = Completer<void>();
      final run = probe(
        t,
      ).inspect(_id, timeout: const Duration(milliseconds: 5));
      await t.enabling.future;
      t.bonds.add(BluetoothBondState.bonding);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      t.bonds.add(BluetoothBondState.bonded);
      t.pendingEnable!.complete();
      expect((await run).hardwareModel, 105);
    },
  );

  test('normal subscription reads model and version, then cleans up', () async {
    final t = _Transport();
    final result = await probe(t).inspect(_id);
    expect(result.hardwareModel, 105);
    expect(result.firmwareVersion, '2.7.26');
    expect(t.events, [
      'connect',
      'refresh',
      'discover',
      'battery',
      'security',
      'enable',
      'request',
      'read',
      'disconnect',
    ]);
    expect(t.framesController.hasListener, false);
    expect(t.bonds.hasListener, false);
    expect(t.isConnected, false);
  });

  test(
    'stale service cache is refreshed before proving characteristics',
    () async {
      final t = _Transport()..staleCache = true;
      expect((await probe(t).inspect(_id)).hardwareModel, 105);
      expect(
        t.events.indexOf('refresh'),
        lessThan(t.events.indexOf('discover')),
      );
      expect(t.events.where((e) => e == 'refresh'), hasLength(1));
    },
  );

  test(
    'cache refresh does not bypass missing required characteristics',
    () async {
      final t = _Transport()..missingCharacteristics = true;
      await expectLater(
        probe(t).inspect(_id),
        throwsA(failure(DeviceMigrationInspectionFailure.serviceIncomplete)),
      );
      expect(t.events.contains('request'), false);
      expect(t.connected, false);
    },
  );

  test('cancel during refresh awaits settlement without discovery', () async {
    final cancellation = MeshtasticInspectionCancellation();
    final t = _Transport()..pendingRefresh = Completer<void>();
    var returned = false;
    final checked = expectLater(
      probe(
        t,
        cancellation: cancellation,
      ).inspect(_id).whenComplete(() => returned = true),
      throwsA(failure(DeviceMigrationInspectionFailure.cancelled)),
    );
    await t.refreshing.future;
    cancellation.cancel();
    await t.disconnecting.future;
    expect(returned, false);
    t.pendingRefresh!.complete();
    await checked;
    expect(t.events.contains('discover'), false);
    expect(t.connected, false);
  });

  test('refresh shares the service deadline without late discovery', () async {
    final t = _Transport()..pendingRefresh = Completer<void>();
    final checked = expectLater(
      probe(t).inspect(_id),
      throwsA(failure(DeviceMigrationInspectionFailure.serviceDiscoveryFailed)),
    );
    await t.disconnecting.future;
    t.pendingRefresh!.complete();
    await checked;
    expect(t.events.contains('discover'), false);
    expect(t.connected, false);
  });

  test('bond-none is not terminal; bonding then bonded continues', () async {
    final t = _Transport()..pendingEnable = Completer<void>();
    final run = probe(t).inspect(_id);
    await t.enabling.future;
    t.bonds.add(BluetoothBondState.none);
    t.bonds.add(BluetoothBondState.bonding);
    await Future<void>.delayed(Duration.zero);
    expect(t.events.contains('request'), false);
    t.bonds.add(BluetoothBondState.bonded);
    t.pendingEnable!.complete();
    expect((await run).hardwareModel, 105);
    expect(t.framesController.hasListener, false);
  });

  test(
    'unfinished bonding yields typed timeout and drains subscription work',
    () async {
      final t = _Transport()..pendingEnable = Completer<void>();
      final run = probe(t).inspect(_id);
      final checked = expectLater(
        run,
        throwsA(failure(DeviceMigrationInspectionFailure.bondingTimedOut)),
      );
      await t.enabling.future;
      t.bonds.add(BluetoothBondState.bonding);
      await checked;
      expect(t.enableSettled, true);
      expect(t.events.contains('request'), false);
      expect(t.framesController.hasListener, false);
      expect(t.bonds.hasListener, false);
      expect(t.isConnected, false);
    },
  );

  test('pending subscription without bonding has distinct timeout', () async {
    final t = _Transport()..pendingEnable = Completer<void>();
    await expectLater(
      probe(t).inspect(_id),
      throwsA(
        failure(DeviceMigrationInspectionFailure.notificationSetupTimedOut),
      ),
    );
    expect(t.enableSettled, true);
  });

  test(
    'bonding failure/disconnect is distinct from unsupported hardware',
    () async {
      final t = _Transport()..pendingEnable = Completer<void>();
      final checked = expectLater(
        probe(t).inspect(_id),
        throwsA(failure(DeviceMigrationInspectionFailure.bondingFailed)),
      );
      await t.enabling.future;
      t.bonds.add(BluetoothBondState.bonding);
      t.bonds.add(BluetoothBondState.none);
      await checked;
      expect(t.events.contains('read'), false);
    },
  );

  test(
    'return waits for disconnect and permits an immediate second inspection',
    () async {
      final t = _Transport()
        ..pendingEnable = Completer<void>()
        ..cleanupGate = Completer<void>();
      var returned = false;
      final checked = expectLater(
        probe(t).inspect(_id).whenComplete(() => returned = true),
        throwsA(
          failure(DeviceMigrationInspectionFailure.notificationSetupTimedOut),
        ),
      );
      await t.disconnecting.future;
      expect(returned, false);
      expect(t.framesController.hasListener, false);
      t.cleanupGate!.complete();
      await checked;
      t.pendingEnable = null;
      t.cleanupGate = null;
      expect((await probe(t).inspect(_id)).hardwareModel, 105);
    },
  );

  test('cancellation interrupts pending CCCD before returning', () async {
    final t = _Transport()..pendingEnable = Completer<void>();
    final cancel = MeshtasticInspectionCancellation();
    final checked = expectLater(
      probe(t, cancellation: cancel).inspect(_id),
      throwsA(failure(DeviceMigrationInspectionFailure.cancelled)),
    );
    await t.enabling.future;
    cancel.cancel();
    await checked;
    expect(t.enableSettled, true);
    expect(t.isConnected, false);
  });

  test(
    'metadata deadline interrupts read and prevents late state mutation',
    () async {
      final t = _Transport()..pendingRead = Completer<List<int>>();
      await expectLater(
        probe(t).inspect(_id, timeout: const Duration(milliseconds: 30)),
        throwsA(failure(DeviceMigrationInspectionFailure.metadataTimedOut)),
      );
      expect(t.readSettled, true);
      expect(t.framesController.hasListener, false);
      t.framesController.add(_metadata);
      t.bonds.add(BluetoothBondState.bonded);
      await Future<void>.delayed(Duration.zero);
      expect(t.events.where((v) => v == 'read').length, 1);
    },
  );

  test('metadata polling timer is cancelled on cancellation', () async {
    final t = _Transport()..metadata = [];
    final cancel = MeshtasticInspectionCancellation();
    final checked = expectLater(
      probe(t, cancellation: cancel).inspect(_id),
      throwsA(failure(DeviceMigrationInspectionFailure.cancelled)),
    );
    await t.reading.future;
    await Future<void>.delayed(Duration.zero);
    cancel.cancel();
    await checked;
    expect(t.events.where((v) => v == 'read').length, 1);
  });

  test('malformed protobuf has a precise failure and cleanup', () async {
    final t = _Transport()..metadata = [0];
    await expectLater(
      probe(t).inspect(_id),
      throwsA(failure(DeviceMigrationInspectionFailure.malformedMetadata)),
    );
    expect(t.isConnected, false);
  });

  test('non-Android path does not subscribe to bond state', () async {
    final t = _Transport()..android = false;
    expect((await probe(t).inspect(_id)).hardwareModel, 105);
    expect(t.bonds.hasListener, false);
  });

  test('already owned connection is not borrowed or disconnected', () async {
    final t = _Transport()..connected = true;
    await expectLater(
      probe(t).inspect(_id),
      throwsA(failure(DeviceMigrationInspectionFailure.connectionAlreadyOwned)),
    );
    expect(t.events, isEmpty);
    expect(t.isConnected, true);
  });

  for (final stage in [
    'connect',
    'discover',
    'security',
    'enable',
    'request',
  ]) {
    test('$stage failure retains stage and performs cleanup', () async {
      final t = _Transport()..failAt = stage;
      final f = switch (stage) {
        'connect' => DeviceMigrationInspectionFailure.connectionFailed,
        'discover' => DeviceMigrationInspectionFailure.serviceDiscoveryFailed,
        'security' => DeviceMigrationInspectionFailure.bondingFailed,
        'enable' => DeviceMigrationInspectionFailure.notificationSetupFailed,
        _ => DeviceMigrationInspectionFailure.metadataRequestFailed,
      };
      await expectLater(probe(t).inspect(_id), throwsA(failure(f)));
      expect(t.events.last, 'disconnect');
      expect(t.isConnected, false);
      expect(t.framesController.hasListener, false);
    });
  }

  test(
    'hardware models remain raw probe evidence for coordinator verification',
    () async {
      for (final model in [0, 9, 105]) {
        final t = _Transport()
          ..metadata = [..._metadata.take(_metadata.length - 1), model];
        expect((await probe(t).inspect(_id)).hardwareModel, model);
      }
    },
  );
}

final class _Transport implements MeshtasticInspectionTransport {
  _Transport() {
    addTearDown(() async {
      await framesController.close();
      await bonds.close();
    });
  }
  final framesController = StreamController<List<int>>.broadcast(sync: true);
  final bonds = StreamController<BluetoothBondState>.broadcast(sync: true);
  final events = <String>[];
  bool connected = false;
  bool staleCache = false;
  bool missingCharacteristics = false;
  Completer<void>? pendingRefresh;
  final refreshing = Completer<void>();
  BluetoothBondState initialBond = BluetoothBondState.none;
  Completer<void>? bondCleanupGate;
  final finishingBond = Completer<void>();
  bool android = true;
  bool requiresEncryption = false;
  bool emitStaleSecurityMetadata = false;
  bool emitMetadataDuringEnable = false;
  bool dropDuplicateRequests = false;
  bool retainPhysicalLink = false;
  List<int>? _lastPhysicalRequest;
  bool completeConfig = false;
  List<List<int>>? configFrames;
  final requests = <List<int>>[];
  List<List<int>> _queuedFrames = [];
  bool _duplicateRequest = false;
  bool securityPrepared = false;
  bool securitySettled = false;
  Completer<void>? pendingSecurity;
  final securing = Completer<void>();
  bool enableSettled = false;
  bool readSettled = false;
  String? failAt;
  Object? enableError;
  bool interruptEnable = true;
  List<int> metadata = _metadata;
  Completer<void>? pendingEnable;
  Completer<List<int>>? pendingRead;
  Completer<void>? cleanupGate;
  final enabling = Completer<void>();
  final reading = Completer<void>();
  final disconnecting = Completer<void>();
  void event(String name) {
    events.add(name);
    if (failAt == name) throw StateError(name);
  }

  @override
  bool get isConnected => connected;
  @override
  Stream<BluetoothBondState>? get bondStates => android ? _bondEvents() : null;
  Stream<BluetoothBondState> _bondEvents() async* {
    yield initialBond;
    yield* bonds.stream;
  }

  @override
  Stream<List<int>> get frames => framesController.stream;
  @override
  bool get hasRequiredCharacteristics => !staleCache && !missingCharacteristics;
  @override
  bool get hasBattery => true;
  @override
  Future<void> connect() async {
    event('connect');
    connected = true;
  }

  @override
  Future<void> refreshGattCache() async {
    event('refresh');
    if (!refreshing.isCompleted) refreshing.complete();
    await pendingRefresh?.future;
    staleCache = false;
  }

  @override
  Future<void> discoverServices() async {
    event('discover');
  }

  @override
  Future<int?> readBattery() async {
    event('battery');
    return 70;
  }

  @override
  Future<void> prepareSecurity() async {
    event('security');
    if (!securing.isCompleted) securing.complete();
    try {
      await pendingSecurity?.future;
      if (emitStaleSecurityMetadata) {
        framesController.add([..._metadata.take(_metadata.length - 1), 106]);
      }
      securityPrepared = true;
    } finally {
      securitySettled = true;
    }
  }

  @override
  Future<void> enableNotifications() async {
    event('enable');
    if (emitMetadataDuringEnable) {
      framesController.add([..._metadata.take(_metadata.length - 1), 106]);
    }
    if (requiresEncryption && !securityPrepared) {
      throw StateError('Encryption is insufficient.');
    }
    if (enableError != null) throw enableError!;
    if (!enabling.isCompleted) enabling.complete();
    try {
      await pendingEnable?.future;
    } finally {
      enableSettled = true;
    }
  }

  @override
  Future<void> requestMetadata(List<int> bytes) async {
    event('request');
    _duplicateRequest =
        dropDuplicateRequests && listEquals(_lastPhysicalRequest, bytes);
    _lastPhysicalRequest = List.of(bytes);
    requests.add(List.of(bytes));
    _queuedFrames = [
      ...?configFrames,
      if (completeConfig) [0x38, ...bytes.skip(1)],
    ];
  }

  @override
  Future<List<int>> readMetadata() async {
    event('read');
    if (!reading.isCompleted) reading.complete();
    try {
      if (_duplicateRequest) return [];
      if (configFrames != null) {
        return _queuedFrames.isEmpty ? [] : _queuedFrames.removeAt(0);
      }
      return pendingRead == null ? metadata : await pendingRead!.future;
    } finally {
      readSettled = true;
    }
  }

  @override
  Future<void> disconnect() async {
    event('disconnect');
    // GAP disconnect resets stock's buffer; releasing only one iOS client
    // need not disconnect the physical link held by another client.
    if (!retainPhysicalLink) _lastPhysicalRequest = null;
    if (!disconnecting.isCompleted) disconnecting.complete();
    if (pendingSecurity?.isCompleted == false) {
      pendingSecurity!.completeError(StateError('disconnected'));
    }
    if (interruptEnable && pendingEnable?.isCompleted == false) {
      pendingEnable!.completeError(StateError('disconnected'));
    }
    if (pendingRead?.isCompleted == false) {
      pendingRead!.completeError(StateError('disconnected'));
    }
    await cleanupGate?.future;
    connected = false;
  }

  @override
  Future<BluetoothBondState?> finishBonding() async {
    events.add('finishBonding');
    if (!finishingBond.isCompleted) finishingBond.complete();
    await bondCleanupGate?.future;
    bonds.add(BluetoothBondState.none);
    return BluetoothBondState.none;
  }
}

List<int> _wireInt(int value) {
  final bytes = <int>[];
  do {
    final next = value & 0x7f;
    value >>= 7;
    bytes.add(next | (value == 0 ? 0 : 0x80));
  } while (value != 0);
  return bytes;
}

List<int> _message(int field, List<int> body) => [
  field << 3 | 2,
  ..._wireInt(body.length),
  ...body,
];
final _myInfo = _message(3, [0x08, ..._wireInt(0x5593756e)]);
List<int> _nodeInfo(int node, List<int> mac) =>
    _message(4, [0x08, ..._wireInt(node), ..._message(2, _message(4, mac))]);
final _ownNodeInfo = _nodeInfo(0x5593756e, [
  0xe9,
  0xb4,
  0x55,
  0x93,
  0x75,
  0x6e,
]);
final _otherNodeInfo = _nodeInfo(0x594b1aa8, [
  0xe9,
  0xb4,
  0x59,
  0x4b,
  0x1a,
  0xa8,
]);

class _UnusedRepository implements DeviceRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
