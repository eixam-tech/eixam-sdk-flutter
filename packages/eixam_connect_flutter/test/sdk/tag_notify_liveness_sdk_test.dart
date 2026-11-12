import 'dart:async';
import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/preferred_ble_device_store.dart';
import 'package:eixam_connect_flutter/src/data/repositories/in_memory_device_repository.dart';
import 'package:eixam_connect_flutter/src/device/ble_debug_registry.dart';
import 'package:eixam_connect_flutter/src/device/ble_device_runtime_provider.dart';
import 'package:eixam_connect_flutter/src/device/eixam_device_runtime_status_packet.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_command.dart';
import 'package:eixam_connect_flutter/src/device/eixam_ble_protocol.dart';
import 'package:eixam_connect_flutter/src/diagnostics/sdk_release_log.dart';
import 'package:eixam_connect_flutter/src/sdk/background_telemetry_platform_adapter.dart';
import 'package:eixam_connect_flutter/src/sdk/eixam_connect_sdk_impl.dart';
import 'package:eixam_connect_flutter/src/sdk/protection_platform_adapter.dart';
import 'package:eixam_connect_flutter/src/sdk/tag_notify_liveness_monitor.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/device/mock_ble_client.dart';
import '../support/fakes/memory_shared_prefs_sdk_store.dart';
import '../support/fakes/sdk_contract_fakes.dart';

/// F12 replay: after an in-app unpair + re-pair the TAG stays connected and
/// accepts writes, but its notifications stop. The real BLE runtime provider,
/// repository and reconnect coordinator run on top of a mock radio.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> releaseLog;

  setUp(() async {
    await BleDebugRegistry.instance.resetForLifecycle();
    releaseLog = <String>[];
    sdkReleaseLogSinkForTesting = releaseLog.add;
  });

  tearDown(() async {
    sdkReleaseLogSinkForTesting = null;
    await BleDebugRegistry.instance.resetForLifecycle();
  });

  List<String> liveness() =>
      releaseLog.where((l) => l.startsWith('TAG_NOTIFY_LIVENESS ')).toList();

  test(
    '(a) notifications stop after a re-pair while writes keep working: '
    'missed x2 -> reconnect through the existing path -> recovered',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.initialize();
      await h.unpairAndRepair();
      await h.settle(const Duration(milliseconds: 300));
      expect(liveness(), contains(_line('ok', 'reply_received', 'pair')));

      // F12: writes still succeed, notifications no longer arrive. A fresh GATT
      // (reconnect) re-registers them.
      h.ble
        ..notificationsDead = true
        ..healOnConnect = true;
      final connectsBefore = h.ble.connects;
      final writesBefore = h.ble.statusWrites;
      final reconnectsBefore = h.repository.reconnects;
      h.resume();

      final recovered = await h.waitFor(
        () => liveness().contains(
          _line('recovered', 'reply_received', 'recovery'),
        ),
      );
      expect(recovered, isTrue, reason: liveness().join('\n'));
      expect(
        liveness(),
        containsAllInOrder(<String>[
          _line('missed', 'no_reply_first', 'resume'),
          _line('missed', 'no_reply_x2', 'resume'),
          _line('missed', 'reconnect_started', 'resume'),
          _line('recovered', 'reply_received', 'recovery'),
        ]),
      );
      expect(h.ble.statusWrites - writesBefore, greaterThanOrEqualTo(3));
      expect(
        liveness().where((l) => l.contains('reconnect_started')),
        hasLength(1),
        reason: 'one forced drop',
      );
      expect(h.ble.disconnects, greaterThanOrEqualTo(1));
      expect(h.ble.connects - connectsBefore, 1, reason: 'existing reconnect');
      expect(h.repository.reconnects - reconnectsBefore, 1);
      final status = await h.sdk.getDeviceStatus();
      expect(status.connected, isTrue);
      expect(status.linkHealth, DeviceLinkHealth.ok);
    },
  );

  test(
    '(b) still no reply after the recovery reconnect -> failed -> '
    'DeviceStatus.linkHealth restartRequired; a later reply clears it',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.initialize();
      await h.settle(const Duration(milliseconds: 300));
      final published = <DeviceLinkHealth>[];
      final sub = h.sdk.watchDeviceStatus().listen(
        (s) => published.add(s.linkHealth),
      );
      addTearDown(sub.cancel);

      final reconnectsBefore = h.repository.reconnects;
      h.ble.notificationsDead = true;
      h.resume();

      final failed = await h.waitFor(
        () => liveness().contains(
          _line('failed', 'no_reply_after_recovery', 'recovery'),
        ),
      );
      expect(failed, isTrue, reason: liveness().join('\n'));
      expect(
        h.repository.reconnects - reconnectsBefore,
        1,
        reason: 'one recovery only',
      );
      final status = await h.sdk.getDeviceStatus();
      expect(status.connected, isTrue);
      expect(status.linkHealth, DeviceLinkHealth.restartRequired);
      await h.settle(const Duration(milliseconds: 50));
      expect(published, contains(DeviceLinkHealth.restartRequired));

      // A later successful check (e.g. on resume) clears it.
      h.ble.notificationsDead = false;
      h.resume();
      expect(
        await h.waitFor(
          () => liveness().contains(
            _line('recovered', 'reply_received', 'resume'),
          ),
        ),
        isTrue,
      );
      expect((await h.sdk.getDeviceStatus()).linkHealth, DeviceLinkHealth.ok);
      expect(h.repository.reconnects - reconnectsBefore, 1);
    },
  );

  test('(c) no check and no reconnect while a pre-SOS/SOS exists; the '
      'deferred check runs once it is over', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.initialize();
    await h.settle(const Duration(milliseconds: 300));

    final reconnectsBefore = h.repository.reconnects;
    h.ble.notificationsDead = true;
    // App-started TAG countdown (pre-SOS on the device).
    await h.provider.deviceSosController.triggerSos();
    expect(
      h.provider.deviceSosController.currentStatus.state,
      DeviceSosState.preConfirm,
    );
    final before = liveness().length;
    h.resume();
    await h.settle(const Duration(milliseconds: 600));

    // Every liveness probe logs a result; during the SOS only skips appear.
    expect(
      liveness().skip(before).where((l) => !l.contains('result=skipped')),
      isEmpty,
      reason: 'no liveness probe during SOS',
    );
    expect(h.ble.disconnects, 0, reason: 'no reconnect during SOS');
    expect(h.repository.reconnects, reconnectsBefore);
    expect(liveness(), contains(_line('skipped', 'sos_active', 'resume')));

    // SOS over: the deferred check runs (and recovers).
    h.provider.deviceSosController.clearPreSosLocally(reason: 'test_end');
    h.ble.healOnConnect = true;
    final recovered = await h.waitFor(
      () =>
          liveness().contains(_line('recovered', 'reply_received', 'recovery')),
    );
    expect(recovered, isTrue, reason: liveness().join('\n'));
    expect(h.repository.reconnects - reconnectsBefore, 1);
  });

  test('after a liveness drop, an SOS that starts meanwhile does not hold '
      'back the reconnect', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.initialize();
    await h.settle(const Duration(milliseconds: 300));
    final reconnectsBefore = h.repository.reconnects;
    h.ble
      ..notificationsDead = true
      ..healOnConnect = true;
    h.resume();
    expect(
      await h.waitFor(
        () => liveness().any((l) => l.contains('reconnect_started')),
      ),
      isTrue,
    );
    // An app SOS countdown starts while the TAG is being reconnected.
    await h.sdk.startPreSos(countdown: const Duration(seconds: 30));
    expect(await h.sdk.getPreSosStatus(), isNotNull);

    expect(
      await h.waitFor(() => h.repository.reconnects > reconnectsBefore),
      isTrue,
      reason: 'the reconnect proceeds during the SOS',
    );
    await h.sdk.cancelPreSos();
  });

  test('(d) a failed write is never a missed reply', () async {
    // Periodic checks only: a resume also starts the coordinator's
    // foreground reconnect campaign, which defers the check.
    final h = _Harness(
      timing: const TagNotifyLivenessTiming(
        replyTimeout: Duration(milliseconds: 100),
        afterConnect: <Duration>[Duration(milliseconds: 50)],
        periodic: Duration(milliseconds: 200),
        deferredRetry: Duration(milliseconds: 50),
      ),
    );
    addTearDown(h.dispose);
    await h.initialize();
    await h.settle(const Duration(milliseconds: 300));

    final reconnectsBefore = h.repository.reconnects;
    h.ble.failWrites = true;
    await h.settle(const Duration(milliseconds: 1000));

    expect(liveness(), contains(_line('skipped', 'write_failed', 'periodic')));
    expect(liveness().where((l) => l.contains('result=missed')), isEmpty);
    expect(h.ble.disconnects, 0);
    expect(h.repository.reconnects, reconnectsBefore);
    expect((await h.sdk.getDeviceStatus()).linkHealth, DeviceLinkHealth.ok);
  });

  test('a TAG that never answered a 0x23 in this session: missed probes '
      'never drop it and never ask for a restart', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    // Notifications dead from the very first connection.
    h.ble.notificationsDead = true;
    await h.initialize();
    await h.settle(const Duration(milliseconds: 300));
    h.resume();
    expect(
      await h.waitFor(
        () => liveness().contains(
          _line('skipped', 'unproven_status_support', 'resume'),
        ),
        timeout: const Duration(seconds: 15),
      ),
      isTrue,
      reason: liveness().join('\n'),
    );
    expect(liveness().where((l) => l.contains('reconnect_started')), isEmpty);
    expect(h.ble.disconnects, 0);
    expect((await h.sdk.getDeviceStatus()).linkHealth, DeviceLinkHealth.ok);
  });

  test(
    'a 0x23 reply from another device never proves this TAG\'s support',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      // This TAG never answers.
      h.ble.notificationsDead = true;
      await h.initialize();
      await h.settle(const Duration(milliseconds: 300));
      final payload = List<int>.of(h.ble.runtimeStatusPayload);
      payload[7] = 0x99;
      payload[8] = 0x99;
      h.foreign.add(
        BleIncomingEvent(
          deviceId: 'another-ble-device',
          type: BleIncomingEventType.deviceRuntimeStatus,
          channel: EixamBleChannel.tel,
          payload: payload,
          payloadHex: '',
          source: DeviceSosTransitionSource.device,
          receivedAt: DateTime.now(),
          deviceRuntimeStatusPacket: EixamDeviceRuntimeStatusPacket.tryParse(
            payload,
          ),
        ),
      );
      await h.settle(const Duration(milliseconds: 50));
      h.resume();
      expect(
        await h.waitFor(
          () => liveness().contains(
            _line('skipped', 'unproven_status_support', 'resume'),
          ),
          timeout: const Duration(seconds: 15),
        ),
        isTrue,
        reason: liveness().join('\n'),
      );
      expect(liveness().where((l) => l.contains('reconnect_started')), isEmpty);
      expect(h.ble.disconnects, 0);
    },
  );

  test('a TAG in its DFU bootloader is never probed', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    h.ble.firmwareVersion = '0.4.3 s140 6.1.1';
    await h.initialize();
    await h.settle(const Duration(milliseconds: 300));
    expect((await h.sdk.getDeviceStatus()).inDfuBootloader, isTrue);
    final before = liveness().length;
    h.resume();
    await h.settle(const Duration(milliseconds: 800));
    final during = liveness().skip(before).toList();
    expect(during, contains(_line('skipped', 'dfu_bootloader', 'resume')));
    expect(during.where((l) => !l.contains('result=skipped')), isEmpty);
  });

  test('L5: the probe never joins another caller\'s pending 0x23', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.initialize();
    await h.settle(const Duration(milliseconds: 300));
    h.ble.notificationsDead = true;
    final before = liveness().length;
    // Another caller's 0x23 is waiting for its reply (5 s timeout).
    final pending = h.sdk.getDeviceRuntimeStatus().then<void>(
      (_) {},
      onError: (Object _) {},
    );
    await pumpEventQueue();
    h.resume();
    await h.settle(const Duration(milliseconds: 1500));

    final during = liveness().skip(before).toList();
    expect(
      during,
      contains(_line('skipped', 'status_request_pending', 'resume')),
    );
    expect(during.where((l) => l.contains('result=missed')), isEmpty);
    await pending;
  });

  test('M4: no check (so no drop) right after a TAG SOS frame', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.initialize();
    await h.settle(const Duration(milliseconds: 300));
    final before = liveness().length;
    // The connected TAG's (node 0x1234) user-deactivated SOS event frame.
    h.ble.emitNotification(
      MockBleClient.demoDeviceId,
      channel: EixamBleChannel.sos,
      payload: const <int>[0xE1, 0x02, 0x34, 0x12, 0x00, 0x00],
    );
    // Let the frame be classified (it may wait on an identity 0x23).
    await h.settle(const Duration(milliseconds: 300));
    h.ble.notificationsDead = true;
    h.resume();
    await h.settle(const Duration(milliseconds: 1500));

    final during = liveness().skip(before).toList();
    expect(during, contains(_line('skipped', 'sos_frame_recent', 'resume')));
    expect(during.where((l) => !l.contains('result=skipped')), isEmpty);
    expect(h.ble.disconnects, 0);
  });

  test('M2: restartRequired is not shown while the native runtime owns BLE, '
      'and the hand-back to Flutter reschedules the checks', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.initialize();
    await h.settle(const Duration(milliseconds: 300));
    h.ble.notificationsDead = true;
    h.resume();
    expect(
      await h.waitFor(() => liveness().any((l) => l.contains('result=failed'))),
      isTrue,
    );
    expect(
      (await h.sdk.getDeviceStatus()).linkHealth,
      DeviceLinkHealth.restartRequired,
    );

    await h.handoff(owner: ProtectionBleOwner.iosPlugin);
    final native = await h.sdk.getDeviceStatus();
    expect(native.connected, isTrue);
    expect(native.linkHealth, DeviceLinkHealth.ok);

    // Ownership returns to Flutter: a fresh check runs and clears the flag.
    h.ble.notificationsDead = false;
    final before = liveness().length;
    h.adapter.snapshot = const ProtectionPlatformSnapshot(
      backgroundCapabilityReady: true,
    );
    await h.repository.reclaimBleOwnershipFromProtectionMode(
      reason: 'test_reclaim',
    );
    await h.sdk.rehydrateProtectionState();
    expect(
      await h.waitFor(
        () =>
            liveness().skip(before).any((l) => l.contains('result=recovered')),
      ),
      isTrue,
      reason: liveness().skip(before).join('\n'),
    );
    expect((await h.sdk.getDeviceStatus()).linkHealth, DeviceLinkHealth.ok);
  });

  for (final owner in [
    ProtectionBleOwner.androidService,
    ProtectionBleOwner.iosPlugin,
  ]) {
    test('(e) native protection owner ($owner) -> no checks', () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.initialize();
      await h.settle(const Duration(milliseconds: 300));
      await h.handoff(owner: owner);
      h.ble.writtenCommands.clear();
      final connectsBefore = h.ble.connects;
      final reconnectsBefore = h.repository.reconnects;
      final before = liveness().length;

      h.resume();
      await h.settle(const Duration(milliseconds: 600));

      // The native owner looks like a disconnect to the monitor: nothing is
      // scheduled, not even a skipped check.
      expect(
        liveness().skip(before).where((l) => !l.contains('result=skipped')),
        isEmpty,
      );
      // Nothing on the Flutter GATT. (The native command channel is the
      // owner's; the monitor never uses it.)
      expect(h.ble.writtenCommands, isEmpty);
      expect(h.ble.connects, connectsBefore);
      expect(h.repository.reconnects, reconnectsBefore);
    });
  }
}

String _line(String result, String reason, String trigger) =>
    'TAG_NOTIFY_LIVENESS result=$result reason=$reason trigger=$trigger';

const _timing = TagNotifyLivenessTiming(
  replyTimeout: Duration(milliseconds: 100),
  afterConnect: <Duration>[Duration(milliseconds: 50)],
  afterResume: Duration(milliseconds: 50),
  periodic: Duration(hours: 1),
  deferredRetry: Duration(milliseconds: 50),
);

class _LivenessBleClient extends MockBleClient {
  /// Writes succeed, notifications are not delivered (F12).
  bool notificationsDead = false;

  /// A new GATT connection re-registers notifications.
  bool healOnConnect = false;
  bool failWrites = false;
  int connects = 0;
  int disconnects = 0;
  int statusWrites = 0;

  @override
  Future<void> connect(String deviceId) {
    connects++;
    if (healOnConnect) notificationsDead = false;
    return super.connect(deviceId);
  }

  @override
  Future<void> disconnect(String deviceId) {
    disconnects++;
    return super.disconnect(deviceId);
  }

  @override
  Future<void> writeDeviceCommand(String deviceId, EixamDeviceCommand command) {
    if (failWrites) {
      throw Exception('GATT write failed');
    }
    if (command.opcode == 0x23) statusWrites++;
    return super.writeDeviceCommand(deviceId, command);
  }

  @override
  void emitNotification(
    String deviceId, {
    required EixamBleChannel channel,
    required List<int> payload,
    int? meshPort,
  }) {
    if (notificationsDead) return;
    super.emitNotification(
      deviceId,
      channel: channel,
      payload: payload,
      meshPort: meshPort,
    );
  }
}

class _Harness {
  _Harness({this.timing = _timing});
  final TagNotifyLivenessTiming timing;

  /// Events of another BLE device injected into the SDK's incoming stream.
  // Closed in dispose.
  // ignore: close_sinks
  final foreign = StreamController<BleIncomingEvent>.broadcast();
  final ble = _LivenessBleClient();
  final adapter = _NativeAdapter();
  late final provider = BleDeviceRuntimeProvider(bleClient: ble);
  late final repository = _CountingRepository(runtimeProvider: provider);
  final store = MemorySharedPrefsSdkStore();
  late final sdk = EixamConnectSdkImpl(
    sosRepository: FakeSosRepository(),
    trackingRepository: FakeTrackingRepository(),
    telemetryRepository: FakeTelemetryRepository(),
    contactsRepository: FakeContactsRepository(),
    deviceRepository: repository,
    deviceRegistryRepository: FakeSdkDeviceRegistryRepository(),
    deathManRepository: FakeDeathManRepository(),
    permissionsRepository: FakePermissionsRepository(
      permissionState: const PermissionState(
        location: SdkPermissionStatus.granted,
        notifications: SdkPermissionStatus.granted,
        bluetooth: SdkPermissionStatus.granted,
        bluetoothEnabled: true,
      ),
    ),
    notificationsRepository: FakeNotificationsRepository(),
    realtimeClient: FakeRealtimeClient(),
    deviceSosController: provider.deviceSosController,
    bleIncomingEvents: _merged(provider.watchIncomingEvents(), foreign.stream),
    preferredBleDeviceStore: PreferredBleDeviceStore(localStore: store),
    localStore: store,
    protectionPlatformAdapter: adapter,
    backgroundTelemetryPlatformAdapter:
        const NoopBackgroundTelemetryPlatformAdapter(),
    tagNotifyLivenessTiming: timing,
  );

  Future<void> initialize() async {
    await ble.initialize();
    await sdk.initialize(
      const EixamSdkConfig(apiBaseUrl: 'https://example.test'),
    );
    await sdk.setSession(
      const EixamSession.signed(
        appId: 'app-demo',
        externalUserId: 'user-demo',
        userHash: 'signed-test',
      ),
    );
    await sdk.pairDevice(pairingCode: MockBleClient.demoDeviceId);
  }

  Future<void> unpairAndRepair() async {
    await sdk.unpairDevice();
    ble.systemAssociationAvailable = true;
    await sdk.pairDevice(pairingCode: MockBleClient.demoDeviceId);
  }

  void resume() {
    sdk.didChangeAppLifecycleState(AppLifecycleState.paused);
    sdk.didChangeAppLifecycleState(AppLifecycleState.resumed);
  }

  Future<void> settle(Duration duration) async {
    await pumpEventQueue();
    await Future<void>.delayed(duration);
    await pumpEventQueue();
  }

  /// The forced drop reconnects through the coordinator's unexpected
  /// disconnect backoff (3-4 s), so allow for it.
  Future<bool> waitFor(
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 45),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (condition()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return condition();
  }

  Future<void> handoff({required ProtectionBleOwner owner}) async {
    adapter.snapshot = ProtectionPlatformSnapshot(
      backgroundCapabilityReady: true,
      serviceRunning: true,
      runtimeActive: true,
      runtimeState: ProtectionRuntimeState.active,
      coverageLevel: ProtectionCoverageLevel.full,
      platform: owner == ProtectionBleOwner.androidService
          ? ProtectionPlatform.android
          : ProtectionPlatform.ios,
      bleOwner: owner,
      serviceBleConnected: true,
      serviceBleReady: true,
      nativeCommandServiceReady: true,
      nativeCommandEa04Ready: true,
      nativeCommandIdentityReady: true,
      nativeCommandQueueHealthy: true,
      nativeCommandReady: true,
      protectedDeviceId: MockBleClient.demoCanonicalHardwareId,
      activeDeviceId: MockBleClient.demoCanonicalHardwareId,
    );
    await repository.releaseBleOwnershipToProtectionMode(
      reason: 'test_native_handoff',
    );
    await sdk.rehydrateProtectionState();
    await pumpEventQueue(times: 10);
  }

  Future<void> dispose() async {
    await foreign.close();
    await sdk.dispose();
    await repository.dispose();
    await provider.dispose();
    await ble.dispose();
  }
}

class _CountingRepository extends InMemoryDeviceRepository {
  _CountingRepository({required super.runtimeProvider});
  int reconnects = 0;

  @override
  Future<DeviceStatus> reconnectDevice({
    required PreferredDevice device,
    String? attemptId,
    bool Function()? canCreateGatt,
  }) {
    reconnects++;
    return super.reconnectDevice(
      device: device,
      attemptId: attemptId,
      canCreateGatt: canCreateGatt,
    );
  }
}

class _NativeAdapter extends NoopProtectionPlatformAdapter {
  ProtectionPlatformSnapshot snapshot = const ProtectionPlatformSnapshot(
    backgroundCapabilityReady: false,
  );
  final commands = <ProtectionPlatformCommandRequest>[];

  @override
  ProtectionPlatform get platform => snapshot.platform;
  @override
  Future<ProtectionPlatformSnapshot> getPlatformSnapshot() async => snapshot;
  @override
  Future<ProtectionPlatformCommandResult> sendProtectionCommand({
    required ProtectionPlatformCommandRequest request,
  }) async {
    commands.add(request);
    return const ProtectionPlatformCommandResult(
      success: true,
      route: 'native',
    );
  }
}

Stream<BleIncomingEvent> _merged(
  Stream<BleIncomingEvent> a,
  Stream<BleIncomingEvent> b,
) {
  // Closed when the last listener cancels.
  // ignore: close_sinks
  late final StreamController<BleIncomingEvent> controller;
  final subscriptions = <StreamSubscription<BleIncomingEvent>>[];
  controller = StreamController<BleIncomingEvent>.broadcast(
    onListen: () {
      subscriptions
        ..add(a.listen(controller.add))
        ..add(b.listen(controller.add));
    },
    onCancel: () async {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      subscriptions.clear();
    },
  );
  return controller.stream;
}
