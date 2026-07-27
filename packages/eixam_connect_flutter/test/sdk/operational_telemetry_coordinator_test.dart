import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/sdk/authoritative_sos_cadence.dart';
import 'package:eixam_connect_flutter/src/sdk/operational_telemetry_coordinator.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('OperationalTelemetryCoordinator', () {
    test('no SOS publishes once every 60 seconds', () {
      fakeAsync((async) {
        final harness = _Harness();
        harness.start();

        async.elapse(const Duration(seconds: 60));
        async.flushMicrotasks();

        expect(harness.publishedPayloads, hasLength(1));
        expect(harness.publishedPayloads.single.latitude, 41.38);
      });
    });

    test('no SOS does not publish before 60 seconds', () {
      fakeAsync((async) {
        final harness = _Harness();
        harness.start();

        async.elapse(const Duration(seconds: 59));
        async.flushMicrotasks();

        expect(harness.publishedPayloads, isEmpty);
      });
    });

    test('authoritative active publishes at 20 seconds without movement', () {
      fakeAsync((async) {
        final harness = _Harness();
        harness.start();
        harness.emitCadence(SosLifecycleStage.active, desired: true);
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 20));
        async.flushMicrotasks();

        expect(harness.publishedPayloads, hasLength(1));
      });
    });

    test('SOS open publishes when moved at least 7 meters', () {
      fakeAsync((async) {
        final harness = _Harness();
        harness.start();
        harness.emitCadence(SosLifecycleStage.active, desired: true);
        async.flushMicrotasks();

        harness.emitPosition(
          _position(latitude: 41.38008, longitude: 2.17),
        );
        async.flushMicrotasks();

        expect(harness.publishedPayloads, hasLength(1));
      });
    });

    test('SOS open does not publish for movement under 7 meters before 20s',
        () {
      fakeAsync((async) {
        final harness = _Harness();
        harness.start();
        harness.emitCadence(SosLifecycleStage.active, desired: true);
        async.flushMicrotasks();

        harness.emitPosition(
          _position(latitude: 41.38003, longitude: 2.17),
        );
        async.elapse(const Duration(seconds: 19));
        async.flushMicrotasks();

        expect(harness.publishedPayloads, isEmpty);
      });
    });

    test('SOS closed switches back to 60 second heartbeat', () {
      fakeAsync((async) {
        final harness = _Harness();
        harness.start();
        harness.emitCadence(SosLifecycleStage.active, desired: true);
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 20));
        async.flushMicrotasks();
        harness.emitCadence(SosLifecycleStage.resolved, desired: false);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 59));
        async.flushMicrotasks();

        expect(harness.publishedPayloads, hasLength(1));

        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();

        expect(harness.publishedPayloads, hasLength(2));
      });
    });

    test('cancelling and cancellation failure retain SOS cadence', () {
      fakeAsync((async) {
        final harness = _Harness();
        harness.start();
        harness.emitCadence(SosLifecycleStage.active, desired: true);
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 20));
        async.flushMicrotasks();
        harness.emitCadence(SosLifecycleStage.cancelling, desired: true);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 20));
        async.flushMicrotasks();
        harness.emitCadence(
          SosLifecycleStage.cancellationFailed,
          desired: true,
        );
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 20));
        async.flushMicrotasks();

        expect(harness.publishedPayloads, hasLength(3));
      });
    });

    test('arming and activating remain normal with no early SOS interval', () {
      fakeAsync((async) {
        final harness = _Harness();
        harness.start();

        harness.emitCadence(SosLifecycleStage.arming, desired: false);
        async.elapse(const Duration(seconds: 20));
        async.flushMicrotasks();
        harness.emitCadence(SosLifecycleStage.activating, desired: false);
        async.elapse(const Duration(seconds: 20));
        async.flushMicrotasks();

        expect(harness.publishedPayloads, isEmpty);

        async.elapse(const Duration(seconds: 20));
        async.flushMicrotasks();

        expect(harness.publishedPayloads, hasLength(1));
      });
    });

    test('active duplicate revision does not reconfigure or delay SOS timer',
        () {
      fakeAsync((async) {
        final harness = _Harness();
        harness.start();
        harness.emitCadence(SosLifecycleStage.active, desired: true);
        async.elapse(const Duration(seconds: 10));
        harness.emitCadence(
          SosLifecycleStage.active,
          desired: true,
          revision: harness.lastRevision,
        );
        async.elapse(const Duration(seconds: 10));
        async.flushMicrotasks();

        expect(harness.publishedPayloads, hasLength(1));
      });
    });

    test('valid local recovery retains SOS cadence', () {
      fakeAsync((async) {
        final harness = _Harness();
        harness.start(
          stage: SosLifecycleStage.active,
          desired: true,
        );
        harness.emitCadence(
          SosLifecycleStage.recoveryRequired,
          desired: true,
        );

        async.elapse(const Duration(seconds: 20));
        async.flushMicrotasks();

        expect(harness.publishedPayloads, hasLength(1));
      });
    });

    test('terminal and definitive idle each use normal cadence', () {
      for (final stage in <SosLifecycleStage>[
        SosLifecycleStage.cancelled,
        SosLifecycleStage.resolved,
        SosLifecycleStage.idle,
      ]) {
        fakeAsync((async) {
          final harness = _Harness();
          harness.start(
            stage: SosLifecycleStage.active,
            desired: true,
          );
          harness.emitCadence(stage, desired: false);

          async.elapse(const Duration(seconds: 59));
          async.flushMicrotasks();
          expect(harness.publishedPayloads, isEmpty, reason: stage.name);

          async.elapse(const Duration(seconds: 1));
          async.flushMicrotasks();
          expect(harness.publishedPayloads, hasLength(1), reason: stage.name);
        });
      }
    });

    test('external relay and ambiguous active stay on normal cadence', () {
      for (final stage in <SosLifecycleStage>[
        SosLifecycleStage.active,
        SosLifecycleStage.recoveryRequired,
      ]) {
        fakeAsync((async) {
          final harness = _Harness();
          harness.start();
          harness.emitCadence(stage, desired: false);

          async.elapse(const Duration(seconds: 20));
          async.flushMicrotasks();
          expect(harness.publishedPayloads, isEmpty, reason: stage.name);
        });
      }
    });

    test('restored local active starts SOS and restored idle starts normal',
        () {
      fakeAsync((async) {
        final active = _Harness();
        active.start(
          stage: SosLifecycleStage.recoveryRequired,
          desired: true,
        );
        final idle = _Harness();
        idle.start();

        async.elapse(const Duration(seconds: 20));
        async.flushMicrotasks();
        expect(active.publishedPayloads, hasLength(1));
        expect(idle.publishedPayloads, isEmpty);

        async.elapse(const Duration(seconds: 40));
        async.flushMicrotasks();
        expect(idle.publishedPayloads, hasLength(1));
      });
    });

    test('no valid location skips publish', () {
      fakeAsync((async) {
        final harness = _Harness(hasInitialPosition: false);
        harness.start();

        async.elapse(const Duration(seconds: 60));
        async.flushMicrotasks();

        expect(harness.publishedPayloads, isEmpty);
        expect(
          harness.logs,
          contains('[SDK_TELEMETRY_LOOP] action=skip reason=no_location'),
        );
      });
    });

    test('publish failure does not stop the loop', () {
      fakeAsync((async) {
        final harness = _Harness();
        harness.publishError = StateError('offline');
        harness.start();

        async.elapse(const Duration(seconds: 60));
        async.flushMicrotasks();
        harness.publishError = null;
        async.elapse(const Duration(seconds: 60));
        async.flushMicrotasks();

        expect(harness.publishCallCount, 2);
        expect(harness.publishedPayloads, hasLength(1));
      });
    });

    test('starting coordinator twice does not create duplicate timers', () {
      fakeAsync((async) {
        final harness = _Harness();
        harness.start();
        harness.start();

        async.elapse(const Duration(seconds: 60));
        async.flushMicrotasks();

        expect(harness.publishedPayloads, hasLength(1));
      });
    });

    test('foreground interval resumes after native owner pause is cleared', () {
      fakeAsync((async) {
        final harness = _Harness();
        harness.start();
        harness.coordinator.setIntervalPublishingEnabled(false);

        async.elapse(const Duration(seconds: 60));
        async.flushMicrotasks();

        expect(harness.publishedPayloads, isEmpty);

        harness.coordinator.setIntervalPublishingEnabled(true);
        async.elapse(const Duration(seconds: 60));
        async.flushMicrotasks();

        expect(harness.publishedPayloads, hasLength(1));
      });
    });

    test('dispose stops timers', () {
      fakeAsync((async) {
        final harness = _Harness();
        harness.start();
        unawaited(harness.coordinator.stop());
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 60));
        async.flushMicrotasks();

        expect(harness.publishedPayloads, isEmpty);
      });
    });
  });
}

class _Harness {
  _Harness({
    TrackingPosition? initialPosition,
    bool hasInitialPosition = true,
  }) : trackingRepository = _FakeTrackingRepository(
          currentPosition:
              hasInitialPosition ? (initialPosition ?? _position()) : null,
        ) {
    coordinator = OperationalTelemetryCoordinator(
      trackingRepository: trackingRepository,
      authoritativeSosCadenceStream: _cadenceController.stream,
      sessionProvider: () => session,
      publishTelemetry: (payload) async {
        publishCallCount++;
        final error = publishError;
        if (error != null) {
          throw error;
        }
        publishedPayloads.add(payload);
      },
      resolvedLocationProvider: () async {
        final position = await trackingRepository.getCurrentPosition();
        return position == null
            ? null
            : SdkResolvedLocation.fromPhoneTrackingPosition(
                position: position,
              );
      },
      clock: () => DateTime.utc(2026, 1, 1),
      logger: logs.add,
    );
  }

  final _cadenceController =
      StreamController<AuthoritativeSosCadence>.broadcast(sync: true);
  final List<SdkTelemetryPayload> publishedPayloads = <SdkTelemetryPayload>[];
  final List<String> logs = <String>[];
  final _FakeTrackingRepository trackingRepository;
  late final OperationalTelemetryCoordinator coordinator;
  EixamSession? session = const EixamSession.signed(
    appId: 'partner-app',
    externalUserId: 'user-1',
    userHash: 'hash-1',
    canonicalExternalUserId: 'canonical-user-1',
  );
  Object? publishError;
  int publishCallCount = 0;
  int lastRevision = 0;

  void start({
    SosLifecycleStage stage = SosLifecycleStage.idle,
    bool desired = false,
  }) {
    coordinator.start(
      initialCadence: AuthoritativeSosCadence(
        lifecycleRevision: lastRevision,
        lifecycleStage: stage,
        desiredLocalSosOwnership: desired,
      ),
    );
  }

  void emitCadence(
    SosLifecycleStage stage, {
    required bool desired,
    int? revision,
  }) {
    lastRevision = revision ?? lastRevision + 1;
    _cadenceController.add(
      AuthoritativeSosCadence(
        lifecycleRevision: lastRevision,
        lifecycleStage: stage,
        desiredLocalSosOwnership: desired,
      ),
    );
  }

  void emitPosition(TrackingPosition position) {
    trackingRepository.emitPosition(position);
  }
}

class _FakeTrackingRepository implements TrackingRepository {
  _FakeTrackingRepository({TrackingPosition? currentPosition})
      : _currentPosition = currentPosition;

  final StreamController<TrackingPosition> _positionsController =
      StreamController<TrackingPosition>.broadcast(sync: true);
  TrackingPosition? _currentPosition;

  @override
  Future<TrackingPosition?> getCurrentPosition() async => _currentPosition;

  @override
  Future<TrackingState> getTrackingState() async => TrackingState.idle;

  @override
  Future<void> startTracking() async {}

  @override
  Future<void> stopTracking() async {}

  @override
  Stream<TrackingPosition> watchPositions() => _positionsController.stream;

  @override
  Stream<TrackingState> watchTrackingState() =>
      const Stream<TrackingState>.empty();

  void emitPosition(TrackingPosition position) {
    _currentPosition = position;
    _positionsController.add(position);
  }
}

TrackingPosition _position({
  double latitude = 41.38,
  double longitude = 2.17,
}) {
  return TrackingPosition(
    latitude: latitude,
    longitude: longitude,
    altitude: 8,
    timestamp: DateTime.utc(2026, 1, 1),
    source: DeliveryMode.mobile,
  );
}
