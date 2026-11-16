import Darwin
import Foundation
import UserNotifications

/// Run with swiftc alongside the store and the classifier (for the kind enum):
///   swiftc -parse-as-library -o /tmp/ios_sos_delivery_tests \
///     Classes/IosBleSosFrameClassifier.swift \
///     Classes/TelAggregateReassembler.swift \
///     Classes/IosNativeSosDeliveryStore.swift \
///     Classes/IosSosPromptNotification.swift \
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
    sdkCancelOfARunningCountdownEndsIt()
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
    ambiguousClosedSosAsksAfterReconnect()
    staleResolvedSosGetsTheResolveCommand()
    countdownBurstAfterReconnectIsANewSos()
    tagCloseEndsTheGuardAndTheNextPressIsAdmitted()
    frameGapWithoutLinkDropEndsTheGuard()
    guardEndsAfterTenMinutes()
    closeWithRecentFramesStopsTheTagAtOnce()
    tagAlreadyClosedArmsNoGuard()
    reconnectRestartsTheGapClock()
    resendPairIsNotACountdown()
    otherTagNeverEndsTheGuard()
    unreportedDropRestartsTheGapClockAtReconnect()
    sessionChangeEndsTheGuard()
    forwardedFramesWithoutAGuardProceedAtOnce()
    sosSeenOnlyThroughDartArmsTheGuard()
    burstThroughDartNeverOpensTheNativeCycle()
    newSdkSosDropsAPendingDecision()
    sessionChangeForgetsTheDartCycle()
    promptTimeoutOpensTheSosThroughTheNativeCreate()
    promptSurvivesAnAppRestart()
    answersNeedAnOpenPrompt()
    promptNotificationActions()
    promptNotificationIsANormalLocalNotification()
    sharedStaleGuardScenarios()
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

  /// F17c-cdc: the app cancels the TAG countdown (8 s in) while the TAG is out
  /// of range: the countdown never becomes a native create. F17c prompt: the
  /// unconfirmed stop arms the record; the ACTIVE retry after the reconnect is
  /// ambiguous: the user is asked, nothing is stopped.
  static func sdkCancelOfARunningCountdownEndsIt() {
    let (store, _) = makeStore()
    _ = store.observe(kind: .active, nodeId: 7, cycleKey: "sos:7:70", deviceId: nil)
    clock += 8_000
    store.noteLinkDropped()
    check(store.closeDeliveredCycle(nodeId: 7, terminal: .cancel), "the SDK cancel ends the countdown")
    check(store.cycleState == .idle, "countdown closed")
    check(store.staleGuardKind == .cancel, "unconfirmed stop recorded")
    clock += 12_000
    _ = store.promoteExpiredCountdown(deviceId: nil)
    check(store.pendingCreateCount == 0, "a cancelled countdown is never promoted")
    clock += 10_000
    store.noteLinkUp()
    let retry = store.observe(kind: .active, nodeId: 7, cycleKey: "sos:7:71", deviceId: nil)
    check(store.lastStaleAction == "pending" && retry.stopTag == nil, "held, no stop written")
    clock += 2_000
    let decided = store.evaluateStaleCandidate()
    check(decided.openPromptDeadlineAt == clock + 30_000 && decided.stopTag == nil, "ambiguous: ask, never stop")
    check(store.pendingCreateCount == 0, "no native create before the answer")
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

  // MARK: - F17b stale guard (2026-11-15: the stop never reached the TAG; its
  // retry frames opened new incidents after every app cancel / portal resolve)

  /// One TAG push as it really arrives: the SOS-characteristic frame and its
  /// TEL copy a few ms later (firmware sendSOSViaBLE()).
  private static func push(_ store: IosNativeSosDeliveryStore, key: String, node: Int = 7) -> IosNativeSosTransition {
    let first = store.observe(kind: .active, nodeId: node, cycleKey: key, deviceId: nil)
    clock += 5
    let copy = store.observe(kind: .active, nodeId: node, cycleKey: key, deviceId: nil)
    check(copy.countdownDeadlineAt == nil && !copy.queuedCreate && copy.stopTag == nil, "the TEL copy is the same push")
    clock -= 5
    return first
  }

  /// A retry push of the closed SOS: no countdown burst after it.
  private static func staleFrame(_ store: IosNativeSosDeliveryStore, key: String) -> IosNativeSosTransition {
    let first = push(store, key: key)
    check(first.queuedCreate == false && first.countdownDeadlineAt == nil, "a guarded push never starts an SOS at once")
    check(first.evaluateStaleAt == clock + 2_000, "decided after the burst window")
    clock += 2_000
    return store.evaluateStaleCandidate()
  }

  static func ambiguousClosedSosAsksAfterReconnect() {
    let (store, _) = makeStore()
    deliver(store, key: "sos:7:70")
    // App cancel while the TAG link is down: the TAG keeps the SOS.
    store.noteLinkDropped()
    check(store.closeDeliveredCycle(nodeId: 7, terminal: .cancel), "SDK closes the handed-over cycle")
    check(store.staleGuardKind == .cancel, "record armed with the cancel")
    clock += 200_000  // reconnect minutes later (A1: a link drop keeps the record)
    let asked = staleFrame(store, key: "sos:7:71")
    check(asked.stopTag == nil, "F17c: never stopped without the user")
    check(asked.openPromptDeadlineAt == clock + 30_000, "the user is asked, 30 s")
    check(store.pendingCreateCount == 0 && store.cycleState == .idle, "no incident before the answer")
    clock += 5_000
    let no = store.answerPrompt("stopTag")
    check(no.stopTag == .cancel && !no.queuedCreate, "No: the cancel stop, no incident")
    check(store.promptDeadlineAt == nil && store.staleGuardKind == .cancel, "prompt closed, record kept")
    clock += 60_000  // the next retry frame of the same SOS
    let again = staleFrame(store, key: "sos:7:72")
    check(again.stopTag == .cancel, "within the No consent: stopped again")
    check(again.openPromptDeadlineAt == nil, "never asked twice for the same answer")
    check(store.pendingCreateCount == 0, "still no new incident")
  }

  static func promptTimeoutOpensTheSosThroughTheNativeCreate() {
    let (store, _) = makeStore()
    deliver(store, key: "sos:7:92")
    store.noteLinkDropped()
    _ = store.closeDeliveredCycle(nodeId: 7, terminal: .resolve)
    clock += 100_000
    let asked = staleFrame(store, key: "sos:7:93")
    let deadline = asked.openPromptDeadlineAt ?? 0
    clock = deadline - 1
    check(!store.answerPrompt("timeout").queuedCreate, "not before the deadline")
    clock = deadline
    let timeout = store.answerPrompt("timeout")
    check(store.lastStaleAction == "sosOpened", "timeout sends the SOS")
    check(timeout.queuedCreate && timeout.stopTag == nil, "native create queued, nothing stopped")
    check(store.pendingCreateCount == 1 && store.cycleState == .createPending, "a normal native SOS")
    check(store.staleGuardKind == nil && store.promptDeadlineAt == nil, "record and prompt ended")
  }

  static func promptSurvivesAnAppRestart() {
    let suite = UUID().uuidString
    let (store, defaults) = makeStore(suite: suite)
    deliver(store, key: "sos:7:94")
    store.noteLinkDropped()
    _ = store.closeDeliveredCycle(nodeId: 7, terminal: .cancel)
    clock += 100_000
    let deadline = staleFrame(store, key: "sos:7:95").openPromptDeadlineAt
    let restarted = IosNativeSosDeliveryStore(defaults: defaults, now: { clock })
    check(restarted.staleGuardKind == .cancel, "unconfirmed stop persisted")
    check(restarted.promptDeadlineAt == deadline && deadline != nil, "open prompt persisted")
    clock += 40_000
    check(restarted.answerPrompt("timeout").queuedCreate, "a deadline passed while dead: the SOS is sent")
  }

  static func answersNeedAnOpenPrompt() {
    let (store, _) = makeStore()
    deliver(store, key: "sos:7:96")
    _ = store.closeDeliveredCycle(nodeId: 7, terminal: .cancel)
    for choice in ["sendSos", "stopTag", "timeout"] {
      let t = store.answerPrompt(choice)
      check(store.lastStaleAction == "none" && !t.queuedCreate && t.stopTag == nil, "\(choice): no prompt, nothing")
    }
  }

  static func staleResolvedSosGetsTheResolveCommand() {
    let (store, _) = makeStore()
    deliver(store, key: "sos:7:73")
    check(store.closeDeliveredCycle(nodeId: 7, terminal: .resolve), "portal resolve closes it")
    clock += 40_000
    check(staleFrame(store, key: "sos:7:74").openPromptDeadlineAt != nil, "resolve: ask")
    check(store.answerPrompt("stopTag").stopTag == .resolve, "No gets the resolve command")
  }

  static func countdownBurstAfterReconnectIsANewSos() {
    let (store, _) = makeStore()
    deliver(store, key: "sos:7:75")
    store.noteLinkDropped()
    _ = store.closeDeliveredCycle(nodeId: 7, terminal: .cancel)
    clock += 120_000
    let firstFrame = clock
    _ = push(store, key: "sos:7:0")
    clock += 500  // the TAG countdown pushes every 500 ms for 2 s (each twice)
    check(push(store, key: "sos:7:0").countdownDeadlineAt == nil, "two pushes are not yet a countdown")
    clock += 500
    let burst = push(store, key: "sos:7:0")
    check(burst.countdownDeadlineAt == firstFrame + 20_000, "third push: countdown = a new SOS from its first push")
    check(burst.stopTag == nil, "a new SOS is never stopped")
    check(store.staleGuardKind == nil, "guard ended")
    clock += 2_000
    check(store.evaluateStaleCandidate().stopTag == nil, "no late stop for the burst")
  }

  static func tagCloseEndsTheGuardAndTheNextPressIsAdmitted() {
    let (store, _) = makeStore()
    deliver(store, key: "sos:7:76")
    _ = store.closeDeliveredCycle(nodeId: 7, terminal: .cancel)
    clock += 30_000
    _ = staleFrame(store, key: "sos:7:77")
    clock += 1_000
    let confirm = store.observe(kind: .cancelled, nodeId: 7, cycleKey: "sos:7", deviceId: nil)
    check(!confirm.queuedCancel && store.pendingCancelCount == 0, "the TAG's confirmation never re-cancels the backend")
    check(store.staleGuardKind == nil, "the TAG confirmed the stop: guard ended")
    clock += 60_000
    let press = store.observe(kind: .active, nodeId: 7, cycleKey: "sos:7:3", deviceId: nil)
    check(press.countdownDeadlineAt == clock + 20_000, "a later single frame is a new SOS again")
  }

  static func frameGapWithoutLinkDropEndsTheGuard() {
    let (store, _) = makeStore()
    deliver(store, key: "sos:7:78")
    _ = store.closeDeliveredCycle(nodeId: 7, terminal: .cancel)
    clock += 10_000
    _ = staleFrame(store, key: "sos:7:79")
    clock += 95_000  // longer than the TAG's 60 s retry: the TAG went idle
    let press = store.observe(kind: .active, nodeId: 7, cycleKey: "sos:7:4", deviceId: nil)
    check(press.countdownDeadlineAt == clock + 20_000, "after a gap a press is admitted")
    check(store.staleGuardKind == nil, "gap ended the guard")
  }

  static func guardEndsAfterTenMinutes() {
    let (store, _) = makeStore()
    deliver(store, key: "sos:7:80")
    store.noteLinkDropped()
    _ = store.closeDeliveredCycle(nodeId: 7, terminal: .cancel)
    clock += 86_401_000
    let press = store.observe(kind: .active, nodeId: 7, cycleKey: "sos:7:5", deviceId: nil)
    check(press.countdownDeadlineAt == clock + 20_000, "one-day cap: admitted")
    check(store.staleGuardKind == nil, "cap ended the guard")
  }

  static func closeWithRecentFramesStopsTheTagAtOnce() {
    let (store, _) = makeStore()
    deliver(store, key: "sos:7:81")
    clock += 1_000
    _ = store.closeDeliveredCycle(nodeId: 7, terminal: .resolve)
    check(store.staleStopToSendNow == .resolve, "TAG link up and SOS frames recent: stop it now")
  }

  static func tagAlreadyClosedArmsNoGuard() {
    let (store, _) = makeStore()
    deliver(store, key: "sos:7:82")
    _ = store.observe(kind: .cancelled, nodeId: 7, cycleKey: "sos:7", deviceId: nil)
    _ = store.closeDeliveredCycle(nodeId: 7, terminal: .cancel)
    check(store.staleGuardKind == nil, "the TAG already stopped: nothing to guard")
    check(store.staleStopToSendNow == nil, "nothing to send")
  }

  static func reconnectRestartsTheGapClock() {
    let (store, _) = makeStore()
    deliver(store, key: "sos:7:83")
    store.noteLinkDropped()
    _ = store.closeDeliveredCycle(nodeId: 7, terminal: .cancel)
    clock += 300_000
    store.noteLinkUp()
    clock += 30_000
    check(staleFrame(store, key: "sos:7:84").openPromptDeadlineAt != nil, "first frame after reconnect: ask")
    _ = store.answerPrompt("stopTag")
    store.noteLinkDropped()
    clock += 5_000
    store.noteLinkUp()
    clock += 95_000  // reconnected, but no frame for 95 s: the TAG is idle
    let press = store.observe(kind: .active, nodeId: 7, cycleKey: "sos:7:6", deviceId: nil)
    check(press.countdownDeadlineAt == clock + 20_000, "idle after reconnect: a press is admitted")
  }

  static func resendPairIsNotACountdown() {
    let (store, _) = makeStore()
    deliver(store, key: "sos:7:85")
    _ = store.closeDeliveredCycle(nodeId: 7, terminal: .cancel)
    clock += 30_000
    // 60 s TEL resend followed by an immediate retry: two pushes 800 ms apart.
    _ = push(store, key: "sos:7:86")
    clock += 800
    check(push(store, key: "sos:7:87").countdownDeadlineAt == nil, "a resend pair is not a countdown")
    clock += 1_200
    let pair = store.evaluateStaleCandidate()
    check(pair.stopTag == nil && pair.openPromptDeadlineAt != nil, "the pair is ambiguous: ask")
    check(store.pendingCreateCount == 0 && store.cycleState == .idle, "no new incident")
  }

  static func otherTagNeverEndsTheGuard() {
    let (store, _) = makeStore()
    deliver(store, key: "sos:7:88")
    _ = store.closeDeliveredCycle(nodeId: 7, terminal: .cancel)
    clock += 10_000
    _ = store.observe(kind: .active, nodeId: 99, cycleKey: "sos:99:1", deviceId: nil)
    check(store.staleGuardKind == .cancel, "another TAG's frame never ends this guard")
  }

  static func unreportedDropRestartsTheGapClockAtReconnect() {
    let (store, _) = makeStore()
    deliver(store, key: "sos:7:89")
    _ = store.closeDeliveredCycle(nodeId: 7, terminal: .resolve)
    clock += 120_000  // Bluetooth off / process death: no didDisconnect
    store.noteLinkUp()
    clock += 20_000
    check(staleFrame(store, key: "sos:7:90").openPromptDeadlineAt != nil, "still ambiguous after reconnect: ask")
  }

  static func sessionChangeEndsTheGuard() {
    let (store, _) = makeStore()
    deliver(store, key: "sos:7:91")
    _ = store.closeDeliveredCycle(nodeId: 7, terminal: .cancel)
    store.disarmStaleGuard()
    check(store.staleGuardKind == nil, "no guard crosses accounts")
  }

  // MARK: - F17c: native is the single classifier for every own-TAG frame

  /// C1: no guard means every Dart frame proceeds at once, Protection armed
  /// or not; nothing waits for a decision window.
  static func forwardedFramesWithoutAGuardProceedAtOnce() {
    let (store, _) = makeStore()
    for _ in 0..<4 {
      let result = store.observeForwardedSosFrame(kind: .active, nodeId: 7)
      check(result.verdict == "proceed", "unguarded frame proceeds")
      check(result.transition.evaluateStaleAt == nil, "no decision timer")
      clock += 500
    }
    check(store.cycleState == .idle, "Dart frames never open the native cycle")
    check(store.pendingCreateCount == 0, "no native create from Dart frames")
  }

  /// Android foreground (2026-11-16): Dart owned the link, native never saw
  /// the cycle, and the SDK cancel logged `NATIVE_SOS_STALE_GUARD_NOT_ARMED
  /// lifecycle=idle`. The forwarded frames are the cycle native saw.
  static func sosSeenOnlyThroughDartArmsTheGuard() {
    let (store, _) = makeStore()
    _ = store.observeForwardedSosFrame(kind: .active, nodeId: 7)
    clock += 25_000
    _ = store.observeForwardedSosFrame(kind: .active, nodeId: 7)
    clock += 5_000
    store.noteLinkDropped()
    check(store.closeDeliveredCycle(nodeId: 7, terminal: .cancel), "terminal of a Dart-seen SOS")
    check(store.staleGuardKind == .cancel, "guard armed from the Dart-seen cycle")
    clock += 200_000
    store.noteLinkUp()
    clock += 30_000
    let first = store.observeForwardedSosFrame(kind: .active, nodeId: 7)
    check(first.verdict == "suppress", "stale frame through Dart is held")
    clock += 2_000
    let decided = store.evaluateStaleCandidate()
    check(decided.stopTag == nil && decided.openPromptDeadlineAt != nil, "ambiguous: ask")

    let (fresh, _) = makeStore()
    _ = fresh.observeForwardedSosFrame(kind: .active, nodeId: 7)
    clock += 5_000
    check(fresh.closeDeliveredCycle(nodeId: 7, terminal: .cancel), "F17c: one rule, a countdown cancel too")
    check(fresh.staleGuardKind == .cancel, "unconfirmed stop recorded at any age")
  }

  static func burstThroughDartNeverOpensTheNativeCycle() {
    let (store, _) = makeStore()
    deliver(store, key: "sos:7:90")
    store.noteLinkDropped()
    _ = store.closeDeliveredCycle(nodeId: 7, terminal: .cancel)
    clock += 120_000
    check(store.observeForwardedSosFrame(kind: .active, nodeId: 7).verdict == "suppress", "push 1 held")
    clock += 500
    check(store.observeForwardedSosFrame(kind: .active, nodeId: 7).verdict == "suppress", "push 2 held")
    clock += 500
    let third = store.observeForwardedSosFrame(kind: .active, nodeId: 7)
    check(third.verdict == "newSos", "push 3: a genuine new SOS")
    check(third.transition.stopTag == nil, "never stopped")
    check(store.staleGuardKind == nil, "guard ended")
    check(store.cycleState == .idle, "Dart runs this SOS: the native cycle stays idle")
  }

  /// M3: a pending decision never writes a stop once a new SOS is open.
  static func newSdkSosDropsAPendingDecision() {
    let (store, _) = makeStore()
    deliver(store, key: "sos:7:91")
    _ = store.closeDeliveredCycle(nodeId: 7, terminal: .cancel)
    clock += 10_000
    _ = store.observeForwardedSosFrame(kind: .active, nodeId: 7)
    clock += 500
    store.disarmForNewSdkSos()
    clock += 1_500
    check(store.evaluateStaleCandidate().stopTag == nil, "no stop after a new SOS opened")
  }

  static func sessionChangeForgetsTheDartCycle() {
    let (store, _) = makeStore()
    _ = store.observeForwardedSosFrame(kind: .active, nodeId: 7)
    clock += 30_000
    store.disarmStaleGuardForSessionChange()
    check(!store.closeDeliveredCycle(nodeId: 7, terminal: .cancel), "previous account's cycle arms nothing")
  }

  // MARK: - F17c prompt notification (owner decision 16/11/2026)

  static func promptNotificationActions() {
    let texts = IosSosPromptNotification.Texts()
    let actions = IosSosPromptNotification.actions(texts: texts)
    check(actions.count == 2, "two actions")
    check(actions[0].identifier == IosSosPromptNotification.sendActionIdentifier &&
          actions[0].title == "Send SOS", "Send SOS first")
    check(!actions[0].options.contains(.authenticationRequired), "Send SOS: one tap, no unlock")
    check(!actions[0].options.contains(.foreground), "Send SOS: answered without opening the app")
    check(actions[1].title == "No, stop the TAG", "No second")
    check(actions[1].options.contains(.authenticationRequired), "No requires the unlock")
    check(IosSosPromptNotification.choice(forActionIdentifier: IosSosPromptNotification.sendActionIdentifier) == "sendSos", "send maps")
    check(IosSosPromptNotification.choice(forActionIdentifier: IosSosPromptNotification.stopActionIdentifier) == "stopTag", "stop maps")
    check(IosSosPromptNotification.choice(forActionIdentifier: UNNotificationDefaultActionIdentifier) == nil, "a tap only opens the app")
    check(IosSosPromptNotification.choice(forActionIdentifier: UNNotificationDismissActionIdentifier) == nil, "dismiss answers nothing (timeout applies)")
    let other = UNNotificationCategory(identifier: "host", actions: [], intentIdentifiers: [], options: [])
    let stale = UNNotificationCategory(identifier: IosSosPromptNotification.categoryIdentifier, actions: [], intentIdentifiers: [], options: [])
    let merged = IosSosPromptNotification.merged([other, stale], texts: texts)
    check(merged.count == 2 && merged.contains(where: { $0.identifier == "host" }), "host categories kept")
    check(merged.first(where: { $0.identifier == IosSosPromptNotification.categoryIdentifier })?.actions.count == 2, "own category replaced")
  }

  static func promptNotificationIsANormalLocalNotification() {
    var texts = IosSosPromptNotification.Texts()
    texts.title = "Tu TAG sigue en SOS"
    let content = IosSosPromptNotification.content(texts: texts, terminal: "cancel", deadlineAtMs: 42)
    check(content.title == "Tu TAG sigue en SOS", "localized title")
    check(content.body.contains("30 s"), "the 30 s countdown is in the text")
    check(content.categoryIdentifier == IosSosPromptNotification.categoryIdentifier, "carries both actions")
    if #available(macOS 12.0, *) {
      check(content.interruptionLevel == .active, "interruption level .active")
      check(content.interruptionLevel != .timeSensitive, "never time-sensitive (no entitlement)")
      check(IosSosPromptNotification.stoppedContent(texts: texts).interruptionLevel == .active, "confirmation .active")
    }
    check(IosSosPromptNotification.isPrompt(userInfo: content.userInfo, identifier: "x"), "recognised by source")
    check(!IosSosPromptNotification.isPrompt(userInfo: [:], identifier: "42001"), "SOS notifications are not the prompt")
  }

  /// The scenario fixture shared with the Android guard and the Dart contract test.
  static func sharedStaleGuardScenarios() {
    let candidates = ["../test/fixtures/stale_sos_guard_scenarios.txt",
                      "test/fixtures/stale_sos_guard_scenarios.txt",
                      "packages/eixam_connect_flutter/test/fixtures/stale_sos_guard_scenarios.txt"]
    guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
          let text = try? String(contentsOfFile: path, encoding: .utf8) else {
      check(false, "shared fixture not found (run from packages/eixam_connect_flutter/ios)")
      return
    }
    var store: IosNativeSosDeliveryStore?
    var name = ""
    var base = 0
    var steps = 0
    var dartFrames = 0
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line.hasPrefix("#") { continue }
      if line.hasPrefix("scenario ") {
        name = String(line.dropFirst("scenario ".count))
        store = makeStore().0
        clock += 10_000_000
        base = clock
        continue
      }
      guard let store else { continue }
      let parts = line.components(separatedBy: " => ")
      let event = parts[0].split(separator: " ").map(String.init)
      let expect = parts[1].split(separator: " ").map(String.init)
      let t = Int(event[0])!
      var args: [String: String] = [:]
      for token in event.dropFirst(2) {
        let kv = token.split(separator: "=", maxSplits: 1).map(String.init)
        if kv.count == 2 { args[kv[0]] = kv[1] }
      }
      var want: [String: String] = [:]
      for token in expect.dropFirst() {
        let kv = token.split(separator: "=", maxSplits: 1).map(String.init)
        if kv.count == 2 { want[kv[0]] = kv[1] }
      }
      let node = Int(args["node"] ?? "7") ?? 7
      let label = "\(name) @\(t) \(event[1])"
      var transition = IosNativeSosTransition()
      var action = "-"
      switch event[1] {
      case "seen":
        let age = Int(args["age"] ?? "0") ?? 0
        switch args["source"] {
        case "native":
          clock = base + t - age
          deliver(store, key: "sos:\(node):1")
        case "native_unclaimed":
          // The native create was queued but never claimed by the SDK.
          clock = base + t - age
          _ = store.observe(kind: .active, nodeId: node, cycleKey: "sos:\(node):1", deviceId: nil)
          clock += 20_000
          _ = store.promoteExpiredCountdown(deviceId: nil)
        case "countdown":
          clock = base + t - age
          _ = store.observe(kind: .active, nodeId: node, cycleKey: "sos:\(node):1", deviceId: nil)
          check(store.cycleState == .preConfirmSeen, "\(name): countdown running")
        case "dart":
          clock = base + t - age
          _ = store.observeForwardedSosFrame(kind: .active, nodeId: node)
          clock = base + t - 1
          _ = store.observeForwardedSosFrame(kind: .active, nodeId: node)
        default:
          break
        }
      case "terminal":
        clock = base + t
        if args["connected"] == "false" { store.noteLinkDropped() } else { store.noteLinkUp() }
        _ = store.closeDeliveredCycle(
          nodeId: node, terminal: IosSosTerminalKind(rawValue: args["kind"] ?? "cancel"))
      case "frame":
        clock = base + t
        if args["source"] == "dart" {
          // t is Dart's receivedAtMs; delivered the native clock.
          clock = base + (Int(args["delivered"] ?? "") ?? t)
          let result = store.observeForwardedSosFrame(
            kind: .active, nodeId: node, receivedAtMs: base + t)
          transition = result.transition
          let wantVerdict = expect[0] == "pass" ? "proceed" : expect[0] == "newSos" ? "newSos" : "suppress"
          check(result.verdict == wantVerdict, "\(label): verdict \(result.verdict) != \(wantVerdict)")
          dartFrames += 1
        } else {
          transition = store.observe(kind: .active, nodeId: node, cycleKey: "sos:\(node):9", deviceId: nil)
        }
        action = store.lastStaleAction
      case "decide":
        clock = base + t
        transition = store.evaluateStaleCandidate()
        action = store.lastStaleAction
      case "close":
        clock = base + t
        if args["source"] == "dart" {
          check(store.observeForwardedSosFrame(kind: .cancelled, nodeId: node).verdict == "proceed",
                "\(label): close proceeds")
        } else {
          _ = store.observe(kind: .cancelled, nodeId: node, cycleKey: "sos:\(node)", deviceId: nil)
        }
      case "answer":
        clock = base + t
        transition = store.answerPrompt(args["choice"] ?? "")
        action = store.lastStaleAction
      case "link_drop":
        store.noteLinkDropped()
      case "link_up":
        clock = base + t
        store.noteLinkUp()
      case "session":
        store.disarmStaleGuardForSessionChange()
      case "sdk_open":
        store.disarmForNewSdkSos()
      default:
        check(false, "\(name): unknown event \(event[1])")
      }
      steps += 1
      if expect[0] != "-" {
        let got = ["notArmed", "ignored", "disarmed"].contains(action) ? "pass" : action
        check(got == expect[0], "\(label): action \(got) != \(expect[0])")
      }
      let stop = transition.stopTag?.rawValue ?? "none"
      check(stop == (want["stop"] ?? "none"), "\(label): stop \(stop) != \(want["stop"] ?? "none")")
      check((transition.openPromptDeadlineAt != nil) == (want["opened"] == "true"), "\(label): opened")
      if let kind = want["kind"] {
        check(store.staleGuardKind?.rawValue == kind, "\(label): kind \(store.staleGuardKind?.rawValue ?? "none") != \(kind)")
      }
      if let prompt = want["prompt"] {
        let got = store.promptDeadlineAt != nil ? "open" : "closed"
        check(got == prompt, "\(label): prompt \(got) != \(prompt)")
      }
      if action == "sosOpened" {
        check(transition.queuedCreate && store.pendingCreateCount == 1, "\(label): the SOS is opened")
      }
      if let armed = want["armed"] {
        check((store.staleGuardKind != nil) == (armed == "true"), "\(label): armed != \(armed)")
      }
    }
    check(steps > 100, "fixture replayed (\(steps) steps)")
    check(dartFrames > 20, "dart frames replayed (\(dartFrames))")
  }
}
