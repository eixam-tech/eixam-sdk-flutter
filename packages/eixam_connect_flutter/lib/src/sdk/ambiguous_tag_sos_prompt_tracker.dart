import 'dart:async';

import 'package:eixam_connect_core/eixam_connect_core.dart';

import '../diagnostics/sdk_release_log.dart';
import 'protection_platform_adapter.dart';

/// F17c: the SDK side of the ambiguous TAG SOS prompt. Native owns the
/// decision, the 30 s timer, the notification and the answer; this only
/// mirrors native's open prompt for the host (it keeps no decision state of
/// its own) and forwards the host's answer.
final class AmbiguousTagSosPromptTracker {
  AmbiguousTagSosPromptTracker({
    required Future<ProtectionOwnTagSosPrompt?> Function() read,
    required Future<String> Function(String choice) answer,
    DateTime Function()? clock,
  }) : _read = read,
       _answer = answer,
       _clock = clock ?? DateTime.now;

  /// After the deadline native sends the SOS and closes the prompt; if that
  /// close event never reaches Dart, the prompt is re-read this much later.
  static const Duration deadlineRecheck = Duration(milliseconds: 1500);

  final Future<ProtectionOwnTagSosPrompt?> Function() _read;
  final Future<String> Function(String choice) _answer;
  final DateTime Function() _clock;
  final StreamController<AmbiguousTagSosPrompt?> _changes =
      StreamController<AmbiguousTagSosPrompt?>.broadcast();
  AmbiguousTagSosPrompt? _current;
  int _readSequence = 0;
  Timer? _deadlineTimer;
  bool _disposed = false;

  AmbiguousTagSosPrompt? get current => _current;

  Stream<AmbiguousTagSosPrompt?> watch() async* {
    yield _current;
    yield* _changes.stream;
  }

  /// Re-reads native's prompt (a native open/close event, initialize, app
  /// resume, a session change). The latest read wins. A failed read keeps
  /// the shown prompt: native still owns the timeout either way.
  Future<void> refresh(String reason) async {
    if (_disposed) {
      return;
    }
    final sequence = ++_readSequence;
    ProtectionOwnTagSosPrompt? native;
    try {
      native = await _read();
    } catch (error) {
      sdkReleaseLog(
        'SOS_OUTBOX_PROMPT_READ_FAILED reason=$reason errorType=${error.runtimeType}',
      );
      return;
    }
    if (_disposed || sequence != _readSequence) {
      return;
    }
    _set(_fromNative(native), reason);
  }

  Future<AmbiguousTagSosAnswerOutcome> answer(
    AmbiguousTagSosChoice choice,
  ) async {
    final wire = switch (choice) {
      AmbiguousTagSosChoice.sendSos => 'sendSos',
      AmbiguousTagSosChoice.stopTag => 'stopTag',
    };
    final action = await _answer(wire);
    sdkReleaseLog('SOS_OUTBOX_PROMPT_ANSWERED choice=$wire action=$action');
    await refresh('answered');
    return switch (action) {
      'sosOpened' => AmbiguousTagSosAnswerOutcome.sosSent,
      'stop' => AmbiguousTagSosAnswerOutcome.tagStopped,
      _ => AmbiguousTagSosAnswerOutcome.noPrompt,
    };
  }

  /// Sign-out: native clears its record first; nothing is shown meanwhile.
  void clear(String reason) {
    _readSequence++;
    _set(null, reason);
  }

  Future<void> dispose() async {
    _disposed = true;
    _deadlineTimer?.cancel();
    await _changes.close();
  }

  AmbiguousTagSosPrompt? _fromNative(ProtectionOwnTagSosPrompt? native) {
    if (native == null) {
      return null;
    }
    final terminal = switch (native.terminal) {
      'resolve' => AmbiguousTagSosTerminal.resolve,
      _ => AmbiguousTagSosTerminal.cancel,
    };
    return AmbiguousTagSosPrompt(
      terminal: terminal,
      deadline: native.deadlineAt.toUtc(),
    );
  }

  void _set(AmbiguousTagSosPrompt? next, String reason) {
    _deadlineTimer?.cancel();
    _deadlineTimer = null;
    if (next != null) {
      final untilDeadline = next.deadline.difference(_clock().toUtc());
      _deadlineTimer = Timer(
        (untilDeadline.isNegative ? Duration.zero : untilDeadline) +
            deadlineRecheck,
        () => unawaited(refresh('deadline_recheck')),
      );
    }
    if (next == _current) {
      return;
    }
    _current = next;
    sdkReleaseLog(
      'SOS_OUTBOX_PROMPT_${next == null ? 'CLOSED' : 'SHOWN'} reason=$reason'
      '${next == null ? '' : ' terminal=${next.terminal.name}'}',
    );
    if (!_changes.isClosed) {
      _changes.add(next);
    }
  }
}
