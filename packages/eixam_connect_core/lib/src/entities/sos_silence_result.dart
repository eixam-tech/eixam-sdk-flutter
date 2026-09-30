enum SosSilenceOutcome { silenceApplied, alreadySilent }

/// Result of silencing the acoustic alert for an open local SOS episode.
///
/// This operation is nonterminal: it does not cancel or resolve the incident,
/// mutate the configured SOS volume, or change the lifecycle generation.
final class SosSilenceResult {
  const SosSilenceResult({
    required this.outcome,
    required this.lifecycleId,
    required this.generation,
    this.incidentId,
  });

  final SosSilenceOutcome outcome;
  final String lifecycleId;
  final int generation;
  final String? incidentId;

  bool get changed => outcome == SosSilenceOutcome.silenceApplied;
}
