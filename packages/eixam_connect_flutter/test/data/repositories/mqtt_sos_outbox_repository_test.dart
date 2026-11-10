import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sos_remote_data_source.dart';
import 'package:eixam_connect_flutter/src/data/dtos/sos_history_dto.dart';
import 'package:eixam_connect_flutter/src/data/dtos/sos_incident_dto.dart';
import 'package:eixam_connect_flutter/src/data/repositories/mqtt_operational_sos_repository.dart';
import 'package:eixam_connect_flutter/src/device/ble_debug_registry.dart';
import 'package:eixam_connect_flutter/src/diagnostics/sdk_release_log.dart';
import 'package:eixam_connect_flutter/src/sdk/operational_realtime_client.dart';
import 'package:eixam_connect_flutter/src/sdk/sdk_mqtt_contract.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes/memory_shared_prefs_sdk_store.dart';

/// F4/F5 delivery rules at the SOS repository: trigger, cancel and TAG cancel
/// go over MQTT only, survive restarts, are retried until the backend
/// confirms, never duplicate an incident and never show `sent` early.
void main() {
  late _Realtime realtime;
  late _Remote remote;
  late MemorySharedPrefsSdkStore store;
  late MqttOperationalSosRepository repository;

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
    sdkReleaseLogSinkForTesting = (_) {};
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
    expect(condition(), isTrue);
  }

  test('MQTT down at SOS time: no error, state stays sending, delivered on '
      'retry; no REST call ever made', () async {
    realtime.failSosPublishes = 3;

    final incident = await repository.triggerSos(
      triggerSource: 'ble_device_runtime_status',
      originatorNodeId: 7,
      incidentId: 'native-sos-7-2',
      cycleKey: 'sos:7:2',
    );

    expect(incident.state, SosState.sending);
    expect(await repository.getSosState(), SosState.sending);
    expect(repository.deliveryStatus.pendingTrigger, isTrue);

    await eventually(() => realtime.publishedSos.isNotEmpty);
    remote.active = _activeDto('backend-1');
    realtime.emit(_event('processed', incidentId: 'backend-1'));
    await eventually(() => !repository.deliveryStatus.pendingTrigger);

    expect(realtime.sosPublishAttempts, greaterThanOrEqualTo(4));
    expect(await repository.getSosState(), SosState.sent);
    expect(remote.restTriggerCalls, 0);
    expect(remote.restCancelCalls, 0);
  });

  test('MQTT late: every attempt carries the same incident identity, so the '
      'backend upserts one incident', () async {
    realtime.failSosPublishes = 2;
    await repository.triggerSos(
      triggerSource: 'ble_device_runtime_status',
      originatorNodeId: 7,
      incidentId: 'native-sos-7-3',
      cycleKey: 'sos:7:3',
    );
    await eventually(() => realtime.publishedSos.length >= 2);
    remote.active = _activeDto('backend-2');
    realtime.emit(_event('processed', incidentId: 'backend-2'));
    await eventually(() => !repository.deliveryStatus.pendingTrigger);

    expect(
      realtime.attemptedSos.map((r) => '${r.incidentId}|${r.cycleKey}').toSet(),
      {'native-sos-7-3|sos:7:3'},
    );
    expect(remote.restTriggerCalls, 0);
  });

  test('UI never shows sent without backend confirmation: published but '
      'unconfirmed stays sending and reports retrying', () async {
    await repository.dispose();
    repository = MqttOperationalSosRepository(
      realtimeClient: realtime,
      remoteDataSource: remote,
      localStore: store,
      mqttConfirmationWarningDelay: const Duration(milliseconds: 10),
      deliveryBackoff: const <Duration>[Duration(milliseconds: 10)],
      deliveryRetryingAfter: const Duration(milliseconds: 100),
    );
    await repository.triggerSos(triggerSource: 'commercial_app');
    await eventually(() => realtime.publishedSos.length >= 2);

    expect(await repository.getSosState(), SosState.sending);
    expect(repository.deliveryStatus.pendingTrigger, isTrue);
    expect(
      (await repository.getCurrentIncident())!.isBackendConfirmed,
      isFalse,
    );

    // After the retrying threshold the incident says "not sent yet".
    await eventually(() => repository.deliveryStatus.retrying);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final incident = (await repository.getCurrentIncident())!;
    expect(incident.isDeliveryRetrying, isTrue);
    expect(
      incident.progress.steps.first.detailCode,
      'delivery_not_confirmed_retrying',
    );

    // Confirmation clears it.
    remote.active = _activeDto('backend-retry');
    realtime.emit(_event('processed', incidentId: 'backend-retry'));
    await eventually(() => !repository.deliveryStatus.pendingTrigger);
    final confirmed = (await repository.getCurrentIncident())!;
    expect(confirmed.isBackendConfirmed, isTrue);
    expect(
      confirmed.progress.steps.first.detailCode,
      'backend_incident_confirmed',
    );
  });

  test('backend read confirms a delivered SOS when the realtime event is '
      'missed', () async {
    remote.active = null;
    realtime.onSosPublished = () => remote.active = _activeDto('backend-3');

    await repository.triggerSos(triggerSource: 'commercial_app');
    await eventually(() => !repository.deliveryStatus.pendingTrigger);

    expect(await repository.getSosState(), SosState.sent);
    final incident = await repository.getCurrentIncident();
    expect(incident!.isBackendConfirmed, isTrue);
    expect(incident.id, 'backend-3');
  });

  test(
    'app cancel is published over MQTT and backend-confirmed; no REST',
    () async {
      remote.active = _activeDto('backend-4');
      realtime.onSosPublished = () {};
      await repository.triggerSos(triggerSource: 'commercial_app');
      realtime.emit(_event('processed', incidentId: 'backend-4'));
      await eventually(() => !repository.deliveryStatus.pendingTrigger);
      realtime.onSosCancelPublished = () {
        remote.active = null;
        realtime.emit(_event('cancelled', incidentId: 'backend-4'));
      };

      final cancelled = await repository.cancelSos();

      expect(cancelled.state, SosState.cancelled);
      expect(realtime.publishedCancels, hasLength(1));
      expect(repository.deliveryStatus.pendingCancel, isFalse);
      expect(remote.restCancelCalls, 0);
      // Settled by the backend `cancelled` event (terminal, as before).
      expect(
        await repository.getSosState(),
        anyOf(SosState.cancelled, SosState.idle),
      );
    },
  );

  test('TAG cancel while in background (no backend incident known) is '
      'published over MQTT and confirmed by the backend', () async {
    remote.active = _activeDto('backend-5');
    realtime.failCancelPublishes = 2;

    await repository.deliverDeviceCancel(reason: 'native_device_cycle_closed');
    expect(repository.deliveryStatus.pendingCancel, isTrue);
    realtime.onSosCancelPublished = () => remote.active = null;

    await eventually(() => !repository.deliveryStatus.pendingCancel);
    expect(realtime.cancelPublishAttempts, greaterThanOrEqualTo(3));
    expect(remote.restCancelCalls, 0);
  });

  test('cancel before the trigger was ever delivered: the trigger is dropped, '
      'never replayed after the cancel', () async {
    realtime.failSosPublishes = 1000;
    await repository.triggerSos(
      triggerSource: 'ble_device_runtime_status',
      originatorNodeId: 7,
      cycleKey: 'sos:7:6',
    );
    await eventually(() => realtime.sosPublishAttempts >= 1);

    realtime.failSosPublishes = 0;
    await repository.deliverDeviceCancel(reason: 'native_device_cycle_closed');
    await eventually(() => !repository.deliveryStatus.pendingCancel);
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(realtime.publishedSos, isEmpty);
    expect(realtime.publishedCancels, isNotEmpty);
    expect(await repository.getSosState(), SosState.idle);
  });

  test('pending SOS survives a restart and is delivered with the same '
      'identity', () async {
    realtime.failSosPublishes = 1000;
    await repository.triggerSos(
      triggerSource: 'ble_device_runtime_status',
      originatorNodeId: 7,
      incidentId: 'native-sos-7-8',
      cycleKey: 'sos:7:8',
    );
    await eventually(() => realtime.sosPublishAttempts >= 1);
    await repository.dispose();

    final restartedRealtime = _Realtime();
    realtime = restartedRealtime;
    remote.active = null;
    restartedRealtime.onSosPublished = () => remote.active = _activeDto('b-8');
    repository = build();
    await repository.restoreState();

    await eventually(() => restartedRealtime.publishedSos.isNotEmpty);
    expect(restartedRealtime.publishedSos.first.incidentId, 'native-sos-7-8');
    expect(restartedRealtime.publishedSos.first.cycleKey, 'sos:7:8');
    await eventually(() => !repository.deliveryStatus.pendingTrigger);
    expect(remote.restTriggerCalls, 0);
  });

  test('a backend close during trigger retries retires the trigger: no '
      'zombie SOS', () async {
    await repository.triggerSos(
      triggerSource: 'ble_device_runtime_status',
      originatorNodeId: 7,
      cycleKey: 'sos:7:30',
    );
    await eventually(() => realtime.publishedSos.isNotEmpty);
    // `processed` was lost; the operator resolves the incident.
    realtime.emit(_event('resolved', incidentId: 'backend-30'));
    await eventually(() => !repository.deliveryStatus.pendingTrigger);
    final publishes = realtime.publishedSos.length;
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(realtime.publishedSos.length, publishes);
  });

  test('an earlier closed incident never counts as delivery of a new SOS '
      'whose publish was lost', () async {
    remote.historyIncidents = <SosIncidentDto>[_activeDto('earlier-cancelled')];
    await repository.triggerSos(
      triggerSource: 'ble_device_runtime_status',
      originatorNodeId: 7,
      cycleKey: 'sos:7:31',
    );
    await eventually(() => realtime.publishedSos.length >= 3);

    expect(repository.deliveryStatus.pendingTrigger, isTrue);
  });

  test('a pending SOS of another account is never delivered', () async {
    await repository.bindSosRuntimeSessionScope('account-a');
    realtime.failSosPublishes = 1000;
    await repository.triggerSos(
      triggerSource: 'ble_device_runtime_status',
      originatorNodeId: 7,
      cycleKey: 'sos:7:32',
    );
    await repository.dispose();

    final restartedRealtime = _Realtime();
    realtime = restartedRealtime;
    repository = build();
    await repository.restoreState();
    await repository.bindSosRuntimeSessionScope('account-b');
    await eventually(() => !repository.deliveryStatus.pendingTrigger);

    expect(restartedRealtime.publishedSos, isEmpty);
  });

  test(
    'backend rehydration never clears an SOS still being delivered',
    () async {
      realtime.failSosPublishes = 1000;
      await repository.triggerSos(
        triggerSource: 'ble_device_runtime_status',
        originatorNodeId: 7,
        cycleKey: 'sos:7:33',
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await repository.rehydrateRuntimeStateFromBackend();

      expect(await repository.getSosState(), SosState.sending);
      expect((await repository.getCurrentIncident())?.cycleKey, 'sos:7:33');
    },
  );

  test('a TAG cancel observed before the current SOS started does not '
      'settle it', () async {
    final before = DateTime.now().toUtc();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    realtime.failSosPublishes = 1000;
    await repository.triggerSos(
      triggerSource: 'ble_device_runtime_status',
      originatorNodeId: 7,
      cycleKey: 'sos:7:34',
    );

    await repository.deliverDeviceCancel(
      reason: 'native_device_cycle_closed',
      observedAt: before,
    );

    expect(await repository.getSosState(), SosState.sending);
    expect(repository.deliveryStatus.pendingTrigger, isTrue);
  });

  group('confirmation belongs to the same incident (M1)', () {
    test('a late event of an incident already seen closed never confirms a '
        'new SOS', () async {
      // Previous SOS: closed by the backend, seen by this phone.
      realtime.emit(_event('cancelled', incidentId: 'old-a'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      remote.active = null;

      await repository.triggerSos(
        triggerSource: 'ble_device_runtime_status',
        originatorNodeId: 7,
        cycleKey: 'sos:7:40',
      );
      await eventually(() => realtime.publishedSos.isNotEmpty);
      // QoS1 redelivery / actuator update of the closed incident.
      realtime.emit(_event('acknowledged', incidentId: 'old-a'));
      realtime.emit(_event('processed', incidentId: 'old-a'));
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(repository.deliveryStatus.pendingTrigger, isTrue);
      expect(await repository.getSosState(), SosState.sending);
    });

    test('an event received before the trigger ever reached the broker is '
        'not its confirmation', () async {
      realtime.failSosPublishes = 1000;
      remote.active = null;
      await repository.triggerSos(
        triggerSource: 'ble_device_runtime_status',
        originatorNodeId: 7,
        cycleKey: 'sos:7:41',
      );
      await eventually(() => realtime.sosPublishAttempts >= 1);

      realtime.emit(_event('processed', incidentId: 'someone-else'));
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(repository.deliveryStatus.pendingTrigger, isTrue);
    });

    test('a repeated close of an earlier incident never confirms a TAG '
        'cancel of the open SOS', () async {
      realtime.emit(_event('cancelled', incidentId: 'old-c'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // The open SOS the TAG cancels; the backend has not closed it yet.
      remote.active = _activeDto('open-d');
      realtime.onSosCancelPublished = () =>
          realtime.emit(_event('cancelled', incidentId: 'old-c'));

      await repository.deliverDeviceCancel(
        reason: 'native_device_cycle_closed',
      );
      await eventually(() => realtime.publishedCancels.length >= 2);

      expect(repository.deliveryStatus.pendingCancel, isTrue);

      // The real close of the open SOS confirms it.
      realtime.onSosCancelPublished = () {
        remote.active = null;
        realtime.emit(_event('cancelled', incidentId: 'open-d'));
      };
      await eventually(() => !repository.deliveryStatus.pendingCancel);
    });

    test('a cancel is not confirmed by a close that arrived before its own '
        'publish', () async {
      remote.active = _activeDto('open-e');
      realtime.failCancelPublishes = 1000;
      await repository.deliverDeviceCancel(
        reason: 'native_device_cycle_closed',
      );
      await eventually(() => realtime.cancelPublishAttempts >= 1);

      realtime.emit(_event('resolved', incidentId: 'other-f'));
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(repository.deliveryStatus.pendingCancel, isTrue);
    });

    test('a late close of an incident whose cancel the backend read confirmed '
        'never retires the next SOS', () async {
      remote.active = _activeDto('backend-g');
      await repository.triggerSos(triggerSource: 'commercial_app');
      realtime.emit(_event('processed', incidentId: 'backend-g'));
      await eventually(() => !repository.deliveryStatus.pendingTrigger);
      // Cancel confirmed by GET /v1/sdk/sos only (event missed).
      realtime.onSosCancelPublished = () => remote.active = null;
      await repository.cancelSos();
      await eventually(() => !repository.deliveryStatus.pendingCancel);

      realtime.onSosCancelPublished = null;
      await repository.triggerSos(
        triggerSource: 'ble_device_runtime_status',
        originatorNodeId: 7,
        cycleKey: 'sos:7:42',
      );
      await eventually(() => realtime.publishedSos.length >= 3);
      realtime.emit(_event('cancelled', incidentId: 'backend-g'));
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(repository.deliveryStatus.pendingTrigger, isTrue);
    });
  });
}

SosIncidentDto _activeDto(String id) => SosIncidentDto(
  id: id,
  state: SosState.sent.name,
  createdAt: DateTime.now().toUtc().toIso8601String(),
  triggerSource: 'commercial_app',
  owner: 'app',
  originKind: SosOriginKind.app.name,
  actionability: SosActionability.localActionable.name,
  displaySurface: SosDisplaySurface.activeAndHistory.name,
);

RealtimeEvent _event(String type, {required String incidentId}) {
  final now = DateTime.now().toUtc();
  return RealtimeEvent(
    type: 'sos.lifecycle',
    timestamp: now,
    payload: <String, dynamic>{
      'type': type,
      'incidentId': incidentId,
      'status': type == 'processed' ? 'active' : type,
      'occurredAt': now.toIso8601String(),
      '_mqttAuthenticatedUserScoped': true,
      '_mqttTopicCategory': 'internal',
    },
  );
}

class _Realtime implements OperationalRealtimeClient {
  final StreamController<RealtimeEvent> _events =
      StreamController<RealtimeEvent>.broadcast();
  final List<MqttOperationalSosRequest> attemptedSos =
      <MqttOperationalSosRequest>[];
  final List<MqttOperationalSosRequest> publishedSos =
      <MqttOperationalSosRequest>[];
  final List<DateTime> publishedCancels = <DateTime>[];
  int failSosPublishes = 0;
  int failCancelPublishes = 0;
  int sosPublishAttempts = 0;
  int cancelPublishAttempts = 0;
  void Function()? onSosPublished;
  void Function()? onSosCancelPublished;

  void emit(RealtimeEvent event) => _events.add(event);

  @override
  Future<void> publishOperationalSos(MqttOperationalSosRequest request) async {
    sosPublishAttempts++;
    attemptedSos.add(request);
    if (sosPublishAttempts <= failSosPublishes) {
      throw const NetworkException('E_MQTT_NOT_CONNECTED', 'down');
    }
    publishedSos.add(request);
    onSosPublished?.call();
  }

  @override
  Future<void> publishOperationalSosCancel({
    required DateTime timestamp,
  }) async {
    cancelPublishAttempts++;
    if (cancelPublishAttempts <= failCancelPublishes) {
      throw const NetworkException('E_MQTT_NOT_CONNECTED', 'down');
    }
    publishedCancels.add(timestamp);
    onSosCancelPublished?.call();
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
  int restTriggerCalls = 0;
  int restCancelCalls = 0;

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
  }) async {
    restTriggerCalls++;
    throw StateError('REST trigger must never be called');
  }

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
  }) async {
    restCancelCalls++;
    throw StateError('REST cancel must never be called');
  }

  @override
  Future<SosIncidentDto?> resolveSos() async => null;

  @override
  Future<SosIncidentDto?> getActiveSos() async => active;

  List<SosIncidentDto> historyIncidents = <SosIncidentDto>[];

  @override
  Future<SosHistoryPageDto> listSosHistory({
    String? cursor,
    int limit = 20,
  }) async => SosHistoryPageDto(
    items: historyIncidents
        .map((incident) => SosHistoryItemDto(incident: incident))
        .toList(),
    hasMore: false,
  );
}
