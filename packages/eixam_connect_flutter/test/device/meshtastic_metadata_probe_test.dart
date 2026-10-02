import 'dart:async';

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
      'discover',
      'battery',
      'enable',
      'request',
      'read',
      'disconnect',
    ]);
    expect(t.framesController.hasListener, false);
    expect(t.bonds.hasListener, false);
    expect(t.isConnected, false);
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

  for (final stage in ['connect', 'discover', 'enable', 'request']) {
    test('$stage failure retains stage and performs cleanup', () async {
      final t = _Transport()..failAt = stage;
      final f = switch (stage) {
        'connect' => DeviceMigrationInspectionFailure.connectionFailed,
        'discover' => DeviceMigrationInspectionFailure.serviceDiscoveryFailed,
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
  BluetoothBondState initialBond = BluetoothBondState.none;
  Completer<void>? bondCleanupGate;
  final finishingBond = Completer<void>();
  bool android = true;
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
  bool get hasRequiredCharacteristics => true;
  @override
  bool get hasBattery => true;
  @override
  Future<void> connect() async {
    event('connect');
    connected = true;
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
  Future<void> enableNotifications() async {
    event('enable');
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
  }

  @override
  Future<List<int>> readMetadata() async {
    event('read');
    if (!reading.isCompleted) reading.complete();
    try {
      return pendingRead == null ? metadata : await pendingRead!.future;
    } finally {
      readSettled = true;
    }
  }

  @override
  Future<void> disconnect() async {
    event('disconnect');
    if (!disconnecting.isCompleted) disconnecting.complete();
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

class _UnusedRepository implements DeviceRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
