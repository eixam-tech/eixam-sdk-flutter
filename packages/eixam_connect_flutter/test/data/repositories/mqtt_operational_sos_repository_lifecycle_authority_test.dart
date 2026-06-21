import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_connect_flutter/src/data/repositories/mqtt_operational_sos_repository.dart';
import 'package:eixam_connect_flutter/src/device/ble_debug_registry.dart';
import 'package:eixam_connect_flutter/src/sdk/operational_realtime_client.dart';
import 'package:eixam_connect_flutter/src/sdk/sdk_mqtt_contract.dart';
import 'package:flutter_test/flutter_test.dart';

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

Future<void> _pumpRealtime() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
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
