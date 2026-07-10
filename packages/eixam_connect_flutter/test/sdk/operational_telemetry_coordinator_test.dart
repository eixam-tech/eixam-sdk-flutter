import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
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

    test('SOS open publishes at 20 seconds even without movement', () {
      fakeAsync((async) {
        final harness = _Harness();
        harness.start();
        harness.emitSosState(SosState.sent);
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
        harness.emitSosState(SosState.sent);
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
        harness.emitSosState(SosState.sent);
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
        harness.emitSosState(SosState.sent);
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 20));
        async.flushMicrotasks();
        harness.emitSosState(SosState.resolved);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 59));
        async.flushMicrotasks();

        expect(harness.publishedPayloads, hasLength(1));

        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();

        expect(harness.publishedPayloads, hasLength(2));
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
      sosStateStream: _sosStateController.stream,
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

  final _sosStateController = StreamController<SosState>.broadcast(sync: true);
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

  void start() {
    coordinator.start(initialSosState: SosState.idle);
  }

  void emitSosState(SosState state) {
    _sosStateController.add(state);
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
