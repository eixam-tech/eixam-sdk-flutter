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

struct IosNativeSosTransition: Equatable {
  /// A new pending create was stored: emit `nativeBackendSyncQueued(create)`.
  var queuedCreate = false
  /// A new pending cancel was stored: emit `nativeBackendSyncQueued(cancel)`.
  var queuedCancel = false
  /// A countdown started: schedule promotion at this time (ms since epoch).
  var countdownDeadlineAt: Int?
  /// The countdown ended without promotion (closed): drop its timer.
  var countdownStopped = false
}

final class IosNativeSosDeliveryStore {
  static let countdownMs = 20_000
  static let eventQueueCapacity = 64
  static let sosEventTypes: Set<String> = [
    "ownDeviceSosLifecycleObserved",
    "nativeBackendSyncQueued",
  ]

  enum Keys {
    static let cycleState = "native_sos_cycle_state"
    static let cycleKey = "native_sos_cycle_key"
    static let cycleNodeId = "native_sos_cycle_node_id"
    static let cycleDeadlineAt = "native_sos_cycle_deadline_at"
    static let pendingCreate = "pending_native_sos_create"
    static let pendingCancel = "pending_native_sos_cancel"
    static let pendingEvents = "pending_sos_events"
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
      // Firmware sosType 1..3 is the SOS kind / fix quality, not the
      // countdown phase: the TAG sends the same frames from the start of its
      // 20 s countdown (Android: first SOS frame starts the countdown). The
      // backend is told only once the countdown elapsed without a cancel.
      switch cycleState {
      case .idle:
        let deadline = now() + Self.countdownMs
        setCycle(.preConfirmSeen, key: cycleKey, nodeId: nodeId, deadlineAt: deadline)
        transition.countdownDeadlineAt = deadline
      case .preConfirmSeen:
        // A later frame after the deadline: the phone was suspended when the
        // countdown elapsed.
        transition = promoteExpiredCountdown(deviceId: deviceId)
      case .createPending:
        // Repeated frames of the same SOS (the TAG keeps sending them).
        break
      }
    case .cancelled, .resolved:
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
      setCycle(.idle, key: nil, nodeId: nil, deadlineAt: nil)
    }
    return transition
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
      return (.preSos, cycleKey)
    case .createPending:
      return (.active, cycleKey)
    }
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

  /// Protection stopped: native no longer observes the TAG, so a countdown
  /// in progress must never be promoted later. Pending records stay: they
  /// describe an SOS / cancel the TAG already produced.
  func resetCycle() -> Bool {
    let wasCounting = cycleState == .preConfirmSeen
    setCycle(.idle, key: nil, nodeId: nil, deadlineAt: nil)
    defaults.removeObject(forKey: Keys.pendingEvents)
    return wasCounting
  }

  private func promote(reason: String, deviceId: String?) {
    let key = cycleKey ?? "native-sos-cycle-\(now())"
    let nodeId = cycleNodeId
    setCycle(.createPending, key: key, nodeId: nodeId, deadlineAt: nil)
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
