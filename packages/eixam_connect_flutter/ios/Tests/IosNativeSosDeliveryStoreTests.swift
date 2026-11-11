import Darwin
import Foundation

/// Run with swiftc alongside the store and the classifier (for the kind enum):
///   swiftc -parse-as-library -o /tmp/ios_sos_delivery_tests \
///     Classes/IosBleSosFrameClassifier.swift \
///     Classes/TelAggregateReassembler.swift \
///     Classes/IosNativeSosDeliveryStore.swift \
///     Tests/IosNativeSosDeliveryStoreTests.swift && /tmp/ios_sos_delivery_tests
///
/// Mirrors Android's ProtectionSosLifecycleLogic / runtime-store pending
/// create/cancel contract; persistence is checked by re-opening the store on
/// the same UserDefaults suite (process death).
@main
struct IosNativeSosDeliveryStoreTests {
  private static var failures = 0
  private static var clock = 1_000_000

  static func main() {
    setbuf(stdout, nil)
    countdownPromotesToPendingCreate()
    countdownExpiredWhileSuspendedPromotesOnNextFrame()
    cancelBeforeCreateQueuesNoBackendCancel()
    cancelAfterCreateQueuesDurableCancel()
    backendTerminalNeverQueuesCancel()
    newCycleAfterCloseGetsNewIdentity()
    pendingRecordsSurviveProcessDeath()
    signatureGuardsAckAndDrop()
    eventQueueKeepsOrderAndOnlySosEvents()
    activeFrameStartsCountdownNotSos()
    repeatedFramesOfActiveSosAreNotNewSos()
    notificationIsOncePerCycleAndStage()
    recycledFrameKeyGivesNewIdentity()
    missedCloseFrameNeverBlocksTheNextSos()
    sdkCloseKeepsAnSosNotHandedOver()
    framesRightAfterACloseNeverOpenAnSos()
    realSosInsideTheQuietWindowIsBackdated()
    olderCancelNeverDropsANewerSos()
    countdownIsReportedAsCountdown()
    claimedCreateIsKeptOnCancel()
    resetCycleNeverPromotesAfterStop()
    countdownKeptAcrossStopIsPromotedAtDeadline()
    sdkCloseDropsACountdownKeptAcrossStop()
    stopStillResetsANonCountdownCycle()
    keptCountdownClosesOnlyForItsTag()
    rearmedRuntimeOwnsTheKeptCountdownAgain()
    oldQueuedEventsAreNotReplayed()
    if failures > 0 {
      print("FAILED: \(failures)")
      exit(1)
    }
    print("OK: IosNativeSosDeliveryStoreTests")
  }

  private static func makeStore(suite: String = UUID().uuidString) -> (IosNativeSosDeliveryStore, UserDefaults) {
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return (IosNativeSosDeliveryStore(defaults: defaults, now: { clock }), defaults)
  }

  private static func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition {
      failures += 1
      print("FAIL line \(line): \(message)")
    }
  }

  static func countdownPromotesToPendingCreate() {
    let (store, _) = makeStore()
    let started = store.observe(kind: .preSos, nodeId: 7, cycleKey: "sos:7:2", deviceId: nil)
    check(started.countdownDeadlineAt == clock + 20_000, "countdown deadline scheduled")
    check(store.cycleState == .preConfirmSeen, "countdown seen")
    check(store.promoteExpiredCountdown(deviceId: nil) == IosNativeSosTransition(), "no promotion before deadline")
    clock += 20_000
    let promoted = store.promoteExpiredCountdown(deviceId: nil)
    check(promoted.queuedCreate && promoted.countdownStopped, "promoted at deadline")
    let pending = store.peekPendingCreate()
    check((pending?["cycleKey"] as? String)?.hasPrefix("sos:7:2@") == true, "cycle identity kept")
    check((pending?["incidentId"] as? String)?.hasPrefix("native-sos-sos-7-2-") == true, "stable incident id")
    check(pending?["nodeId"] as? Int == 7 && pending?["deviceId"] as? String == "7", "device identity")
    check(pending?["state"] as? String == "pending_mqtt", "pending_mqtt state")
    check(store.promoteExpiredCountdown(deviceId: nil) == IosNativeSosTransition(), "promoted once")
  }

  static func countdownExpiredWhileSuspendedPromotesOnNextFrame() {
    let (store, _) = makeStore()
    _ = store.observe(kind: .preSos, nodeId: 7, cycleKey: "sos:7:3", deviceId: nil)
    clock += 25_000
    let next = store.observe(kind: .preSos, nodeId: 7, cycleKey: "sos:7:4", deviceId: nil)
    check(next.queuedCreate, "late countdown frame promotes")
    check((store.peekPendingCreate()?["cycleKey"] as? String)?.hasPrefix("sos:7:3@") == true, "keeps the cycle's first identity")
  }

  static func cancelBeforeCreateQueuesNoBackendCancel() {
    let (store, _) = makeStore()
    _ = store.observe(kind: .preSos, nodeId: 7, cycleKey: "sos:7:8", deviceId: nil)
    let cancelled = store.observe(kind: .cancelled, nodeId: 7, cycleKey: "sos:7", deviceId: nil)
    check(!cancelled.queuedCancel && cancelled.countdownStopped, "countdown cancel stays local")
    check(store.pendingCancelCount == 0 && store.pendingCreateCount == 0, "nothing for the backend")
    check(store.cycleState == .idle, "cycle closed")
  }

  static func cancelAfterCreateQueuesDurableCancel() {
    let (store, _) = makeStore()
    _ = store.observe(kind: .active, nodeId: 7, cycleKey: "sos:7:9", deviceId: nil)
    clock += 20_000
    _ = store.promoteExpiredCountdown(deviceId: nil)
    clock += 5_000
    let cancelled = store.observe(kind: .cancelled, nodeId: 7, cycleKey: "sos:7", deviceId: nil)
    check(cancelled.queuedCancel, "TAG cancel of an SOS queues a backend cancel")
    check(store.pendingCancelCreatedAt == clock, "cancel keeps its observation time")
    check(store.pendingCreateCount == 0, "a never-claimed create is retired natively (no zombie)")
    check(store.ackPendingCancel(), "SDK outbox accepts it")
    check(!store.ackPendingCancel(), "accepted once")
  }

  static func backendTerminalNeverQueuesCancel() {
    let (store, _) = makeStore()
    _ = store.observe(kind: .active, nodeId: 7, cycleKey: "sos:7:10", deviceId: nil)
    clock += 20_000
    _ = store.promoteExpiredCountdown(deviceId: nil)
    let resolved = store.observe(kind: .resolved, nodeId: 7, cycleKey: "sos:7", deviceId: nil)
    check(!resolved.queuedCancel, "0xE3 is never a TAG cancel")
    check(store.pendingCancelCount == 0 && store.cycleState == .idle, "closed without cancel")
  }

  static func newCycleAfterCloseGetsNewIdentity() {
    let (store, _) = makeStore()
    _ = store.observe(kind: .active, nodeId: 7, cycleKey: "sos:7:11", deviceId: nil)
    clock += 20_000
    _ = store.promoteExpiredCountdown(deviceId: nil)
    let first = store.peekPendingCreate()
    _ = store.observe(kind: .cancelled, nodeId: 7, cycleKey: "sos:7", deviceId: nil)
    clock += 60_000  // after the post-close quiet window
    let next = store.observe(kind: .active, nodeId: 7, cycleKey: "sos:7:12", deviceId: nil)
    check(next.countdownDeadlineAt != nil, "new SOS after a close starts its countdown")
    clock += 20_000
    check(store.promoteExpiredCountdown(deviceId: nil).queuedCreate, "queued at its deadline")
    let second = store.peekPendingCreate()
    check((second?["cycleKey"] as? String)?.hasPrefix("sos:7:12@") == true, "new cycle identity")
    check(second?["signature"] as? String != first?["signature"] as? String, "new signature")
    check(second?["createdAt"] as? Int == clock, "new creation time")
  }

  static func pendingRecordsSurviveProcessDeath() {
    let suite = "ios-sos-delivery-death-\(UUID().uuidString)"
    let (store, defaults) = makeStore(suite: suite)
    _ = store.observe(kind: .preSos, nodeId: 7, cycleKey: "sos:7:13", deviceId: nil)
    // Process dies during the countdown; relaunched after the deadline.
    clock += 60_000
    let relaunched = IosNativeSosDeliveryStore(defaults: defaults, now: { clock })
    check(relaunched.cycleState == .preConfirmSeen, "countdown survives")
    check(relaunched.promoteExpiredCountdown(deviceId: nil).queuedCreate, "promoted after relaunch")
    _ = relaunched.observe(kind: .cancelled, nodeId: 7, cycleKey: "sos:7", deviceId: nil)
    let again = IosNativeSosDeliveryStore(defaults: defaults, now: { clock })
    check(again.pendingCreateCount == 0 && again.pendingCancelCount == 1, "unclaimed create retired, cancel survives")
    defaults.removePersistentDomain(forName: suite)
  }

  static func signatureGuardsAckAndDrop() {
    let (store, _) = makeStore()
    _ = store.observe(kind: .active, nodeId: 7, cycleKey: "sos:7:14", deviceId: nil)
    clock += 20_000
    _ = store.promoteExpiredCountdown(deviceId: nil)
    let signature = store.peekPendingCreate()?["signature"] as? String ?? ""
    check(!store.ackPendingCreate(signature: "other"), "foreign signature rejected")
    store.markPendingCreate(signature: signature, state: "mqtt_flush_started")
    check(store.peekPendingCreate()?["retryCount"] as? Int == 1, "flush attempt counted")
    store.markPendingCreate(signature: signature, state: "mqtt_published_pending_backend_confirm", published: true)
    check(store.peekPendingCreate()?["lastPublishedAt"] as? Int == clock, "publish time kept")
    check(store.dropPendingCreate(signature: signature), "own signature dropped")
    check(store.pendingCreateCount == 0, "retired")
  }

  static func eventQueueKeepsOrderAndOnlySosEvents() {
    let (store, _) = makeStore()
    store.enqueue(event: ["type": "woke", "timestamp": 1])
    for index in 0..<(IosNativeSosDeliveryStore.eventQueueCapacity + 3) {
      store.enqueue(event: [
        "type": index.isMultiple(of: 2) ? "ownDeviceSosLifecycleObserved" : "nativeBackendSyncQueued",
        "timestamp": clock + index,
      ])
    }
    let drained = store.drainEvents()
    check(drained.count == IosNativeSosDeliveryStore.eventQueueCapacity, "bounded")
    check(drained.first?["timestamp"] as? Int == clock + 3, "oldest overflow dropped")
    check(drained.map { ($0["timestamp"] as? Int ?? -1) - clock } == Array(3..<(IosNativeSosDeliveryStore.eventQueueCapacity + 3)), "in order")
    check(store.drainEvents().isEmpty, "drained once")
  }

  static func claimedCreateIsKeptOnCancel() {
    let (store, _) = makeStore()
    _ = store.observe(kind: .active, nodeId: 7, cycleKey: "sos:7:20", deviceId: nil)
    clock += 20_000
    _ = store.promoteExpiredCountdown(deviceId: nil)
    let signature = store.peekPendingCreate()?["signature"] as? String ?? ""
    store.markPendingCreate(signature: signature, state: "mqtt_flush_started")
    let cancelled = store.observe(kind: .cancelled, nodeId: 7, cycleKey: "sos:7", deviceId: nil)
    check(cancelled.queuedCancel, "cancel queued")
    check(store.pendingCreateCount == 1, "a claimed create stays: the SDK outbox orders the cancel after it")
  }

  static func resetCycleNeverPromotesAfterStop() {
    let (store, _) = makeStore()
    _ = store.observe(kind: .preSos, nodeId: 7, cycleKey: "sos:7:24", deviceId: nil)
    check(store.resetCycle(), "countdown was running")
    clock += 30_000
    check(!store.promoteExpiredCountdown(deviceId: nil).queuedCreate, "no promotion after stop")
    check(store.pendingCreateCount == 0, "nothing to publish")
  }

  /// F11: the app reopened during a background TAG countdown and the host
  /// stopped the runtime; the SOS must still reach the backend.
  static func countdownKeptAcrossStopIsPromotedAtDeadline() {
    let (store, _) = makeStore()
    _ = store.observe(kind: .preSos, nodeId: 7, cycleKey: "sos:7:60", deviceId: nil)
    let deadline = store.cycleDeadlineAt
    check(deadline != nil && store.stopObserving() == deadline, "countdown kept with its deadline")
    check(store.cycleState == .preConfirmSeen, "countdown still running after stop")
    check(store.countdownDeadlineAt == deadline, "snapshot still shows the countdown")
    check(!store.promoteExpiredCountdown(deviceId: nil).queuedCreate, "no promotion before deadline")
    clock += 20_000
    let promoted = store.promoteExpiredCountdown(deviceId: nil)
    check(promoted.queuedCreate && promoted.countdownStopped, "kept countdown promoted at its deadline")
    check(store.cycleState == .createPending, "handed over")
    check(store.pendingCreateCount == 1, "durable pending create stored")
    check((store.peekPendingCreate()?["cycleKey"] as? String)?.hasPrefix("sos:7:60@") == true, "cycle identity kept")
  }

  /// After the stop Dart owns BLE: its TAG/app cancel (SDK terminal) closes
  /// the kept countdown, so it is never promoted (no false SOS).
  static func sdkCloseDropsACountdownKeptAcrossStop() {
    let (store, _) = makeStore()
    _ = store.observe(kind: .preSos, nodeId: 7, cycleKey: "sos:7:61", deviceId: nil)
    _ = store.stopObserving()
    clock += 5_000
    check(store.closeDeliveredCycle(), "SDK terminal closes the kept countdown")
    check(store.cycleState == .idle, "cycle closed")
    clock += 30_000
    check(!store.promoteExpiredCountdown(deviceId: nil).queuedCreate, "never promoted after the cancel")
    check(store.pendingCreateCount == 0, "nothing to publish")
  }

  static func stopStillResetsANonCountdownCycle() {
    let (store, _) = makeStore()
    _ = store.observe(kind: .active, nodeId: 7, cycleKey: "sos:7:62", deviceId: nil)
    clock += 20_000
    _ = store.promoteExpiredCountdown(deviceId: nil)
    _ = store.observe(kind: .cancelled, nodeId: 7, cycleKey: "sos:7:62", deviceId: nil)
    check(store.pendingCancelCount == 1, "TAG cancel pending")
    clock += 60_000
    _ = store.observe(kind: .active, nodeId: 7, cycleKey: "sos:7:63", deviceId: nil)
    clock += 20_000
    _ = store.promoteExpiredCountdown(deviceId: nil)
    check(store.stopObserving() == nil, "a handed-over cycle is reset, not kept")
    check(store.cycleState == .idle, "cycle reset")
    check(store.pendingCreateCount == 1 && store.pendingCancelCount == 1, "pending records kept")
  }

  /// A terminal of another TAG never closes the kept countdown.
  static func keptCountdownClosesOnlyForItsTag() {
    let (store, _) = makeStore()
    _ = store.observe(kind: .preSos, nodeId: 7, cycleKey: "sos:7:64", deviceId: nil)
    _ = store.stopObserving()
    check(!store.closeDeliveredCycle(nodeId: 9), "another TAG's terminal keeps the countdown")
    check(store.cycleState == .preConfirmSeen, "countdown still running")
    check(store.closeDeliveredCycle(nodeId: 7), "its own TAG's terminal closes it")
    clock += 30_000
    check(!store.promoteExpiredCountdown(deviceId: nil).queuedCreate, "never promoted")

    // A countdown whose frames carried no node id is closed by any terminal
    // the SDK reports: keeping it would risk a false SOS.
    let (anonymous, _) = makeStore()
    _ = anonymous.observe(kind: .preSos, nodeId: nil, cycleKey: "sos:-:3", deviceId: nil)
    _ = anonymous.stopObserving()
    check(anonymous.closeDeliveredCycle(nodeId: 7), "unknown-node countdown closed by the SDK terminal")
    clock += 30_000
    check(!anonymous.promoteExpiredCountdown(deviceId: nil).queuedCreate, "unknown-node countdown never promoted")
  }

  /// Protection armed again: native observes the TAG itself (and its cancel
  /// frame), so the SDK close no longer drops the countdown.
  static func rearmedRuntimeOwnsTheKeptCountdownAgain() {
    let (store, _) = makeStore()
    _ = store.observe(kind: .preSos, nodeId: 7, cycleKey: "sos:7:65", deviceId: nil)
    _ = store.stopObserving()
    store.resumeObserving()
    check(!store.closeDeliveredCycle(nodeId: nil), "observed countdown is not closed by the SDK")
    clock += 20_000
    check(store.promoteExpiredCountdown(deviceId: nil).queuedCreate, "promoted at its deadline")
  }

  static func oldQueuedEventsAreNotReplayed() {
    let (store, _) = makeStore()
    store.enqueue(event: ["type": "nativeBackendSyncQueued", "timestamp": clock])
    clock += 16 * 60 * 1000
    store.enqueue(event: ["type": "nativeBackendSyncQueued", "timestamp": clock])
    check(store.drainEvents().count == 1, "only recent events replayed")
  }

  static func activeFrameStartsCountdownNotSos() {
    // Real TAG (fw 2.7.68): first frame at countdown start is sosType 3.
    let (store, _) = makeStore()
    let first = store.observe(kind: .active, nodeId: 7, cycleKey: "sos:7:30", deviceId: nil)
    check(!first.queuedCreate, "no SOS for the backend inside the countdown")
    check(first.countdownDeadlineAt == clock + 20_000, "countdown started")
    clock += 10_000
    let cancelled = store.observe(kind: .cancelled, nodeId: 7, cycleKey: "sos:7", deviceId: nil)
    check(!cancelled.queuedCancel && store.pendingCreateCount == 0, "cancel in the countdown stays local")

    let (fresh, _) = makeStore()
    _ = fresh.observe(kind: .active, nodeId: nil, cycleKey: nil, deviceId: "PERIPHERAL-1")
    clock += 20_000
    check(fresh.promoteExpiredCountdown(deviceId: "PERIPHERAL-1").queuedCreate, "queued at the deadline")
    check(fresh.peekPendingCreate()?["deviceId"] as? String == "PERIPHERAL-1", "falls back to protected device id")
  }

  static func repeatedFramesOfActiveSosAreNotNewSos() {
    let (store, _) = makeStore()
    _ = store.observe(kind: .active, nodeId: 7, cycleKey: "sos:7:31", deviceId: nil)
    clock += 20_000
    _ = store.promoteExpiredCountdown(deviceId: nil)
    let signature = store.peekPendingCreate()?["signature"] as? String ?? ""
    _ = store.ackPendingCreate(signature: signature)
    for packet in 32...35 {
      clock += 5_000
      let repeated = store.observe(kind: .active, nodeId: 7, cycleKey: "sos:7:\(packet)", deviceId: nil)
      check(repeated == IosNativeSosTransition(), "repeat \(packet) of the delivered SOS is ignored")
    }
    check(store.pendingCreateCount == 0, "no second SOS")
  }

  static func notificationIsOncePerCycleAndStage() {
    let (store, _) = makeStore()
    _ = store.observe(kind: .active, nodeId: 7, cycleKey: "sos:7:40", deviceId: nil)
    let started = clock
    let countdown = store.notification(for: .active)
    check(countdown?.kind == .preSos && countdown?.cycleKey == "sos:7:40@\(started)", "countdown notification, not 'SOS active'")
    clock += 2_000
    _ = store.observe(kind: .active, nodeId: 7, cycleKey: "sos:7:41", deviceId: nil)
    check(store.notification(for: .active)?.cycleKey == "sos:7:40@\(started)", "repeat frame: same key (deduped)")
    clock += 20_000
    _ = store.promoteExpiredCountdown(deviceId: nil)
    _ = store.observe(kind: .active, nodeId: 7, cycleKey: "sos:7:42", deviceId: nil)
    let active = store.notification(for: .active)
    check(active?.kind == .active && active?.cycleKey == "sos:7:40@\(started)", "active once, keyed by the cycle")
    check(store.notification(for: .cancelled) == nil, "close frames handled by the caller")
    // Next SOS that happens to reuse the same frame cycle key (4-bit packet
    // id) still gets its own notifications.
    _ = store.observe(kind: .cancelled, nodeId: 7, cycleKey: "sos:7", deviceId: nil)
    clock += 60_000
    _ = store.observe(kind: .active, nodeId: 7, cycleKey: "sos:7:40", deviceId: nil)
    check(store.notification(for: .active)?.cycleKey != "sos:7:40@\(started)", "a new SOS is never deduplicated against the previous one")
  }

  static func recycledFrameKeyGivesNewIdentity() {
    // Real TAG: 4-bit packet id, so a later SOS can start with the same
    // frame cycle key as the previous one.
    let (store, _) = makeStore()
    _ = store.observe(kind: .active, nodeId: 7, cycleKey: "sos:7:3", deviceId: nil)
    clock += 20_000
    _ = store.promoteExpiredCountdown(deviceId: nil)
    let first = store.peekPendingCreate()
    _ = store.ackPendingCreate(signature: first?["signature"] as? String ?? "")
    _ = store.observe(kind: .cancelled, nodeId: 7, cycleKey: "sos:7", deviceId: nil)
    clock += 90_000
    _ = store.observe(kind: .active, nodeId: 7, cycleKey: "sos:7:3", deviceId: nil)
    clock += 20_000
    _ = store.promoteExpiredCountdown(deviceId: nil)
    let second = store.peekPendingCreate()
    check(second?["cycleKey"] as? String != first?["cycleKey"] as? String, "new SOS never reuses the previous identity")
    check(second?["incidentId"] as? String != first?["incidentId"] as? String, "new incident id")
  }

  private static func deliver(_ store: IosNativeSosDeliveryStore, key: String) {
    _ = store.observe(kind: .active, nodeId: 7, cycleKey: key, deviceId: nil)
    clock += 20_000
    _ = store.promoteExpiredCountdown(deviceId: nil)
    _ = store.ackPendingCreate(signature: store.peekPendingCreate()?["signature"] as? String ?? "")
  }

  static func missedCloseFrameNeverBlocksTheNextSos() {
    let (store, _) = makeStore()
    deliver(store, key: "sos:7:50")
    // Resolved while the phone missed the TAG's close frame; the SDK knows.
    check(store.closeDeliveredCycle(), "SDK closes a handed-over cycle")
    check(store.cycleState == .idle, "cycle closed")
    clock += 3_600_000
    let next = store.observe(kind: .active, nodeId: 7, cycleKey: "sos:7:51", deviceId: nil)
    check(next.countdownDeadlineAt == clock + 20_000, "next SOS starts its countdown")
    clock += 20_000
    check(store.promoteExpiredCountdown(deviceId: nil).queuedCreate, "next SOS handed over")
  }

  static func sdkCloseKeepsAnSosNotHandedOver() {
    let (store, _) = makeStore()
    _ = store.observe(kind: .active, nodeId: 7, cycleKey: "sos:7:52", deviceId: nil)
    check(!store.closeDeliveredCycle(), "countdown is not closed by the SDK")
    clock += 20_000
    _ = store.promoteExpiredCountdown(deviceId: nil)
    check(!store.closeDeliveredCycle(), "an SOS not handed over yet is kept")
    check(store.pendingCreateCount == 1, "nothing lost")
  }

  static func framesRightAfterACloseNeverOpenAnSos() {
    let (store, _) = makeStore()
    deliver(store, key: "sos:7:53")
    _ = store.closeDeliveredCycle()
    // The TAG keeps repeating until it gets the close, then stops.
    for _ in 0..<5 {
      clock += 4_000
      let stale = store.observe(kind: .active, nodeId: 7, cycleKey: "sos:7:54", deviceId: nil)
      check(stale == IosNativeSosTransition(), "stale frame in the quiet window ignored")
    }
    clock += 600_000
    let fresh = store.observe(kind: .active, nodeId: 7, cycleKey: "sos:7:55", deviceId: nil)
    check(fresh.countdownDeadlineAt == clock + 20_000, "a much later SOS gets a full countdown")
  }

  static func realSosInsideTheQuietWindowIsBackdated() {
    let (store, _) = makeStore()
    _ = store.observe(kind: .active, nodeId: 7, cycleKey: "sos:7:56", deviceId: nil)
    clock += 5_000
    _ = store.observe(kind: .cancelled, nodeId: 7, cycleKey: "sos:7", deviceId: nil)
    // Accidental cancel, then a real SOS 8 s later; frames keep coming.
    clock += 8_000
    let firstFrame = clock
    _ = store.observe(kind: .active, nodeId: 7, cycleKey: "sos:7:57", deviceId: nil)
    clock += 10_000
    _ = store.observe(kind: .active, nodeId: 7, cycleKey: "sos:7:58", deviceId: nil)
    clock += 14_000
    let after = store.observe(kind: .active, nodeId: 7, cycleKey: "sos:7:59", deviceId: nil)
    check(after.queuedCreate, "countdown backdated to the first frame: already elapsed")
    check((store.peekPendingCreate()?["cycleKey"] as? String)?.hasSuffix("@\(firstFrame)") == true, "starts at the first frame")
  }

  static func olderCancelNeverDropsANewerSos() {
    let (store, _) = makeStore()
    deliver(store, key: "sos:7:60")
    clock += 1_000
    _ = store.observe(kind: .cancelled, nodeId: 7, cycleKey: "sos:7", deviceId: nil)
    check(store.pendingCancelSupersedesCreate, "cancel without a create: cancelPending")
    clock += 60_000
    _ = store.observe(kind: .active, nodeId: 7, cycleKey: "sos:7:61", deviceId: nil)
    clock += 20_000
    _ = store.promoteExpiredCountdown(deviceId: nil)
    check(store.pendingCancelCount == 1 && store.pendingCreateCount == 1, "older cancel not handed over yet")
    check(!store.pendingCancelSupersedesCreate, "the newer SOS is not reported as cancelled")
  }

  static func countdownIsReportedAsCountdown() {
    let (store, _) = makeStore()
    _ = store.observe(kind: .active, nodeId: 7, cycleKey: "sos:7:62", deviceId: nil)
    check(store.countdownDeadlineAt == clock + 20_000, "countdown deadline exposed")
    clock += 20_000
    _ = store.promoteExpiredCountdown(deviceId: nil)
    check(store.countdownDeadlineAt == nil, "no countdown once handed over")
  }
}
