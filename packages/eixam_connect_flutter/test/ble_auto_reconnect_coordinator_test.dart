import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/preferred_ble_device_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/shared_prefs_sdk_store.dart';
import 'package:eixam_connect_flutter/src/device/ble_debug_registry.dart';
import 'package:eixam_connect_flutter/src/device/known_device_reconnect_repository.dart';
import 'package:eixam_connect_flutter/src/device/preferred_ble_device.dart';
import 'package:eixam_connect_flutter/src/sdk/ble_auto_reconnect_coordinator.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('BleAutoReconnectCoordinator', () {
    test('Android foreground unexpected disconnect waits three seconds',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      BleDebugRegistry.instance.reset();
      final repository = _FakeDeviceRepository();
      final store = PreferredBleDeviceStore(localStore: SharedPrefsSdkStore());
      Duration? scheduledDelay;
      final coordinator = BleAutoReconnectCoordinator(
        deviceRepository: repository,
        preferredDeviceStore: store,
        isIosPlatform: () => false,
        retryTimerFactory: (delay, callback) {
          scheduledDelay = delay;
          return Timer(const Duration(days: 1), callback);
        },
      );
      await coordinator.initialize(
        initialStatus: await repository.getDeviceStatus(),
        deviceStatusStream: repository.watchDeviceStatus(),
      );

      coordinator.onUnexpectedDisconnect();

      expect(scheduledDelay, const Duration(seconds: 3));
      expect(
        BleDebugRegistry.instance.currentState.events
            .map((event) => event.message),
        contains('Reconnect scheduled in 3s'),
      );
      await coordinator.dispose();
    });

    test('tries startup auto-connect when a preferred device exists', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      BleDebugRegistry.instance.reset();
      final repository = _FakeDeviceRepository();
      final store = PreferredBleDeviceStore(localStore: SharedPrefsSdkStore());
      await store.savePreferredDevice(
        PreferredBleDevice(
          deviceId: 'ble-demo-r1',
          displayName: 'EIXAM Demo',
          lastConnectedAt: DateTime.parse('2026-03-23T10:00:00Z'),
        ),
      );
      final coordinator = BleAutoReconnectCoordinator(
        deviceRepository: repository,
        preferredDeviceStore: store,
      );

      await coordinator.initialize(
        initialStatus: await repository.getDeviceStatus(),
        deviceStatusStream: repository.watchDeviceStatus(),
      );
      await coordinator.tryAutoConnectOnStartup();

      expect(repository.reconnectCallCount, 1);
      expect(repository.pairCallCount, 0);
      expect(
        BleDebugRegistry.instance.currentState.selectedDeviceId,
        'ble-demo-r1',
      );
      await coordinator.dispose();
    });

    test('handoff reconnect uses known-device reconnect path', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      BleDebugRegistry.instance.reset();
      final repository = _FakeDeviceRepository();
      final store = PreferredBleDeviceStore(localStore: SharedPrefsSdkStore());
      await store.savePreferredDevice(
        PreferredBleDevice(
          deviceId: 'ble-demo-r1',
          displayName: 'EIXAM Demo',
          lastConnectedAt: DateTime.parse('2026-03-23T10:00:00Z'),
        ),
      );
      final coordinator = BleAutoReconnectCoordinator(
        deviceRepository: repository,
        preferredDeviceStore: store,
      );

      await coordinator.initialize(
        initialStatus: await repository.getDeviceStatus(),
        deviceStatusStream: repository.watchDeviceStatus(),
      );
      final result = await coordinator.tryAutoConnectForHandoff(
        trigger: 'startup',
        attemptId: 'attempt-1',
      );

      expect(result.status, PreferredDeviceReconnectResultStatus.connected);
      expect(repository.reconnectCallCount, 1);
      expect(repository.pairCallCount, 0);
      expect(repository.lastReconnectedDeviceId, 'ble-demo-r1');
      expect(repository.lastReconnectAttemptId, 'attempt-1');
      await coordinator.dispose();
    });

    test(
        'DFU suppression blocks every reconnect trigger until resumed '
        '(foreground bounces must not defeat it)', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      BleDebugRegistry.instance.reset();
      final repository = _FakeDeviceRepository();
      final store = PreferredBleDeviceStore(localStore: SharedPrefsSdkStore());
      await store.savePreferredDevice(
        PreferredBleDevice(
          deviceId: 'ble-demo-r1',
          displayName: 'EIXAM Demo',
          lastConnectedAt: DateTime.parse('2026-03-23T10:00:00Z'),
        ),
      );
      final coordinator = BleAutoReconnectCoordinator(
        deviceRepository: repository,
        preferredDeviceStore: store,
      );
      await coordinator.initialize(
        initialStatus: await repository.getDeviceStatus(),
        deviceStatusStream: repository.watchDeviceStatus(),
      );

      await coordinator.suspendForDfuTransfer(reason: 'firmware_dfu_transfer');

      // A lifecycle bounce mid-DFU (bonding dialog / notification shade):
      // background then foreground. On resume the foreground path fires a
      // reconnect — the suppression must swallow it.
      coordinator.setAppForeground(false);
      coordinator.setAppForeground(true);
      await coordinator.tryAutoConnectOnResume();
      // App-level handoff reconnect (uses the foreground-exempt 'startup'
      // trigger) must be blocked too.
      final handoff = await coordinator.tryAutoConnectForHandoff(
        trigger: 'startup',
        attemptId: 'attempt-dfu',
      );
      // Device-stream disconnect (the device rebooting into the bootloader).
      coordinator.onUnexpectedDisconnect();
      // Give any wrongly-scheduled retry a chance to fire.
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(handoff.status, PreferredDeviceReconnectResultStatus.failed);
      expect(handoff.reason, 'dfu_transfer_in_progress');
      expect(repository.reconnectCallCount, 0);
      expect(repository.pairCallCount, 0);

      // Once the transfer window closes, reconnects work again.
      coordinator.resumeAfterDfuTransfer(reason: 'firmware_dfu_complete');
      final afterResume = await coordinator.tryAutoConnectForHandoff(
        trigger: 'startup',
        attemptId: 'attempt-post-dfu',
      );
      expect(
        afterResume.status,
        PreferredDeviceReconnectResultStatus.connected,
      );
      expect(repository.reconnectCallCount, 1);
      await coordinator.dispose();
    });

    test(
        'provisioning ownership suppresses generic triggers but allows its '
        'explicit reconnect', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      BleDebugRegistry.instance.reset();
      final readiness = StreamController<PermissionState>.broadcast();
      final repository = _FakeDeviceRepository();
      final store = PreferredBleDeviceStore(localStore: SharedPrefsSdkStore());
      await store.savePreferredDevice(
        PreferredBleDevice(
          deviceId: 'ble-demo-r1',
          displayName: 'EIXAM Demo',
          lastConnectedAt: DateTime.parse('2026-03-23T10:00:00Z'),
        ),
      );
      final coordinator = BleAutoReconnectCoordinator(
        deviceRepository: repository,
        preferredDeviceStore: store,
      );
      await coordinator.initialize(
        initialStatus: await repository.getDeviceStatus(),
        deviceStatusStream: repository.watchDeviceStatus(),
      );
      await coordinator.startBleReadinessReconnectMonitor(
        readinessStream: readiness.stream,
      );
      readiness.add(
        const PermissionState(
          bluetooth: SdkPermissionStatus.granted,
          bluetoothEnabled: false,
        ),
      );
      await _settleReconnectMonitor();

      await coordinator.acquireProvisioningReconnectOwnership();
      coordinator.setAppForeground(false);
      coordinator.setAppForeground(true);
      await coordinator.tryAutoConnectOnStartup();
      await coordinator.tryAutoConnectOnResume();
      coordinator.onUnexpectedDisconnect();
      readiness.add(
        const PermissionState(
          bluetooth: SdkPermissionStatus.granted,
          bluetoothEnabled: true,
        ),
      );
      await _settleReconnectMonitor();

      expect(repository.reconnectCallCount, 0);
      expect(
        BleDebugRegistry.instance.currentState.events
            .map((event) => event.message),
        contains('PROVISIONING_REBOOT generic_reconnect_suppressed=true'),
      );
      final explicit = await coordinator.reconnectForProvisioningReboot(
        platformRemoteId: 'ble-demo-r1',
      );
      expect(explicit.connected, isTrue);
      expect(repository.reconnectCallCount, 1);

      coordinator.releaseProvisioningReconnectOwnership();
      repository.setDisconnected();
      await coordinator.tryAutoConnectOnStartup();
      expect(repository.reconnectCallCount, 2);
      await readiness.close();
      await coordinator.dispose();
    });

    test('provisioning ownership cancels and settles an existing campaign',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      BleDebugRegistry.instance.reset();
      final repository = _FakeDeviceRepository()
        ..pairErrors = <Object>[
          const DeviceException(
            'E_BLE_DEVICE_NOT_FOUND',
            'Preferred device was not found.',
          ),
        ];
      final store = PreferredBleDeviceStore(localStore: SharedPrefsSdkStore());
      await store.savePreferredDevice(
        PreferredBleDevice(
          deviceId: 'ble-demo-r1',
          displayName: 'EIXAM Demo',
          lastConnectedAt: DateTime.parse('2026-03-23T10:00:00Z'),
        ),
      );
      final delayStarted = Completer<void>();
      final coordinator = BleAutoReconnectCoordinator(
        deviceRepository: repository,
        preferredDeviceStore: store,
        preferredReconnectDelay: (_) {
          if (!delayStarted.isCompleted) delayStarted.complete();
          return Completer<void>().future;
        },
      );
      await coordinator.initialize(
        initialStatus: await repository.getDeviceStatus(),
        deviceStatusStream: repository.watchDeviceStatus(),
      );

      final campaign = coordinator.tryAutoConnectOnStartup();
      await delayStarted.future;
      await coordinator.acquireProvisioningReconnectOwnership();
      await campaign;

      expect(repository.reconnectCallCount, 1);
      expect(
        BleDebugRegistry.instance.currentState.events
            .map((event) => event.message),
        contains(
          'BLE_PREFERRED_RECONNECT_CAMPAIGN_CANCELLED '
          'reason=provisioning_reboot',
        ),
      );
      coordinator.releaseProvisioningReconnectOwnership();
      await coordinator.dispose();
    });

    test(
      'handoff reconnect returns bluetoothOff when BLE is not ready',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        BleDebugRegistry.instance.reset();
        final repository = _FakeDeviceRepository();
        final store = PreferredBleDeviceStore(
          localStore: SharedPrefsSdkStore(),
        );
        await store.savePreferredDevice(
          PreferredBleDevice(
            deviceId: 'ble-demo-r1',
            displayName: 'EIXAM Demo',
            lastConnectedAt: DateTime.parse('2026-03-23T10:00:00Z'),
          ),
        );
        final coordinator = BleAutoReconnectCoordinator(
          deviceRepository: repository,
          preferredDeviceStore: store,
          permissionStateProvider: () async => const PermissionState(
            bluetooth: SdkPermissionStatus.granted,
            bluetoothEnabled: false,
          ),
        );

        await coordinator.initialize(
          initialStatus: await repository.getDeviceStatus(),
          deviceStatusStream: repository.watchDeviceStatus(),
        );
        final result = await coordinator.tryAutoConnectForHandoff(
          trigger: 'startup',
          attemptId: 'attempt-1',
        );

        expect(
          result.status,
          PreferredDeviceReconnectResultStatus.bluetoothOff,
        );
        expect(repository.reconnectCallCount, 0);
        expect(
          BleDebugRegistry.instance.currentState.events.map(
            (event) => event.message,
          ),
          contains('BLE_READINESS_BLOCKED bluetoothOff'),
        );
        await coordinator.dispose();
      },
    );

    test(
      'iOS handoff retries early unknown readiness when it becomes ready',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        BleDebugRegistry.instance.reset();
        final repository = _FakeDeviceRepository();
        final store = PreferredBleDeviceStore(
          localStore: SharedPrefsSdkStore(),
        );
        await store.savePreferredDevice(
          PreferredBleDevice(
            deviceId: '11111111-1111-1111-1111-111111111111',
            displayName: 'EIXAM Demo',
            lastConnectedAt: DateTime.parse('2026-03-23T10:00:00Z'),
          ),
        );
        var readinessReadCount = 0;
        final retryDelays = <Duration>[];
        final coordinator = BleAutoReconnectCoordinator(
          deviceRepository: repository,
          preferredDeviceStore: store,
          isIosPlatform: () => true,
          permissionStateProvider: () async {
            readinessReadCount++;
            if (readinessReadCount == 1) {
              return const PermissionState(
                bluetooth: SdkPermissionStatus.unknown,
                bluetoothEnabled: false,
              );
            }
            return const PermissionState(
              bluetooth: SdkPermissionStatus.granted,
              bluetoothEnabled: true,
            );
          },
          preferredReconnectDelay: (delay) async {
            retryDelays.add(delay);
          },
        );

        await coordinator.initialize(
          initialStatus: await repository.getDeviceStatus(),
          deviceStatusStream: repository.watchDeviceStatus(),
        );
        final result = await coordinator.tryAutoConnectForHandoff(
          trigger: 'startup',
          attemptId: 'attempt-1',
        );

        expect(result.status, PreferredDeviceReconnectResultStatus.connected);
        expect(repository.reconnectCallCount, 1);
        expect(readinessReadCount, 2);
        expect(retryDelays, <Duration>[const Duration(seconds: 1)]);
        expect(
          BleDebugRegistry.instance.currentState.events.map(
            (event) => event.message,
          ),
          containsAll(<String>[
            'BLE_READINESS_PENDING_IOS reason=adapter_state_warmup',
            'EIXAM_RECONNECT_TRACE sdk_campaign_attempt_result '
                'attemptNumber=1 result=bluetoothOff '
                'reason=ios_readiness_warmup_retry retryable=true',
          ]),
        );
        await coordinator.dispose();
      },
    );

    test(
      'handoff reconnect returns permissionMissing without provider call',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        BleDebugRegistry.instance.reset();
        final repository = _FakeDeviceRepository();
        final store = PreferredBleDeviceStore(
          localStore: SharedPrefsSdkStore(),
        );
        await store.savePreferredDevice(
          PreferredBleDevice(
            deviceId: 'ble-demo-r1',
            displayName: 'EIXAM Demo',
            lastConnectedAt: DateTime.parse('2026-03-23T10:00:00Z'),
          ),
        );
        final coordinator = BleAutoReconnectCoordinator(
          deviceRepository: repository,
          preferredDeviceStore: store,
          permissionStateProvider: () async => const PermissionState(
            bluetooth: SdkPermissionStatus.denied,
            bluetoothEnabled: true,
          ),
        );

        await coordinator.initialize(
          initialStatus: await repository.getDeviceStatus(),
          deviceStatusStream: repository.watchDeviceStatus(),
        );
        final result = await coordinator.tryAutoConnectForHandoff(
          trigger: 'startup',
          attemptId: 'attempt-1',
        );

        expect(
          result.status,
          PreferredDeviceReconnectResultStatus.permissionMissing,
        );
        expect(repository.reconnectCallCount, 0);
        expect(
          BleDebugRegistry.instance.currentState.events.map(
            (event) => event.message,
          ),
          contains('BLE_READINESS_BLOCKED permissionMissing'),
        );
        await coordinator.dispose();
      },
    );

    test(
      'handoff reconnect returns noKnownDevice without scanning loop',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        BleDebugRegistry.instance.reset();
        final repository = _FakeDeviceRepository();
        final store = PreferredBleDeviceStore(
          localStore: SharedPrefsSdkStore(),
        );
        final coordinator = BleAutoReconnectCoordinator(
          deviceRepository: repository,
          preferredDeviceStore: store,
        );

        await coordinator.initialize(
          initialStatus: await repository.getDeviceStatus(),
          deviceStatusStream: repository.watchDeviceStatus(),
        );
        final result = await coordinator.tryAutoConnectForHandoff(
          trigger: 'startup',
          attemptId: 'attempt-1',
        );

        expect(
          result.status,
          PreferredDeviceReconnectResultStatus.noKnownDevice,
        );
        expect(repository.reconnectCallCount, 0);
        expect(repository.pairCallCount, 0);
        await coordinator.dispose();
      },
    );

    test('BLE-ready transition starts preferred reconnect campaign', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      BleDebugRegistry.instance.reset();
      final readiness = StreamController<PermissionState>.broadcast();
      final repository = _FakeDeviceRepository();
      final store = PreferredBleDeviceStore(localStore: SharedPrefsSdkStore());
      await store.savePreferredDevice(
        PreferredBleDevice(
          deviceId: 'ble-demo-r1',
          displayName: 'EIXAM Demo',
          lastConnectedAt: DateTime.parse('2026-03-23T10:00:00Z'),
        ),
      );
      final coordinator = BleAutoReconnectCoordinator(
        deviceRepository: repository,
        preferredDeviceStore: store,
        preferredReconnectDelay: (_) async {},
      );

      await coordinator.initialize(
        initialStatus: await repository.getDeviceStatus(),
        deviceStatusStream: repository.watchDeviceStatus(),
      );
      await coordinator.startBleReadinessReconnectMonitor(
        readinessStream: readiness.stream,
      );
      readiness.add(
        const PermissionState(
          bluetooth: SdkPermissionStatus.granted,
          bluetoothEnabled: false,
        ),
      );
      await _settleReconnectMonitor();
      readiness.add(
        const PermissionState(
          bluetooth: SdkPermissionStatus.granted,
          bluetoothEnabled: true,
        ),
      );
      await _settleReconnectMonitor();

      expect(repository.reconnectCallCount, 1);
      expect(
        BleDebugRegistry.instance.currentState.events.map(
          (event) => event.message,
        ),
        containsAll(<String>[
          'EIXAM_RECONNECT_TRACE sdk_ble_readiness_changed previousReadiness=notReady currentReadiness=ready hasPermission=true bluetoothReady=true',
          'EIXAM_RECONNECT_TRACE sdk_ble_ready_reconnect_trigger source=ble_ready',
        ]),
      );
      await readiness.close();
      await coordinator.dispose();
    });

    test('BLE-ready transition skips when already connected', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      BleDebugRegistry.instance.reset();
      final readiness = StreamController<PermissionState>.broadcast();
      final repository = _FakeDeviceRepository()
        ..setConnected(commandCapable: true);
      final store = PreferredBleDeviceStore(localStore: SharedPrefsSdkStore());
      await store.savePreferredDevice(
        PreferredBleDevice(
          deviceId: 'ble-demo-r1',
          displayName: 'EIXAM Demo',
          lastConnectedAt: DateTime.parse('2026-03-23T10:00:00Z'),
        ),
      );
      final coordinator = BleAutoReconnectCoordinator(
        deviceRepository: repository,
        preferredDeviceStore: store,
      );

      await coordinator.initialize(
        initialStatus: await repository.getDeviceStatus(),
        deviceStatusStream: repository.watchDeviceStatus(),
      );
      await coordinator.startBleReadinessReconnectMonitor(
        readinessStream: readiness.stream,
      );
      readiness.add(
        const PermissionState(
          bluetooth: SdkPermissionStatus.granted,
          bluetoothEnabled: false,
        ),
      );
      await _settleReconnectMonitor();
      readiness.add(
        const PermissionState(
          bluetooth: SdkPermissionStatus.granted,
          bluetoothEnabled: true,
        ),
      );
      await _settleReconnectMonitor();

      expect(repository.reconnectCallCount, 0);
      expect(
        BleDebugRegistry.instance.currentState.events.map(
          (event) => event.message,
        ),
        contains(
          'EIXAM_RECONNECT_TRACE sdk_ble_ready_reconnect_skipped reason=already_connected',
        ),
      );
      await readiness.close();
      await coordinator.dispose();
    });

    test('BLE-ready transition skips without preferred device', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      BleDebugRegistry.instance.reset();
      final readiness = StreamController<PermissionState>.broadcast();
      final repository = _FakeDeviceRepository();
      final store = PreferredBleDeviceStore(localStore: SharedPrefsSdkStore());
      final coordinator = BleAutoReconnectCoordinator(
        deviceRepository: repository,
        preferredDeviceStore: store,
      );

      await coordinator.initialize(
        initialStatus: await repository.getDeviceStatus(),
        deviceStatusStream: repository.watchDeviceStatus(),
      );
      await coordinator.startBleReadinessReconnectMonitor(
        readinessStream: readiness.stream,
      );
      readiness.add(
        const PermissionState(
          bluetooth: SdkPermissionStatus.granted,
          bluetoothEnabled: false,
        ),
      );
      await _settleReconnectMonitor();
      readiness.add(
        const PermissionState(
          bluetooth: SdkPermissionStatus.granted,
          bluetoothEnabled: true,
        ),
      );
      await _settleReconnectMonitor();

      expect(repository.reconnectCallCount, 0);
      expect(
        BleDebugRegistry.instance.currentState.events.map(
          (event) => event.message,
        ),
        contains(
          'EIXAM_RECONNECT_TRACE sdk_ble_ready_reconnect_skipped reason=no_preferred_device',
        ),
      );
      await readiness.close();
      await coordinator.dispose();
    });

    test('BLE-ready transition shares in-flight guard with startup', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      BleDebugRegistry.instance.reset();
      final readiness = StreamController<PermissionState>.broadcast();
      final repository = _FakeDeviceRepository()
        ..reconnectDelay = const Duration(milliseconds: 40);
      final store = PreferredBleDeviceStore(localStore: SharedPrefsSdkStore());
      await store.savePreferredDevice(
        PreferredBleDevice(
          deviceId: 'ble-demo-r1',
          displayName: 'EIXAM Demo',
          lastConnectedAt: DateTime.parse('2026-03-23T10:00:00Z'),
        ),
      );
      final coordinator = BleAutoReconnectCoordinator(
        deviceRepository: repository,
        preferredDeviceStore: store,
      );

      await coordinator.initialize(
        initialStatus: await repository.getDeviceStatus(),
        deviceStatusStream: repository.watchDeviceStatus(),
      );
      await coordinator.startBleReadinessReconnectMonitor(
        readinessStream: readiness.stream,
      );
      final startup = coordinator.tryAutoConnectForHandoff(trigger: 'startup');
      await Future<void>.delayed(const Duration(milliseconds: 1));
      readiness.add(
        const PermissionState(
          bluetooth: SdkPermissionStatus.granted,
          bluetoothEnabled: true,
        ),
      );
      await startup;
      await _settleReconnectMonitor();

      expect(repository.reconnectCallCount, 1);
      expect(
        BleDebugRegistry.instance.currentState.events.map(
          (event) => event.message,
        ),
        contains(
          'EIXAM_RECONNECT_TRACE sdk_ble_ready_reconnect_skipped reason=inflight',
        ),
      );
      await readiness.close();
      await coordinator.dispose();
    });

    test('BLE-ready transition can re-arm after exhausted campaign', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      BleDebugRegistry.instance.reset();
      final readiness = StreamController<PermissionState>.broadcast();
      final repository = _FakeDeviceRepository()
        ..pairErrors = List<Object>.generate(
          10,
          (_) => PlatformException(
            code: 'deviceDisconnected',
            message: 'deviceDisconnected',
          ),
        );
      final store = PreferredBleDeviceStore(localStore: SharedPrefsSdkStore());
      await store.savePreferredDevice(
        PreferredBleDevice(
          deviceId: 'ble-demo-r1',
          displayName: 'EIXAM Demo',
          lastConnectedAt: DateTime.parse('2026-03-23T10:00:00Z'),
        ),
      );
      final coordinator = BleAutoReconnectCoordinator(
        deviceRepository: repository,
        preferredDeviceStore: store,
        preferredReconnectDelay: (_) async {},
      );

      await coordinator.initialize(
        initialStatus: await repository.getDeviceStatus(),
        deviceStatusStream: repository.watchDeviceStatus(),
      );
      await coordinator.startBleReadinessReconnectMonitor(
        readinessStream: readiness.stream,
      );
      readiness.add(
        const PermissionState(
          bluetooth: SdkPermissionStatus.granted,
          bluetoothEnabled: false,
        ),
      );
      await _settleReconnectMonitor();
      readiness.add(
        const PermissionState(
          bluetooth: SdkPermissionStatus.granted,
          bluetoothEnabled: true,
        ),
      );
      await _settleReconnectMonitor();

      expect(repository.reconnectCallCount, 10);
      readiness.add(
        const PermissionState(
          bluetooth: SdkPermissionStatus.granted,
          bluetoothEnabled: false,
        ),
      );
      await _settleReconnectMonitor();
      readiness.add(
        const PermissionState(
          bluetooth: SdkPermissionStatus.granted,
          bluetoothEnabled: true,
        ),
      );
      await _settleReconnectMonitor();

      expect(repository.reconnectCallCount, 11);
      await readiness.close();
      await coordinator.dispose();
    });

    test('handoff reconnect is single-flight', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      BleDebugRegistry.instance.reset();
      final repository = _FakeDeviceRepository()
        ..reconnectDelay = const Duration(milliseconds: 20);
      final store = PreferredBleDeviceStore(localStore: SharedPrefsSdkStore());
      await store.savePreferredDevice(
        PreferredBleDevice(
          deviceId: 'ble-demo-r1',
          displayName: 'EIXAM Demo',
          lastConnectedAt: DateTime.parse('2026-03-23T10:00:00Z'),
        ),
      );
      final coordinator = BleAutoReconnectCoordinator(
        deviceRepository: repository,
        preferredDeviceStore: store,
      );

      await coordinator.initialize(
        initialStatus: await repository.getDeviceStatus(),
        deviceStatusStream: repository.watchDeviceStatus(),
      );
      final first = coordinator.tryAutoConnectForHandoff(
        trigger: 'startup',
        attemptId: 'attempt-1',
      );
      final second = await coordinator.tryAutoConnectForHandoff(
        trigger: 'startup',
        attemptId: 'attempt-2',
      );

      expect(second.status, PreferredDeviceReconnectResultStatus.reconnecting);
      expect(
        (await first).status,
        PreferredDeviceReconnectResultStatus.connected,
      );
      expect(repository.reconnectCallCount, 1);
      await coordinator.dispose();
    });

    test('preferred reconnect exhausts after ten failed attempts', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      BleDebugRegistry.instance.reset();
      final repository = _FakeDeviceRepository()
        ..pairErrors = List<Object>.filled(
          10,
          const DeviceException(
            'E_BLE_DEVICE_NOT_FOUND',
            'Preferred device was not found.',
          ),
        );
      final store = PreferredBleDeviceStore(localStore: SharedPrefsSdkStore());
      await store.savePreferredDevice(
        PreferredBleDevice(
          deviceId: 'ble-demo-r1',
          displayName: 'EIXAM Demo',
          lastConnectedAt: DateTime.parse('2026-03-23T10:00:00Z'),
        ),
      );
      final retryDelays = <Duration>[];
      final coordinator = BleAutoReconnectCoordinator(
        deviceRepository: repository,
        preferredDeviceStore: store,
        preferredReconnectDelay: (delay) async {
          retryDelays.add(delay);
        },
      );

      await coordinator.initialize(
        initialStatus: await repository.getDeviceStatus(),
        deviceStatusStream: repository.watchDeviceStatus(),
      );
      final result = await coordinator.tryAutoConnectForHandoff(
        trigger: 'startup',
        attemptId: 'attempt-1',
      );

      expect(result.status, PreferredDeviceReconnectResultStatus.exhausted);
      expect(repository.reconnectCallCount, 10);
      expect(retryDelays, hasLength(9));
      expect(
        BleDebugRegistry.instance.currentState.events.map(
          (event) => event.message,
        ),
        contains(
          'BLE_PREFERRED_RECONNECT_CAMPAIGN_EXHAUSTED '
          'trigger=startup attempts=10 lastResult=reconnecting',
        ),
      );
      await coordinator.dispose();
    });

    test('preferred reconnect remains in flight between attempts', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      BleDebugRegistry.instance.reset();
      final repository = _FakeDeviceRepository()
        ..pairErrors = <Object>[
          const DeviceException(
            'E_BLE_DEVICE_NOT_FOUND',
            'Preferred device was not found.',
          ),
        ];
      final store = PreferredBleDeviceStore(localStore: SharedPrefsSdkStore());
      await store.savePreferredDevice(
        PreferredBleDevice(
          deviceId: 'ble-demo-r1',
          displayName: 'EIXAM Demo',
          lastConnectedAt: DateTime.parse('2026-03-23T10:00:00Z'),
        ),
      );
      final delayStarted = Completer<Duration>();
      final delayCompleter = Completer<void>();
      final coordinator = BleAutoReconnectCoordinator(
        deviceRepository: repository,
        preferredDeviceStore: store,
        preferredReconnectDelay: (delay) {
          if (!delayStarted.isCompleted) {
            delayStarted.complete(delay);
          }
          return delayCompleter.future;
        },
      );

      await coordinator.initialize(
        initialStatus: await repository.getDeviceStatus(),
        deviceStatusStream: repository.watchDeviceStatus(),
      );
      final first = coordinator.tryAutoConnectForHandoff(
        trigger: 'startup',
        attemptId: 'attempt-1',
      );
      expect(await delayStarted.future, const Duration(seconds: 1));

      final duplicate = await coordinator.tryAutoConnectForHandoff(
        trigger: 'startup',
        attemptId: 'attempt-2',
      );
      expect(
        duplicate.status,
        PreferredDeviceReconnectResultStatus.reconnecting,
      );
      expect(duplicate.reason, 'inflight');
      expect(repository.reconnectCallCount, 1);

      delayCompleter.complete();
      expect(
        (await first).status,
        PreferredDeviceReconnectResultStatus.connected,
      );
      expect(repository.reconnectCallCount, 2);
      await coordinator.dispose();
    });

    test(
      'preferred reconnect treats attempt bluetoothOff as retryable after ready preflight',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        BleDebugRegistry.instance.reset();
        final repository = _FakeDeviceRepository()
          ..pairErrors = <Object>[
            const DeviceException(
              'E_DEVICE_BLUETOOTH_OFF',
              'Adapter was not ready for this attempt.',
            ),
          ];
        final store = PreferredBleDeviceStore(
          localStore: SharedPrefsSdkStore(),
        );
        await store.savePreferredDevice(
          PreferredBleDevice(
            deviceId: 'ble-demo-r1',
            displayName: 'EIXAM Demo',
            lastConnectedAt: DateTime.parse('2026-03-23T10:00:00Z'),
          ),
        );
        final delayStarted = Completer<Duration>();
        final delayCompleter = Completer<void>();
        final coordinator = BleAutoReconnectCoordinator(
          deviceRepository: repository,
          preferredDeviceStore: store,
          permissionStateProvider: () async => const PermissionState(
            bluetooth: SdkPermissionStatus.granted,
            bluetoothEnabled: true,
          ),
          preferredReconnectDelay: (delay) {
            if (!delayStarted.isCompleted) {
              delayStarted.complete(delay);
            }
            return delayCompleter.future;
          },
        );

        await coordinator.initialize(
          initialStatus: await repository.getDeviceStatus(),
          deviceStatusStream: repository.watchDeviceStatus(),
        );
        final first = coordinator.tryAutoConnectForHandoff(
          trigger: 'startup',
          attemptId: 'attempt-1',
        );
        expect(await delayStarted.future, const Duration(seconds: 1));
        expect(repository.reconnectCallCount, 1);
        expect(
          BleDebugRegistry.instance.currentState.events.map(
            (event) => event.message,
          ),
          contains(
            'EIXAM_RECONNECT_TRACE sdk_campaign_attempt_result '
            'attemptNumber=1 result=bluetoothOff '
            'reason=attempt_bluetooth_off_transient_retry retryable=true',
          ),
        );

        final duplicate = await coordinator.tryAutoConnectForHandoff(
          trigger: 'startup',
          attemptId: 'attempt-2',
        );
        expect(
          duplicate.status,
          PreferredDeviceReconnectResultStatus.reconnecting,
        );
        expect(duplicate.reason, 'inflight');

        delayCompleter.complete();
        expect(
          (await first).status,
          PreferredDeviceReconnectResultStatus.connected,
        );
        expect(repository.reconnectCallCount, 2);
        await coordinator.dispose();
      },
    );

    test('preferred reconnect stops early when a retry succeeds', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      BleDebugRegistry.instance.reset();
      final repository = _FakeDeviceRepository()
        ..pairErrors = <Object>[
          const DeviceException(
            'E_BLE_DEVICE_NOT_FOUND',
            'Preferred device was not found.',
          ),
        ];
      final store = PreferredBleDeviceStore(localStore: SharedPrefsSdkStore());
      await store.savePreferredDevice(
        PreferredBleDevice(
          deviceId: 'ble-demo-r1',
          displayName: 'EIXAM Demo',
          lastConnectedAt: DateTime.parse('2026-03-23T10:00:00Z'),
        ),
      );
      final coordinator = BleAutoReconnectCoordinator(
        deviceRepository: repository,
        preferredDeviceStore: store,
        preferredReconnectDelay: (_) async {},
      );

      await coordinator.initialize(
        initialStatus: await repository.getDeviceStatus(),
        deviceStatusStream: repository.watchDeviceStatus(),
      );
      final result = await coordinator.tryAutoConnectForHandoff(
        trigger: 'startup',
        attemptId: 'attempt-1',
      );

      expect(result.status, PreferredDeviceReconnectResultStatus.connected);
      expect(repository.reconnectCallCount, 2);
      await coordinator.dispose();
    });

    test(
      'preferred reconnect exhausts after ten retryable bluetoothOff attempts',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        BleDebugRegistry.instance.reset();
        final repository = _FakeDeviceRepository()
          ..pairErrors = List<Object>.filled(
            10,
            const DeviceException(
              'E_DEVICE_BLUETOOTH_OFF',
              'Adapter was not ready for this attempt.',
            ),
          );
        final store = PreferredBleDeviceStore(
          localStore: SharedPrefsSdkStore(),
        );
        await store.savePreferredDevice(
          PreferredBleDevice(
            deviceId: 'ble-demo-r1',
            displayName: 'EIXAM Demo',
            lastConnectedAt: DateTime.parse('2026-03-23T10:00:00Z'),
          ),
        );
        final retryDelays = <Duration>[];
        final coordinator = BleAutoReconnectCoordinator(
          deviceRepository: repository,
          preferredDeviceStore: store,
          permissionStateProvider: () async => const PermissionState(
            bluetooth: SdkPermissionStatus.granted,
            bluetoothEnabled: true,
          ),
          preferredReconnectDelay: (delay) async {
            retryDelays.add(delay);
          },
        );

        await coordinator.initialize(
          initialStatus: await repository.getDeviceStatus(),
          deviceStatusStream: repository.watchDeviceStatus(),
        );
        final result = await coordinator.tryAutoConnectForHandoff(
          trigger: 'startup',
          attemptId: 'attempt-1',
        );

        expect(result.status, PreferredDeviceReconnectResultStatus.exhausted);
        expect(repository.reconnectCallCount, 10);
        expect(retryDelays, hasLength(9));
        expect(
          BleDebugRegistry.instance.currentState.events.map(
            (event) => event.message,
          ),
          contains('EIXAM_RECONNECT_TRACE sdk_campaign_exhausted attempts=10'),
        );
        await coordinator.dispose();
      },
    );

    test('preferred reconnect cancels on dispose', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      BleDebugRegistry.instance.reset();
      final repository = _FakeDeviceRepository()
        ..pairErrors = List<Object>.filled(
          10,
          const DeviceException(
            'E_BLE_DEVICE_NOT_FOUND',
            'Preferred device was not found.',
          ),
        );
      final store = PreferredBleDeviceStore(localStore: SharedPrefsSdkStore());
      await store.savePreferredDevice(
        PreferredBleDevice(
          deviceId: 'ble-demo-r1',
          displayName: 'EIXAM Demo',
          lastConnectedAt: DateTime.parse('2026-03-23T10:00:00Z'),
        ),
      );
      final delayStarted = Completer<void>();
      final delayCompleter = Completer<void>();
      final coordinator = BleAutoReconnectCoordinator(
        deviceRepository: repository,
        preferredDeviceStore: store,
        preferredReconnectDelay: (_) {
          if (!delayStarted.isCompleted) {
            delayStarted.complete();
          }
          return delayCompleter.future;
        },
      );

      await coordinator.initialize(
        initialStatus: await repository.getDeviceStatus(),
        deviceStatusStream: repository.watchDeviceStatus(),
      );
      final reconnect = coordinator.tryAutoConnectForHandoff(
        trigger: 'startup',
        attemptId: 'attempt-1',
      );
      await delayStarted.future;
      await coordinator.dispose();

      final result = await reconnect;
      expect(result.status, PreferredDeviceReconnectResultStatus.failed);
      expect(result.reason, 'campaign_cancelled');
      expect(repository.reconnectCallCount, 1);
    });

    test(
      'manual pair is not aborted by a cancelled reconnect campaign',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        BleDebugRegistry.instance.reset();
        final repository = _FakeDeviceRepository()
          ..reconnectDelay = const Duration(seconds: 30);
        final store =
            PreferredBleDeviceStore(localStore: SharedPrefsSdkStore());
        await store.savePreferredDevice(
          PreferredBleDevice(
            deviceId: 'ble-demo-r1',
            displayName: 'EIXAM Demo',
            lastConnectedAt: DateTime.parse('2026-03-23T10:00:00Z'),
          ),
        );
        final coordinator = BleAutoReconnectCoordinator(
          deviceRepository: repository,
          preferredDeviceStore: store,
        );
        await coordinator.initialize(
          initialStatus: await repository.getDeviceStatus(),
          deviceStatusStream: repository.watchDeviceStatus(),
        );
        unawaited(coordinator.tryAutoConnectForHandoff(trigger: 'startup'));
        await Future<void>.delayed(Duration.zero);
        expect(repository.reconnectCallCount, 1);
        coordinator.cancelPreferredReconnect(reason: 'host_cancelled');
        await Future<void>.delayed(Duration.zero);

        final status = await coordinator.pairDeviceManually(
          pairingCode: '1234',
        );

        expect(status.connected, isTrue);
        expect(repository.pairCallCount, 1);
        await coordinator.dispose();
      },
    );

    test('skips auto-connect when manual disconnect is active', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      BleDebugRegistry.instance.reset();
      final repository = _FakeDeviceRepository();
      final store = PreferredBleDeviceStore(localStore: SharedPrefsSdkStore());
      await store.savePreferredDevice(
        PreferredBleDevice(
          deviceId: 'ble-demo-r1',
          displayName: 'EIXAM Demo',
          lastConnectedAt: DateTime.parse('2026-03-23T10:00:00Z'),
        ),
      );
      final coordinator = BleAutoReconnectCoordinator(
        deviceRepository: repository,
        preferredDeviceStore: store,
      );

      await coordinator.initialize(
        initialStatus: await repository.getDeviceStatus(),
        deviceStatusStream: repository.watchDeviceStatus(),
      );
      await coordinator.onManualDisconnect();
      await coordinator.tryAutoConnectOnResume();

      expect(repository.pairCallCount, 0);
      expect(await store.readManualDisconnectRequested(), isTrue);
      await coordinator.dispose();
    });

    test('tries auto-connect again when app returns to foreground', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      BleDebugRegistry.instance.reset();
      final repository = _FakeDeviceRepository();
      final store = PreferredBleDeviceStore(localStore: SharedPrefsSdkStore());
      await store.savePreferredDevice(
        PreferredBleDevice(
          deviceId: 'ble-demo-r1',
          displayName: 'EIXAM Demo',
          lastConnectedAt: DateTime.parse('2026-03-23T10:00:00Z'),
        ),
      );
      final coordinator = BleAutoReconnectCoordinator(
        deviceRepository: repository,
        preferredDeviceStore: store,
      );

      await coordinator.initialize(
        initialStatus: await repository.getDeviceStatus(),
        deviceStatusStream: repository.watchDeviceStatus(),
      );

      coordinator.setAppForeground(false);
      repository.setDisconnected();
      coordinator.setAppForeground(true);
      await Future<void>.delayed(Duration.zero);

      expect(repository.reconnectCallCount, 1);
      expect(repository.lastReconnectedDeviceId, 'ble-demo-r1');
      expect(repository.lastPairingCode, isNull);
      await coordinator.dispose();
    });

    test('tries resume auto-connect for a known preferred device', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      BleDebugRegistry.instance.reset();
      final repository = _FakeDeviceRepository();
      final store = PreferredBleDeviceStore(localStore: SharedPrefsSdkStore());
      await store.savePreferredDevice(
        PreferredBleDevice(
          deviceId: 'ble-demo-r1',
          displayName: 'EIXAM Demo',
          lastConnectedAt: DateTime.parse('2026-03-23T10:00:00Z'),
        ),
      );
      final coordinator = BleAutoReconnectCoordinator(
        deviceRepository: repository,
        preferredDeviceStore: store,
      );

      await coordinator.initialize(
        initialStatus: await repository.getDeviceStatus(),
        deviceStatusStream: repository.watchDeviceStatus(),
      );
      repository.setDisconnected();

      await coordinator.tryAutoConnectOnResume();

      expect(repository.reconnectCallCount, 1);
      expect(repository.lastReconnectedDeviceId, 'ble-demo-r1');
      expect(repository.lastPairingCode, isNull);
      await coordinator.dispose();
    });

    test(
      'iOS delegates logical preferred ids to runtime scan resolution',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        BleDebugRegistry.instance.reset();
        final repository = _FakeDeviceRepository();
        final store = PreferredBleDeviceStore(
          localStore: SharedPrefsSdkStore(),
        );
        await store.savePreferredDevice(
          PreferredBleDevice(
            deviceId: 'ble-demo-r1',
            displayName: 'EIXAM Demo',
            lastConnectedAt: DateTime.parse('2026-03-23T10:00:00Z'),
          ),
        );
        final coordinator = BleAutoReconnectCoordinator(
          deviceRepository: repository,
          preferredDeviceStore: store,
          isIosPlatform: () => true,
        );

        await coordinator.initialize(
          initialStatus: await repository.getDeviceStatus(),
          deviceStatusStream: repository.watchDeviceStatus(),
        );
        repository.setDisconnected();

        await coordinator.tryAutoConnectOnResume();

        expect(repository.reconnectCallCount, 1);
        expect(repository.lastReconnectedDeviceId, 'ble-demo-r1');
        expect(
          BleDebugRegistry.instance.currentState.events.map(
            (event) => event.message,
          ),
          containsAll(<String>[
            'DEVICE_IDENTITY_RESOLVED platform=ios '
                'device_identity_present=true remoteIdPresent=false',
            'BLE_RECONNECT_REQUIRES_SCAN platform=ios reason=missing_valid_remote_id',
          ]),
        );
        await coordinator.dispose();
      },
    );

    test('stops auto-connect when phone Bluetooth bond was removed', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      BleDebugRegistry.instance.reset();
      final repository = _FakeDeviceRepository()
        ..pairErrors = <Object>[
          const DeviceException(
            'E_DEVICE_MOBILE_BOND_REQUIRED',
            'The device is no longer paired in the phone Bluetooth settings.',
          ),
        ];
      final store = PreferredBleDeviceStore(localStore: SharedPrefsSdkStore());
      await store.savePreferredDevice(
        PreferredBleDevice(
          deviceId: 'ble-demo-r1',
          displayName: 'EIXAM Demo',
          lastConnectedAt: DateTime.parse('2026-03-23T10:00:00Z'),
        ),
      );
      final coordinator = BleAutoReconnectCoordinator(
        deviceRepository: repository,
        preferredDeviceStore: store,
      );

      await coordinator.initialize(
        initialStatus: await repository.getDeviceStatus(),
        deviceStatusStream: repository.watchDeviceStatus(),
      );
      await coordinator.tryAutoConnectOnResume();

      expect(repository.reconnectCallCount, 1);
      expect(await store.getPreferredDevice(), isNull);
      expect(await store.readManualDisconnectRequested(), isTrue);
      expect(
        BleDebugRegistry.instance.currentState.events.map(
          (event) => event.message,
        ),
        contains(
          'BLE_AUTO_RECONNECT_STOPPED reason=android_bond_missing '
          'device_identity_present=true',
        ),
      );
      await coordinator.dispose();
    });

    test('stops auto-connect when iOS pairing information was removed',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      BleDebugRegistry.instance.reset();
      final repository = _FakeDeviceRepository()
        ..pairErrors = <Object>[
          const DeviceException.bleIosPairingInformationRemoved(),
        ];
      final store = PreferredBleDeviceStore(localStore: SharedPrefsSdkStore());
      await store.savePreferredDevice(
        PreferredBleDevice(
          deviceId: '97BA8682-44B7-5BA3-2257-381176EB6AAB',
          displayName: 'EIXAM Demo',
          lastConnectedAt: DateTime.parse('2026-03-23T10:00:00Z'),
        ),
      );
      final coordinator = BleAutoReconnectCoordinator(
        deviceRepository: repository,
        preferredDeviceStore: store,
        isIosPlatform: () => true,
      );

      await coordinator.initialize(
        initialStatus: await repository.getDeviceStatus(),
        deviceStatusStream: repository.watchDeviceStatus(),
      );
      final firstResult = await coordinator.tryAutoConnectForHandoff(
        trigger: 'resume',
      );
      await coordinator.tryAutoConnectOnResume();

      expect(
        firstResult.status,
        PreferredDeviceReconnectResultStatus.noKnownDevice,
      );
      expect(firstResult.reason, 'mobile_bond_missing');
      expect(repository.reconnectCallCount, 1);
      expect(await store.getPreferredDevice(), isNull);
      expect(await store.readManualDisconnectRequested(), isTrue);
      expect(
        BleDebugRegistry.instance.currentState.events.map(
          (event) => event.message,
        ),
        contains(
          'BLE_AUTO_RECONNECT_STOPPED '
          'reason=ios_pairing_information_removed '
          'device_identity_present=true',
        ),
      );
      await coordinator.dispose();
    });

    test(
      'manual connect clears stale preferred device on iOS pairing removal',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        BleDebugRegistry.instance.reset();
        BleDebugRegistry.instance.selectDevice(
          '97BA8682-44B7-5BA3-2257-381176EB6AAB',
        );
        final repository = _FakeDeviceRepository()
          ..pairErrors = <Object>[
            const DeviceException.bleIosPairingInformationRemoved(),
          ];
        final store = PreferredBleDeviceStore(
          localStore: SharedPrefsSdkStore(),
        );
        await store.savePreferredDevice(
          PreferredBleDevice(
            deviceId: '97BA8682-44B7-5BA3-2257-381176EB6AAB',
            displayName: 'EIXAM Demo',
            lastConnectedAt: DateTime.parse('2026-03-23T10:00:00Z'),
          ),
        );
        final coordinator = BleAutoReconnectCoordinator(
          deviceRepository: repository,
          preferredDeviceStore: store,
          isIosPlatform: () => true,
        );

        await coordinator.initialize(
          initialStatus: await repository.getDeviceStatus(),
          deviceStatusStream: repository.watchDeviceStatus(),
        );

        await expectLater(
          coordinator.pairDeviceManually(pairingCode: '1234'),
          throwsA(
            isA<DeviceException>().having(
              (error) => error.code,
              'code',
              DeviceException.bleIosPairingInformationRemovedCode,
            ),
          ),
        );

        expect(repository.pairCallCount, 1);
        expect(await store.getPreferredDevice(), isNull);
        expect(await store.readManualDisconnectRequested(), isTrue);
        expect(
          BleDebugRegistry.instance.currentState.events.map(
            (event) => event.message,
          ),
          contains(
            'BLE_AUTO_RECONNECT_STOPPED '
            'reason=ios_pairing_information_removed '
            'device_identity_present=true',
          ),
        );
        await coordinator.dispose();
      },
    );

    test(
      'uses restored paired device id when preferred store is empty',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        BleDebugRegistry.instance.reset();
        final repository = _FakeDeviceRepository()..setDisconnected();
        final store = PreferredBleDeviceStore(
          localStore: SharedPrefsSdkStore(),
        );
        final coordinator = BleAutoReconnectCoordinator(
          deviceRepository: repository,
          preferredDeviceStore: store,
        );

        await coordinator.initialize(
          initialStatus: await repository.getDeviceStatus(),
          deviceStatusStream: repository.watchDeviceStatus(),
        );
        await coordinator.tryAutoConnectOnStartup();

        expect(repository.reconnectCallCount, 1);
        expect(repository.lastReconnectedDeviceId, 'demo-device');
        await coordinator.dispose();
      },
    );

    test(
      'rebinds an already connected device when command channel is not ready',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        BleDebugRegistry.instance.reset();
        final repository = _FakeDeviceRepository()
          ..setConnected(commandCapable: false);
        final store = PreferredBleDeviceStore(
          localStore: SharedPrefsSdkStore(),
        );
        await store.savePreferredDevice(
          PreferredBleDevice(
            deviceId: 'ble-demo-r1',
            displayName: 'EIXAM Demo',
            lastConnectedAt: DateTime.parse('2026-03-23T10:00:00Z'),
          ),
        );
        final coordinator = BleAutoReconnectCoordinator(
          deviceRepository: repository,
          preferredDeviceStore: store,
        );

        await coordinator.initialize(
          initialStatus: await repository.getDeviceStatus(),
          deviceStatusStream: repository.watchDeviceStatus(),
        );
        await coordinator.tryAutoConnectOnResume();

        expect(repository.refreshCallCount, 1);
        expect(repository.reconnectCallCount, 1);
        expect(repository.lastReconnectedDeviceId, 'ble-demo-r1');
        expect(
          BleDebugRegistry.instance.currentState.events.map(
            (event) => event.message,
          ),
          contains(
            'BLE_AUTO_CONNECT_REBIND trigger=resume reason=command_channel_not_ready',
          ),
        );
        await coordinator.dispose();
      },
    );

    test(
      'skips already connected device when command channel is ready',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        BleDebugRegistry.instance.reset();
        final repository = _FakeDeviceRepository()
          ..setConnected(commandCapable: true);
        final store = PreferredBleDeviceStore(
          localStore: SharedPrefsSdkStore(),
        );
        await store.savePreferredDevice(
          PreferredBleDevice(
            deviceId: 'ble-demo-r1',
            displayName: 'EIXAM Demo',
            lastConnectedAt: DateTime.parse('2026-03-23T10:00:00Z'),
          ),
        );
        final coordinator = BleAutoReconnectCoordinator(
          deviceRepository: repository,
          preferredDeviceStore: store,
        );

        await coordinator.initialize(
          initialStatus: await repository.getDeviceStatus(),
          deviceStatusStream: repository.watchDeviceStatus(),
        );
        await coordinator.tryAutoConnectOnResume();

        expect(repository.refreshCallCount, 1);
        expect(repository.reconnectCallCount, 0);
        expect(
          BleDebugRegistry.instance.currentState.events.map(
            (event) => event.message,
          ),
          contains(
            'BLE_AUTO_CONNECT_SKIPPED trigger=resume reason=command_channel_ready',
          ),
        );
        await coordinator.dispose();
      },
    );

    test(
      'retries manual connect once for transient disconnect failures',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        BleDebugRegistry.instance.reset();
        final repository = _FakeDeviceRepository()
          ..pairErrors = <Object>[
            PlatformException(
              code: 'deviceDisconnected',
              message: 'deviceDisconnected',
            ),
          ];
        final store = PreferredBleDeviceStore(
          localStore: SharedPrefsSdkStore(),
        );
        final coordinator = BleAutoReconnectCoordinator(
          deviceRepository: repository,
          preferredDeviceStore: store,
        );

        await coordinator.initialize(
          initialStatus: await repository.getDeviceStatus(),
          deviceStatusStream: repository.watchDeviceStatus(),
        );

        final status = await coordinator.pairDeviceManually(
          pairingCode: '1234',
        );

        expect(status.connected, isTrue);
        expect(repository.pairCallCount, 2);
        expect(
          BleDebugRegistry.instance.currentState.events.map(
            (event) => event.message,
          ),
          contains('manual_connect_retry_start'),
        );
        expect(
          BleDebugRegistry.instance.currentState.events.map(
            (event) => event.message,
          ),
          contains('manual_connect_retry_success'),
        );
        await coordinator.dispose();
      },
    );

    test(
      'retries auto-connect campaign for transient disconnect failures',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        BleDebugRegistry.instance.reset();
        final repository = _FakeDeviceRepository()
          ..pairErrors = <Object>[
            PlatformException(
              code: 'deviceDisconnected',
              message: 'deviceDisconnected',
            ),
          ];
        final store = PreferredBleDeviceStore(
          localStore: SharedPrefsSdkStore(),
        );
        await store.savePreferredDevice(
          PreferredBleDevice(
            deviceId: 'ble-demo-r1',
            displayName: 'EIXAM Demo',
            lastConnectedAt: DateTime.parse('2026-03-23T10:00:00Z'),
          ),
        );
        final coordinator = BleAutoReconnectCoordinator(
          deviceRepository: repository,
          preferredDeviceStore: store,
          preferredReconnectDelay: (_) async {},
        );

        await coordinator.initialize(
          initialStatus: await repository.getDeviceStatus(),
          deviceStatusStream: repository.watchDeviceStatus(),
        );

        await coordinator.tryAutoConnectOnStartup();

        expect(repository.reconnectCallCount, 2);
        expect(repository.pairCallCount, 0);
        expect(
          BleDebugRegistry.instance.currentState.events
              .map((event) => event.message)
              .where((message) => message == 'manual_connect_retry_start'),
          isEmpty,
        );
        await coordinator.dispose();
      },
    );
  });
}

Future<void> _settleReconnectMonitor() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class _FakeDeviceRepository
    implements DeviceRepository, KnownDeviceReconnectRepository {
  final StreamController<DeviceStatus> _controller =
      StreamController<DeviceStatus>.broadcast();

  DeviceStatus _status = const DeviceStatus(
    deviceId: 'demo-device',
    deviceAlias: 'Demo Device',
    model: 'EIXAM R1',
    paired: false,
    activated: false,
    connected: false,
    lifecycleState: DeviceLifecycleState.unpaired,
  );

  int pairCallCount = 0;
  int reconnectCallCount = 0;
  int refreshCallCount = 0;
  String? lastPairingCode;
  String? lastReconnectedDeviceId;
  String? lastReconnectAttemptId;
  List<Object> pairErrors = <Object>[];
  Duration reconnectDelay = Duration.zero;
  bool _commandCapable = false;

  void setDisconnected() {
    _status = _status.copyWith(
      paired: true,
      connected: false,
      lifecycleState: DeviceLifecycleState.paired,
      clearProvisioningError: true,
    );
    _controller.add(_status);
  }

  void setConnected({required bool commandCapable}) {
    _commandCapable = commandCapable;
    _status = _status.copyWith(
      deviceId: 'ble-demo-r1',
      deviceAlias: 'EIXAM Demo',
      paired: true,
      connected: true,
      lifecycleState: DeviceLifecycleState.paired,
      clearProvisioningError: true,
    );
    _controller.add(_status);
  }

  @override
  Future<DeviceStatus> activateDevice({required String activationCode}) async {
    return _status;
  }

  @override
  Future<DeviceStatus> getDeviceStatus() async => _status;

  @override
  Future<DeviceStatus> pairDevice({required String pairingCode}) async {
    pairCallCount++;
    lastPairingCode = pairingCode;
    if (pairErrors.isNotEmpty) {
      throw pairErrors.removeAt(0);
    }
    _status = _status.copyWith(
      deviceId: 'ble-demo-r1',
      deviceAlias: 'EIXAM Demo',
      paired: true,
      connected: true,
      lifecycleState: DeviceLifecycleState.paired,
      clearProvisioningError: true,
    );
    _controller.add(_status);
    return _status;
  }

  @override
  Future<DeviceStatus> reconnectDevice({
    required PreferredDevice device,
    String? attemptId,
  }) async {
    reconnectCallCount++;
    lastReconnectedDeviceId = device.deviceId;
    lastReconnectAttemptId = attemptId;
    if (reconnectDelay > Duration.zero) {
      await Future<void>.delayed(reconnectDelay);
    }
    if (pairErrors.isNotEmpty) {
      throw pairErrors.removeAt(0);
    }
    _status = _status.copyWith(
      deviceId: device.deviceId,
      deviceAlias: device.displayName ?? 'EIXAM Demo',
      paired: true,
      connected: true,
      lifecycleState: DeviceLifecycleState.paired,
      clearProvisioningError: true,
    );
    _commandCapable = true;
    _controller.add(_status);
    return _status;
  }

  @override
  Future<DeviceStatus> refreshDeviceStatus() async {
    refreshCallCount++;
    return _status;
  }

  @override
  Future<RuntimeIdentitySnapshot> getRuntimeIdentitySnapshot() async {
    return RuntimeIdentitySnapshot(
      connectedBleNodeId: null,
      deviceId: _status.connected ? _status.deviceId : null,
      serviceBleConnected: _status.connected,
      commandCapable: _commandCapable,
      readinessReason: _status.connected && _commandCapable
          ? RuntimeIdentityReadinessReason.ready
          : _status.connected
              ? RuntimeIdentityReadinessReason.commandPathNotReady
              : RuntimeIdentityReadinessReason.noConnectedDevice,
      lastUpdatedAt: _status.lastSyncedAt ?? _status.lastSeen,
    );
  }

  @override
  Future<void> unpairDevice() async {
    _status = _status.copyWith(
      paired: false,
      connected: false,
      lifecycleState: DeviceLifecycleState.unpaired,
    );
    _controller.add(_status);
  }

  @override
  Stream<DeviceStatus> watchDeviceStatus() => _controller.stream;
}
