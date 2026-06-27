import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/shared_prefs_sdk_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sos_remote_data_source.dart';
import 'package:eixam_connect_flutter/src/data/dtos/sos_history_dto.dart';
import 'package:eixam_connect_flutter/src/data/dtos/sos_incident_dto.dart';
import 'package:eixam_connect_flutter/src/data/repositories/mqtt_operational_sos_repository.dart';
import 'package:eixam_connect_flutter/src/device/ble_debug_registry.dart';
import 'package:eixam_connect_flutter/src/sdk/operational_realtime_client.dart';
import 'package:eixam_connect_flutter/src/sdk/sdk_mqtt_contract.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes/memory_shared_prefs_sdk_store.dart';

void main() {
  group('MqttOperationalSosRepository lifecycle authority', () {
    late _FakeOperationalRealtimeClient realtimeClient;
    late MqttOperationalSosRepository repository;

    setUp(() {
      BleDebugRegistry.instance.reset();
      realtimeClient = _FakeOperationalRealtimeClient();
      repository = MqttOperationalSosRepository(
        realtimeClient: realtimeClient,
      );
    });

    tearDown(() async {
      await repository.dispose();
      await realtimeClient.dispose();
      BleDebugRegistry.instance.reset();
    });

    test('clears stale restored open state without incident and publishes SOS',
        () async {
      final remoteDataSource = _FakeSosRemoteDataSource();
      final store = MemorySharedPrefsSdkStore()
        ..stringValues[SharedPrefsSdkStore.sosStateKey] = SosState.sent.name;
      await repository.dispose();
      repository = MqttOperationalSosRepository(
        realtimeClient: realtimeClient,
        remoteDataSource: remoteDataSource,
        localStore: store,
      );
      await repository.restoreState();

      final incident = await repository.triggerSos(
        triggerSource: 'commercial_app',
      );

      expect(incident.state, SosState.sent);
      expect(realtimeClient.publishedSos, hasLength(1));
      expect(remoteDataSource.getActiveSosCalls, 1);
      expect(await repository.getSosState(), SosState.sent);
      expect(_hasDiagnostic('SOS_ALREADY_ACTIVE_GUARD_CHECK'), isTrue);
      expect(_hasDiagnostic('SOS_ALREADY_ACTIVE_GUARD_STALE_CLEARED'), isTrue);
      expect(_hasDiagnostic('SOS_TRIGGER_CONTINUES_AFTER_STALE_GUARD_CLEAR'),
          isTrue);
    });

    test('keeps duplicate protection for real active local incident', () async {
      await _triggerAppSos(repository);
      final publishCount = realtimeClient.publishedSos.length;

      await expectLater(
        repository.triggerSos(triggerSource: 'commercial_app'),
        throwsA(
          isA<SosException>().having(
            (error) => error.code,
            'code',
            'E_SOS_ALREADY_ACTIVE',
          ),
        ),
      );

      expect(realtimeClient.publishedSos, hasLength(publishCount));
      expect(await repository.getSosState(), SosState.sent);
      expect(_hasDiagnostic('SOS_ALREADY_ACTIVE_GUARD_BLOCKED'), isTrue);
    });

    test('keeps duplicate protection when backend rehydrates active SOS',
        () async {
      final remoteDataSource = _FakeSosRemoteDataSource()
        ..active = _localActiveDto(id: 'backend-active-sos');
      final store = MemorySharedPrefsSdkStore()
        ..stringValues[SharedPrefsSdkStore.sosStateKey] = SosState.sent.name;
      await repository.dispose();
      repository = MqttOperationalSosRepository(
        realtimeClient: realtimeClient,
        remoteDataSource: remoteDataSource,
        localStore: store,
      );
      await repository.restoreState();

      await expectLater(
        repository.triggerSos(triggerSource: 'commercial_app'),
        throwsA(
          isA<SosException>().having(
            (error) => error.code,
            'code',
            'E_SOS_ALREADY_ACTIVE',
          ),
        ),
      );

      expect(realtimeClient.publishedSos, isEmpty);
      expect(await repository.getSosState(), SosState.sent);
      expect((await repository.getCurrentIncident())!.id, 'backend-active-sos');
      expect(_hasDiagnostic('SOS_ALREADY_ACTIVE_GUARD_BLOCKED'), isTrue);
    });

    test('does not clear cancel-pending state as stale', () async {
      final remoteDataSource = _FakeSosRemoteDataSource();
      final store = MemorySharedPrefsSdkStore()
        ..stringValues[SharedPrefsSdkStore.sosStateKey] =
            SosState.cancelRequested.name;
      await repository.dispose();
      repository = MqttOperationalSosRepository(
        realtimeClient: realtimeClient,
        remoteDataSource: remoteDataSource,
        localStore: store,
      );
      await repository.restoreState();

      await expectLater(
        repository.triggerSos(triggerSource: 'commercial_app'),
        throwsA(
          isA<SosException>().having(
            (error) => error.code,
            'code',
            'E_SOS_ALREADY_ACTIVE',
          ),
        ),
      );

      expect(realtimeClient.publishedSos, isEmpty);
      expect(await repository.getSosState(), SosState.cancelRequested);
      expect(_hasDiagnostic('SOS_ALREADY_ACTIVE_GUARD_BLOCKED'), isTrue);
    });

    test(
        'does not promote external backend evidence while clearing stale guard',
        () async {
      final remoteDataSource = _FakeSosRemoteDataSource()
        ..active = _externalActiveDto(id: 'remote-relay-history-sos');
      final store = MemorySharedPrefsSdkStore()
        ..stringValues[SharedPrefsSdkStore.sosStateKey] = SosState.sent.name;
      await repository.dispose();
      repository = MqttOperationalSosRepository(
        realtimeClient: realtimeClient,
        remoteDataSource: remoteDataSource,
        localStore: store,
      );
      await repository.restoreState();

      final incident = await repository.triggerSos(
        triggerSource: 'commercial_app',
      );

      expect(realtimeClient.publishedSos, hasLength(1));
      expect(incident.id, isNot('remote-relay-history-sos'));
      final current = await repository.getCurrentIncident();
      expect(current?.id, isNot('remote-relay-history-sos'));
      expect(_hasDiagnostic('SOS_ALREADY_ACTIVE_GUARD_STALE_CLEARED'), isTrue);
      expect(
          _hasDiagnostic(
              'SOS_ORIGIN_DECISION source=mqtt_repository_rehydrate'),
          isTrue);
    });

    test('accepts matching active incidentId lifecycle update', () async {
      final incident = await _triggerAppSos(repository);

      realtimeClient.emitEvent(_lifecycleEvent(
        incidentId: incident.id,
        state: 'acknowledged',
      ));
      await _pumpRealtime();

      expect(await repository.getSosState(), SosState.acknowledged);
      expect(
          _hasDiagnostic('MQTT_SOS_LIFECYCLE_ACCEPTED_ACTIVE_INCIDENT_MATCH'),
          isTrue);
    });

    test('accepts matching correlationId lifecycle update', () async {
      final incident = await _triggerAppSos(repository);
      final correlationId = _lastCorrelationId();

      realtimeClient.emitEvent(_lifecycleEvent(
        incidentId: 'backend-correlation-incident',
        state: 'acknowledged',
        correlationId: correlationId,
      ));
      await _pumpRealtime();

      final current = await repository.getCurrentIncident();
      expect(current!.id, 'backend-correlation-incident');
      expect(current.state, SosState.acknowledged);
      expect(incident.id, isNot(current.id));
      expect(_hasDiagnostic('MQTT_SOS_LIFECYCLE_ACCEPTED_CORRELATION_MATCH'),
          isTrue);
    });

    test('accepts matching cycleKey lifecycle update', () async {
      await _triggerAppSos(repository, cycleKey: 'cycle-local-1');

      realtimeClient.emitEvent(_lifecycleEvent(
        incidentId: 'backend-cycle-incident',
        state: 'acknowledged',
        cycleKey: 'cycle-local-1',
      ));
      await _pumpRealtime();

      final current = await repository.getCurrentIncident();
      expect(current!.id, 'backend-cycle-incident');
      expect(current.state, SosState.acknowledged);
      expect(_hasDiagnostic('MQTT_SOS_LIFECYCLE_ACCEPTED_CYCLE_MATCH'), isTrue);
    });

    test('rejects mismatched incidentId without correlation or cycle proof',
        () async {
      final incident = await _triggerAppSos(repository);

      realtimeClient.emitEvent(_lifecycleEvent(
        incidentId: 'other-incident',
        state: 'cancelled',
      ));
      await _pumpRealtime();

      final current = await repository.getCurrentIncident();
      expect(current!.id, incident.id);
      expect(current.state, SosState.sent);
      expect(await repository.getSosState(), SosState.sent);
      expect(_hasDiagnostic('MQTT_SOS_LIFECYCLE_REJECTED_IDENTITY_MISMATCH'),
          isTrue);
    });

    test('rejects external remote_lora_relay lifecycle for local active SOS',
        () async {
      final incident = await _triggerAppSos(repository);

      realtimeClient.emitEvent(_lifecycleEvent(
        incidentId: incident.id,
        state: 'cancelled',
        source: 'remote_lora_relay',
        actionability: 'externalOnly',
        displaySurface: 'historyOnly',
      ));
      await _pumpRealtime();

      final current = await repository.getCurrentIncident();
      expect(current!.id, incident.id);
      expect(current.state, SosState.sent);
      expect(await repository.getSosState(), SosState.sent);
      expect(
          _hasDiagnostic('MQTT_SOS_LIFECYCLE_REJECTED_EXTERNAL_ONLY'), isTrue);
    });

    test('leaves external remote_lora_relay lifecycle history-only when idle',
        () async {
      realtimeClient.emitEvent(_lifecycleEvent(
        incidentId: 'remote-history-incident',
        state: 'sent',
        source: 'remote_lora_relay',
        actionability: 'externalOnly',
        displaySurface: 'historyOnly',
      ));
      await _pumpRealtime();

      expect(await repository.getSosState(), SosState.idle);
      expect(await repository.getCurrentIncident(), isNull);
      expect(
          _hasDiagnostic('MQTT_SOS_LIFECYCLE_REJECTED_EXTERNAL_ONLY'), isTrue);
    });

    test('accepts actuator_update for matching active incident', () async {
      final incident = await _triggerAppSos(repository);

      realtimeClient.emitEvent(_actuatorEvent(
        incidentId: incident.id,
        snapshotVersion: 7,
      ));
      await _pumpRealtime();

      final current = await repository.getCurrentIncident();
      expect(current!.actuators!.snapshotVersion, 7);
      expect(_hasDiagnostic('SOS_ACTUATOR_UPDATE_ACCEPTED'), isTrue);
    });

    test('ignores actuator_update for mismatched incident', () async {
      await _triggerAppSos(repository);

      realtimeClient.emitEvent(_actuatorEvent(
        incidentId: 'other-incident',
        snapshotVersion: 7,
      ));
      await _pumpRealtime();

      final current = await repository.getCurrentIncident();
      expect(current!.actuators, isNull);
      expect(_hasDiagnostic('SOS_ACTUATOR_UPDATE_IGNORED'), isTrue);
    });

    test('preserves app-origin local lifecycle flow', () async {
      final incident = await _triggerAppSos(repository);

      realtimeClient.emitEvent(_lifecycleEvent(
        incidentId: incident.id,
        state: 'acknowledged',
        source: 'button_ui',
        triggerSource: 'button_ui',
        actionability: 'localActionable',
        displaySurface: 'activeAndHistory',
      ));
      await _pumpRealtime();

      expect(await repository.getSosState(), SosState.acknowledged);
    });

    test('preserves own BLE-device-origin lifecycle flow', () async {
      final incident = await repository.triggerSos(
        triggerSource: 'ble_device_runtime_status',
        positionSnapshot: _position(),
        deviceId: 'local-device',
        hardwareId: 'AA:BB:CC:DD:EE:FF',
        originatorNodeId: 42,
        cycleKey: 'sos:42:9',
      );

      realtimeClient.emitEvent(_lifecycleEvent(
        incidentId: incident.id,
        state: 'acknowledged',
        triggerSource: 'ble_device_runtime_status',
        actionability: 'localActionable',
        displaySurface: 'activeAndHistory',
      ));
      await _pumpRealtime();

      expect(await repository.getSosState(), SosState.acknowledged);
    });
  });
}

Future<SosIncident> _triggerAppSos(
  MqttOperationalSosRepository repository, {
  String? cycleKey,
}) {
  return repository.triggerSos(
    triggerSource: 'button_ui',
    cycleKey: cycleKey,
  );
}

RealtimeEvent _lifecycleEvent({
  required String incidentId,
  required String state,
  String? clientIncidentId,
  String? correlationId,
  String? cycleKey,
  String? source,
  String? triggerSource,
  String? actionability,
  String? displaySurface,
}) {
  return RealtimeEvent(
    type: 'sos.lifecycle',
    timestamp: DateTime.utc(2026, 6, 21),
    payload: <String, dynamic>{
      'type': 'sos.lifecycle',
      'incidentId': incidentId,
      'state': state,
      if (clientIncidentId != null) 'clientIncidentId': clientIncidentId,
      if (correlationId != null) 'correlationId': correlationId,
      if (cycleKey != null) 'cycleKey': cycleKey,
      if (source != null) 'source': source,
      if (triggerSource != null) 'triggerSource': triggerSource,
      if (actionability != null) 'actionability': actionability,
      if (displaySurface != null) 'displaySurface': displaySurface,
    },
  );
}

RealtimeEvent _actuatorEvent({
  required String incidentId,
  required int snapshotVersion,
}) {
  return RealtimeEvent(
    type: 'sos.actuator_update',
    timestamp: DateTime.utc(2026, 6, 21),
    payload: <String, dynamic>{
      'type': 'sos.actuator_update',
      'incidentId': incidentId,
      'snapshotVersion': snapshotVersion,
      'actuators': const <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'contacts',
          'type': 'emergency_contacts',
          'status': 'sent',
          'outcome': 'success',
        },
      ],
    },
  );
}

TrackingPosition _position() {
  return TrackingPosition(
    latitude: 41.3874,
    longitude: 2.1686,
    timestamp: DateTime.utc(2026, 6, 21),
    source: DeliveryMode.mobile,
  );
}

String _lastCorrelationId() {
  final messages = BleDebugRegistry.instance.currentState.events
      .map((event) => event.message)
      .where((message) => message.contains('correlationId='))
      .toList();
  expect(messages, isNotEmpty);
  final match = RegExp(r'correlationId=([^\s]+)').firstMatch(messages.last);
  expect(match, isNotNull);
  return match!.group(1)!;
}

bool _hasDiagnostic(String token) {
  return BleDebugRegistry.instance.currentState.events.any(
    (event) => event.message.contains(token),
  );
}

SosIncidentDto _localActiveDto({required String id}) {
  return SosIncidentDto(
    id: id,
    state: SosState.sent.name,
    createdAt: DateTime.utc(2026, 6, 21).toIso8601String(),
    triggerSource: 'commercial_app',
    owner: 'app',
    originKind: SosOriginKind.app.name,
    actionability: SosActionability.localActionable.name,
    displaySurface: SosDisplaySurface.activeAndHistory.name,
  );
}

SosIncidentDto _externalActiveDto({required String id}) {
  return SosIncidentDto(
    id: id,
    state: SosState.sent.name,
    createdAt: DateTime.utc(2026, 6, 21).toIso8601String(),
    source: 'remote_lora_relay',
    triggerSource: 'remote_lora_relay',
    relaySource: 'remote_lora_relay',
    owner: 'external',
    originKind: SosOriginKind.remoteRelay.name,
    actionability: SosActionability.externalOnly.name,
    displaySurface: SosDisplaySurface.historyOnly.name,
  );
}

Future<void> _pumpRealtime() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

final class _FakeSosRemoteDataSource implements SosRemoteDataSource {
  SosIncidentDto? active;
  int getActiveSosCalls = 0;

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
    active = _localActiveDto(id: incidentId ?? 'backend-triggered-sos');
    return active!;
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
    final cancelled = active?.copyWith(state: SosState.cancelled.name);
    active = cancelled;
    return cancelled;
  }

  @override
  Future<SosIncidentDto?> resolveSos() async {
    final resolved = active?.copyWith(state: SosState.resolved.name);
    active = resolved;
    return resolved;
  }

  @override
  Future<SosIncidentDto?> getActiveSos() async {
    getActiveSosCalls += 1;
    return active;
  }

  @override
  Future<SosHistoryPageDto> listSosHistory({
    String? cursor,
    int limit = 20,
  }) async {
    return const SosHistoryPageDto(items: [], hasMore: false);
  }
}

class _FakeOperationalRealtimeClient implements OperationalRealtimeClient {
  final StreamController<RealtimeConnectionState> _connectionController =
      StreamController<RealtimeConnectionState>.broadcast();
  final StreamController<RealtimeEvent> _eventController =
      StreamController<RealtimeEvent>.broadcast();
  final List<MqttOperationalSosRequest> publishedSos =
      <MqttOperationalSosRequest>[];
  final List<SdkTelemetryPayload> publishedTelemetry = <SdkTelemetryPayload>[];

  @override
  Future<void> connect() async {
    _connectionController.add(RealtimeConnectionState.connected);
  }

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> publishOperationalSos(MqttOperationalSosRequest request) async {
    publishedSos.add(request);
  }

  @override
  Future<void> publishTelemetry(SdkTelemetryPayload payload) async {
    publishedTelemetry.add(payload);
  }

  @override
  Future<void> reconnectIfSessionChanged(EixamSession session) async {}

  @override
  Stream<RealtimeConnectionState> watchConnectionState() {
    return _connectionController.stream;
  }

  @override
  Stream<RealtimeEvent> watchEvents() {
    return _eventController.stream;
  }

  void emitEvent(RealtimeEvent event) {
    _eventController.add(event);
  }

  Future<void> dispose() async {
    await _connectionController.close();
    await _eventController.close();
  }
}
