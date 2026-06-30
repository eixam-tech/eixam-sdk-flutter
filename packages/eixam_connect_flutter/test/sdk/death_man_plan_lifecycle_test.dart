import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/preferred_ble_device_store.dart';
import 'package:eixam_connect_flutter/src/device/ble_incoming_event.dart';
import 'package:eixam_connect_flutter/src/device/device_sos_controller.dart';
import 'package:eixam_connect_flutter/src/sdk/background_telemetry_platform_adapter.dart';
import 'package:eixam_connect_flutter/src/sdk/eixam_connect_sdk_impl.dart';
import 'package:eixam_connect_flutter/src/sdk/protection_platform_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/builders/device_status_builder.dart';
import '../support/fakes/memory_shared_prefs_sdk_store.dart';
import '../support/fakes/sdk_contract_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Death Man Plan lifecycle', () {
    late _DeathManHarness harness;

    setUp(() async {
      harness = _DeathManHarness();
      await harness.initialize();
    });

    tearDown(() async {
      await harness.dispose();
    });

    test('final confirmation writes the same transition as the state machine',
        () async {
      final events = <EixamSdkEvent>[];
      final subscription = harness.sdk.watchEvents().listen(events.add);

      final now = DateTime.now();
      await harness.sdk.scheduleDeathMan(
        expectedReturnAt: now.subtract(const Duration(seconds: 1)),
        gracePeriod: const Duration(hours: 1),
        checkInWindow: const Duration(hours: 1),
      );

      await harness.waitForStatus(DeathManStatus.awaitingConfirmation);
      await _waitUntil(
        () => events.whereType<DeathManStatusChangedEvent>().any((event) {
          return event.status == DeathManStatus.awaitingConfirmation.name;
        }),
      );

      final machine = DeathManStateMachine()
        ..transitionTo(DeathManStatus.monitoring);
      expect(
        machine.transitionTo(DeathManStatus.awaitingConfirmation),
        DeathManStatus.awaitingConfirmation,
      );
      expect(
        harness.deathManRepository.updatedStatuses,
        <DeathManStatus>[
          DeathManStatus.monitoring,
          DeathManStatus.awaitingConfirmation,
        ],
      );
      expect(
        events.whereType<DeathManStatusChangedEvent>().map((event) {
          return event.status;
        }),
        contains(DeathManStatus.awaitingConfirmation.name),
      );

      await subscription.cancel();
    });

    test('overdue auto-SOS path follows state machine and triggers once',
        () async {
      final events = <EixamSdkEvent>[];
      final subscription = harness.sdk.watchEvents().listen(events.add);

      final now = DateTime.now();
      await harness.sdk.scheduleDeathMan(
        expectedReturnAt: now.subtract(const Duration(seconds: 3)),
        gracePeriod: const Duration(seconds: 1),
        checkInWindow: const Duration(seconds: 1),
        autoTriggerSos: true,
      );

      await harness.waitForSosTriggerCount(1);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      final machine = DeathManStateMachine()
        ..transitionTo(DeathManStatus.monitoring)
        ..transitionTo(DeathManStatus.awaitingConfirmation)
        ..transitionTo(DeathManStatus.overdue)
        ..transitionTo(DeathManStatus.escalated);
      expect(
        machine.transitionTo(DeathManStatus.expired),
        DeathManStatus.expired,
      );
      expect(
        harness.deathManRepository.updatedStatuses,
        <DeathManStatus>[
          DeathManStatus.monitoring,
          DeathManStatus.awaitingConfirmation,
          DeathManStatus.overdue,
          DeathManStatus.escalated,
          DeathManStatus.expired,
        ],
      );
      expect(harness.sosRepository.triggerCallCount, 1);
      expect(
        harness.sosRepository.lastTriggerSource,
        'death_man_protocol',
      );
      expect(events.whereType<DeathManEscalatedEvent>(), hasLength(1));
      expect(
        events.whereType<DeathManStatusChangedEvent>().map((event) {
          return event.status;
        }),
        containsAll(<String>[
          DeathManStatus.awaitingConfirmation.name,
          DeathManStatus.overdue.name,
          DeathManStatus.expired.name,
        ]),
      );

      await subscription.cancel();
    });

    test('confirmed safe during final confirmation prevents auto-SOS',
        () async {
      final now = DateTime.now();
      final plan = await harness.sdk.scheduleDeathMan(
        expectedReturnAt: now.subtract(const Duration(seconds: 1)),
        gracePeriod: const Duration(hours: 1),
        checkInWindow: const Duration(hours: 1),
        autoTriggerSos: true,
      );
      await harness.waitForStatus(DeathManStatus.awaitingConfirmation);

      await harness.sdk.confirmDeathManCheckIn(plan.id);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(harness.deathManRepository.activePlan?.status,
          DeathManStatus.confirmedSafe);
      expect(harness.sosRepository.triggerCallCount, 0);
    });

    test('cancel during final confirmation prevents auto-SOS', () async {
      final now = DateTime.now();
      final plan = await harness.sdk.scheduleDeathMan(
        expectedReturnAt: now.subtract(const Duration(seconds: 1)),
        gracePeriod: const Duration(hours: 1),
        checkInWindow: const Duration(hours: 1),
        autoTriggerSos: true,
      );
      await harness.waitForStatus(DeathManStatus.awaitingConfirmation);

      await harness.sdk.cancelDeathMan(plan.id);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(harness.deathManRepository.activePlan?.status,
          DeathManStatus.cancelled);
      expect(harness.sosRepository.triggerCallCount, 0);
    });

    test('restore routes stale scheduled plan through valid intermediates',
        () async {
      await harness.dispose();
      harness = _DeathManHarness(
        activePlan: DeathManPlan(
          id: 'restored-dmp',
          expectedReturnAt: DateTime.now().subtract(const Duration(seconds: 1)),
          gracePeriod: const Duration(hours: 1),
          checkInWindow: const Duration(hours: 1),
          autoTriggerSos: true,
          status: DeathManStatus.scheduled,
        ),
      );

      await harness.initialize();
      await harness.waitForStatus(DeathManStatus.awaitingConfirmation);

      expect(
        harness.deathManRepository.updatedStatuses,
        <DeathManStatus>[
          DeathManStatus.monitoring,
          DeathManStatus.awaitingConfirmation,
        ],
      );
      expect(harness.sosRepository.triggerCallCount, 0);
    });
  });
}

final class _DeathManHarness {
  _DeathManHarness({DeathManPlan? activePlan})
      : sosRepository = FakeSosRepository(),
        trackingRepository = FakeTrackingRepository(
          currentPosition: TrackingPosition(
            latitude: 41.38,
            longitude: 2.17,
            timestamp: DateTime.utc(2026, 1, 1),
            source: DeliveryMode.mobile,
          ),
        ),
        telemetryRepository = FakeTelemetryRepository(),
        contactsRepository = FakeContactsRepository(),
        deviceRepository = FakeDeviceRepository(
          initialStatus: buildDeviceStatus(
            connected: false,
            paired: false,
            activated: false,
          ),
        ),
        deviceRegistryRepository = FakeSdkDeviceRegistryRepository(),
        deathManRepository = FakeDeathManRepository()..activePlan = activePlan,
        permissionsRepository = FakePermissionsRepository(
          permissionState: const PermissionState(
            location: SdkPermissionStatus.granted,
            notifications: SdkPermissionStatus.granted,
            bluetooth: SdkPermissionStatus.granted,
          ),
        ),
        notificationsRepository = FakeNotificationsRepository(),
        realtimeClient = FakeRealtimeClient(),
        deviceSosController = DeviceSosController(),
        localStore = MemorySharedPrefsSdkStore() {
    sdk = EixamConnectSdkImpl(
      sosRepository: sosRepository,
      trackingRepository: trackingRepository,
      telemetryRepository: telemetryRepository,
      contactsRepository: contactsRepository,
      deviceRepository: deviceRepository,
      deviceRegistryRepository: deviceRegistryRepository,
      deathManRepository: deathManRepository,
      permissionsRepository: permissionsRepository,
      notificationsRepository: notificationsRepository,
      realtimeClient: realtimeClient,
      deviceSosController: deviceSosController,
      bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
      preferredBleDeviceStore: PreferredBleDeviceStore(localStore: localStore),
      localStore: localStore,
      protectionPlatformAdapter: const NoopProtectionPlatformAdapter(),
      backgroundTelemetryPlatformAdapter:
          const NoopBackgroundTelemetryPlatformAdapter(),
    );
  }

  final FakeSosRepository sosRepository;
  final FakeTrackingRepository trackingRepository;
  final FakeTelemetryRepository telemetryRepository;
  final FakeContactsRepository contactsRepository;
  final FakeDeviceRepository deviceRepository;
  final FakeSdkDeviceRegistryRepository deviceRegistryRepository;
  final FakeDeathManRepository deathManRepository;
  final FakePermissionsRepository permissionsRepository;
  final FakeNotificationsRepository notificationsRepository;
  final FakeRealtimeClient realtimeClient;
  final DeviceSosController deviceSosController;
  final MemorySharedPrefsSdkStore localStore;
  late final EixamConnectSdkImpl sdk;

  Future<void> initialize() async {
    await sdk.initialize(
      const EixamSdkConfig(apiBaseUrl: 'https://api.example.test'),
    );
    await sdk.setSession(
      const EixamSession.signed(
        appId: 'partner-app',
        externalUserId: 'user-1',
        userHash: 'hash-1',
      ),
    );
  }

  Future<void> waitForStatus(DeathManStatus status) async {
    await _waitUntil(() => deathManRepository.activePlan?.status == status);
  }

  Future<void> waitForSosTriggerCount(int count) async {
    await _waitUntil(() => sosRepository.triggerCallCount == count);
  }

  Future<void> dispose() async {
    await sdk.dispose();
    await sosRepository.dispose();
    await trackingRepository.dispose();
    await contactsRepository.dispose();
    await deviceRepository.dispose();
    await deathManRepository.dispose();
    await realtimeClient.dispose();
  }
}

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for condition');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
