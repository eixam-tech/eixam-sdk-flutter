/// F17c: the stop the SDK sent for the previous SOS and the TAG never
/// confirmed. "No, stop the TAG" writes the same command again.
enum AmbiguousTagSosTerminal {
  /// An app cancel (`0x04`).
  cancel,

  /// A portal / backend resolve (`0x07`).
  resolve,
}

/// The user's answer to an [AmbiguousTagSosPrompt].
enum AmbiguousTagSosChoice {
  /// Open the SOS (normal flow, cancellable as usual).
  sendSos,

  /// Stop the TAG again with the matching command; no SOS is opened.
  stopTag,
}

/// What an answer did.
enum AmbiguousTagSosAnswerOutcome {
  /// The SOS was opened (the answer was "Send SOS", or a late "No" after the
  /// deadline, which is the timeout).
  sosSent,

  /// The TAG was told to stop; no SOS was sent.
  tagStopped,

  /// No prompt was open (already answered, timed out, or closed).
  noPrompt,
}

/// F17c: the SDK cannot tell whether the TAG's SOS frames are the SOS the
/// user already stopped (the TAG never confirmed the stop) or a new
/// emergency. The host shows a full-screen prompt; the SDK also posts a local
/// notification with both actions. With no answer by [deadline], the SDK
/// sends the SOS (native timer, also with the app closed).
final class AmbiguousTagSosPrompt {
  const AmbiguousTagSosPrompt({required this.terminal, required this.deadline});

  final AmbiguousTagSosTerminal terminal;

  /// UTC. The SOS is sent automatically at this time.
  final DateTime deadline;

  /// Seconds left until the automatic SOS, never negative.
  int secondsLeft(DateTime now) {
    final ms = deadline.difference(now.toUtc()).inMilliseconds;
    if (ms <= 0) {
      return 0;
    }
    return (ms + 999) ~/ 1000;
  }

  @override
  bool operator ==(Object other) =>
      other is AmbiguousTagSosPrompt &&
      other.terminal == terminal &&
      other.deadline == deadline;

  @override
  int get hashCode => Object.hash(terminal, deadline);

  @override
  String toString() =>
      'AmbiguousTagSosPrompt(terminal: ${terminal.name}, deadline: $deadline)';
}

/// Optional SDK capability (check with `sdk is AmbiguousTagSosPromptControl`).
abstract interface class AmbiguousTagSosPromptControl {
  /// The open prompt, or null.
  AmbiguousTagSosPrompt? get currentAmbiguousTagSosPrompt;

  /// Emits the current prompt (or null) on listen, then every change: a new
  /// prompt, or null once it closed (answered, timed out, the TAG confirmed
  /// the stop, a new countdown on the TAG, sign-out).
  Stream<AmbiguousTagSosPrompt?> watchAmbiguousTagSosPrompt();

  /// The user's answer from the host's full-screen prompt.
  Future<AmbiguousTagSosAnswerOutcome> answerAmbiguousTagSosPrompt(
    AmbiguousTagSosChoice choice,
  );
}
