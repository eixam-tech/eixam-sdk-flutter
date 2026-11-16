import 'dart:async';

import '../diagnostics/sdk_release_log.dart';

/// F17c: the native store's answer for one own-TAG SOS frame that Dart
/// received through its own BLE link (flutter_blue_plus).
enum OwnTagSosFrameVerdict {
  /// Not guarded (or the guard just ended): handle the frame exactly as before.
  proceed,

  /// A countdown burst under the stale guard: a genuine new SOS; handle it.
  newSos,

  /// A copy, a frame still being classified, or a frame of an SOS the SDK
  /// already closed: drop it (native decides whether the TAG needs a stop).
  suppress;

  static OwnTagSosFrameVerdict fromWire(Object? value) => switch (value) {
    'newSos' => OwnTagSosFrameVerdict.newSos,
    'suppress' => OwnTagSosFrameVerdict.suppress,
    _ => OwnTagSosFrameVerdict.proceed,
  };
}

/// One raw own-TAG SOS frame as Dart received it.
final class OwnTagSosFrameReport {
  const OwnTagSosFrameReport({
    required this.bytes,
    required this.characteristic,
    required this.receivedAt,
    this.isClose = false,
  });

  final List<int> bytes;

  /// `sos` or `tel`: the GATT characteristic that delivered the frame.
  final String characteristic;
  final DateTime receivedAt;

  /// The TAG's own close frame (`0xE1/0xE2/0xE3`).
  final bool isClose;
}

typedef OwnTagSosFrameClassifier =
    Future<OwnTagSosFrameVerdict> Function(OwnTagSosFrameReport frame);

/// F17c: native is the single classifier of "stale vs new" for every own-TAG
/// SOS frame, whichever BLE path received it. Dart never starts a countdown,
/// trigger or cancel from a raw TAG frame while the native classifier is
/// reachable: each frame is forwarded in arrival order and handled only when
/// native admits it. Dart keeps no copy of native's guard state.
///
/// The classifier owns its own bound and fail-open policy; a classifier that
/// throws here still fails open (the frame is handled as before F17c).
final class OwnTagSosFrameGate {
  OwnTagSosFrameClassifier? _classifier;
  Future<void> _tail = Future<void>.value();
  OwnTagSosFrameVerdict? _admitting;

  /// F17c: the native verdict of the start frame being handled right now
  /// (set only while its handler runs). `newSos` is native's proof of a new
  /// TAG countdown (>= 3 pushes in 1.7 s): the device SOS admission accepts
  /// it even after an SDK terminal the TAG never confirmed.
  OwnTagSosFrameVerdict? get admittingVerdict => _admitting;

  bool get hasClassifier => _classifier != null;

  void setClassifier(OwnTagSosFrameClassifier? classifier) {
    _classifier = classifier;
  }

  /// [process] runs only when native admits the frame. Without a classifier
  /// it runs synchronously, as before F17c.
  void submitStartFrame(OwnTagSosFrameReport frame, void Function() process) {
    final classifier = _classifier;
    if (classifier == null) {
      process();
      return;
    }
    _enqueue('start', () async {
      var verdict = OwnTagSosFrameVerdict.proceed;
      try {
        verdict = await classifier(frame);
      } catch (_) {
        verdict = OwnTagSosFrameVerdict.proceed;
      }
      if (verdict == OwnTagSosFrameVerdict.suppress) {
        sdkReleaseLog(
          'SOS_OUTBOX_STALE_FRAME_SUPPRESSED '
          'characteristic=${frame.characteristic}',
        );
        return;
      }
      _admitting = verdict;
      try {
        _runHandler('start', process);
      } finally {
        _admitting = null;
      }
    });
  }

  /// An own-TAG SOS event frame (close `0xE1/0xE2/0xE3` and the other SOS
  /// events). It keeps its arrival order with the start frames (a close never
  /// overtakes an earlier SOS push still being classified); a close frame is
  /// also forwarded so native ends its guard whichever path received it.
  /// [process] always runs (event frames are never suppressed).
  void submitEventFrame(OwnTagSosFrameReport frame, void Function() process) {
    final classifier = _classifier;
    if (classifier == null) {
      process();
      return;
    }
    _enqueue('event', () async {
      if (frame.isClose) {
        try {
          await classifier(frame);
        } catch (_) {
          // The classifier logs its own failures.
        }
      }
      _runHandler('event', process);
    });
  }

  /// H-B: the chain never breaks. A step that throws (the frame handler, a
  /// log sink, anything) is release-logged and the next frame still runs;
  /// one bad frame must never silently drop every later SOS frame.
  void _enqueue(String stage, Future<void> Function() step) {
    _tail = _tail.then((_) async {
      try {
        await step();
      } catch (error) {
        _logFailure(stage, error);
      }
    });
  }

  /// A throwing handler is logged; the frame was admitted, so nothing else
  /// is skipped.
  void _runHandler(String stage, void Function() process) {
    try {
      process();
    } catch (error) {
      _logFailure(stage, error);
    }
  }

  static void _logFailure(String stage, Object error) {
    try {
      sdkReleaseLog(
        'SOS_OUTBOX_STALE_GATE_HANDLER_FAILED stage=$stage '
        'errorType=${error.runtimeType}',
      );
    } catch (_) {
      // Logging must never break the frame chain.
    }
  }

  /// A close frame handled elsewhere: forwarded to native, in order.
  void forwardCloseFrame(OwnTagSosFrameReport frame) {
    submitEventFrame(frame, () {});
  }

  /// Completes once every frame submitted so far was handled (tests).
  Future<void> get idle => _tail;
}
