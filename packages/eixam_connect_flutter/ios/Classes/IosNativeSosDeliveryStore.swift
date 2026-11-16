import Foundation

/// Native side of the background SOS hand-off on iOS. Mirrors Android's
/// `ProtectionRuntimeStore` / `ProtectionSosLifecycleLogic` contract:
///
/// - The TAG cycle (pre-SOS countdown, active, closed) is tracked natively, so
///   an SOS becomes a durable *pending create* even while Dart is suspended
///   or not attached. Dart claims it through peek/mark/ack/drop and hands it
///   to the MQTT outbox; native never talks to the backend.
/// - A TAG cancel of an SOS that already reached the create stage becomes a
///   durable *pending cancel*, retired once Dart's outbox accepted it. A
///   backend terminal (`0xE3`, `.resolved`) never queues a cancel.
/// - SOS events emitted while Dart is not listening are persisted in order
///   (not a single-slot snapshot) and replayed when it attaches.
///
/// Foundation only (no UIKit/CoreBluetooth) so it runs under `swiftc` tests.
enum IosNativeSosCycleState: String {
  case idle
  case preConfirmSeen
  case createPending
}

/// The SDK's terminal for an SOS the TAG never confirmed closing: the TAG
/// gets the same command the SDK sends (cancel `0x04`, resolve `0x07`).
enum IosSosTerminalKind: String {
  case cancel
  case resolve
}

struct IosNativeSosTransition: Equatable {
  /// A new pending create was stored: emit `nativeBackendSyncQueued(create)`.
  var queuedCreate = false
  /// A new pending cancel was stored: emit `nativeBackendSyncQueued(cancel)`.
  var queuedCancel = false
  /// A countdown started: schedule promotion at this time (ms since epoch).
  var countdownDeadlineAt: Int?
  /// The countdown ended without promotion (closed): drop its timer.
  var countdownStopped = false
  /// F17b: the TAG still runs an SOS the SDK closed: write this command.
  var stopTag: IosSosTerminalKind?
  /// F17b: first stop of this guard: tell the user (once).
  var staleStopNotice = false
  /// F17b: a guarded frame waits for a countdown burst: call
  /// `evaluateStaleCandidate()` at this time (ms since epoch).
  var evaluateStaleAt: Int?
}

final class IosNativeSosDeliveryStore {
  static let countdownMs = 20_000
  /// After a close, frames are the TAG's close burst / stale repeats for
  /// this long; a new SOS needs a frame after it (no zombie SOS).
  static let closeQuietMs = 30_000
  /// Frames this long after a close can belong to a new SOS: its countdown
  /// is backdated to the first of them once the quiet window has passed.
  static let closeBurstMs = 5_000
  static let eventQueueCapacity = 64
  /// F17b stale guard. Firmware (verified): every BLE SOS push is sent twice
  /// (SOS then TEL characteristic, ms apart); a TAG countdown pushes in its
  /// first 2 s every 500 ms (4 pushes); an ACTIVE/ACK SOS pushes once per
  /// retry (2/8/20 s, then 60 s; the 60 s TEL resend can add a second push
  /// soon after). Frames carry no phase bit (sosType is 3).
  static let staleDuplicateMs = 300
  static let staleBurstWindowMs = 1_700
  static let staleBurstPushes = 3
  static let staleDecisionMs = 2_000
  static let staleGapMs = 90_000
  static let staleGuardMaxMs = 600_000
  /// F17c-cdc: a cycle first seen this long ago is past its TAG countdown
  /// burst (4 pushes in its first 2 s): no burst push of it can follow the
  /// SDK terminal, so the guard classifies the rest. An app cancel during the
  /// countdown with the TAG out of range never reaches it: the TAG goes
  /// ACTIVE and its retries must be stopped, never a new SOS.
  static let observedPastBurstMs = 2_000
  static let sosEventTypes: Set<String> = [
    "ownDeviceSosLifecycleObserved",
    "nativeBackendSyncQueued",
  ]

  enum Keys {
    static let cycleState = "native_sos_cycle_state"
    static let cycleKey = "native_sos_cycle_key"
    static let cycleNodeId = "native_sos_cycle_node_id"
    static let cycleDeadlineAt = "native_sos_cycle_deadline_at"
    static let cycleStartedAt = "native_sos_cycle_started_at"
    static let lastClosedAt = "native_sos_last_closed_at"
    static let firstFrameAfterCloseAt = "native_sos_first_frame_after_close_at"
    static let cycleKeptAfterStop = "native_sos_cycle_kept_after_stop"
    static let pendingCreate = "pending_native_sos_create"
    static let pendingCancel = "pending_native_sos_cancel"
    static let pendingEvents = "pending_sos_events"
    static let staleGuardKind = "native_sos_stale_guard_kind"
    static let staleGuardNodeId = "native_sos_stale_guard_node_id"
    static let staleGuardArmedAt = "native_sos_stale_guard_armed_at"
    static let staleGuardLastFrameAt = "native_sos_stale_guard_last_frame_at"
    static let staleGuardLinkDropped = "native_sos_stale_guard_link_dropped"
    static let staleGuardCandidateAt = "native_sos_stale_guard_candidate_at"
    static let staleGuardCandidatePushes = "native_sos_stale_guard_candidate_pushes"
    static let staleGuardLastPushAt = "native_sos_stale_guard_last_push_at"
    static let staleGuardNoticeShown = "native_sos_stale_guard_notice_shown"
    static let lastSosFrameAt = "native_sos_last_frame_at"
    static let dartCycleFirstSeenAt = "native_sos_dart_cycle_first_seen_at"
    static let dartCycleLastSeenAt = "native_sos_dart_cycle_last_seen_at"
    static let dartCycleNodeId = "native_sos_dart_cycle_node_id"
  }

  private let defaults: UserDefaults
  private let now: () -> Int

  init(defaults: UserDefaults, now: @escaping () -> Int) {
    self.defaults = defaults
    self.now = now
  }

  // MARK: - TAG cycle

  var cycleState: IosNativeSosCycleState {
    IosNativeSosCycleState(rawValue: defaults.string(forKey: Keys.cycleState) ?? "") ?? .idle
  }

  var cycleKey: String? { defaults.string(forKey: Keys.cycleKey) }

  var cycleNodeId: Int? { defaults.object(forKey: Keys.cycleNodeId) as? Int }

  var cycleDeadlineAt: Int? { defaults.object(forKey: Keys.cycleDeadlineAt) as? Int }

  /// Applies one classified TAG SOS frame. `deviceId` is the protected
  /// device identity used when the frame carries no node id.
  func observe(
    kind: IosBleSosSnapshotKind,
    nodeId: Int?,
    cycleKey: String?,
    deviceId: String?
  ) -> IosNativeSosTransition {
    var transition = IosNativeSosTransition()
    switch kind {
    case .preSos, .active:
      defaults.set(now(), forKey: Keys.lastSosFrameAt)
      if let guarded = observeGuardedFrame(nodeId: nodeId) {
        return guarded
      }
      // Firmware sosType 1..3 is the SOS kind / fix quality, not the
      // countdown phase: the TAG sends the same frames from the start of its
      // 20 s countdown (Android: first SOS frame starts the countdown). The
      // backend is told only once the countdown elapsed without a cancel.
      switch cycleState {
      case .idle:
        let timestamp = now()
        if let closedAt = defaults.object(forKey: Keys.lastClosedAt) as? Int,
           timestamp - closedAt < Self.closeQuietMs {
          // Close burst / stale repeats of the SOS that just closed. Remember
          // when frames kept coming, in case this is a new SOS.
          if timestamp - closedAt >= Self.closeBurstMs,
             defaults.object(forKey: Keys.firstFrameAfterCloseAt) == nil {
            defaults.set(timestamp, forKey: Keys.firstFrameAfterCloseAt)
          }
          break
        }
        var start = timestamp
        if let first = defaults.object(forKey: Keys.firstFrameAfterCloseAt) as? Int,
           timestamp - first < Self.closeQuietMs + Self.countdownMs {
          // Frames kept coming through the quiet window: a new SOS that
          // started then (its TAG countdown is already running).
          start = first
        }
        defaults.removeObject(forKey: Keys.firstFrameAfterCloseAt)
        let deadline = start + Self.countdownMs
        setCycle(.preConfirmSeen, key: cycleKey, nodeId: nodeId, deadlineAt: deadline)
        defaults.set(start, forKey: Keys.cycleStartedAt)
        if timestamp >= deadline {
          transition = promoteExpiredCountdown(deviceId: deviceId)
        } else {
          transition.countdownDeadlineAt = deadline
        }
      case .preConfirmSeen:
        // A later frame after the deadline: the phone was suspended when the
        // countdown elapsed.
        transition = promoteExpiredCountdown(deviceId: deviceId)
      case .createPending:
        // Repeated frames of the same SOS (the TAG keeps sending them).
        break
      }
    case .cancelled, .resolved:
      // The TAG's own close: it confirmed the stop (or closed by itself).
      disarmStaleGuard()
      clearDartCycle()
      let state = cycleState
      if state == .createPending, kind == .cancelled {
        // Never claimed by the SDK: nothing reached the broker, so the
        // cancelled SOS must never be published later (zombie SOS).
        if pendingCreateRecord?["state"] as? String == "pending_mqtt" {
          defaults.removeObject(forKey: Keys.pendingCreate)
        }
        storePendingCancel()
        transition.queuedCancel = true
      }
      transition.countdownStopped = state == .preConfirmSeen
      closeCycle()
    }
    return transition
  }

  private func closeCycle() {
    setCycle(.idle, key: nil, nodeId: nil, deadlineAt: nil)
    defaults.removeObject(forKey: Keys.cycleStartedAt)
    defaults.removeObject(forKey: Keys.firstFrameAfterCloseAt)
    defaults.set(now(), forKey: Keys.lastClosedAt)
  }

  /// The SDK says the SOS is over (cancelled / resolved / idle). Closes a
  /// cycle already handed over, in case its close frame never reached the
  /// phone (otherwise the next TAG SOS would be ignored natively). A cycle
  /// whose SOS was not handed over yet is kept: nothing is ever lost.
  /// Exception: a countdown kept across a runtime stop. Native no longer
  /// observes the TAG, Dart does: its TAG/app cancel must close it, or the
  /// countdown would be promoted into a false SOS at its deadline. Only the
  /// terminal of the same TAG closes it; when either node id is unknown the
  /// terminal closes it (keeping it would risk a false SOS).
  /// F17b: with [terminal], a handed-over SOS the TAG never confirmed
  /// closing arms the stale guard: the TAG still runs it (the SDK's own stop
  /// may not have reached it), so its frames must stop it, never open a new
  /// incident.
  /// F17c: the cycle may also have been seen only through Dart's forwarded
  /// frames (Dart owned the TAG link, native never saw it): the terminal of an
  /// SOS seen past its countdown burst arms the guard too (Android foreground
  /// `NATIVE_SOS_STALE_GUARD_NOT_ARMED lifecycle=idle`).
  /// F17c-cdc: the SDK cancel of a running countdown past its burst ends it
  /// and arms the guard (the TAG may never get the stop and go ACTIVE). The
  /// SDK already drops the create of a cycle cancelled after its start (M5),
  /// so ending it here loses nothing; a later burst is a new SOS.
  func closeDeliveredCycle(nodeId: Int? = nil, terminal: IosSosTerminalKind? = nil) -> Bool {
    let keptCountdown = cycleState == .preConfirmSeen &&
      defaults.bool(forKey: Keys.cycleKeptAfterStop) &&
      (nodeId == nil || cycleNodeId == nil || nodeId == cycleNodeId)
    let handedOver = cycleState == .createPending && pendingCreateRecord == nil
    let dartSeen = terminal != nil && cycleState == .idle && pendingCreateRecord == nil &&
      dartCycleHandedOver
    let cancelledCountdown = !keptCountdown && terminal == .cancel &&
      cycleState == .preConfirmSeen && pendingCreateRecord == nil &&
      (nodeId == nil || cycleNodeId == nil || nodeId == cycleNodeId) &&
      (defaults.object(forKey: Keys.cycleStartedAt) as? Int).map {
        now() - $0 >= Self.observedPastBurstMs
      } == true
    guard keptCountdown || handedOver || dartSeen || cancelledCountdown else {
      return false
    }
    let guardNode = cycleNodeId ?? dartCycleNodeId ?? nodeId
    let linkDropped = defaults.bool(forKey: Keys.staleGuardLinkDropped)
    if keptCountdown || handedOver || cancelledCountdown {
      closeCycle()
    }
    if handedOver || dartSeen || cancelledCountdown, let terminal {
      armStaleGuard(terminal, nodeId: guardNode, linkDropped: linkDropped)
      clearDartCycle()
    }
    return true
  }

  // MARK: - F17c Dart-forwarded frames (native is the single classifier)

  /// Dart's answer for one forwarded own-TAG frame: `proceed` (not guarded,
  /// handle it as before), `newSos` (a countdown burst under the guard:
  /// handle it) or `suppress` (a copy, still deciding, or the closed SOS).
  /// The same guard, copy collapse (which also merges the same push arriving
  /// through both paths) and burst rule as the native frame path. Pure
  /// persistence: works whether or not Protection is armed. A burst admitted
  /// here never opens the native cycle (Dart runs that SOS).
  func observeForwardedSosFrame(
    kind: IosBleSosSnapshotKind,
    nodeId: Int?
  ) -> (verdict: String, transition: IosNativeSosTransition) {
    switch kind {
    case .cancelled, .resolved:
      disarmStaleGuard()
      clearDartCycle()
      lastStaleAction = "close"
      return ("proceed", IosNativeSosTransition())
    case .preSos, .active:
      defaults.set(now(), forKey: Keys.lastSosFrameAt)
      let transition = observeGuardedFrame(nodeId: nodeId, driveCycle: false)
      let verdict: String
      switch lastStaleAction {
      case "notArmed", "ignored", "disarmed": verdict = "proceed"
      case "newSos": verdict = "newSos"
      default: verdict = "suppress"
      }
      if verdict != "suppress" {
        noteDartCycleFrame(nodeId: nodeId)
      }
      return (verdict, transition ?? IosNativeSosTransition())
    }
  }

  /// The SDK opened a new SOS lifecycle: no pending decision may stop it (M3).
  func disarmForNewSdkSos() {
    disarmStaleGuard()
  }

  private var dartCycleNodeId: Int? { defaults.object(forKey: Keys.dartCycleNodeId) as? Int }

  private var dartCycleHandedOver: Bool {
    guard let first = defaults.object(forKey: Keys.dartCycleFirstSeenAt) as? Int else {
      return false
    }
    let last = defaults.object(forKey: Keys.dartCycleLastSeenAt) as? Int ?? first
    let timestamp = now()
    return timestamp - first >= Self.observedPastBurstMs &&
      timestamp - last >= 0 && timestamp - last <= Self.staleGuardMaxMs
  }

  private func noteDartCycleFrame(nodeId: Int?) {
    let timestamp = now()
    let last = defaults.object(forKey: Keys.dartCycleLastSeenAt) as? Int
    let node = dartCycleNodeId
    let sameTag = node == nil || nodeId == nil || node == nodeId
    if defaults.object(forKey: Keys.dartCycleFirstSeenAt) == nil || !sameTag ||
       last == nil || timestamp - last! < 0 || timestamp - last! > Self.staleGapMs {
      defaults.set(timestamp, forKey: Keys.dartCycleFirstSeenAt)
      set(nodeId, forKey: Keys.dartCycleNodeId)
    } else if node == nil, let nodeId {
      defaults.set(nodeId, forKey: Keys.dartCycleNodeId)
    }
    defaults.set(timestamp, forKey: Keys.dartCycleLastSeenAt)
  }

  private func clearDartCycle() {
    for key in [Keys.dartCycleFirstSeenAt, Keys.dartCycleLastSeenAt, Keys.dartCycleNodeId] {
      defaults.removeObject(forKey: key)
    }
  }

  // MARK: - F17b stale guard

  var staleGuardKind: IosSosTerminalKind? {
    IosSosTerminalKind(rawValue: defaults.string(forKey: Keys.staleGuardKind) ?? "")
  }

  /// Last guard decision (`notArmed`, `ignored`, `duplicate`, `disarmed`,
  /// `pending`, `newSos`, `stale`, `none`, `close`), named like the Android
  /// guard actions so the shared scenario fixture replays identically.
  private(set) var lastStaleAction = "notArmed"

  /// Right after arming: the TAG link is up and its SOS frames are recent,
  /// so the stop can be written now (the frame path covers the rest).
  var staleStopToSendNow: IosSosTerminalKind? {
    guard let kind = staleGuardKind,
          let lastFrame = defaults.object(forKey: Keys.lastSosFrameAt) as? Int,
          now() - lastFrame <= Self.staleGapMs,
          !defaults.bool(forKey: Keys.staleGuardLinkDropped) else {
      return nil
    }
    return kind
  }

  /// The TAG link dropped. The guard survives it (A1): after a reconnect the
  /// TAG may still run the SOS the SDK closed.
  func noteLinkDropped() {
    defaults.set(true, forKey: Keys.staleGuardLinkDropped)
  }

  /// The TAG link is back. An armed guard measures its gap from now: a TAG
  /// still running the closed SOS sends a frame within 60 s.
  func noteLinkUp() {
    // Always: a drop may have gone unreported (Bluetooth off, process death).
    if staleGuardKind != nil {
      defaults.set(now(), forKey: Keys.staleGuardLastFrameAt)
    }
    defaults.set(false, forKey: Keys.staleGuardLinkDropped)
  }

  /// No countdown burst followed the guarded frame: it belongs to the SOS
  /// the SDK closed. Stop it again; tell the user once.
  func evaluateStaleCandidate() -> IosNativeSosTransition {
    var transition = IosNativeSosTransition()
    guard let kind = staleGuardKind,
          let candidateAt = defaults.object(forKey: Keys.staleGuardCandidateAt) as? Int,
          now() - candidateAt > Self.staleBurstWindowMs else {
      lastStaleAction = "none"
      return transition
    }
    lastStaleAction = "stale"
    defaults.removeObject(forKey: Keys.staleGuardCandidateAt)
    defaults.removeObject(forKey: Keys.staleGuardCandidatePushes)
    transition.stopTag = kind
    if !defaults.bool(forKey: Keys.staleGuardNoticeShown) {
      defaults.set(true, forKey: Keys.staleGuardNoticeShown)
      transition.staleStopNotice = true
    }
    return transition
  }

  private func armStaleGuard(_ kind: IosSosTerminalKind, nodeId: Int?, linkDropped: Bool) {
    disarmStaleGuard()
    defaults.set(kind.rawValue, forKey: Keys.staleGuardKind)
    set(nodeId, forKey: Keys.staleGuardNodeId)
    defaults.set(now(), forKey: Keys.staleGuardArmedAt)
    defaults.set(now(), forKey: Keys.staleGuardLastFrameAt)
    defaults.set(linkDropped, forKey: Keys.staleGuardLinkDropped)
  }

  /// Also the session change (`force`): a guard never crosses accounts.
  func disarmStaleGuardForSessionChange() {
    disarmStaleGuard()
    clearDartCycle()
  }

  func disarmStaleGuard() {
    for key in [Keys.staleGuardKind, Keys.staleGuardNodeId, Keys.staleGuardArmedAt,
                Keys.staleGuardLastFrameAt, Keys.staleGuardLinkDropped,
                Keys.staleGuardCandidateAt, Keys.staleGuardCandidatePushes,
                Keys.staleGuardLastPushAt, Keys.staleGuardNoticeShown] {
      defaults.removeObject(forKey: key)
    }
  }

  /// nil: not guarded, handle the frame normally. Otherwise the guard's
  /// decision for this countdown/active frame.
  private func observeGuardedFrame(nodeId: Int?, driveCycle: Bool = true) -> IosNativeSosTransition? {
    guard staleGuardKind != nil else {
      lastStaleAction = "notArmed"
      return nil
    }
    let timestamp = now()
    let armedAt = defaults.object(forKey: Keys.staleGuardArmedAt) as? Int ?? timestamp
    let lastFrameAt = defaults.object(forKey: Keys.staleGuardLastFrameAt) as? Int ?? armedAt
    let linkDropped = defaults.bool(forKey: Keys.staleGuardLinkDropped)
    let guardNode = defaults.object(forKey: Keys.staleGuardNodeId) as? Int
    if guardNode != nil && nodeId != nil && guardNode != nodeId {
      lastStaleAction = "ignored"
      return nil  // another TAG: not this guard's business (never disarms it)
    }
    if timestamp - armedAt > Self.staleGuardMaxMs ||
       (!linkDropped && timestamp - lastFrameAt > Self.staleGapMs) {
      // Cap, or the TAG went idle (gap without a link drop).
      disarmStaleGuard()
      lastStaleAction = "disarmed"
      return nil
    }
    if let lastPush = defaults.object(forKey: Keys.staleGuardLastPushAt) as? Int,
       timestamp - lastPush < Self.staleDuplicateMs {
      // The TEL copy of the same push, or (F17c) the same push through the
      // other BLE path.
      lastStaleAction = "duplicate"
      return IosNativeSosTransition()
    }
    defaults.set(timestamp, forKey: Keys.staleGuardLastPushAt)
    defaults.set(timestamp, forKey: Keys.staleGuardLastFrameAt)
    defaults.set(false, forKey: Keys.staleGuardLinkDropped)
    if let candidateAt = defaults.object(forKey: Keys.staleGuardCandidateAt) as? Int,
       timestamp - candidateAt <= Self.staleBurstWindowMs {
      let pushes = (defaults.object(forKey: Keys.staleGuardCandidatePushes) as? Int ?? 1) + 1
      defaults.set(pushes, forKey: Keys.staleGuardCandidatePushes)
      guard pushes >= Self.staleBurstPushes else {
        lastStaleAction = "pending"
        return IosNativeSosTransition()
      }
      // Countdown burst: a new SOS, counted from its first push.
      lastStaleAction = "newSos"
      disarmStaleGuard()
      guard driveCycle else {
        // Dart received this burst and runs the SOS (F17c).
        return IosNativeSosTransition()
      }
      let deadline = candidateAt + Self.countdownMs
      setCycle(.preConfirmSeen, key: nil, nodeId: nodeId, deadlineAt: deadline)
      defaults.set(candidateAt, forKey: Keys.cycleStartedAt)
      defaults.removeObject(forKey: Keys.firstFrameAfterCloseAt)
      var transition = IosNativeSosTransition()
      if timestamp >= deadline {
        transition = promoteExpiredCountdown(deviceId: nil)
      } else {
        transition.countdownDeadlineAt = deadline
      }
      return transition
    }
    // An earlier candidate whose decision was missed (suspended) was the
    // closed SOS: stop it now. This push opens the next candidate.
    var transition = evaluateStaleCandidate()
    defaults.set(timestamp, forKey: Keys.staleGuardCandidateAt)
    defaults.set(1, forKey: Keys.staleGuardCandidatePushes)
    transition.evaluateStaleAt = timestamp + Self.staleDecisionMs
    lastStaleAction = "pending"
    return transition
  }

  /// Native countdown deadline while it runs: the snapshot must show a
  /// countdown, never a sent SOS (frames carry sosType 3 from the start).
  var countdownDeadlineAt: Int? {
    cycleState == .preConfirmSeen ? cycleDeadlineAt : nil
  }

  /// A pending TAG cancel only cancels a pending SOS created before it; a
  /// newer SOS (created while an older cancel was not yet handed over) wins.
  var pendingCancelSupersedesCreate: Bool {
    guard let cancelAt = pendingCancelCreatedAt else { return false }
    guard let createAt = pendingCreateRecord?["createdAt"] as? Int else { return true }
    return cancelAt >= createAt
  }

  /// Which local SOS notification a countdown/active frame raises once the
  /// cycle was updated: the countdown stage → pre-SOS, the handed-over stage
  /// → active. Keyed by the cycle, so the TAG's repeated frames (new packet
  /// id each time) raise it once. Close frames are handled by the caller.
  func notification(
    for kind: IosBleSosSnapshotKind
  ) -> (kind: IosBleSosSnapshotKind, cycleKey: String?)? {
    guard kind == .preSos || kind == .active else { return nil }
    switch cycleState {
    case .idle:
      return nil
    case .preConfirmSeen:
      return (.preSos, notificationCycleId)
    case .createPending:
      return (.active, notificationCycleId)
    }
  }

  /// Unique per SOS: the frame cycle key alone repeats (4-bit packet id), so
  /// a later SOS could be deduplicated against an earlier one.
  var notificationCycleId: String? {
    guard cycleState != .idle else { return nil }
    let started = defaults.object(forKey: Keys.cycleStartedAt) as? Int ?? 0
    return "\(cycleKey ?? "cycle")@\(started)"
  }

  /// Countdown timer fired, or a snapshot / resume / restoration found the
  /// countdown already elapsed while the app was suspended.
  func promoteExpiredCountdown(deviceId: String?) -> IosNativeSosTransition {
    var transition = IosNativeSosTransition()
    guard cycleState == .preConfirmSeen,
          let deadline = cycleDeadlineAt,
          now() >= deadline else {
      return transition
    }
    promote(reason: "device_cycle_active_after_timeout", deviceId: deviceId)
    transition.queuedCreate = true
    transition.countdownStopped = true
    return transition
  }

  /// Drops the TAG cycle: a countdown in progress is never promoted later.
  /// Pending records stay: they describe an SOS / cancel the TAG already
  /// produced. The runtime stop uses `stopObserving()`, which keeps a
  /// running countdown.
  func resetCycle() -> Bool {
    let wasCounting = cycleState == .preConfirmSeen
    setCycle(.idle, key: nil, nodeId: nil, deadlineAt: nil)
    defaults.removeObject(forKey: Keys.cycleStartedAt)
    defaults.removeObject(forKey: Keys.firstFrameAfterCloseAt)
    defaults.removeObject(forKey: Keys.pendingEvents)
    return wasCounting
  }

  /// Protection stopped: native no longer observes the TAG. A countdown in
  /// progress is kept and still promoted at its deadline (F11: reopening the
  /// app during a background TAG countdown stopped the runtime and lost the
  /// SOS); the SDK's terminal closes it (`closeDeliveredCycle`) if Dart sees
  /// a cancel. Any other cycle is reset as before. Returns the kept deadline,
  /// or nil when the cycle was reset.
  func stopObserving() -> Int? {
    guard cycleState == .preConfirmSeen, let deadline = cycleDeadlineAt else {
      _ = resetCycle()
      return nil
    }
    defaults.removeObject(forKey: Keys.pendingEvents)
    defaults.set(true, forKey: Keys.cycleKeptAfterStop)
    return deadline
  }

  /// Protection armed again: native observes the TAG (and its close frame)
  /// itself, so a kept countdown is a normal observed countdown again.
  func resumeObserving() {
    defaults.removeObject(forKey: Keys.cycleKeptAfterStop)
  }

  private func promote(reason: String, deviceId: String?) {
    let frameKey = cycleKey ?? "native-sos-cycle"
    let nodeId = cycleNodeId
    let started = defaults.object(forKey: Keys.cycleStartedAt) as? Int ?? now()
    setCycle(.createPending, key: frameKey, nodeId: nodeId, deadlineAt: nil)
    defaults.set(started, forKey: Keys.cycleStartedAt)
    // The frame cycle key (node + 4-bit packet id) repeats across SOS. The
    // SDK fences a pending SOS whose cycle equals the one it just closed, so
    // a new SOS with a recycled key was dropped as a replay (device QA): the
    // hand-off identity is unique per cycle.
    let key = "\(frameKey)@\(started)"
    let timestamp = now()
    // Reuse a pending record only for the same TAG cycle: an older record
    // must never lend its identity to a new SOS.
    let existing = pendingCreateRecord.flatMap { record in
      record["cycleKey"] as? String == key ? record : nil
    }
    let incidentId = existing?["incidentId"] as? String ?? "native-sos-\(Self.sanitize(key))"
    let correlationId = existing?["correlationId"] as? String ?? "native-sos-\(timestamp)"
    var record: [String: Any] = [
      "incidentId": incidentId,
      "cycleKey": key,
      "correlationId": correlationId,
      "source": "native_protection_sos",
      "triggerSource": "native_protection_sos",
      "createdAt": existing?["createdAt"] as? Int ?? timestamp,
      "updatedAt": timestamp,
      "state": "pending_mqtt",
      "retryCount": existing?["retryCount"] as? Int ?? 0,
      "reason": reason,
    ]
    if let nodeId {
      record["nodeId"] = nodeId
      record["deviceId"] = String(nodeId)
    } else if let deviceId, !deviceId.isEmpty {
      record["deviceId"] = deviceId
    }
    record["signature"] = Self.signature(incidentId: incidentId, cycleKey: key, correlationId: correlationId)
    defaults.set(record, forKey: Keys.pendingCreate)
  }

  private func setCycle(
    _ state: IosNativeSosCycleState,
    key: String?,
    nodeId: Int?,
    deadlineAt: Int?
  ) {
    defaults.set(state.rawValue, forKey: Keys.cycleState)
    defaults.removeObject(forKey: Keys.cycleKeptAfterStop)
    set(key, forKey: Keys.cycleKey)
    set(nodeId, forKey: Keys.cycleNodeId)
    set(deadlineAt, forKey: Keys.cycleDeadlineAt)
  }

  private func set(_ value: Any?, forKey key: String) {
    if let value {
      defaults.set(value, forKey: key)
    } else {
      defaults.removeObject(forKey: key)
    }
  }

  // MARK: - Pending create (Android contract)

  private var pendingCreateRecord: [String: Any]? {
    defaults.dictionary(forKey: Keys.pendingCreate)
  }

  var pendingCreateCount: Int { pendingCreateRecord == nil ? 0 : 1 }

  func peekPendingCreate() -> [String: Any]? { pendingCreateRecord }

  func markPendingCreate(signature: String, state: String, published: Bool = false) {
    guard var record = matchingCreate(signature) else { return }
    let timestamp = now()
    record["state"] = state
    record["updatedAt"] = timestamp
    record["lastAttemptAt"] = timestamp
    if published {
      record["lastPublishedAt"] = timestamp
    } else {
      record["retryCount"] = (record["retryCount"] as? Int ?? 0) + 1
    }
    defaults.set(record, forKey: Keys.pendingCreate)
  }

  func retainPendingCreate(signature: String, reason: String) {
    guard var record = matchingCreate(signature) else { return }
    record["updatedAt"] = now()
    record["result"] = "NATIVE_SOS_PENDING_RETAINED:\(reason)"
    defaults.set(record, forKey: Keys.pendingCreate)
  }

  /// Dart's outbox owns the SOS (confirmed, or durably queued): retire it.
  func ackPendingCreate(signature: String) -> Bool {
    guard matchingCreate(signature) != nil else { return false }
    defaults.removeObject(forKey: Keys.pendingCreate)
    return true
  }

  func dropPendingCreate(signature: String) -> Bool {
    ackPendingCreate(signature: signature)
  }

  private func matchingCreate(_ signature: String) -> [String: Any]? {
    let normalized = signature.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, let record = pendingCreateRecord else { return nil }
    if record["signature"] as? String == normalized ||
       record["correlationId"] as? String == normalized {
      return record
    }
    return nil
  }

  // MARK: - Pending cancel

  private var pendingCancelRecord: [String: Any]? {
    defaults.dictionary(forKey: Keys.pendingCancel)
  }

  var pendingCancelCount: Int { pendingCancelRecord == nil ? 0 : 1 }

  /// When the TAG cancel was observed; the SDK orders it against newer SOS.
  var pendingCancelCreatedAt: Int? { pendingCancelRecord?["createdAt"] as? Int }

  private func storePendingCancel() {
    var record: [String: Any] = [
      "createdAt": now(),
      "state": "pending",
    ]
    if let key = cycleKey {
      record["lifecycleId"] = key
    }
    defaults.set(record, forKey: Keys.pendingCancel)
  }

  /// The SDK's MQTT outbox accepted the TAG cancel.
  func ackPendingCancel() -> Bool {
    guard pendingCancelRecord != nil else { return false }
    defaults.removeObject(forKey: Keys.pendingCancel)
    return true
  }

  // MARK: - Ordered SOS event queue (Dart not listening)

  func enqueue(event: [String: Any]) {
    guard let type = event["type"] as? String, Self.sosEventTypes.contains(type) else {
      return
    }
    var queue = defaults.array(forKey: Keys.pendingEvents) as? [[String: Any]] ?? []
    queue.append(event)
    if queue.count > Self.eventQueueCapacity {
      queue.removeFirst(queue.count - Self.eventQueueCapacity)
    }
    defaults.set(queue, forKey: Keys.pendingEvents)
  }

  /// Oldest first; the queue is emptied. Events older than [maxAgeMs] are
  /// dropped: the durable pending records carry anything still owed.
  func drainEvents(maxAgeMs: Int = 15 * 60 * 1000) -> [[String: Any]] {
    let queue = defaults.array(forKey: Keys.pendingEvents) as? [[String: Any]] ?? []
    defaults.removeObject(forKey: Keys.pendingEvents)
    let oldest = now() - maxAgeMs
    return queue.filter { ($0["timestamp"] as? Int ?? 0) >= oldest }
  }

  // MARK: - Helpers

  static func signature(incidentId: String, cycleKey: String, correlationId: String) -> String {
    "\(incidentId):\(cycleKey):\(correlationId)"
  }

  static func sanitize(_ value: String) -> String {
    String(value.map { character -> Character in
      character.isASCII && (character.isLetter || character.isNumber || "_.-".contains(character))
        ? character
        : "-"
    })
  }
}
