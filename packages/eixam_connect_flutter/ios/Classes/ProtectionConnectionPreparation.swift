import Foundation

/// CoreBluetooth callbacks and snapshot requests run on the main queue. Keep
/// one connection/discovery transaction alive across reentrant status reads.
///
/// F17a (2026-11-15): a discovery CoreBluetooth never answered (requested
/// before Bluetooth was powered on after a state restoration) held the gate
/// forever and the runtime never left "recovering". A requested discovery now
/// expires after `timeoutMs`; a pending connect keeps the gate until
/// didConnect / didFailToConnect as before. Times are monotonic ms.
struct ProtectionConnectionPreparation {
  static let timeoutMs = 15_000

  private(set) var peripheral: UUID?
  private var beganAt: Int?
  private var discoveryRequested = false
  private var lastRediscoveryAt: Int?

  mutating func begin(_ identifier: UUID, now: Int = Self.nowMs()) -> Bool {
    if peripheral != nil, !(discoveryRequested && isExpired(now: now)) {
      return false
    }
    peripheral = identifier
    beganAt = now
    discoveryRequested = false
    return true
  }

  /// Service discovery was requested: the transaction gets a fresh budget
  /// and may expire (iOS can ignore the request).
  mutating func startDiscovery(_ identifier: UUID, now: Int = Self.nowMs()) {
    peripheral = identifier
    beganAt = now
    discoveryRequested = true
  }

  mutating func finish(_ identifier: UUID? = nil) {
    if identifier == nil || identifier == peripheral {
      peripheral = nil
      beganAt = nil
      discoveryRequested = false
    }
  }

  /// A rediscovery was started: the next one waits at least `timeoutMs`
  /// (a discovery that fails fast is never repeated at frame rate).
  mutating func noteRediscovery(now: Int = Self.nowMs()) {
    lastRediscoveryAt = now
  }

  /// The armed runtime holds a connected protected peripheral without its
  /// services / writable characteristic (restored link): discover again,
  /// unless a discovery is still in flight, one ran recently, or Bluetooth is
  /// not powered on yet (iOS ignores discovery then; power-on retries).
  func shouldRediscover(
    armed: Bool,
    poweredOn: Bool,
    peripheralConnected: Bool,
    servicesDiscovered: Bool,
    subscriptionsActive: Bool,
    hasCommandCharacteristic: Bool,
    now: Int = Self.nowMs()
  ) -> Bool {
    guard armed, poweredOn, peripheralConnected else { return false }
    let ready = servicesDiscovered && subscriptionsActive && hasCommandCharacteristic
    guard !ready else { return false }
    if let lastRediscoveryAt, now - lastRediscoveryAt <= Self.timeoutMs {
      return false
    }
    return peripheral == nil || (discoveryRequested && isExpired(now: now))
  }

  private func isExpired(now: Int) -> Bool {
    guard let beganAt else { return true }
    return now - beganAt > Self.timeoutMs
  }

  static func nowMs() -> Int {
    Int(ProcessInfo.processInfo.systemUptime * 1000)
  }
}
