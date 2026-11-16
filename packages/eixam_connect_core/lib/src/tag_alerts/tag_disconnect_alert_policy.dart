import 'tag_alert.dart';

/// Why the TAG link is down, as classified when the drop was observed.
enum TagDisconnectCause {
  /// The link dropped and nothing explains it: the case worth an alert.
  unexpected,

  /// The user (or the app on their behalf) disconnected or unpaired.
  manual,

  /// A deliberate flow caused it: firmware update, provisioning, reboot window
  /// or device migration. The alert waits until the hold ends.
  expected,

  /// The phone's Bluetooth adapter is off.
  bluetoothOff,
}

/// Everything the policy needs, sampled at one instant. Snapshots are
/// state-based on purpose: a newer snapshot fully replaces an older one, so
/// they can be coalesced without losing a transition.
final class TagLinkSnapshot {
  const TagLinkSnapshot({
    required this.deviceKey,
    required this.observedAt,
    required this.paired,
    required this.connected,
    this.deviceAlias,
    this.disconnectedSince,
    this.cause = TagDisconnectCause.unexpected,
    this.holdUntil,
    this.sosActive = false,
    this.backgroundDisarm = false,
    this.backgrounded = false,
    this.lastTagPosition,
  });

  final String deviceKey;
  final String? deviceAlias;
  final DateTime observedAt;
  final bool paired;
  final bool connected;

  /// When this run of the app observed the current drop. Null when the TAG was
  /// already away at start: the policy then leaves things as they are.
  final DateTime? disconnectedSince;
  final TagDisconnectCause cause;

  /// End of the deliberate flow that explains an `expected` drop.
  final DateTime? holdUntil;

  /// An SOS is in progress: no disconnect alert is armed or kept.
  final bool sosActive;

  /// The platform cannot be relied on to push the lease right now (iOS while
  /// the app is suspended). The lease is dropped; a woken app still arms at
  /// the disconnect.
  final bool backgroundDisarm;

  /// The app is in the background. A drop observed now may have only a short
  /// wake-up window to schedule its alert, so the controller schedules it
  /// without waiting on any permission round-trip.
  final bool backgrounded;

  /// Last position reported by the TAG itself, for the alert content only.
  final TagAlertPosition? lastTagPosition;
}

enum TagLeasePhase {
  /// Nothing scheduled.
  disarmed,

  /// Connected: a dead-man alert is scheduled and pushed forward.
  leased,

  /// Disconnected: the alert is scheduled at the exact deadline.
  pending,

  /// Disconnected but a deliberate flow or an off adapter explains it.
  suppressed,
}

final class TagLeaseState {
  const TagLeaseState({
    this.phase = TagLeasePhase.disarmed,
    this.fireAt,
    this.lastPushAt,
    this.kind = TagAlertKind.tagDisconnected,
  });

  static const TagLeaseState none = TagLeaseState();

  final TagLeasePhase phase;
  final DateTime? fireAt;
  final DateTime? lastPushAt;
  final TagAlertKind kind;
}

sealed class TagDisconnectAction {
  const TagDisconnectAction();
}

final class TagDisconnectNoAction extends TagDisconnectAction {
  const TagDisconnectNoAction();
}

/// Schedule (or reschedule) [kind] for [at]; when [clearDelivered] the slot's
/// already delivered alert is removed first.
final class TagDisconnectSchedule extends TagDisconnectAction {
  const TagDisconnectSchedule({
    required this.kind,
    required this.at,
    required this.elapsed,
    this.clearDelivered = false,
  });

  final TagAlertKind kind;
  final DateTime at;
  final Duration elapsed;
  final bool clearDelivered;
}

/// Remove the scheduled and delivered alerts of these kinds.
final class TagDisconnectCancel extends TagDisconnectAction {
  const TagDisconnectCancel(this.kinds);

  final Set<TagAlertKind> kinds;
}

final class TagDisconnectDecision {
  const TagDisconnectDecision(this.state, this.actions);

  final TagLeaseState state;
  final List<TagDisconnectAction> actions;
}

/// Pure "TAG forgotten or dropped" policy.
///
/// While the link is up a dead-man alert stays scheduled at
/// `lastPush + X + slack` and is pushed forward at most every [pushInterval]
/// (slack = the push interval, so it can never fire before X after the real
/// last contact and at most 1.25 X after it). When an unexpected drop is
/// observed it is rescheduled to exactly `disconnectedSince + X`. It never
/// fires for a manual disconnect, an unpair, a deliberate flow (the deadline
/// moves to the end of the hold), during an SOS, or when the setting is
/// "never". A reconnect removes the alert, delivered or pending.
abstract final class TagDisconnectAlertPolicy {
  static const Duration minPushInterval = Duration(seconds: 60);
  static const Duration maxPushInterval = Duration(minutes: 10);

  /// `clamp(X / 4, 60 s, 10 min)`.
  static Duration pushIntervalFor(Duration disconnectAfter) {
    final quarter = Duration(microseconds: disconnectAfter.inMicroseconds ~/ 4);
    if (quarter < minPushInterval) return minPushInterval;
    if (quarter > maxPushInterval) return maxPushInterval;
    return quarter;
  }

  static const Set<TagAlertKind> _all = {
    TagAlertKind.tagDisconnected,
    TagAlertKind.bluetoothOff,
  };

  static TagDisconnectDecision evaluate({
    required TagLinkSnapshot snapshot,
    required TagLeaseState state,
    required Duration? disconnectAfter,
    required bool permissionAllowed,
  }) {
    final held =
        disconnectAfter == null ||
        !permissionAllowed ||
        !snapshot.paired ||
        snapshot.sosActive;
    if (held) {
      return _disarm(state);
    }
    final after = disconnectAfter;

    if (snapshot.connected) {
      if (snapshot.backgroundDisarm) return _disarm(state);
      final interval = pushIntervalFor(after);
      final now = snapshot.observedAt;
      final armed = state.phase == TagLeasePhase.leased;
      if (armed &&
          state.lastPushAt != null &&
          now.difference(state.lastPushAt!) < interval) {
        return TagDisconnectDecision(state, const <TagDisconnectAction>[]);
      }
      final fireAt = now.add(after).add(interval);
      return TagDisconnectDecision(
        TagLeaseState(
          phase: TagLeasePhase.leased,
          fireAt: fireAt,
          lastPushAt: now,
        ),
        <TagDisconnectAction>[
          TagDisconnectSchedule(
            kind: TagAlertKind.tagDisconnected,
            at: fireAt,
            elapsed: after,
            // Coming back from a drop, or from a previous run of the app that
            // left an alert on screen: it must not stay there.
            clearDelivered: state.phase != TagLeasePhase.leased,
          ),
          if (state.kind == TagAlertKind.bluetoothOff &&
              state.phase != TagLeasePhase.disarmed)
            const TagDisconnectCancel({TagAlertKind.bluetoothOff}),
        ],
      );
    }

    // Link is down.
    final observedSince = snapshot.disconnectedSince;
    if (observedSince == null) {
      // The drop was not observed by this run of the app (cold start with the
      // TAG away): there is no honest start time, and an alert scheduled by an
      // earlier run must not be moved. Nothing to do until the TAG connects.
      return TagDisconnectDecision(state, const <TagDisconnectAction>[]);
    }
    final since = observedSince;
    switch (snapshot.cause) {
      case TagDisconnectCause.manual:
        return _suppress(state);
      case TagDisconnectCause.expected:
        final hold = snapshot.holdUntil;
        if (hold == null || hold.isAfter(snapshot.observedAt)) {
          return _suppress(state);
        }
        return _pending(
          state,
          kind: TagAlertKind.tagDisconnected,
          effectiveSince: hold.isAfter(since) ? hold : since,
          after: after,
        );
      case TagDisconnectCause.bluetoothOff:
        return _pending(
          state,
          kind: TagAlertKind.bluetoothOff,
          effectiveSince: since,
          after: after,
        );
      case TagDisconnectCause.unexpected:
        return _pending(
          state,
          kind: TagAlertKind.tagDisconnected,
          effectiveSince: since,
          after: after,
        );
    }
  }

  static TagDisconnectDecision _pending(
    TagLeaseState state, {
    required TagAlertKind kind,
    required DateTime effectiveSince,
    required Duration after,
  }) {
    final fireAt = effectiveSince.add(after);
    if (state.phase == TagLeasePhase.pending &&
        state.kind == kind &&
        state.fireAt == fireAt) {
      return TagDisconnectDecision(state, const <TagDisconnectAction>[]);
    }
    final other = kind == TagAlertKind.bluetoothOff
        ? TagAlertKind.tagDisconnected
        : TagAlertKind.bluetoothOff;
    return TagDisconnectDecision(
      TagLeaseState(phase: TagLeasePhase.pending, fireAt: fireAt, kind: kind),
      <TagDisconnectAction>[
        TagDisconnectSchedule(kind: kind, at: fireAt, elapsed: after),
        if (state.phase != TagLeasePhase.disarmed && state.kind == other)
          TagDisconnectCancel({other}),
      ],
    );
  }

  static TagDisconnectDecision _suppress(TagLeaseState state) {
    if (state.phase == TagLeasePhase.suppressed) {
      return TagDisconnectDecision(state, const <TagDisconnectAction>[]);
    }
    return TagDisconnectDecision(
      const TagLeaseState(phase: TagLeasePhase.suppressed),
      state.phase == TagLeasePhase.disarmed
          ? const <TagDisconnectAction>[]
          : const <TagDisconnectAction>[TagDisconnectCancel(_all)],
    );
  }

  static TagDisconnectDecision _disarm(TagLeaseState state) {
    if (state.phase == TagLeasePhase.disarmed) {
      return TagDisconnectDecision(state, const <TagDisconnectAction>[]);
    }
    return const TagDisconnectDecision(
      TagLeaseState.none,
      <TagDisconnectAction>[TagDisconnectCancel(_all)],
    );
  }
}
