import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/datasources_local/shared_prefs_sdk_store.dart';
import 'package:eixam_connect_flutter/src/data/datasources_remote/sos_remote_data_source.dart';
import 'package:eixam_connect_flutter/src/data/dtos/sos_history_dto.dart';
import 'package:eixam_connect_flutter/src/data/dtos/sos_incident_dto.dart';
import 'package:eixam_connect_flutter/src/data/repositories/mqtt_operational_sos_repository.dart';
import 'package:eixam_connect_flutter/src/data/repositories/sos_runtime_rehydration_support.dart';
import 'package:eixam_connect_flutter/src/device/ble_debug_registry.dart';
import 'package:eixam_connect_flutter/src/mappers/local_state_serializers.dart';
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
      expect(remoteDataSource.getActiveSosCalls, greaterThanOrEqualTo(1));
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
      final correlationId = repository.debugLastTrustedCorrelationId;
      expect(correlationId, isNotNull);

      realtimeClient.emitEvent(_lifecycleEvent(
        incidentId: 'backend-correlation-incident',
        state: 'acknowledged',
        correlationId: correlationId!,
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

    test('settles active to cancelled through validated transition path',
        () async {
      final incident = await _triggerAppSos(repository);
      final states = <SosState>[];
      final subscription = repository.watchSosState().listen(states.add);

      realtimeClient.emitEvent(_lifecycleEvent(
        incidentId: incident.id,
        state: 'cancelled',
        terminalReason: SosTerminalReason.cancelledByUser.name,
      ));
      await _pumpRealtime();

      expect(await repository.getSosState(), SosState.cancelled);
      expect(
          states,
          containsAllInOrder(<SosState>[
            SosState.cancelRequested,
            SosState.cancelled,
          ]));
      final current = await repository.getCurrentIncident();
      expect(current!.state, SosState.cancelled);
      expect(current.terminalReason, SosTerminalReason.cancelledByUser);
      expect(_hasDiagnostic('accepted_via_valid_path'), isTrue);
      await subscription.cancel();
    });

    test('settles active to resolved with typed terminal reason', () async {
      final incident = await _triggerAppSos(repository);

      realtimeClient.emitEvent(_lifecycleEvent(
        incidentId: incident.id,
        state: 'resolved',
        terminalReason: SosTerminalReason.backendRejected.name,
      ));
      await _pumpRealtime();

      expect(await repository.getSosState(), SosState.resolved);
      final current = await repository.getCurrentIncident();
      expect(current!.state, SosState.resolved);
      expect(current.terminalReason, SosTerminalReason.backendRejected);
    });

    test('rejects unsupported live terminal transition without mutation',
        () async {
      final incident = await _triggerAppSos(repository);

      realtimeClient.emitEvent(_lifecycleEvent(
        incidentId: incident.id,
        state: 'acknowledged',
      ));
      await _pumpRealtime();
      expect(await repository.getSosState(), SosState.acknowledged);

      realtimeClient.emitEvent(_lifecycleEvent(
        incidentId: incident.id,
        state: 'cancelled',
        terminalReason: SosTerminalReason.cancelledByUser.name,
      ));
      await _pumpRealtime();

      expect(await repository.getSosState(), SosState.acknowledged);
      final current = await repository.getCurrentIncident();
      expect(current!.state, SosState.acknowledged);
      expect(current.terminalReason, isNull);
      expect(_hasDiagnostic('invalid_live_transition:realtime_event'), isTrue);
    });

    test('cold restore can seed terminal state without live validation',
        () async {
      final store = MemorySharedPrefsSdkStore()
        ..stringValues[SharedPrefsSdkStore.sosStateKey] =
            SosState.cancelled.name;
      await repository.dispose();
      repository = MqttOperationalSosRepository(
        realtimeClient: realtimeClient,
        localStore: store,
      );

      await repository.restoreState();

      expect(await repository.getSosState(), SosState.cancelled);
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

    test('rejects stale terminal replay after newer active incident', () async {
      final staleIncident = await _triggerAppSos(repository);

      realtimeClient.emitEvent(_lifecycleEvent(
        incidentId: staleIncident.id,
        state: 'cancelled',
      ));
      await _pumpRealtime();
      expect(await repository.getSosState(), SosState.cancelled);

      final newerIncident = await _triggerAppSos(repository);
      realtimeClient.emitEvent(_lifecycleEvent(
        incidentId: staleIncident.id,
        state: 'resolved',
      ));
      await _pumpRealtime();

      final current = await repository.getCurrentIncident();
      expect(current!.id, newerIncident.id);
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
      final observedUpdate = repository.watchCurrentIncident().firstWhere(
            (item) => item?.actuators?.snapshotVersion == 7,
          );
      final incident = await _triggerAppSos(repository);

      realtimeClient.emitEvent(_actuatorEvent(
        incidentId: incident.id,
        snapshotVersion: 7,
      ));
      await _pumpRealtime();

      final current = await repository.getCurrentIncident();
      expect(current!.actuators!.snapshotVersion, 7);
      expect((await observedUpdate)!.actuators!.snapshotVersion, 7);
      expect(_hasDiagnostic('SOS_ACTUATOR_UPDATE_ACCEPTED'), isTrue);
    });

    test('older and equal actuator versions cannot regress delivery', () async {
      final incident = await _triggerAppSos(repository);
      realtimeClient.emitEvent(_actuatorEvent(
        incidentId: incident.id,
        snapshotVersion: 7,
        status: 'delivered',
      ));
      await _pumpRealtime();

      realtimeClient.emitEvent(_actuatorEvent(
        incidentId: incident.id,
        snapshotVersion: 6,
        status: 'failed',
      ));
      realtimeClient.emitEvent(_actuatorEvent(
        incidentId: incident.id,
        snapshotVersion: 7,
        status: 'failed',
      ));
      await _pumpRealtime();

      final current = await repository.getCurrentIncident();
      expect(current!.actuators!.snapshotVersion, 7);
      expect(
          current.actuators!.items.single.status, SosActuatorStatus.delivered);
    });

    test('buffers a canonical actuator candidate while handoff is pending',
        () async {
      await _triggerAppSos(repository);

      realtimeClient.emitEvent(_actuatorEvent(
        incidentId: 'other-incident',
        snapshotVersion: 7,
      ));
      await _pumpRealtime();

      final current = await repository.getCurrentIncident();
      expect(current!.actuators, isNull);
      expect(_hasDiagnostic('SOS_MQTT_ACTUATOR_UPDATE_BUFFERED'), isTrue);
    });

    test('processed lifecycle confirms reception before actuator planning',
        () async {
      final remoteDataSource = _FakeSosRemoteDataSource();
      await repository.dispose();
      repository = MqttOperationalSosRepository(
        realtimeClient: realtimeClient,
        remoteDataSource: remoteDataSource,
      );
      final localIncident = await _triggerAppSos(repository);
      expect(localIncident.isBackendConfirmed, isFalse);
      remoteDataSource.active = _localActiveDto(id: 'backend-incident-1');

      realtimeClient.emitEvent(_lifecycleEvent(
        incidentId: 'backend-incident-1',
        clientIncidentId: localIncident.id,
        state: 'active',
        source: 'button_ui',
        triggerSource: 'button_ui',
        actionability: 'localActionable',
        displaySurface: 'activeAndHistory',
      ));
      await _pumpRealtime();

      final current = await repository.getCurrentIncident();
      expect(current!.id, 'backend-incident-1');
      expect(current.isBackendConfirmed, isTrue);
      expect(current.actuators, isNull);
      expect(current.progress.steps.first.state, SosProgressState.succeeded);
      expect(remoteDataSource.getActiveSosCalls, 0);
    });

    test('processed event without correlation cannot claim local SOS',
        () async {
      final localIncident = await _triggerAppSos(repository);

      realtimeClient.emitEvent(_processedEvent(
        incidentId: 'canonical-processed-incident',
      ));
      await _pumpRealtime();

      final current = await repository.getCurrentIncident();
      expect(current!.id, localIncident.id);
      expect(current.isBackendConfirmed, isFalse);
      expect(_hasDiagnostic('reason=identity_mismatch'), isTrue);
    });

    test('internal and legacy processed aliases produce one handoff', () async {
      final local = await _triggerAppSos(repository);
      final eventAt = DateTime.now().toUtc();

      realtimeClient.emitEvent(_processedEvent(
        incidentId: 'canonical-alias-incident',
        clientIncidentId: local.id,
        timestamp: eventAt,
        topicCategory: 'internal',
      ));
      realtimeClient.emitEvent(_processedEvent(
        incidentId: 'canonical-alias-incident',
        clientIncidentId: local.id,
        timestamp: eventAt,
        topicCategory: 'legacy_alias',
      ));
      await _pumpRealtime();

      expect(
        (await repository.getCurrentIncident())!.id,
        'canonical-alias-incident',
      );
      final handoffs = BleDebugRegistry.instance.currentState.events.where(
        (event) => event.message.contains('SOS_CANONICAL_INCIDENT_HANDOFF'),
      );
      expect(handoffs, hasLength(1));
      expect(_hasDiagnostic('reason=duplicate_alias_or_event'), isTrue);
    });

    test('unrelated remote processed event cannot claim local SOS', () async {
      final local = await _triggerAppSos(repository);

      realtimeClient.emitEvent(_processedEvent(
        incidentId: 'remote-relay-incident',
        source: 'remote_lora_relay',
      ));
      await _pumpRealtime();

      final current = await repository.getCurrentIncident();
      expect(current!.id, local.id);
      expect(current.isBackendConfirmed, isFalse);
      expect(_hasDiagnostic('reason=external_only'), isTrue);
    });

    test('unknown MQTT event is ignored without changing state', () async {
      final local = await _triggerAppSos(repository);
      realtimeClient.emitEvent(RealtimeEvent(
        type: 'sos.unknown',
        timestamp: DateTime.now().toUtc(),
        payload: const <String, dynamic>{
          'type': 'sos.unknown',
          'incidentId': 'unknown-incident',
          '_mqttAuthenticatedUserScoped': true,
          '_mqttTopicCategory': 'internal',
        },
      ));
      await _pumpRealtime();

      expect((await repository.getCurrentIncident())!.id, local.id);
      expect(_hasDiagnostic('reason=unsupported_event_type'), isTrue);
    });

    test('publish stays local and never calls REST before processed event',
        () async {
      final remoteDataSource = _FakeSosRemoteDataSource();
      await repository.dispose();
      repository = MqttOperationalSosRepository(
        realtimeClient: realtimeClient,
        remoteDataSource: remoteDataSource,
      );
      final local = await repository.triggerSos(
        triggerSource: 'button_ui',
        positionSnapshot: _position(),
      );
      expect(local.isBackendConfirmed, isFalse);
      expect(local.progress.steps, hasLength(1));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final current = await repository.getCurrentIncident();
      expect(current!.id, local.id);
      expect(current.isBackendConfirmed, isFalse);
      expect(current.progress.steps.first.state, SosProgressState.pending);
      expect(remoteDataSource.getActiveSosCalls, 0);
      expect(_hasDiagnostic('SOS_BACKEND_CONFIRMATION_REST'), isFalse);
    });

    test('processed plan and later actuator update expose two contacts',
        () async {
      final remoteDataSource = _FakeSosRemoteDataSource();
      await repository.dispose();
      repository = MqttOperationalSosRepository(
        realtimeClient: realtimeClient,
        remoteDataSource: remoteDataSource,
      );
      final local = await _triggerAppSos(repository);

      realtimeClient.emitEvent(_processedEvent(
        incidentId: 'canonical-mqtt-incident',
        clientIncidentId: local.id,
        snapshotVersion: 1,
        contactStatuses: const <String>['scheduled', 'scheduled'],
      ));
      await _pumpRealtime();

      var current = await repository.getCurrentIncident();
      var contacts = current!.progress.steps.singleWhere(
        (step) => step.type == SosProgressStepType.emergencyContacts,
      );
      expect(contacts.totalTargets, 2);
      expect(contacts.state, SosProgressState.inProgress);

      realtimeClient.emitEvent(_actuatorEvent(
        incidentId: 'canonical-mqtt-incident',
        snapshotVersion: 2,
        status: 'delivered',
        contactStatuses: const <String>['delivered', 'delivered'],
      ));
      await _pumpRealtime();

      current = await repository.getCurrentIncident();
      contacts = current!.progress.steps.singleWhere(
        (step) => step.type == SosProgressStepType.emergencyContacts,
      );
      expect(contacts.totalTargets, 2);
      expect(contacts.successfulTargets, 2);
      expect(contacts.state, SosProgressState.succeeded);
      expect(remoteDataSource.getActiveSosCalls, 0);
    });

    test('MQTT contact delivery plus failure exposes partial progress',
        () async {
      final local = await _triggerAppSos(repository);
      realtimeClient.emitEvent(_processedEvent(
        incidentId: 'canonical-partial-incident',
        clientIncidentId: local.id,
      ));
      await _pumpRealtime();
      realtimeClient.emitEvent(_actuatorEvent(
        incidentId: 'canonical-partial-incident',
        snapshotVersion: 3,
        status: 'delivered',
        contactStatuses: const <String>['delivered', 'failed'],
      ));
      await _pumpRealtime();

      final contacts =
          (await repository.getCurrentIncident())!.progress.steps.singleWhere(
                (step) => step.type == SosProgressStepType.emergencyContacts,
              );
      expect(contacts.totalTargets, 2);
      expect(contacts.successfulTargets, 1);
      expect(contacts.failedTargets, 1);
      expect(contacts.state, SosProgressState.partiallySucceeded);
    });

    test('actuator update before processed is buffered then applied', () async {
      final remoteDataSource = _FakeSosRemoteDataSource();
      await repository.dispose();
      repository = MqttOperationalSosRepository(
        realtimeClient: realtimeClient,
        remoteDataSource: remoteDataSource,
      );
      final local = await _triggerAppSos(repository);

      realtimeClient.emitEvent(_actuatorEvent(
        incidentId: 'mqtt-buffered-incident',
        snapshotVersion: 2,
        status: 'delivered',
        contactStatuses: const <String>['delivered', 'delivered'],
      ));
      await _pumpRealtime();
      expect((await repository.getCurrentIncident())!.actuators, isNull);
      expect(_hasDiagnostic('SOS_MQTT_ACTUATOR_UPDATE_BUFFERED'), isTrue);

      realtimeClient.emitEvent(_processedEvent(
        incidentId: 'mqtt-buffered-incident',
        clientIncidentId: local.id,
      ));
      await _pumpRealtime();

      final current = await repository.getCurrentIncident();
      expect(current!.id, 'mqtt-buffered-incident');
      expect(current.actuators!.snapshotVersion, 2);
      expect(
        current.progress.steps
            .singleWhere(
              (step) => step.type == SosProgressStepType.emergencyContacts,
            )
            .successfulTargets,
        2,
      );
      expect(_hasDiagnostic('source=pre_processed_buffer'), isTrue);
      expect(remoteDataSource.getActiveSosCalls, 0);
    });

    test('MQTT warning timeout reconciles an active backend incident',
        () async {
      final remoteDataSource = _FakeSosRemoteDataSource();
      await repository.dispose();
      repository = MqttOperationalSosRepository(
        realtimeClient: realtimeClient,
        remoteDataSource: remoteDataSource,
        mqttConfirmationWarningDelay: const Duration(milliseconds: 1),
      );
      final local = await _triggerAppSos(repository);
      remoteDataSource.active = _localActiveDto(
        id: 'backend-timeout-confirmed',
        cycleKey: local.cycleKey,
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final current = await repository.getCurrentIncident();
      expect(current!.id, 'backend-timeout-confirmed');
      expect(current.progress.provisionalIncidentId, local.id);
      expect(current.isBackendConfirmed, isTrue);
      expect(current.state, SosState.sent);
      expect(current.progress.steps.first.state, SosProgressState.succeeded);
      expect(_hasDiagnostic('SOS_BACKEND_CONFIRMATION_TIMEOUT'), isTrue);
      expect(remoteDataSource.getActiveSosCalls, 1);
    });

    test('device-origin provisional id hands off to backend confirmation',
        () async {
      await repository.triggerSos(
        triggerSource: 'ble_device_runtime_status',
        positionSnapshot: _position(),
        deviceId: '13579',
        originatorNodeId: 13579,
        incidentId: 'device-runtime-13579:7',
        cycleKey: 'sos-cycle:13579:7',
      );

      realtimeClient.emitEvent(_processedEvent(
        incidentId: 'backend-device-incident',
        clientIncidentId: 'device-runtime-13579:7',
      ));
      await _pumpRealtime();

      final current = await repository.getCurrentIncident();
      expect(current!.id, 'backend-device-incident');
      expect(current.isBackendConfirmed, isTrue);
      expect(current.progress.provisionalIncidentId, 'device-runtime-13579:7');
      expect(current.deviceId, '13579');
      expect(current.originatorNodeId, 13579);
      expect(current.cycleKey, 'sos-cycle:13579:7');
    });

    test('null cancel response stays pending while backend remains active',
        () async {
      final remoteDataSource = _FakeSosRemoteDataSource()
        ..cancelReturnsNull = true;
      await repository.dispose();
      repository = MqttOperationalSosRepository(
        realtimeClient: realtimeClient,
        remoteDataSource: remoteDataSource,
        cancelRemoteDataSource: remoteDataSource,
      );
      final local = await _triggerAppSos(repository);
      remoteDataSource.active = _localActiveDto(
        id: 'backend-still-active',
        cycleKey: local.cycleKey,
      );

      final pending = await repository.cancelSos();

      expect(pending.state, SosState.cancelRequested);
      expect(await repository.getSosState(), SosState.cancelRequested);
      expect(
          (await repository.getCurrentIncident())!.id, 'backend-still-active');
      expect(remoteDataSource.lastCancelIncidentId, local.id);
    });

    test('active cancel response stays pending until terminal MQTT evidence',
        () async {
      final remoteDataSource = _FakeSosRemoteDataSource()
        ..keepActiveOnCancel = true;
      await repository.dispose();
      repository = MqttOperationalSosRepository(
        realtimeClient: realtimeClient,
        remoteDataSource: remoteDataSource,
        cancelRemoteDataSource: remoteDataSource,
      );
      final local = await _triggerAppSos(repository);
      remoteDataSource.active = _localActiveDto(
        id: 'backend-cancel-pending',
        cycleKey: local.cycleKey,
      );

      final pending = await repository.cancelSos();
      expect(pending.state, SosState.cancelRequested);

      realtimeClient.emitEvent(_lifecycleEvent(
        incidentId: 'backend-cancel-pending',
        state: 'cancelled',
        cycleKey: local.cycleKey,
      ));
      await _pumpRealtime();

      expect(await repository.getSosState(), SosState.cancelled);
      expect(
        (await repository.getCurrentIncident())!.state,
        SosState.cancelled,
      );
    });

    test('explicit active-query absence confirms cancellation', () async {
      final remoteDataSource = _FakeSosRemoteDataSource()
        ..cancelReturnsNull = true;
      await repository.dispose();
      repository = MqttOperationalSosRepository(
        realtimeClient: realtimeClient,
        remoteDataSource: remoteDataSource,
        cancelRemoteDataSource: remoteDataSource,
      );
      await _triggerAppSos(repository);

      final cancelled = await repository.cancelSos();

      expect(cancelled.state, SosState.cancelled);
      expect(await repository.getSosState(), SosState.idle);
      expect(await repository.getCurrentIncident(), isNull);
    });

    test('active-query exception keeps cancellation non-terminal', () async {
      final remoteDataSource = _FakeSosRemoteDataSource()
        ..cancelReturnsNull = true
        ..getActiveSosError = StateError('query failed');
      await repository.dispose();
      repository = MqttOperationalSosRepository(
        realtimeClient: realtimeClient,
        remoteDataSource: remoteDataSource,
        cancelRemoteDataSource: remoteDataSource,
      );
      await _triggerAppSos(repository);

      final pending = await repository.cancelSos();

      expect(pending.state, SosState.cancelRequested);
      expect(await repository.getSosState(), SosState.cancelRequested);
    });

    test('missing-incident success keeps cancellation non-terminal', () async {
      final remoteDataSource = _FakeSosRemoteDataSource()
        ..cancelReturnsNull = true
        ..getActiveSosError = const SosException(
          'E_HTTP_SOS_GET_ACTIVE_FAILED',
          'E_HTTP_SOS_GET_ACTIVE_FAILED',
        );
      await repository.dispose();
      repository = MqttOperationalSosRepository(
        realtimeClient: realtimeClient,
        remoteDataSource: remoteDataSource,
        cancelRemoteDataSource: remoteDataSource,
      );
      await _triggerAppSos(repository);

      final pending = await repository.cancelSos();

      expect(pending.state, SosState.cancelRequested);
      expect(await repository.getSosState(), SosState.cancelRequested);
    });

    test('wrong incident terminal response cannot close cancellation',
        () async {
      final remoteDataSource = _FakeSosRemoteDataSource();
      await repository.dispose();
      repository = MqttOperationalSosRepository(
        realtimeClient: realtimeClient,
        remoteDataSource: remoteDataSource,
        cancelRemoteDataSource: remoteDataSource,
      );
      await _triggerAppSos(repository);
      remoteDataSource.cancelResponse = _localActiveDto(
        id: 'different-backend-incident',
        state: SosState.cancelled,
      );

      final pending = await repository.cancelSos();

      expect(pending.state, SosState.cancelRequested);
      expect(await repository.getSosState(), SosState.cancelRequested);
    });

    test('wrong cycle terminal response cannot close cancellation', () async {
      final remoteDataSource = _FakeSosRemoteDataSource();
      await repository.dispose();
      repository = MqttOperationalSosRepository(
        realtimeClient: realtimeClient,
        remoteDataSource: remoteDataSource,
        cancelRemoteDataSource: remoteDataSource,
      );
      final local = await _triggerAppSos(repository);
      remoteDataSource.cancelResponse = _localActiveDto(
        id: local.id,
        state: SosState.cancelled,
        cycleKey: 'different-cycle',
      );

      final pending = await repository.cancelSos();

      expect(pending.state, SosState.cancelRequested);
      expect(await repository.getSosState(), SosState.cancelRequested);
    });

    test('wrong device terminal response cannot close cancellation', () async {
      final remoteDataSource = _FakeSosRemoteDataSource();
      await repository.dispose();
      repository = MqttOperationalSosRepository(
        realtimeClient: realtimeClient,
        remoteDataSource: remoteDataSource,
        cancelRemoteDataSource: remoteDataSource,
      );
      final local = await repository.triggerSos(
        triggerSource: 'ble_device_runtime_status',
        positionSnapshot: _position(),
        deviceId: '13579',
        originatorNodeId: 13579,
        incidentId: 'device-runtime-13579:9',
        cycleKey: 'sos-cycle:13579:9',
      );
      remoteDataSource.cancelResponse = _localActiveDto(
        id: local.id,
        state: SosState.cancelled,
        cycleKey: local.cycleKey,
        deviceId: '24680',
        originatorNodeId: 24680,
      );

      final pending = await repository.cancelSos();

      expect(pending.state, SosState.cancelRequested);
      expect(await repository.getSosState(), SosState.cancelRequested);
    });

    test('late timeout result cannot regress cancellation', () async {
      final query = Completer<SosIncidentDto?>();
      final remoteDataSource = _FakeSosRemoteDataSource()
        ..getActiveSosCompleter = query
        ..keepActiveOnCancel = true;
      await repository.dispose();
      repository = MqttOperationalSosRepository(
        realtimeClient: realtimeClient,
        remoteDataSource: remoteDataSource,
        cancelRemoteDataSource: remoteDataSource,
        mqttConfirmationWarningDelay: const Duration(milliseconds: 1),
      );
      final local = await _triggerAppSos(repository);
      remoteDataSource.active = _localActiveDto(
        id: 'backend-late-active',
        cycleKey: local.cycleKey,
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));

      final pending = await repository.cancelSos();
      query.complete(remoteDataSource.active);
      await _pumpRealtime();

      expect(pending.state, SosState.cancelRequested);
      expect(await repository.getSosState(), SosState.cancelRequested);
      expect((await repository.getCurrentIncident())!.id, local.id);
    });

    test('timeout result from a stale lifecycle generation is ignored',
        () async {
      final query = Completer<SosIncidentDto?>();
      final remoteDataSource = _FakeSosRemoteDataSource()
        ..getActiveSosCompleter = query;
      await repository.dispose();
      repository = MqttOperationalSosRepository(
        realtimeClient: realtimeClient,
        remoteDataSource: remoteDataSource,
        mqttConfirmationWarningDelay: const Duration(milliseconds: 1),
      );
      final first = await _triggerAppSos(repository);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await repository.clearSosRuntimeForSessionChange();
      final second = await _triggerAppSos(repository);

      query.complete(_localActiveDto(
        id: 'backend-first-generation',
        cycleKey: first.cycleKey,
      ));
      await _pumpRealtime();

      final current = await repository.getCurrentIncident();
      expect(current!.id, second.id);
      expect(current.isBackendConfirmed, isFalse);
    });

    test('cancel during confirmation stops retries and cannot reopen',
        () async {
      final remoteDataSource = _FakeSosRemoteDataSource();
      await repository.dispose();
      repository = MqttOperationalSosRepository(
        realtimeClient: realtimeClient,
        remoteDataSource: remoteDataSource,
        cancelRemoteDataSource: remoteDataSource,
      );
      await _triggerAppSos(repository);
      realtimeClient.emitEvent(_actuatorEvent(
        incidentId: 'late-active',
        snapshotVersion: 2,
      ));
      await _pumpRealtime();
      await repository.cancelSos();
      realtimeClient.emitEvent(_processedEvent(incidentId: 'late-active'));
      await Future<void>.delayed(const Duration(milliseconds: 90));

      expect(await repository.getSosState(), SosState.idle);
      expect(await repository.watchCurrentIncident().first, isNull);
      expect(_hasDiagnostic('reason=cancel_requested'), isTrue);
    });

    test('session clear stops confirmation and removes local progress',
        () async {
      final remoteDataSource = _FakeSosRemoteDataSource();
      await repository.dispose();
      repository = MqttOperationalSosRepository(
        realtimeClient: realtimeClient,
        remoteDataSource: remoteDataSource,
      );
      await _triggerAppSos(repository);
      realtimeClient.emitEvent(_actuatorEvent(
        incidentId: 'other-user-incident',
        snapshotVersion: 2,
      ));
      await _pumpRealtime();
      await repository.clearSosRuntimeForSessionChange();
      realtimeClient.emitEvent(
        _processedEvent(incidentId: 'other-user-incident'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(await repository.getSosState(), SosState.idle);
      expect(await repository.watchCurrentIncident().first, isNull);
      expect(_hasDiagnostic('reason=session_cleared'), isTrue);
    });

    test('stale actuator event cannot reopen a locally cancelled incident',
        () async {
      await repository.dispose();
      repository = MqttOperationalSosRepository(
        realtimeClient: realtimeClient,
        cancelRemoteDataSource: _FakeSosRemoteDataSource(),
      );
      final incident = await _triggerAppSos(repository);
      await repository.cancelSos();

      realtimeClient.emitEvent(_actuatorEvent(
        incidentId: incident.id,
        snapshotVersion: 99,
      ));
      await _pumpRealtime();

      expect(await repository.getSosState(), SosState.idle);
      expect(await repository.getCurrentIncident(), isNull);
      expect(_hasDiagnostic('SOS_ACTUATOR_UPDATE_IGNORED'), isTrue);
    });

    test('cached confirmed active incident clears on no-active REST response',
        () async {
      final store = MemorySharedPrefsSdkStore();
      final cached = SosIncident(
        id: 'remotely-closed',
        state: SosState.sent,
        createdAt: DateTime.utc(2026, 6, 21),
        isBackendConfirmed: true,
      );
      store.jsonValues[SharedPrefsSdkStore.sosIncidentKey] =
          LocalStateSerializers.sosIncidentToJson(cached);
      store.stringValues[SharedPrefsSdkStore.sosStateKey] = SosState.sent.name;
      await repository.dispose();
      repository = MqttOperationalSosRepository(
        realtimeClient: realtimeClient,
        remoteDataSource: _FakeSosRemoteDataSource(),
        localStore: store,
      );
      await repository.restoreState();

      final result = await repository.rehydrateRuntimeStateFromBackend();

      expect(result.outcome, SosRuntimeRehydrationOutcome.clearedToIdle);
      expect(await repository.getCurrentIncident(), isNull);
      expect(store.jsonValues[SharedPrefsSdkStore.sosIncidentKey], isNull);
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
  String? terminalReason,
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
      if (terminalReason != null) 'terminalReason': terminalReason,
    },
  );
}

RealtimeEvent _actuatorEvent({
  required String incidentId,
  required int snapshotVersion,
  String status = 'sent',
  List<String> contactStatuses = const <String>[],
  DateTime? timestamp,
  String topicCategory = 'internal',
}) {
  final eventAt = (timestamp ?? DateTime.now()).toUtc();
  return RealtimeEvent(
    type: 'sos.actuator_update',
    timestamp: eventAt,
    payload: <String, dynamic>{
      'type': 'sos.actuator_update',
      'userId': '11111111-1111-1111-1111-111111111111',
      'incidentId': incidentId,
      'snapshotVersion': snapshotVersion,
      'updatedAt': eventAt.toIso8601String(),
      '_mqttAuthenticatedUserScoped': true,
      '_mqttTopicCategory': topicCategory,
      'actuators': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'contacts',
          'type': 'emergency_contacts',
          'status': status,
          'outcome': status == 'failed' ? 'failure' : 'success',
          if (contactStatuses.isNotEmpty)
            'contacts': <Map<String, dynamic>>[
              for (var index = 0; index < contactStatuses.length; index++)
                <String, dynamic>{
                  'contactId': 'contact-${index + 1}',
                  'status': contactStatuses[index],
                },
            ],
        },
      ],
    },
  );
}

RealtimeEvent _processedEvent({
  required String incidentId,
  String? clientIncidentId,
  DateTime? timestamp,
  String topicCategory = 'internal',
  String? source,
  int? snapshotVersion,
  List<String> contactStatuses = const <String>[],
}) {
  final eventAt = (timestamp ?? DateTime.now()).toUtc();
  return RealtimeEvent(
    type: 'processed',
    timestamp: eventAt,
    payload: <String, dynamic>{
      'type': 'processed',
      'userId': '11111111-1111-1111-1111-111111111111',
      'incidentId': incidentId,
      if (clientIncidentId != null) 'clientIncidentId': clientIncidentId,
      'status': 'active',
      'occurredAt': eventAt.toIso8601String(),
      'openedAt': eventAt.toIso8601String(),
      'updatedAt': eventAt.toIso8601String(),
      '_mqttAuthenticatedUserScoped': true,
      '_mqttTopicCategory': topicCategory,
      if (source != null) 'source': source,
      if (snapshotVersion != null) 'snapshotVersion': snapshotVersion,
      if (snapshotVersion != null)
        'actuators': <String, dynamic>{
          'snapshotVersion': snapshotVersion,
          'items': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'contacts',
              'type': 'emergency_contacts',
              'status': 'scheduled',
              'outcome': 'pending',
              'contacts': <Map<String, dynamic>>[
                for (var index = 0; index < contactStatuses.length; index++)
                  <String, dynamic>{
                    'contactId': 'contact-${index + 1}',
                    'status': contactStatuses[index],
                  },
              ],
            },
          ],
        },
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

bool _hasDiagnostic(String token) {
  return BleDebugRegistry.instance.currentState.events.any(
    (event) => event.message.contains(token),
  );
}

SosIncidentDto _localActiveDto({
  required String id,
  SosState state = SosState.sent,
  String? cycleKey,
  String? deviceId,
  int? originatorNodeId,
  SosActuatorSnapshot? actuators,
}) {
  return SosIncidentDto(
    id: id,
    state: state.name,
    createdAt: DateTime.utc(2026, 6, 21).toIso8601String(),
    triggerSource: 'commercial_app',
    owner: 'app',
    cycleKey: cycleKey,
    deviceId: deviceId,
    originatorNodeId: originatorNodeId,
    originKind: SosOriginKind.app.name,
    actionability: SosActionability.localActionable.name,
    displaySurface: SosDisplaySurface.activeAndHistory.name,
    actuators: actuators,
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
  bool cancelReturnsNull = false;
  bool keepActiveOnCancel = false;
  SosIncidentDto? cancelResponse;
  Object? getActiveSosError;
  Completer<SosIncidentDto?>? getActiveSosCompleter;
  String? lastCancelIncidentId;

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
    lastCancelIncidentId = incidentId;
    if (cancelReturnsNull) return null;
    if (cancelResponse != null) return cancelResponse;
    if (keepActiveOnCancel) return active;
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
    if (getActiveSosError case final error?) throw error;
    if (getActiveSosCompleter case final completer?) {
      return completer.future;
    }
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
