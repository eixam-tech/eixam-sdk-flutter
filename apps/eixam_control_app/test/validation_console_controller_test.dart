import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';
import 'package:eixam_control_app/src/bootstrap/validation_backend_config.dart';
import 'package:eixam_control_app/src/features/operational_demo/validation_console_controller.dart';
import 'package:eixam_control_app/src/features/operational_demo/validation_models.dart';
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

    test('trigger SOS finalizes immediately with WARNING when location is missing',
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
      sdk.cancelIncident = _incident('incident-6', SosState.cancelled);
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

    test('telemetry finalizes with NOK and remains stable across rebuild',
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

      final first =
          _resultFor(controller, ValidationCapabilityId.telemetrySample);
      final second =
          _resultFor(controller, ValidationCapabilityId.telemetrySample);
      expect(first.status, ValidationRunStatus.nok);
      expect(first.status, isNot(ValidationRunStatus.running));
      expect(second.status, first.status);
      expect(second.diagnosticText, first.diagnosticText);
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
  return controller
      .buildMvpCapabilityCards(
        activeBackendConfig: ValidationBackendConfig.production,
        activeBackendLocalhostWarning: false,
        draftBackendConfig: ValidationBackendConfig.production,
        draftBackendLocalhostWarning: false,
        backendApplyInProgress: false,
        sdkGeneration: 1,
      )
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
  Object? telemetryError;
  Object? triggerError;
  Object? cancelError;

  @override
  Future<SosIncident> triggerSos(SosTriggerPayload payload) async {
    if (triggerError != null) {
      throw triggerError!;
    }
    return triggerIncident;
  }

  @override
  Future<SosIncident> cancelSos() async {
    if (cancelError != null) {
      throw cancelError!;
    }
    return cancelIncident;
  }

  @override
  Future<void> publishTelemetry(SdkTelemetryPayload payload) async {
    if (telemetryError != null) {
      throw telemetryError!;
    }
  }

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
