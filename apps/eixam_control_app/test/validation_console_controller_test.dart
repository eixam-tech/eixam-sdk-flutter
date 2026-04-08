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

    test(
        'trigger then cancel validation stays viable when refresh briefly sees no current incident',
        () async {
      controller.deviceDebugController.permissionState =
          const PermissionState(location: SdkPermissionStatus.granted);
      sdk.triggerIncident = _incident('incident-refresh-gap', SosState.sent);
      sdk.cancelIncident =
          _incident('incident-refresh-gap', SosState.cancelled);
      sdk.queuedCurrentIncidents.addAll(<SosIncident?>[
        // The validation host may refresh in the short backend visibility gap
        // immediately after trigger, but it should still allow the later cancel
        // validation to proceed through the SDK.
        null,
        sdk.cancelIncident,
      ]);
      sdk.queuedSosStates.addAll(<SosState>[
        SosState.sent,
        SosState.sent,
        SosState.cancelRequested,
        SosState.idle,
      ]);
      sdk.queuedDiagnostics.addAll(<SdkOperationalDiagnostics>[
        _diagnostics(),
        _diagnostics(),
        _diagnostics(),
        _diagnostics(),
      ]);

      await controller.runTriggerSosValidation(
        message: 'demo',
        triggerSource: 'test',
        timeout: const Duration(milliseconds: 20),
      );
      await controller.runCancelSosValidation(
        timeout: const Duration(milliseconds: 20),
      );

      expect(
        _resultFor(controller, ValidationCapabilityId.triggerSos).status,
        ValidationRunStatus.ok,
      );
      expect(
        _resultFor(controller, ValidationCapabilityId.cancelSos).status,
        ValidationRunStatus.ok,
      );
      expect(sdk.getCurrentSosIncidentCallCount, 2);
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

    test('shutdown uses Android service route when protection mode owns BLE',
        () async {
      sdk.protectionStatus = sdk.protectionStatus.copyWith(
        modeState: ProtectionModeState.armed,
        runtimeState: ProtectionRuntimeState.active,
        coverageLevel: ProtectionCoverageLevel.full,
        foregroundServiceRunning: true,
        protectionRuntimeActive: true,
        bleOwner: ProtectionBleOwner.androidService,
        protectedDeviceId: 'device-protected',
        lastCommandRoute: 'androidService',
        lastCommandResult:
            'SHUTDOWN native write succeeded via androidService.',
      );
      controller.protectionStatus = sdk.protectionStatus;

      await controller.runShutdownValidation();

      final result =
          _resultFor(controller, ValidationCapabilityId.shutdownCommand);
      expect(result.status, ValidationRunStatus.ok);
      expect(result.diagnosticText, contains('androidService'));
    });

    test('shutdown uses iOS plugin route when protection mode owns BLE',
        () async {
      sdk.protectionStatus = sdk.protectionStatus.copyWith(
        modeState: ProtectionModeState.armed,
        runtimeState: ProtectionRuntimeState.active,
        coverageLevel: ProtectionCoverageLevel.full,
        protectionRuntimeActive: true,
        bleOwner: ProtectionBleOwner.iosPlugin,
        protectedDeviceId: 'device-ios-protected',
        lastCommandRoute: 'iosPlugin',
        lastCommandResult: 'SHUTDOWN native write succeeded via iosPlugin.',
      );
      controller.protectionStatus = sdk.protectionStatus;

      await controller.runShutdownValidation();

      final result =
          _resultFor(controller, ValidationCapabilityId.shutdownCommand);
      expect(result.status, ValidationRunStatus.ok);
      expect(result.diagnosticText, contains('iosPlugin'));
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

    test('protection readiness reports default blockers without changing mode',
        () {
      controller.protectionReadiness = sdk.protectionReadiness;
      controller.protectionStatus = sdk.protectionStatus;
      final card = controller.buildProtectionCapabilityCards().firstWhere(
            (item) => item.id == ValidationCapabilityId.protectionReadiness,
          );

      expect(card.result.status, ValidationRunStatus.warning);
      expect(card.result.diagnosticText, contains('Protection Mode'));
      expect(controller.protectionStatus.modeState, ProtectionModeState.off);
    });

    test('enter protection mode records a safe warning with no-op blockers',
        () async {
      await controller.enterProtectionMode();

      final card = controller.buildProtectionCapabilityCards().firstWhere(
            (item) => item.id == ValidationCapabilityId.protectionEnter,
          );

      expect(card.result.status, ValidationRunStatus.warning);
      expect(card.result.diagnosticText, contains('Protection Mode'));
      expect(controller.protectionStatus.modeState, ProtectionModeState.off);
    });

    test('enter protection mode warning uses explicit degradation reason',
        () async {
      sdk.enterProtectionResult = EnterProtectionModeResult(
        success: true,
        status: sdk.protectionStatus.copyWith(
          modeState: ProtectionModeState.degraded,
          runtimeState: ProtectionRuntimeState.active,
          coverageLevel: ProtectionCoverageLevel.partial,
          foregroundServiceRunning: true,
          protectionRuntimeActive: true,
          bleOwner: ProtectionBleOwner.androidService,
          serviceBleConnected: true,
          serviceBleReady: false,
          degradationReason:
              'Android foreground service connected to the protected device, but TEL/SOS subscriptions are not active yet.',
          updatedAt: DateTime.utc(2026, 4, 5, 11),
        ),
      );

      await controller.enterProtectionMode();

      final card = controller.buildProtectionCapabilityCards().firstWhere(
            (item) => item.id == ValidationCapabilityId.protectionEnter,
          );

      expect(card.result.status, ValidationRunStatus.warning);
      expect(
        card.result.diagnosticText,
        contains('TEL/SOS subscriptions are not active yet'),
      );
    });

    test('exit protection stays not run until explicitly triggered', () {
      controller.protectionStatus = controller.protectionStatus.copyWith(
        modeState: ProtectionModeState.off,
        runtimeState: ProtectionRuntimeState.inactive,
      );

      final card = controller.buildProtectionCapabilityCards().firstWhere(
            (item) => item.id == ValidationCapabilityId.protectionExit,
          );

      expect(card.result.status, ValidationRunStatus.notRun);
      expect(card.result.diagnosticText, contains('explicitly'));
    });

    test('exit protection becomes ok only after explicit action success',
        () async {
      sdk.protectionStatus = sdk.protectionStatus.copyWith(
        modeState: ProtectionModeState.armed,
        runtimeState: ProtectionRuntimeState.active,
        coverageLevel: ProtectionCoverageLevel.full,
      );
      controller.protectionStatus = sdk.protectionStatus;

      await controller.exitProtectionMode();

      final card = controller.buildProtectionCapabilityCards().firstWhere(
            (item) => item.id == ValidationCapabilityId.protectionExit,
          );

      expect(card.result.status, ValidationRunStatus.ok);
      expect(card.result.diagnosticText, contains('returned to the off state'));
    });

    test('protection cards render Android runtime fields when available', () {
      controller.protectionStatus = controller.protectionStatus.copyWith(
        platform: ProtectionPlatform.android,
        platformRuntimeConfigured: true,
        restorationConfigured: true,
        foregroundServiceRunning: true,
        protectionRuntimeActive: true,
        bleOwner: ProtectionBleOwner.androidService,
        serviceBleConnected: true,
        serviceBleReady: true,
        protectedDeviceId: 'device-protected',
        pendingNativeSosCreateCount: 1,
        pendingNativeSosCancelCount: 1,
        lastNativeBackendHandoffResult: 'cancel_synced',
        lastCommandRoute: 'androidService',
        lastCommandResult:
            'SHUTDOWN native write succeeded via androidService.',
        nativeBackendBaseUrl: 'http://127.0.0.1:8080',
        nativeBackendConfigValid: true,
        nativeBackendConfigIssue:
            'Debug localhost backend allowed. Debug cleartext backend allowed',
        debugLocalhostBackendAllowed: true,
        debugCleartextBackendAllowed: true,
        modeState: ProtectionModeState.degraded,
        runtimeState: ProtectionRuntimeState.active,
        coverageLevel: ProtectionCoverageLevel.partial,
      );
      controller.protectionDiagnostics =
          controller.protectionDiagnostics.copyWith(
        lastPlatformEvent: 'runtimeStarted',
        lastPlatformEventAt: DateTime.utc(2026, 4, 5, 12),
        pendingNativeSosCreateCount: 1,
        pendingNativeSosCancelCount: 1,
        lastNativeBackendHandoffResult: 'cancel_synced',
        protectedDeviceId: 'device-protected',
        lastCommandRoute: 'androidService',
        lastCommandResult:
            'SHUTDOWN native write succeeded via androidService.',
        nativeBackendBaseUrl: 'http://127.0.0.1:8080',
        nativeBackendConfigValid: true,
        nativeBackendConfigIssue:
            'Debug localhost backend allowed. Debug cleartext backend allowed',
        debugLocalhostBackendAllowed: true,
        debugCleartextBackendAllowed: true,
      );

      final statusCard = controller.buildProtectionCapabilityCards().firstWhere(
            (item) => item.id == ValidationCapabilityId.protectionStatus,
          );
      final readinessCard =
          controller.buildProtectionCapabilityCards().firstWhere(
                (item) => item.id == ValidationCapabilityId.protectionReadiness,
              );
      final diagnosticsCard =
          controller.buildProtectionCapabilityCards().firstWhere(
                (item) =>
                    item.id == ValidationCapabilityId.protectionDiagnostics,
              );

      expect(
        {
          for (final field in statusCard.currentState) field.label: field.value,
        }['BLE owner'],
        'androidService',
      );
      expect(
        {
          for (final field in readinessCard.currentState)
            field.label: field.value,
        }['Restoration configured'],
        'Yes',
      );
      expect(
        {
          for (final field in statusCard.currentState) field.label: field.value,
        }['Foreground service'],
        'Yes',
      );
      expect(
        {
          for (final field in diagnosticsCard.currentState)
            field.label: field.value,
        }['Last platform event'],
        'runtimeStarted',
      );
      expect(
        {
          for (final field in statusCard.currentState) field.label: field.value,
        }['Pending native SOS create'],
        '1',
      );
      expect(
        {
          for (final field in statusCard.currentState) field.label: field.value,
        }['Protected device'],
        'device-protected',
      );
      expect(
        {
          for (final field in diagnosticsCard.currentState)
            field.label: field.value,
        }['Native backend result'],
        'cancel_synced',
      );
      expect(
        {
          for (final field in diagnosticsCard.currentState)
            field.label: field.value,
        }['Last command route'],
        'androidService',
      );
      expect(
        {
          for (final field in statusCard.currentState) field.label: field.value,
        }['Debug localhost allowed'],
        'Yes',
      );
      expect(
        {
          for (final field in diagnosticsCard.currentState)
            field.label: field.value,
        }['Debug cleartext allowed'],
        'Yes',
      );
    });

    test('protection cards render iOS readiness fields honestly', () {
      controller.protectionStatus = controller.protectionStatus.copyWith(
        platform: ProtectionPlatform.ios,
        platformRuntimeConfigured: true,
        restorationConfigured: true,
        backgroundCapabilityState: ProtectionCapabilityState.configured,
        bleOwner: ProtectionBleOwner.iosPlugin,
        runtimeState: ProtectionRuntimeState.recovering,
        protectionRuntimeActive: true,
        serviceBleConnected: true,
        activeDeviceId: 'device-ios-runtime',
        coverageLevel: ProtectionCoverageLevel.partial,
        degradationReason:
            'The iOS plugin runtime is connected, but TEL/SOS subscriptions are not active yet.',
        lastRestorationEvent: 'restorationDetected',
      );
      controller.protectionDiagnostics =
          controller.protectionDiagnostics.copyWith(
        lastPlatformEvent: 'runtimeStarting',
        lastRestorationEvent: 'restorationDetected',
      );

      final readinessCard =
          controller.buildProtectionCapabilityCards().firstWhere(
                (item) => item.id == ValidationCapabilityId.protectionReadiness,
              );
      final statusCard = controller.buildProtectionCapabilityCards().firstWhere(
            (item) => item.id == ValidationCapabilityId.protectionStatus,
          );

      expect(
        {
          for (final field in readinessCard.currentState)
            field.label: field.value,
        }['Background capability'],
        'configured',
      );
      expect(
        {
          for (final field in readinessCard.currentState)
            field.label: field.value,
        }['Restoration configured'],
        'Yes',
      );
      expect(
        {
          for (final field in statusCard.currentState) field.label: field.value,
        }['Degradation reason'],
        contains('TEL/SOS subscriptions are not active yet'),
      );
      expect(
        {
          for (final field in statusCard.currentState) field.label: field.value,
        }['Last restoration event'],
        'restorationDetected',
      );
      expect(
        {
          for (final field in statusCard.currentState) field.label: field.value,
        }['BLE owner'],
        'iosPlugin',
      );
      expect(
        {
          for (final field in statusCard.currentState) field.label: field.value,
        }['Active device'],
        'device-ios-runtime',
      );
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
  final List<SosIncident?> queuedCurrentIncidents = <SosIncident?>[];

  SosState currentSosState = SosState.idle;
  SdkOperationalDiagnostics currentDiagnostics = _diagnostics();
  SosIncident triggerIncident = _incident('trigger-default', SosState.idle);
  SosIncident cancelIncident = _incident('cancel-default', SosState.idle);
  SosIncident? currentIncident;
  SosIncident? refreshedCurrentIncident;
  int getCurrentSosIncidentCallCount = 0;
  DeviceStatus deviceStatus = const DeviceStatus(
    deviceId: '',
    paired: false,
    activated: false,
    connected: false,
  );
  ProtectionReadinessReport protectionReadiness =
      const ProtectionReadinessReport(
    canArm: false,
    blockingIssues: <ProtectionBlockingIssue>[
      ProtectionBlockingIssue(
        type: ProtectionBlockingIssueType.platformBackgroundCapabilityMissing,
        message:
            'Protection Mode platform runtime is not configured in this host app yet.',
        canBeResolvedInline: false,
      ),
    ],
  );
  ProtectionStatus protectionStatus = ProtectionStatus(
    modeState: ProtectionModeState.off,
    coverageLevel: ProtectionCoverageLevel.none,
    runtimeState: ProtectionRuntimeState.inactive,
    sessionReady: false,
    devicePaired: false,
    deviceConnected: false,
    bluetoothEnabled: false,
    locationPermissionGranted: false,
    notificationsPermissionGranted: false,
    platformBackgroundCapabilityReady: false,
    backendReachable: false,
    realtimeReady: false,
    storeAndForwardEnabled: false,
    pendingSosCount: 0,
    pendingTelemetryCount: 0,
    updatedAt: DateTime.utc(2026, 4, 4),
  );
  ProtectionDiagnostics protectionDiagnostics = const ProtectionDiagnostics(
    pendingSosCount: 0,
    pendingTelemetryCount: 0,
  );
  EnterProtectionModeResult? enterProtectionResult;
  PermissionState permissionState = const PermissionState();
  DeviceSosStatus deviceSosStatus = DeviceSosStatus.initial();
  Object? telemetryError;
  Object? triggerError;
  Object? cancelError;
  final StreamController<ProtectionStatus> _protectionStatusController =
      StreamController<ProtectionStatus>.broadcast();
  final StreamController<ProtectionDiagnostics>
      _protectionDiagnosticsController =
      StreamController<ProtectionDiagnostics>.broadcast();

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
  Future<SosIncident?> getCurrentSosIncident() async {
    getCurrentSosIncidentCallCount++;
    if (queuedCurrentIncidents.isNotEmpty) {
      return queuedCurrentIncidents.removeAt(0);
    }
    return refreshedCurrentIncident ?? currentIncident;
  }

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
  Future<ProtectionReadinessReport> evaluateProtectionReadiness() async =>
      protectionReadiness;

  @override
  Future<EnterProtectionModeResult> enterProtectionMode({
    ProtectionModeOptions options = const ProtectionModeOptions(),
  }) async {
    final configuredResult = enterProtectionResult;
    if (configuredResult != null) {
      protectionStatus = configuredResult.status;
      _protectionStatusController.add(protectionStatus);
      return configuredResult;
    }
    protectionStatus = protectionStatus.copyWith(
      updatedAt: DateTime.utc(2026, 4, 4, 12),
    );
    _protectionStatusController.add(protectionStatus);
    return EnterProtectionModeResult(
      success: false,
      status: protectionStatus,
      blockingIssues: protectionReadiness.blockingIssues,
    );
  }

  @override
  Future<ProtectionStatus> exitProtectionMode() async {
    protectionStatus = protectionStatus.copyWith(
      modeState: ProtectionModeState.off,
      runtimeState: ProtectionRuntimeState.inactive,
      coverageLevel: ProtectionCoverageLevel.none,
      updatedAt: DateTime.utc(2026, 4, 4, 13),
    );
    _protectionStatusController.add(protectionStatus);
    return protectionStatus;
  }

  @override
  Future<ProtectionStatus> getProtectionStatus() async => protectionStatus;

  @override
  Stream<ProtectionStatus> watchProtectionStatus() =>
      _protectionStatusController.stream;

  @override
  Future<ProtectionDiagnostics> getProtectionDiagnostics() async =>
      protectionDiagnostics;

  @override
  Stream<ProtectionDiagnostics> watchProtectionDiagnostics() =>
      _protectionDiagnosticsController.stream;

  @override
  Future<ProtectionStatus> rehydrateProtectionState() async {
    _protectionStatusController.add(protectionStatus);
    return protectionStatus;
  }

  @override
  Future<FlushProtectionQueuesResult> flushProtectionQueues() async {
    _protectionDiagnosticsController.add(protectionDiagnostics);
    return const FlushProtectionQueuesResult(
      flushedSosCount: 0,
      flushedTelemetryCount: 0,
      success: true,
    );
  }

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
    await _protectionStatusController.close();
    await _protectionDiagnosticsController.close();
  }
}
