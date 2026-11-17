import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sos_remote_data_source.dart';
import 'package:eixam_connect_flutter/src/data/dtos/sos_history_dto.dart';
import 'package:eixam_connect_flutter/src/data/dtos/sos_incident_dto.dart';
import 'package:eixam_connect_flutter/src/data/repositories/mqtt_operational_sos_repository.dart';
import 'package:eixam_connect_flutter/src/data/repositories/sos_runtime_rehydration_support.dart';
import 'package:eixam_connect_flutter/src/device/ble_debug_registry.dart';
import 'package:eixam_connect_flutter/src/diagnostics/sdk_release_log.dart';
import 'package:eixam_connect_flutter/src/sdk/operational_realtime_client.dart';
import 'package:eixam_connect_flutter/src/sdk/sdk_mqtt_contract.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes/memory_shared_prefs_sdk_store.dart';

/// F17c review r6 CRITICAL-1 (Roger 17/11/2026): a TAG close frame (0xE1 /
/// 0xE2) settled SOS A locally and a new TAG SOS B started before the backend
/// confirmed A's close. A's late events and REST reads (the backend keeps one
/// open SOS per user and its events carry no client identity) must never be
/// taken as B's: B is never closed, never given A's identity, and its trigger
/// is never retired by them. A missed SOS is worse than a duplicate.
void main() {
  late _Realtime realtime;
  late _Remote remote;
  late MemorySharedPrefsSdkStore store;
  late MqttOperationalSosRepository repository;
  late List<String> releaseLines;

  MqttOperationalSosRepository build() => MqttOperationalSosRepository(
    realtimeClient: realtime,
    remoteDataSource: remote,
    cancelRemoteDataSource: remote,
    localStore: store,
    mqttConfirmationWarningDelay: const Duration(milliseconds: 20),
    cancelConfirmationWait: const Duration(milliseconds: 300),
    deliveryBackoff: const <Duration>[Duration(milliseconds: 10)],
  );

  setUp(() {
    BleDebugRegistry.instance.reset();
    releaseLines = <String>[];
    sdkReleaseLogSinkForTesting = releaseLines.add;
    realtime = _Realtime();
    remote = _Remote();
    store = MemorySharedPrefsSdkStore();
    repository = build();
  });

  tearDown(() async {
    sdkReleaseLogSinkForTesting = null;
    await repository.dispose();
  });

  Future<void> eventually(bool Function() condition) async {
    for (var i = 0; i < 200 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<void> settle([int ms = 60]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  Future<void> restart() async {
    await repository.dispose();
    realtime = _Realtime();
    repository = build();
    await repository.restoreState();
    await settle(100);
  }

  /// A sent (optionally confirmed as `backend-A`), closed by the TAG, then B
  /// triggered and published. Returns the publish timestamps of A and B (the
  /// backend echoes them as `occurredAt`).
  Future<(DateTime, DateTime)> aSentThenB({
    required bool aConfirmed,
    bool aSettledBeforeClose = false,
  }) async {
    await repository.triggerSos(
      triggerSource: 'ble_device_runtime_status',
      originatorNodeId: 7,
      incidentId: 'device-runtime-sos:7:1',
      cycleKey: 'sos:7:1',
    );
    await eventually(() => realtime.publishedSos.isNotEmpty);
    final aPublishedAt = realtime.publishedSos.first.timestamp.toUtc();
    if (aConfirmed) {
      realtime.emit(
        _event('processed', incidentId: 'backend-A', occurredAt: aPublishedAt),
      );
      await eventually(() => !repository.deliveryStatus.pendingTrigger);
      expect((await repository.getCurrentIncident())?.id, 'backend-A');
    }
    await settle(20);
    final closedAt = DateTime.now().toUtc();
    if (aSettledBeforeClose) {
      // (d) a native pending TAG cancel settled A first.
      await repository.deliverDeviceCancel(
        reason: 'native_pending_cancel',
        observedAt: closedAt,
      );
    }
    await repository.closeSosSupersededByTagClose(observedAt: closedAt);
    await settle(5);
    await repository.triggerSos(
      triggerSource: 'ble_device_runtime_status',
      originatorNodeId: 7,
      incidentId: 'device-runtime-sos:7:2',
      cycleKey: 'sos:7:2',
    );
    await eventually(() => realtime.publishedSos.length >= 2);
    final bPublishedAt = realtime.publishedSos.last.timestamp.toUtc();
    expect(bPublishedAt.isAfter(closedAt), isTrue);
    return (aPublishedAt, bPublishedAt);
  }

  Future<void> expectBOpen(String reason) async {
    final state = await repository.getSosState();
    expect(
      state,
      isNot(anyOf(SosState.idle, SosState.cancelled, SosState.resolved)),
      reason: reason,
    );
    final incident = await repository.getCurrentIncident();
    expect(incident, isNotNull, reason: reason);
    expect(incident!.id, isNot('backend-A'), reason: '$reason: never A');
    expect(incident.cycleKey, 'sos:7:2', reason: reason);
  }

  group('F17c r7: a superseded SOS never reaches the new one', () {
    for (final withOccurredAt in <bool>[true, false]) {
      final label = withOccurredAt ? 'occurredAt=A' : 'no occurredAt';
      test('(a) A not confirmed at the TAG close: A\'s late acknowledged then '
          'cancelled ($label) never adopt, confirm or close B', () async {
        final (aAt, _) = await aSentThenB(aConfirmed: false);
        realtime.emit(
          _event(
            'acknowledged',
            incidentId: 'backend-A',
            occurredAt: withOccurredAt ? aAt : null,
          ),
        );
        await settle();
        await expectBOpen('after A acknowledged');
        expect(
          repository.deliveryStatus.pendingTrigger,
          isTrue,
          reason: 'A\'s ack never confirms B\'s trigger',
        );
        realtime.emit(
          _event(
            'cancelled',
            incidentId: 'backend-A',
            occurredAt: withOccurredAt ? aAt : null,
          ),
        );
        await settle();
        await expectBOpen('after A cancelled');
        expect(
          repository.deliveryStatus.pendingTrigger,
          isTrue,
          reason: 'A\'s cancelled never retires B\'s trigger',
        );
      });
    }

    test('(b) A not confirmed: REST returns A while B is open -> B kept; '
        'A\'s cancelled then never ends B', () async {
      final (aAt, _) = await aSentThenB(aConfirmed: false);
      remote.active = _activeDto('backend-A', occurredAt: aAt);
      final result = await repository.rehydrateRuntimeStateFromBackend();
      expect(result.outcome, SosRuntimeRehydrationOutcome.keptLocalFallback);
      await expectBOpen('REST returned A');
      realtime.emit(
        _event('cancelled', incidentId: 'backend-A', occurredAt: aAt),
      );
      await settle();
      await expectBOpen('A cancelled after REST');
    });

    test('(b) REST returns an open incident not provably B (no occurredAt) '
        'while B is unconfirmed -> B kept, never replaced', () async {
      await aSentThenB(aConfirmed: false);
      remote.active = _activeDto('backend-X');
      final result = await repository.rehydrateRuntimeStateFromBackend();
      expect(result.outcome, SosRuntimeRehydrationOutcome.keptLocalFallback);
      await expectBOpen('REST returned an unattributable incident');
    });

    test('(b) R1b: A confirmed; REST returns A; A cancelled; B\'s exact '
        'processed confirms B as itself', () async {
      final (aAt, bAt) = await aSentThenB(aConfirmed: true);
      remote.active = _activeDto('backend-A', occurredAt: aAt);
      final result = await repository.rehydrateRuntimeStateFromBackend();
      expect(result.outcome, SosRuntimeRehydrationOutcome.keptLocalFallback);
      await expectBOpen('REST returned A');
      realtime.emit(
        _event('cancelled', incidentId: 'backend-A', occurredAt: aAt),
      );
      await settle();
      await expectBOpen('A cancelled');
      remote.active = _activeDto('backend-B', occurredAt: bAt);
      realtime.emit(
        _event('processed', incidentId: 'backend-B', occurredAt: bAt),
      );
      await eventually(() => !repository.deliveryStatus.pendingTrigger);
      final incident = await repository.getCurrentIncident();
      expect(incident?.id, 'backend-B');
      expect(incident?.isBackendConfirmed, isTrue);
      expect(await repository.getSosState(), SosState.sent);
    });

    test('(c) R5: A confirmed; app restart before A\'s late events; REST '
        'returns A; A\'s cancelled never ends B', () async {
      final (aAt, _) = await aSentThenB(aConfirmed: true);
      await restart();
      await expectBOpen('restored');
      remote.active = _activeDto('backend-A', occurredAt: aAt);
      final result = await repository.rehydrateRuntimeStateFromBackend();
      expect(result.outcome, SosRuntimeRehydrationOutcome.keptLocalFallback);
      await expectBOpen('REST returned A after restart');
      realtime.emit(
        _event('cancelled', incidentId: 'backend-A', occurredAt: aAt),
      );
      await settle();
      await expectBOpen('A cancelled after restart');
    });

    test(
      '(c) R6: A confirmed; app restart; A\'s cancelled first never '
      'retires B\'s trigger; an absence read with a terminal hint keeps B',
      () async {
        await aSentThenB(aConfirmed: true);
        await restart();
        realtime.emit(_event('cancelled', incidentId: 'backend-A'));
        await settle();
        await expectBOpen('A cancelled after restart');
        expect(
          repository.deliveryStatus.pendingTrigger,
          isTrue,
          reason: 'B\'s trigger is not retired by A\'s cancelled',
        );
        remote.active = null;
        final result = await repository.rehydrateRuntimeStateFromBackend(
          terminalAbsenceExpected: true,
        );
        expect(result.outcome, SosRuntimeRehydrationOutcome.keptLocalFallback);
        await expectBOpen('absence read after A cancelled');
      },
    );

    test('(c) A not confirmed; app restart; A\'s late acknowledged and '
        'cancelled (occurredAt=A) never reach B', () async {
      final (aAt, _) = await aSentThenB(aConfirmed: false);
      await restart();
      realtime.emit(
        _event('acknowledged', incidentId: 'backend-A', occurredAt: aAt),
      );
      await settle();
      realtime.emit(
        _event('cancelled', incidentId: 'backend-A', occurredAt: aAt),
      );
      await settle();
      await expectBOpen('A\'s events after restart');
      expect(repository.deliveryStatus.pendingTrigger, isTrue);
    });

    test('(d) A already settled (native pending cancel) before the TAG close: '
        'A\'s late acknowledged then cancelled never reach B', () async {
      final (aAt, _) = await aSentThenB(
        aConfirmed: false,
        aSettledBeforeClose: true,
      );
      realtime.emit(
        _event('acknowledged', incidentId: 'backend-A', occurredAt: aAt),
      );
      await settle();
      realtime.emit(
        _event('cancelled', incidentId: 'backend-A', occurredAt: aAt),
      );
      await settle();
      await expectBOpen('A\'s events after an already settled close');
      expect(repository.deliveryStatus.pendingTrigger, isTrue);
    });

    test('a backend read for B\'s trigger while A is still open never '
        'confirms B with A', () async {
      final (aAt, _) = await aSentThenB(aConfirmed: false);
      remote.active = _activeDto('backend-A', occurredAt: aAt);
      // Several confirmation windows: the outbox reads the backend.
      await settle(200);
      await expectBOpen('outbox read returned A');
      expect(
        (await repository.getCurrentIncident())?.isBackendConfirmed,
        isFalse,
      );
      expect(repository.deliveryStatus.pendingTrigger, isTrue);
    });

    test('legitimate path kept: after B\'s exact processed, B\'s own '
        'cancelled (its incident id) closes B', () async {
      final (_, bAt) = await aSentThenB(aConfirmed: true);
      realtime.emit(
        _event('processed', incidentId: 'backend-B', occurredAt: bAt),
      );
      await eventually(() => !repository.deliveryStatus.pendingTrigger);
      expect((await repository.getCurrentIncident())?.id, 'backend-B');
      realtime.emit(
        _event('cancelled', incidentId: 'backend-B', occurredAt: bAt),
      );
      await settle();
      expect(
        await repository.getSosState(),
        anyOf(SosState.cancelled, SosState.idle),
      );
    });
  });

  // F17c review r7 MEDIUM-1 (Roger 17/11/2026): the backend merged B into
  // A's still-open incident (A's cancel rejected or dropped): B's own events
  // carry A's incident id with B's exact publish timestamp as `occurredAt`.
  // That exact timestamp is B's, so the id is B's from then on: B's own
  // resolve, REST absence and user cancel close B (before and after a
  // restart). A's own late evidence (A's publish timestamp) stays A's.
  group('F17c r8: B merged into A\'s still-open incident', () {
    Future<DateTime> mergedB() async {
      final (_, bAt) = await aSentThenB(aConfirmed: true);
      remote.active = _activeDto('backend-A', occurredAt: bAt);
      realtime.emit(
        _event('processed', incidentId: 'backend-A', occurredAt: bAt),
      );
      await eventually(() => !repository.deliveryStatus.pendingTrigger);
      return bAt;
    }

    Future<void> expectMergedBConfirmed(
      String reason, {
      bool localCopy = true,
    }) async {
      expect(
        repository.deliveryStatus.pendingTrigger,
        isFalse,
        reason: '$reason: B confirmed',
      );
      final incident = await repository.getCurrentIncident();
      expect(incident?.id, 'backend-A', reason: '$reason: merged id');
      if (localCopy) {
        // A REST hydration replaces the local copy with the backend's (no
        // cycle key): the same SOS by id.
        expect(incident?.cycleKey, 'sos:7:2', reason: '$reason: still B');
      }
      expect(incident?.isBackendConfirmed, isTrue, reason: reason);
      expect(await repository.getSosState(), SosState.sent, reason: reason);
      expect(
        repository.stopGuard.isSupersededIncident('backend-A'),
        isFalse,
        reason: '$reason: the merged id is B\'s now',
      );
    }

    test('B\'s exact processed on A\'s id confirms B; B\'s own resolved '
        'closes B', () async {
      final bAt = await mergedB();
      await expectMergedBConfirmed('processed');
      remote.active = null;
      realtime.emit(
        _event('resolved', incidentId: 'backend-A', occurredAt: bAt),
      );
      await settle();
      expect(
        await repository.getSosState(),
        anyOf(SosState.resolved, SosState.idle),
      );
    });

    test('merged through REST only (no processed reached the phone): the '
        'outbox read and the rehydration take B on A\'s id; B\'s REST '
        'absence then closes B', () async {
      final (_, bAt) = await aSentThenB(aConfirmed: true);
      remote.active = _activeDto('backend-A', occurredAt: bAt);
      await eventually(() => !repository.deliveryStatus.pendingTrigger);
      final hydrated = await repository.rehydrateRuntimeStateFromBackend();
      expect(
        hydrated.outcome,
        SosRuntimeRehydrationOutcome.hydratedFromBackend,
      );
      await expectMergedBConfirmed('rest', localCopy: false);
      remote.active = null;
      final absence = await repository.rehydrateRuntimeStateFromBackend(
        terminalAbsenceExpected: true,
      );
      expect(absence.outcome, SosRuntimeRehydrationOutcome.clearedToIdle);
      expect(await repository.getSosState(), SosState.idle);
    });

    test('merged, then an app restart: B\'s own resolved still closes B',
        () async {
      final bAt = await mergedB();
      await restart();
      final restored = await repository.getCurrentIncident();
      expect(restored?.id, 'backend-A');
      expect(repository.stopGuard.isSupersededIncident('backend-A'), isFalse);
      remote.active = null;
      realtime.emit(
        _event('resolved', incidentId: 'backend-A', occurredAt: bAt),
      );
      await settle();
      expect(
        await repository.getSosState(),
        anyOf(SosState.resolved, SosState.idle),
      );
    });

    test('merged: the user cancel of B is confirmed by B\'s own cancelled',
        () async {
      final bAt = await mergedB();
      final cancel = repository.cancelSos();
      await eventually(() => realtime.publishedCancels.length >= 2);
      remote.active = null;
      realtime.emit(
        _event('cancelled', incidentId: 'backend-A', occurredAt: bAt),
      );
      final cancelled = await cancel;
      expect(cancelled.state, SosState.cancelled);
      expect(
        await repository.getSosState(),
        anyOf(SosState.cancelled, SosState.idle),
      );
    });

    test('merged: a late event carrying A\'s own publish timestamp is still '
        'A\'s (never closes B, never takes the id back)', () async {
      final (aAt, bAt) = await aSentThenB(aConfirmed: true);
      remote.active = _activeDto('backend-A', occurredAt: bAt);
      realtime.emit(
        _event('processed', incidentId: 'backend-A', occurredAt: bAt),
      );
      await eventually(() => !repository.deliveryStatus.pendingTrigger);
      realtime.emit(
        _event('cancelled', incidentId: 'backend-A', occurredAt: aAt),
      );
      await settle();
      await expectMergedBConfirmed('A\'s late cancelled');
      realtime.emit(
        _event('resolved', incidentId: 'backend-A', occurredAt: bAt),
      );
      await settle();
      expect(
        await repository.getSosState(),
        anyOf(SosState.resolved, SosState.idle),
      );
    });
  });

  // F17c review r7 LOW-4: only timestamps this phone published are a
  // superseded SOS's. An SOS from another source (a LoRa gateway, a second
  // phone of the account) whose `occurredAt` is at or before the TAG close
  // (another clock) is never consumed or hidden.
  group('F17c r8: another source\'s SOS right after a TAG close', () {
    test('REST returns another source\'s open SOS with occurredAt before the '
        'close: adopted, never hidden as the closed SOS', () async {
      await repository.triggerSos(
        triggerSource: 'ble_device_runtime_status',
        originatorNodeId: 7,
        incidentId: 'device-runtime-sos:7:1',
        cycleKey: 'sos:7:1',
      );
      await eventually(() => realtime.publishedSos.isNotEmpty);
      realtime.emit(
        _event(
          'processed',
          incidentId: 'backend-A',
          occurredAt: realtime.publishedSos.first.timestamp.toUtc(),
        ),
      );
      await eventually(() => !repository.deliveryStatus.pendingTrigger);
      await settle(20);
      final closedAt = DateTime.now().toUtc();
      await repository.closeSosSupersededByTagClose(observedAt: closedAt);
      // A's close confirmed; another source opened an SOS whose clock is
      // two seconds behind this phone's.
      realtime.emit(_event('cancelled', incidentId: 'backend-A'));
      await settle();
      final otherAt = closedAt.subtract(const Duration(seconds: 2));
      expect(repository.stopGuard.isSupersededOccurrence(otherAt), isFalse);
      remote.active = _activeDto('backend-X', occurredAt: otherAt);
      final result = await repository.rehydrateRuntimeStateFromBackend();
      expect(result.outcome, SosRuntimeRehydrationOutcome.hydratedFromBackend);
      expect((await repository.getCurrentIncident())?.id, 'backend-X');
      expect(repository.stopGuard.isSupersededIncident('backend-X'), isFalse);
    });

    test('LOW-2: the current SOS hydrated from another source: a late event '
        'of the closed SOS (this phone\'s older publish timestamp) is the '
        'closed SOS\'s, never the current one\'s', () async {
      await repository.triggerSos(
        triggerSource: 'ble_device_runtime_status',
        originatorNodeId: 7,
        incidentId: 'device-runtime-sos:7:1',
        cycleKey: 'sos:7:1',
      );
      await eventually(() => realtime.publishedSos.isNotEmpty);
      final aAt = realtime.publishedSos.first.timestamp.toUtc();
      await settle(20);
      await repository.closeSosSupersededByTagClose(
        observedAt: DateTime.now().toUtc(),
      );
      await settle(20);
      final otherAt = DateTime.now().toUtc();
      remote.active = _activeDto('backend-X', occurredAt: otherAt);
      final result = await repository.rehydrateRuntimeStateFromBackend();
      expect(result.outcome, SosRuntimeRehydrationOutcome.hydratedFromBackend);
      realtime.emit(
        _event('cancelled', incidentId: 'backend-A', occurredAt: aAt),
      );
      await settle();
      final incident = await repository.getCurrentIncident();
      expect(incident?.id, 'backend-X');
      expect(
        await repository.getSosState(),
        isNot(anyOf(SosState.idle, SosState.cancelled, SosState.resolved)),
      );
    });
  });
}

SosIncidentDto _activeDto(String id, {DateTime? occurredAt}) {
  final at = (occurredAt ?? DateTime.now()).toUtc().toIso8601String();
  return SosIncidentDto.fromJson(<String, dynamic>{
    'id': id,
    'status': 'active',
    // REST `createdAt` is the server's row time, not the SOS occurrence.
    'createdAt': DateTime.now().toUtc().toIso8601String(),
    if (occurredAt != null) 'occurredAt': at,
    'triggerSource': 'ble_device_runtime_status',
    'owner': 'device',
    'originKind': SosOriginKind.ownDevice.name,
    'actionability': SosActionability.localActionable.name,
    'displaySurface': SosDisplaySurface.activeAndHistory.name,
  });
}

RealtimeEvent _event(
  String type, {
  required String incidentId,
  DateTime? occurredAt,
}) {
  final now = DateTime.now().toUtc();
  return RealtimeEvent(
    type: 'sos.lifecycle',
    timestamp: now,
    payload: <String, dynamic>{
      'type': type,
      'incidentId': incidentId,
      'status': type == 'processed' ? 'active' : type,
      if (occurredAt != null) 'occurredAt': occurredAt.toIso8601String(),
      '_mqttAuthenticatedUserScoped': true,
      '_mqttTopicCategory': 'internal',
    },
  );
}

class _Realtime implements OperationalRealtimeClient {
  final StreamController<RealtimeEvent> _events =
      StreamController<RealtimeEvent>.broadcast();
  final List<MqttOperationalSosRequest> publishedSos =
      <MqttOperationalSosRequest>[];
  final List<DateTime> publishedCancels = <DateTime>[];

  void emit(RealtimeEvent event) => _events.add(event);

  @override
  Future<void> publishOperationalSos(MqttOperationalSosRequest request) async {
    publishedSos.add(request);
  }

  @override
  Future<void> publishOperationalSosCancel({
    required DateTime timestamp,
  }) async {
    publishedCancels.add(timestamp);
  }

  @override
  Future<void> publishTelemetry(SdkTelemetryPayload payload) async {}

  @override
  Future<void> reconnectIfSessionChanged(EixamSession session) async {}

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Stream<RealtimeConnectionState> watchConnectionState() =>
      const Stream<RealtimeConnectionState>.empty();

  @override
  Stream<RealtimeEvent> watchEvents() => _events.stream;
}

class _Remote implements SosRemoteDataSource {
  SosIncidentDto? active;

  @override
  Future<SosIncidentDto> triggerSos({
    String? message,
    required String triggerSource,
    TrackingPosition? positionSnapshot,
    String? deviceId,
    String? hardwareId,
    int? originatorNodeId,
    int? relayNodeId,
    String? relayDeviceId,
    String? relayHardwareId,
    String? relaySource,
    String? incidentId,
    String? cycleKey,
    OsSosWidgetActivation? osWidgetActivation,
    SdkDeviceBatterySnapshot? deviceBattery,
    SdkCoverageSnapshot? deviceCoverage,
    int? mobileBattery,
    SdkCoverageSnapshot? mobileCoverage,
  }) async => throw StateError('REST trigger must never be called');

  @override
  Future<SosIncidentDto?> cancelSos({
    String? deviceId,
    String? source,
    String? triggerSource,
    String? relaySource,
    int? originatorNodeId,
    int? relayNodeId,
    String? relayHardwareId,
    String? incidentId,
    String? cycleKey,
    DateTime? occurredAt,
  }) async => throw StateError('REST cancel must never be called');

  @override
  Future<SosIncidentDto?> resolveSos() async => null;

  @override
  Future<SosIncidentDto?> getActiveSos() async => active;

  @override
  Future<SosHistoryPageDto> listSosHistory({
    String? cursor,
    int limit = 20,
  }) async =>
      const SosHistoryPageDto(items: <SosHistoryItemDto>[], hasMore: false);
}
