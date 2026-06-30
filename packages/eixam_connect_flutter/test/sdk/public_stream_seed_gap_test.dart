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

  group('public stream async seed gap', () {
    test(
        'watchDeviceSosStatus buffers SOS status emitted while seed is pending',
        () async {
      final deviceSosController = _DelayedDeviceSosController();
      final seedStatus = _deviceSosStatus(DeviceSosState.inactive, 1);
      final liveStatus = _deviceSosStatus(DeviceSosState.active, 2);
      final seed = Completer<DeviceSosStatus>();
      deviceSosController.nextStatus = seed.future;
      final sdk = _buildSdk(deviceSosController: deviceSosController);
      final emitted = <DeviceSosStatus>[];
      final subscription = sdk.watchDeviceSosStatus().listen(emitted.add);

      await pumpEventQueue();
      deviceSosController.emitStatus(liveStatus);
      await pumpEventQueue(times: 5);
      expect(emitted, isEmpty);

      seed.complete(seedStatus);
      await pumpEventQueue(times: 5);

      expect(emitted, <DeviceSosStatus>[seedStatus, liveStatus]);

      await subscription.cancel();
      await sdk.dispose();
      await deviceSosController.dispose();
    });

    test(
        'watchPositions buffers telemetry position emitted while seed is pending',
        () async {
      final trackingRepository = _DelayedTrackingRepository();
      final seedPosition = _position(1);
      final livePosition = _position(2);
      final seed = Completer<TrackingPosition?>();
      trackingRepository.nextPosition = seed.future;
      final sdk = _buildSdk(trackingRepository: trackingRepository);
      final emitted = <TrackingPosition>[];
      final subscription = sdk.watchPositions().listen(emitted.add);

      await pumpEventQueue();
      trackingRepository.emitPosition(livePosition);
      await pumpEventQueue(times: 5);
      expect(emitted, isEmpty);

      seed.complete(seedPosition);
      await pumpEventQueue(times: 5);

      expect(emitted, <TrackingPosition>[seedPosition, livePosition]);

      await subscription.cancel();
      await sdk.dispose();
      await trackingRepository.dispose();
    });

    test('cancelling seeded stream cancels the internal live subscription',
        () async {
      final trackingRepository = _DelayedTrackingRepository();
      trackingRepository.nextPosition = Completer<TrackingPosition?>().future;
      final sdk = _buildSdk(trackingRepository: trackingRepository);

      final subscription = sdk.watchPositions().listen((_) {});
      await pumpEventQueue();
      expect(trackingRepository.positionListenCount, 1);

      await subscription.cancel();

      expect(trackingRepository.positionCancelCount, 1);

      await sdk.dispose();
      await trackingRepository.dispose();
    });

    test('watchPositions still emits seed first when no live event arrives',
        () async {
      final trackingRepository = _DelayedTrackingRepository();
      final seedPosition = _position(3);
      trackingRepository.nextPosition = Future<TrackingPosition?>.value(
        seedPosition,
      );
      final sdk = _buildSdk(trackingRepository: trackingRepository);

      await expectLater(
        sdk.watchPositions().take(1),
        emits(seedPosition),
      );

      await sdk.dispose();
      await trackingRepository.dispose();
    });

    test('watchDeviceSosStatus drops duplicate live status matching seed',
        () async {
      final deviceSosController = _DelayedDeviceSosController();
      final liveStatus = _deviceSosStatus(DeviceSosState.active, 4);
      final seed = Completer<DeviceSosStatus>();
      deviceSosController.nextStatus = seed.future;
      final sdk = _buildSdk(deviceSosController: deviceSosController);
      final emitted = <DeviceSosStatus>[];
      final subscription = sdk.watchDeviceSosStatus().listen(emitted.add);

      await pumpEventQueue();
      deviceSosController.emitStatus(liveStatus);
      await pumpEventQueue(times: 5);

      seed.complete(liveStatus);
      await pumpEventQueue(times: 5);

      expect(emitted, <DeviceSosStatus>[liveStatus]);

      await subscription.cancel();
      await sdk.dispose();
      await deviceSosController.dispose();
    });
  });
}

EixamConnectSdkImpl _buildSdk({
  SosRepository? sosRepository,
  TrackingRepository? trackingRepository,
  DeviceSosController? deviceSosController,
}) {
  final localStore = MemorySharedPrefsSdkStore();
  return EixamConnectSdkImpl(
    sosRepository: sosRepository ?? FakeSosRepository(),
    trackingRepository: trackingRepository ?? FakeTrackingRepository(),
    telemetryRepository: FakeTelemetryRepository(),
    contactsRepository: FakeContactsRepository(),
    deviceRepository: FakeDeviceRepository(initialStatus: buildDeviceStatus()),
    deviceRegistryRepository: FakeSdkDeviceRegistryRepository(),
    deathManRepository: FakeDeathManRepository(),
    permissionsRepository: FakePermissionsRepository(),
    notificationsRepository: FakeNotificationsRepository(),
    realtimeClient: FakeRealtimeClient(),
    deviceSosController: deviceSosController ?? DeviceSosController(),
    bleIncomingEvents: const Stream<BleIncomingEvent>.empty(),
    preferredBleDeviceStore: PreferredBleDeviceStore(localStore: localStore),
    localStore: localStore,
    protectionPlatformAdapter: const NoopProtectionPlatformAdapter(),
    backgroundTelemetryPlatformAdapter:
        const NoopBackgroundTelemetryPlatformAdapter(),
  );
}

TrackingPosition _position(int index) {
  return TrackingPosition(
    latitude: 41 + index.toDouble(),
    longitude: 2 + index.toDouble(),
    timestamp: DateTime.utc(2026, 1, 1, 12, index),
  );
}

DeviceSosStatus _deviceSosStatus(DeviceSosState state, int index) {
  return DeviceSosStatus(
    state: state,
    lastEvent: 'TEST_DEVICE_SOS_${state.name.toUpperCase()}',
    updatedAt: DateTime.utc(2026, 1, 1, 13, index),
  );
}

class _DelayedDeviceSosController extends DeviceSosController {
  final StreamController<DeviceSosStatus> _controller =
      StreamController<DeviceSosStatus>.broadcast();

  Future<DeviceSosStatus>? nextStatus;
  DeviceSosStatus current = _deviceSosStatus(DeviceSosState.inactive, 0);

  @override
  Future<DeviceSosStatus> getStatus() async {
    final delayed = nextStatus;
    if (delayed == null) {
      return current;
    }
    nextStatus = null;
    return delayed;
  }

  @override
  Stream<DeviceSosStatus> watchStatus() => _controller.stream;

  void emitStatus(DeviceSosStatus status) {
    current = status;
    _controller.add(status);
  }

  @override
  Future<void> dispose() async {
    await _controller.close();
  }
}

class _DelayedTrackingRepository implements TrackingRepository {
  final StreamController<TrackingPosition> _positionsController =
      StreamController<TrackingPosition>.broadcast();
  final StreamController<TrackingState> _stateController =
      StreamController<TrackingState>.broadcast();

  Future<TrackingPosition?>? nextPosition;
  TrackingPosition? currentPosition;
  TrackingState state = TrackingState.idle;
  int positionListenCount = 0;
  int positionCancelCount = 0;

  @override
  Future<void> startTracking() async {
    state = TrackingState.tracking;
    _stateController.add(state);
  }

  @override
  Future<void> stopTracking() async {
    state = TrackingState.idle;
    _stateController.add(state);
  }

  @override
  Future<TrackingPosition?> getCurrentPosition() async {
    final delayed = nextPosition;
    if (delayed == null) {
      return currentPosition;
    }
    nextPosition = null;
    return delayed;
  }

  @override
  Future<TrackingState> getTrackingState() async => state;

  @override
  Stream<TrackingPosition> watchPositions() {
    late final StreamController<TrackingPosition> controller;
    StreamSubscription<TrackingPosition>? subscription;
    controller = StreamController<TrackingPosition>(
      onListen: () {
        positionListenCount++;
        subscription = _positionsController.stream.listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: () async {
        positionCancelCount++;
        await subscription?.cancel();
      },
    );
    return controller.stream;
  }

  @override
  Stream<TrackingState> watchTrackingState() => _stateController.stream;

  void emitPosition(TrackingPosition position) {
    currentPosition = position;
    _positionsController.add(position);
  }

  Future<void> dispose() async {
    await _positionsController.close();
    await _stateController.close();
  }
}
