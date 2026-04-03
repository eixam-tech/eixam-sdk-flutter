enum ValidationRunStatus {
  notRun,
  running,
  ok,
  nok,
  warning,
}

enum ValidationCapabilityId {
  backendConfiguration,
  sessionConfiguration,
  httpConnectivity,
  mqttConnectivity,
  triggerSos,
  cancelSos,
  telemetrySample,
  contacts,
  backendReconfigure,
  permissions,
  notifications,
  bleScan,
  pairConnectDevice,
  activateDevice,
  refreshDeviceStatus,
  unpairDevice,
  deviceSosFlow,
  commandChannelReadiness,
  inetCommands,
  ackRelay,
  shutdownCommand,
  backendDeviceRegistryAlignment,
  globalSummary,
}

enum ValidationReadiness {
  ready,
  partial,
  blocked,
}

class ValidationExpectation {
  const ValidationExpectation({
    required this.expectedResult,
    required this.howToValidate,
  });

  final String expectedResult;
  final String howToValidate;
}

class ValidationStateField {
  const ValidationStateField({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;
}

class ValidationCapabilityResult {
  const ValidationCapabilityResult({
    required this.status,
    this.diagnosticText,
    this.lastExecutedAt,
  });

  final ValidationRunStatus status;
  final String? diagnosticText;
  final DateTime? lastExecutedAt;

  ValidationCapabilityResult copyWith({
    ValidationRunStatus? status,
    Object? diagnosticText = _unset,
    Object? lastExecutedAt = _unset,
  }) {
    return ValidationCapabilityResult(
      status: status ?? this.status,
      diagnosticText: identical(diagnosticText, _unset)
          ? this.diagnosticText
          : diagnosticText as String?,
      lastExecutedAt: identical(lastExecutedAt, _unset)
          ? this.lastExecutedAt
          : lastExecutedAt as DateTime?,
    );
  }

  static const Object _unset = Object();
}

class ValidationCardViewModel {
  const ValidationCardViewModel({
    required this.id,
    required this.title,
    required this.description,
    required this.expectation,
    required this.result,
    this.isCritical = false,
    this.currentState = const <ValidationStateField>[],
  });

  final ValidationCapabilityId id;
  final String title;
  final String description;
  final ValidationExpectation expectation;
  final ValidationCapabilityResult result;
  final bool isCritical;
  final List<ValidationStateField> currentState;
}

class ValidationSummaryViewModel {
  const ValidationSummaryViewModel({
    required this.title,
    required this.description,
    required this.totalCapabilities,
    required this.passed,
    required this.warning,
    required this.failed,
    required this.notRun,
    required this.running,
    required this.readiness,
  });

  final String title;
  final String description;
  final int totalCapabilities;
  final int passed;
  final int warning;
  final int failed;
  final int notRun;
  final int running;
  final ValidationReadiness readiness;
}
