import 'package:eixam_connect_core/eixam_connect_core.dart';

enum SosRuntimeRehydrationOutcome {
  hydratedFromBackend,
  clearedToIdle,
  keptLocalFallback,
}

class SosRuntimeRehydrationResult {
  const SosRuntimeRehydrationResult({
    required this.outcome,
    required this.resultingState,
    this.diagnosticNote,
  });

  final SosRuntimeRehydrationOutcome outcome;
  final SosState resultingState;
  final String? diagnosticNote;
}

abstract interface class SosRuntimeRehydrationSupport {
  Future<SosRuntimeRehydrationResult> rehydrateRuntimeStateFromBackend({
    bool terminalAbsenceExpected = false,
  });
}

/// A parsed, authenticated MQTT terminal update that deliberately failed the
/// lifecycle-correlation check. The terminal stage is only a hint: consumers
/// must first establish authenticated active-SOS absence before applying it.
class SosRejectedTerminalReconciliationRequest {
  const SosRejectedTerminalReconciliationRequest({required this.terminalState});

  final SosState terminalState;
}

/// Implemented by live repositories which can ask the SDK to reconcile a
/// correlation-rejected terminal MQTT update through the authenticated API.
abstract interface class SosRejectedTerminalReconciliationSource {
  Stream<SosRejectedTerminalReconciliationRequest>
      watchRejectedTerminalReconciliations();
}

/// Marks a repository whose active SOS lifecycle must not be recovered through
/// automatic REST rehydration. Cached state remains visible until MQTT resumes.
abstract interface class MqttOnlyLiveSosLifecycle {}

/// Reads the account-scoped current-active endpoint without promoting history
/// or mutating the repository's local lifecycle.
abstract interface class AuthoritativeActiveSosLookup {
  Future<SosIncident?> getAuthoritativeActiveSos();
}

/// Clears account-scoped in-memory SOS state when authentication ownership
/// changes. This is intentionally separate from the public repository contract.
abstract interface class SosRuntimeSessionIsolation {
  Future<void> clearSosRuntimeForSessionChange();
}
