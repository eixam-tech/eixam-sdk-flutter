import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_control_app/src/bootstrap/validation_backend_config.dart';
import 'package:eixam_control_app/src/features/operational_demo/validation_console_controller.dart';
import 'package:eixam_control_app/src/features/operational_demo/validation_models.dart';
import 'package:eixam_connect_flutter/src/device/ble_debug_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ValidationConsoleController validation flows', () {
    late _FakeValidationSdk sdk;
    late ValidationConsoleController controller;

    setUp(() {
      sdk = _FakeValidationSdk();
      controller = ValidationConsoleController(sdk: sdk);
    });

    tearDown(() async {
      controller.dispose();
      await sdk.dispose();
    });

    test('trigger SOS finalizes with OK when SOS leaves idle', () async {
      controller.deviceDebugController.permissionState =
          const PermissionState(location: SdkPermissionStatus.granted);
      sdk.triggerIncident = _incident('incident-1', SosState.sent);
      sdk.queuedSosStates.addAll(<SosState>[
        SosState.triggerRequested,
        SosState.sent,
      ]);
      sdk.queuedDiagnostics.addAll(<SdkOperationalDiagnostics>[
        _diagnostics(),
        _diagnostics(),
      ]);

      await controller.runTriggerSosValidation(
        message: 'demo',
        triggerSource: 'test',
        timeout: const Duration(milliseconds: 20),
      );

      final result = _resultFor(controller, ValidationCapabilityId.triggerSos);
      expect(result.status, ValidationRunStatus.ok);
      expect(result.lastExecutedAt, isNotNull);
      expect(result.diagnosticText, contains('incident incident-1'));
    });

    test('trigger SOS finalizes with WARNING when SOS stays buffered',
        () async {
      controller.deviceDebugController.permissionState =
          const PermissionState(location: SdkPermissionStatus.granted);
      sdk.triggerIncident = _incident('incident-2', SosState.idle);
      sdk.queuedSosStates.addAll(<SosState>[
        SosState.idle,
        SosState.idle,
        SosState.idle,
      ]);
      sdk.queuedDiagnostics.addAll(<SdkOperationalDiagnostics>[
        _diagnostics(pendingSos: true),
        _diagnostics(pendingSos: true),
        _diagnostics(pendingSos: true),
      ]);

      await controller.runTriggerSosValidation(
        message: 'demo',
        triggerSource: 'test',
        timeout: const Duration(milliseconds: 20),
      );

      final result = _resultFor(controller, ValidationCapabilityId.triggerSos);
      expect(result.status, ValidationRunStatus.warning);
      expect(result.diagnosticText, contains('accepted locally'));
    });

    test('trigger SOS finalizes with NOK when no evidence appears', () async {
      controller.deviceDebugController.permissionState =
          const PermissionState(location: SdkPermissionStatus.granted);
      sdk.triggerIncident = _incident('incident-3', SosState.idle);
      sdk.queuedSosStates.addAll(<SosState>[
        SosState.idle,
        SosState.idle,
        SosState.idle,
      ]);
      sdk.queuedDiagnostics.addAll(<SdkOperationalDiagnostics>[
        _diagnostics(),
        _diagnostics(),
        _diagnostics(),
      ]);

      await controller.runTriggerSosValidation(
        message: 'demo',
        triggerSource: 'test',
        timeout: const Duration(milliseconds: 20),
      );

      final result = _resultFor(controller, ValidationCapabilityId.triggerSos);
      expect(result.status, ValidationRunStatus.nok);
      expect(result.status, isNot(ValidationRunStatus.running));
    });

    test(
        'trigger SOS finalizes immediately with WARNING when location is missing',
        () async {
      controller.deviceDebugController.permissionState =
          const PermissionState(location: SdkPermissionStatus.denied);

      await controller.runTriggerSosValidation(
        message: 'demo',
        triggerSource: 'test',
        timeout: const Duration(milliseconds: 20),
      );

      final result = _resultFor(controller, ValidationCapabilityId.triggerSos);
      expect(result.status, ValidationRunStatus.warning);
      expect(result.status, isNot(ValidationRunStatus.running));
      expect(
        result.diagnosticText,
        contains('User location permission is required'),
      );
    });

    test('trigger SOS card exposes prerequisite summary', () {
      controller.deviceDebugController.permissionState = const PermissionState(
        location: SdkPermissionStatus.permanentlyDenied,
      );
      controller.session = const EixamSession(
        appId: 'app',
        externalUserId: 'user',
        userHash: 'hash',
        canonicalExternalUserId: 'canonical',
        sdkUserId: 'sdk-user',
      );
      controller.operationalDiagnostics = const SdkOperationalDiagnostics(
        connectionState: RealtimeConnectionState.connected,
        telemetryPublishTopic: 'telemetry/topic',
        sosEventTopics: <String>['sos/topic'],
        bridge: SdkBridgeDiagnostics(),
      );

      final card = _cardFor(controller, ValidationCapabilityId.triggerSos);
      final prerequisites = {
        for (final field in card.prerequisites) field.label: field.value,
      };

      expect(prerequisites['Location permission'], 'Permanently denied');
      expect(prerequisites['Session ready'], 'Yes');
      expect(prerequisites['MQTT ready'], 'Yes');
    });

    test('cancel SOS finalizes with OK when runtime becomes non-active',
        () async {
      controller.sosState = SosState.sent;
      controller.lastSosIncident = _incident('incident-4', SosState.sent);
      sdk.cancelIncident = _incident('incident-4', SosState.cancelled);
      sdk.queuedSosStates.addAll(<SosState>[
        SosState.cancelRequested,
        SosState.cancelRequested,
        SosState.idle,
      ]);
      sdk.queuedDiagnostics.addAll(<SdkOperationalDiagnostics>[
        _diagnostics(),
        _diagnostics(),
        _diagnostics(),
      ]);

      await controller.runCancelSosValidation(
        timeout: const Duration(milliseconds: 20),
      );

      final result = _resultFor(controller, ValidationCapabilityId.cancelSos);
      expect(result.status, ValidationRunStatus.ok);
      expect(result.diagnosticText, contains('cancelled'));
    });

    test('cancel SOS finalizes with WARNING when cancellation is still pending',
        () async {
      controller.sosState = SosState.sent;
      controller.lastSosIncident = _incident('incident-5', SosState.sent);
      sdk.cancelIncident = _incident('incident-5', SosState.cancelRequested);
      sdk.queuedSosStates.addAll(<SosState>[
        SosState.cancelRequested,
        SosState.cancelRequested,
        SosState.cancelRequested,
      ]);
      sdk.queuedDiagnostics.addAll(<SdkOperationalDiagnostics>[
        _diagnostics(),
        _diagnostics(),
        _diagnostics(),
      ]);

      await controller.runCancelSosValidation(
        timeout: const Duration(milliseconds: 20),
      );

      final result = _resultFor(controller, ValidationCapabilityId.cancelSos);
      expect(result.status, ValidationRunStatus.warning);
      expect(result.diagnosticText, contains('cancelRequested'));
    });

    test(
        'cancel SOS finalizes with OK when backend-visible incident is cancelled',
        () async {
      controller.sosState = SosState.sent;
      controller.lastSosIncident = _incident('incident-6', SosState.sent);
      sdk.cancelIncident = _incident('incident-6', SosState.cancelRequested);
      sdk.refreshedCurrentIncident =
          _incident('incident-6', SosState.cancelled);
      sdk.queuedSosStates.addAll(<SosState>[
        SosState.cancelRequested,
        SosState.cancelRequested,
        SosState.cancelRequested,
      ]);
      sdk.queuedDiagnostics.addAll(<SdkOperationalDiagnostics>[
        _diagnostics(),
        _diagnostics(),
        _diagnostics(),
      ]);

      await controller.runCancelSosValidation(
        timeout: const Duration(milliseconds: 20),
      );

      final result = _resultFor(controller, ValidationCapabilityId.cancelSos);
      expect(result.status, ValidationRunStatus.ok);
      expect(result.diagnosticText, contains('cancelled'));
    });

    test('telemetry finalizes with OK when published evidence is observed',
        () async {
      final payload = _payload();
      sdk.queuedDiagnostics.addAll(<SdkOperationalDiagnostics>[
        _diagnostics(lastDecision: 'Telemetry publish queued'),
        _diagnostics(lastDecision: 'Telemetry published'),
      ]);

      await controller.runTelemetryValidation(
        payload,
        timeout: const Duration(milliseconds: 20),
      );

      final result =
          _resultFor(controller, ValidationCapabilityId.telemetrySample);
      expect(result.status, ValidationRunStatus.ok);
      expect(result.diagnosticText, contains('observable'));
    });

    test(
        'telemetry finalizes with OK for direct publish success without bridge signal',
        () async {
      final payload = _payload();
      sdk.queuedDiagnostics.addAll(<SdkOperationalDiagnostics>[
        _diagnostics(),
        _diagnostics(),
      ]);

      await controller.runTelemetryValidation(
        payload,
        timeout: const Duration(milliseconds: 20),
      );

      final result =
          _resultFor(controller, ValidationCapabilityId.telemetrySample);
      expect(result.status, ValidationRunStatus.ok);
    });

    test('telemetry finalizes with WARNING when sample remains buffered',
        () async {
      final payload = _payload();
      sdk.queuedDiagnostics.addAll(<SdkOperationalDiagnostics>[
        _diagnostics(pendingTelemetry: true),
        _diagnostics(pendingTelemetry: true),
      ]);

      await controller.runTelemetryValidation(
        payload,
        timeout: const Duration(milliseconds: 20),
      );

      final result =
          _resultFor(controller, ValidationCapabilityId.telemetrySample);
      expect(result.status, ValidationRunStatus.warning);
      expect(result.diagnosticText, contains('buffered'));
    });

    test(
        'telemetry finalizes with NOK on meaningful failure evidence and remains stable across rebuild',
        () async {
      final payload = _payload();
      sdk.queuedDiagnostics.addAll(<SdkOperationalDiagnostics>[
        _diagnostics(lastDecision: 'Telemetry publish failed: timeout'),
        _diagnostics(lastDecision: 'Telemetry publish failed: timeout'),
      ]);

      await controller.runTelemetryValidation(
        payload,
        timeout: const Duration(milliseconds: 20),
      );

      final first =
          _resultFor(controller, ValidationCapabilityId.telemetrySample);
      final second =
          _resultFor(controller, ValidationCapabilityId.telemetrySample);
      expect(first.status, ValidationRunStatus.nok);
      expect(first.status, isNot(ValidationRunStatus.running));
      expect(second.status, first.status);
      expect(second.diagnosticText, first.diagnosticText);
    });

    test('notifications finalize instead of staying RUNNING', () async {
      await controller.initializeNotificationsValidation();

      final result =
          _resultFor(controller, ValidationCapabilityId.notifications);
      expect(result.status, isNot(ValidationRunStatus.running));
      expect(
        result.status,
        anyOf(ValidationRunStatus.warning, ValidationRunStatus.ok),
      );
    });

    test('pair/connect returns OK when connected even with stale error',
        () async {
      controller.deviceDebugController.lastError = 'Old connection timeout';
      controller.deviceDebugController.bleDebugState =
          const BleDebugState(connectionError: 'Old BLE error');
      sdk.deviceStatus = const DeviceStatus(
        deviceId: 'device-42',
        paired: true,
        activated: true,
        connected: true,
      );

      await controller.runPairConnectValidation();

      final result =
          _resultFor(controller, ValidationCapabilityId.pairConnectDevice);
      expect(result.status, ValidationRunStatus.ok);
      expect(result.diagnosticText, contains('device-42'));
    });

    test('shutdown finalizes instead of staying RUNNING', () async {
      controller.deviceDebugController.bleDebugState = const BleDebugState(
        commandWriterReady: true,
        lastWriteResult: 'success',
      );

      await controller.runShutdownValidation();

      final result =
          _resultFor(controller, ValidationCapabilityId.shutdownCommand);
      expect(result.status, ValidationRunStatus.ok);
      expect(result.status, isNot(ValidationRunStatus.running));
    });

    test('device SOS card text clarifies runtime vs backend semantics', () {
      controller.operationalDiagnostics = const SdkOperationalDiagnostics(
        connectionState: RealtimeConnectionState.disconnected,
        bridge: SdkBridgeDiagnostics(
          lastBleSosEventSummary: 'BLE SOS packet seen',
        ),
      );

      final card =
          _bleCardFor(controller, ValidationCapabilityId.deviceSosFlow);
      final currentState = {
        for (final field in card.currentState) field.label: field.value,
      };

      expect(card.title, contains('runtime'));
      expect(card.description, contains('runtime'));
      expect(card.expectation.expectedResult, contains('does not by itself'));
      expect(currentState['Bridge SOS visibility'], 'BLE SOS packet seen');
    });
  });
}

ValidationCapabilityResult _resultFor(
  ValidationConsoleController controller,
  ValidationCapabilityId id,
) {
  return _cardFor(controller, id).result;
}

ValidationCardViewModel _cardFor(
  ValidationConsoleController controller,
  ValidationCapabilityId id,
) {
  final allCards = <ValidationCardViewModel>[
    ...controller.buildMvpCapabilityCards(
      activeBackendConfig: ValidationBackendConfig.production,
      activeBackendLocalhostWarning: false,
      draftBackendConfig: ValidationBackendConfig.production,
      draftBackendLocalhostWarning: false,
      backendApplyInProgress: false,
      sdkGeneration: 1,
    ),
    ...controller.buildBleCapabilityCards(),
  ];
  return allCards.firstWhere((card) => card.id == id);
}

ValidationCardViewModel _bleCardFor(
  ValidationConsoleController controller,
  ValidationCapabilityId id,
) {
  return controller
      .buildBleCapabilityCards()
      .firstWhere((card) => card.id == id);
}

SosIncident _incident(String id, SosState state) {
  return SosIncident(
    id: id,
    state: state,
    createdAt: DateTime.utc(2026, 4, 4),
  );
}

SdkTelemetryPayload _payload() {
  return SdkTelemetryPayload(
    timestamp: DateTime.utc(2026, 4, 4, 12),
    latitude: 41.4,
    longitude: 2.1,
    altitude: 12,
    userId: 'user-1',
    deviceId: 'device-1',
  );
}

SdkOperationalDiagnostics _diagnostics({
  bool pendingSos = false,
  bool pendingTelemetry = false,
  String? lastDecision,
}) {
  return SdkOperationalDiagnostics(
    connectionState: RealtimeConnectionState.disconnected,
    bridge: SdkBridgeDiagnostics(
      lastDecision: lastDecision,
      pendingSos: pendingSos
          ? PendingSosDiagnostics(
              signature: 'pending-sos',
              message: 'buffered',
              positionSnapshot: TrackingPosition(
                latitude: 1,
                longitude: 1,
                timestamp: DateTime.utc(2026, 4, 4),
              ),
            )
          : null,
      pendingTelemetry: pendingTelemetry
          ? PendingTelemetryDiagnostics(
              signature: 'pending-telemetry',
              payload: _payload(),
            )
          : null,
    ),
  );
}

class _FakeValidationSdk implements EixamConnectSdk {
  final StreamController<SosState> _sosStateController =
      StreamController<SosState>.broadcast();
  final StreamController<EixamSdkEvent> _sosEventController =
      StreamController<EixamSdkEvent>.broadcast();

  final List<SosState> queuedSosStates = <SosState>[];
  final List<SdkOperationalDiagnostics> queuedDiagnostics =
      <SdkOperationalDiagnostics>[];

  SosState currentSosState = SosState.idle;
  SdkOperationalDiagnostics currentDiagnostics = _diagnostics();
  SosIncident triggerIncident = _incident('trigger-default', SosState.idle);
  SosIncident cancelIncident = _incident('cancel-default', SosState.idle);
  SosIncident? currentIncident;
  SosIncident? refreshedCurrentIncident;
  DeviceStatus deviceStatus = const DeviceStatus(
    deviceId: '',
    paired: false,
    activated: false,
    connected: false,
  );
  PermissionState permissionState = const PermissionState();
  DeviceSosStatus deviceSosStatus = DeviceSosStatus.initial();
  Object? telemetryError;
  Object? triggerError;
  Object? cancelError;

  @override
  Future<SosIncident> triggerSos(SosTriggerPayload payload) async {
    if (triggerError != null) {
      throw triggerError!;
    }
    currentIncident = triggerIncident;
    return triggerIncident;
  }

  @override
  Future<SosIncident> cancelSos() async {
    if (cancelError != null) {
      throw cancelError!;
    }
    currentIncident = cancelIncident;
    return cancelIncident;
  }

  @override
  Future<SosIncident?> getCurrentSosIncident() async =>
      refreshedCurrentIncident ?? currentIncident;

  @override
  Future<void> publishTelemetry(SdkTelemetryPayload payload) async {
    if (telemetryError != null) {
      throw telemetryError!;
    }
  }

  @override
  Future<void> initializeNotifications() async {}

  @override
  Future<void> showLocalNotification({
    required String title,
    required String body,
  }) async {}

  @override
  Future<DeviceStatus> connectDevice({required String pairingCode}) async {
    return deviceStatus;
  }

  @override
  Future<DeviceStatus> getDeviceStatus() async => deviceStatus;

  @override
  Future<DeviceStatus> refreshDeviceStatus() async => deviceStatus;

  @override
  Future<PreferredDevice?> get preferredDevice async => null;

  @override
  Future<PermissionState> getPermissionState() async => permissionState;

  @override
  Future<DeviceSosStatus> getDeviceSosStatus() async => deviceSosStatus;

  @override
  Stream<DeviceSosStatus> watchDeviceSosStatus() =>
      const Stream<DeviceSosStatus>.empty();

  @override
  Future<void> sendShutdownToDevice() async {}

  @override
  Stream<DeviceStatus> get deviceStatusStream =>
      const Stream<DeviceStatus>.empty();

  @override
  Future<SosState> getSosState() async {
    if (queuedSosStates.isNotEmpty) {
      currentSosState = queuedSosStates.removeAt(0);
    }
    return currentSosState;
  }

  @override
  Future<SdkOperationalDiagnostics> getOperationalDiagnostics() async {
    if (queuedDiagnostics.isNotEmpty) {
      currentDiagnostics = queuedDiagnostics.removeAt(0);
    }
    return currentDiagnostics;
  }

  @override
  Stream<SosState> get currentSosStateStream => _sosStateController.stream;

  @override
  Stream<EixamSdkEvent> get lastSosEventStream => _sosEventController.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  Future<void> dispose() async {
    await _sosStateController.close();
    await _sosEventController.close();
  }
}
