import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/sdk/android_tracking_owner_arbiter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late _TrackingRepository repository;
  late AndroidTrackingOwnerArbiter arbiter;

  setUp(() {
    repository = _TrackingRepository();
    arbiter = AndroidTrackingOwnerArbiter(
      trackingRepository: repository,
    );
  });

  tearDown(() => arbiter.dispose());

  test('starts once for the first distinct owner and stops for the final owner',
      () async {
    expect(arbiter.diagnostics.requestedOwners, isEmpty);
    expect(arbiter.diagnostics.appliedRunning, isFalse);

    await arbiter.addOwner(AndroidTrackingOwner.legacyPublicTracking);
    await arbiter.addOwner(AndroidTrackingOwner.legacyPublicTracking);
    await arbiter.addOwner(AndroidTrackingOwner.sos);

    expect(repository.startCount, 1);
    expect(repository.maxConcurrentStreams, 1);

    await arbiter.removeOwner(AndroidTrackingOwner.sos);
    await arbiter.removeOwner(AndroidTrackingOwner.sos);
    expect(repository.stopCount, 0);

    await arbiter.removeOwner(AndroidTrackingOwner.legacyPublicTracking);
    expect(repository.stopCount, 1);
    expect(arbiter.diagnostics.requestedOwners, isEmpty);
  });

  test('SOS alone starts and stops idempotently', () async {
    await arbiter.addOwner(AndroidTrackingOwner.sos);
    await arbiter.addOwner(AndroidTrackingOwner.sos);
    await arbiter.removeOwner(AndroidTrackingOwner.sos);
    await arbiter.removeOwner(AndroidTrackingOwner.sos);

    expect(repository.startCount, 1);
    expect(repository.stopCount, 1);
  });

  test('failed start retains desired owner and reconciliation retries',
      () async {
    repository.failNextStart = true;

    await expectLater(
      arbiter.addOwner(AndroidTrackingOwner.sos),
      throwsA(isA<TrackingException>()),
    );

    expect(
      arbiter.diagnostics.requestedOwners,
      <AndroidTrackingOwner>{AndroidTrackingOwner.sos},
    );
    expect(arbiter.diagnostics.appliedRunning, isFalse);
    expect(arbiter.diagnostics.startAttemptCount, 1);

    await arbiter.reconcile();

    expect(repository.startCount, 2);
    expect(arbiter.diagnostics.appliedRunning, isTrue);
    expect(arbiter.diagnostics.reconciliationCount, 1);
  });

  test('failed stop stays applied and later reconciliation retries', () async {
    await arbiter.addOwner(AndroidTrackingOwner.sos);
    repository.failNextStop = true;

    await expectLater(
      arbiter.removeOwner(AndroidTrackingOwner.sos),
      throwsA(isA<TrackingException>()),
    );

    expect(arbiter.diagnostics.requestedOwners, isEmpty);
    expect(arbiter.diagnostics.appliedRunning, isTrue);

    await arbiter.reconcile();

    expect(repository.stopCount, 2);
    expect(arbiter.diagnostics.appliedRunning, isFalse);
  });

  test('reconciliation restarts an externally stopped repository', () async {
    await arbiter.addOwner(AndroidTrackingOwner.sos);
    repository.state = TrackingState.idle;
    repository.activeStreams = 0;

    await arbiter.reconcile();

    expect(repository.startCount, 2);
    expect(repository.maxConcurrentStreams, 1);
  });

  test('legacy owner survives SOS removal and disposal seals ownership',
      () async {
    await arbiter.addOwner(AndroidTrackingOwner.legacyPublicTracking);
    await arbiter.addOwner(AndroidTrackingOwner.sos);
    await arbiter.removeOwner(AndroidTrackingOwner.sos);

    expect(
      arbiter.diagnostics.requestedOwners,
      <AndroidTrackingOwner>{AndroidTrackingOwner.legacyPublicTracking},
    );
    expect(repository.stopCount, 0);

    await arbiter.dispose();
    expect(arbiter.diagnostics.requestedOwners, isEmpty);
    expect(arbiter.diagnostics.disposed, isTrue);
    expect(
      () => arbiter.addOwner(AndroidTrackingOwner.sos),
      throwsStateError,
    );
  });
}

final class _TrackingRepository implements TrackingRepository {
  int startCount = 0;
  int stopCount = 0;
  int activeStreams = 0;
  int maxConcurrentStreams = 0;
  bool failNextStart = false;
  bool failNextStop = false;
  TrackingState state = TrackingState.idle;

  @override
  Future<TrackingPosition?> getCurrentPosition() async => null;

  @override
  Future<TrackingState> getTrackingState() async => state;

  @override
  Future<void> startTracking() async {
    startCount += 1;
    if (failNextStart) {
      failNextStart = false;
      throw const TrackingException('E_TRACKING_START_ERROR', 'controlled');
    }
    activeStreams = 1;
    maxConcurrentStreams = activeStreams > maxConcurrentStreams
        ? activeStreams
        : maxConcurrentStreams;
    state = TrackingState.tracking;
  }

  @override
  Future<void> stopTracking() async {
    stopCount += 1;
    if (failNextStop) {
      failNextStop = false;
      throw const TrackingException('E_TRACKING_STOP_ERROR', 'controlled');
    }
    activeStreams = 0;
    state = TrackingState.idle;
  }

  @override
  Stream<TrackingPosition> watchPositions() => const Stream.empty();

  @override
  Stream<TrackingState> watchTrackingState() => const Stream.empty();
}
