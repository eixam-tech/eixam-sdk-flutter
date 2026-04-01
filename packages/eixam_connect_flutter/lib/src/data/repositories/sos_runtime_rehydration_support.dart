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
  Future<SosRuntimeRehydrationResult> rehydrateRuntimeStateFromBackend();
}
