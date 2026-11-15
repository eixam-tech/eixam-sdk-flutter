import Darwin
import Foundation

/// Run with swiftc:
///   swiftc -parse-as-library -o /tmp/ios_preparation_tests \
///     Classes/ProtectionConnectionPreparation.swift \
///     Tests/ProtectionConnectionPreparationTests.swift && /tmp/ios_preparation_tests
///
/// 2026-11-15 (F17a): after a relaunch, CoreBluetooth restored the TAG link
/// before Bluetooth was powered on; discovery was requested too early (ignored
/// by iOS), the preparation gate stayed held forever and the runtime never left
/// "recovering": SOS frames arrived but nothing could be written to the TAG.
@main
struct ProtectionConnectionPreparationTests {
  private static var failures = 0
  private static let tag = UUID()

  static func main() {
    setbuf(stdout, nil)
    aHeldGateExpires()
    aFreshGateStillSerializes()
    connectedWithoutCharacteristicsIsRediscovered()
    readyOrNotConnectedIsLeftAlone()
    discoveryInFlightIsNotRepeated()
    noDiscoveryBeforePowerOn()
    aPendingConnectNeverExpires()
    discoveryRestartsTheBudget()
    rediscoveryIsRateLimited()
    if failures > 0 {
      print("FAILED: \(failures)")
      exit(1)
    }
    print("OK: ProtectionConnectionPreparationTests")
  }

  private static func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition {
      failures += 1
      print("FAIL line \(line): \(message)")
    }
  }

  static func aHeldGateExpires() {
    var gate = ProtectionConnectionPreparation()
    check(gate.begin(tag, now: 1_000), "first begin")
    gate.startDiscovery(tag, now: 1_000)
    check(!gate.begin(tag, now: 1_000 + 5_000), "held while discovery may still answer")
    check(gate.begin(tag, now: 1_000 + ProtectionConnectionPreparation.timeoutMs + 1),
          "a gate never answered is released after the timeout")
  }

  static func aFreshGateStillSerializes() {
    var gate = ProtectionConnectionPreparation()
    _ = gate.begin(tag, now: 0)
    gate.finish(tag)
    check(gate.begin(tag, now: 10), "finished gate can begin again")
  }

  static func connectedWithoutCharacteristicsIsRediscovered() {
    let gate = ProtectionConnectionPreparation()
    check(gate.shouldRediscover(
      armed: true, poweredOn: true, peripheralConnected: true,
      servicesDiscovered: false, subscriptionsActive: false,
      hasCommandCharacteristic: false, now: 0),
      "restored link without characteristics: discover again")
    check(gate.shouldRediscover(
      armed: true, poweredOn: true, peripheralConnected: true,
      servicesDiscovered: true, subscriptionsActive: true,
      hasCommandCharacteristic: false, now: 0),
      "no writable characteristic: discover again")
  }

  static func readyOrNotConnectedIsLeftAlone() {
    let gate = ProtectionConnectionPreparation()
    check(!gate.shouldRediscover(
      armed: true, poweredOn: true, peripheralConnected: true,
      servicesDiscovered: true, subscriptionsActive: true,
      hasCommandCharacteristic: true, now: 0), "ready: nothing to do")
    check(!gate.shouldRediscover(
      armed: true, poweredOn: true, peripheralConnected: false,
      servicesDiscovered: false, subscriptionsActive: false,
      hasCommandCharacteristic: false, now: 0), "not connected: the reconnect path owns it")
    check(!gate.shouldRediscover(
      armed: false, poweredOn: true, peripheralConnected: true,
      servicesDiscovered: false, subscriptionsActive: false,
      hasCommandCharacteristic: false, now: 0), "not armed: not ours")
  }

  static func discoveryInFlightIsNotRepeated() {
    var gate = ProtectionConnectionPreparation()
    gate.startDiscovery(tag, now: 0)
    check(!gate.shouldRediscover(
      armed: true, poweredOn: true, peripheralConnected: true,
      servicesDiscovered: false, subscriptionsActive: false,
      hasCommandCharacteristic: false, now: 3_000), "discovery in flight: wait for it")
    check(gate.shouldRediscover(
      armed: true, poweredOn: true, peripheralConnected: true,
      servicesDiscovered: false, subscriptionsActive: false,
      hasCommandCharacteristic: false, now: ProtectionConnectionPreparation.timeoutMs + 1),
      "discovery never answered: try again")
  }

  static func noDiscoveryBeforePowerOn() {
    let gate = ProtectionConnectionPreparation()
    check(!gate.shouldRediscover(
      armed: true, poweredOn: false, peripheralConnected: true,
      servicesDiscovered: false, subscriptionsActive: false,
      hasCommandCharacteristic: false, now: 0),
      "iOS ignores discovery before power-on: wait for it")
  }

  static func aPendingConnectNeverExpires() {
    var gate = ProtectionConnectionPreparation()
    _ = gate.begin(tag, now: 0)  // connect() to an out-of-range TAG: no timeout
    check(!gate.begin(tag, now: 10 * ProtectionConnectionPreparation.timeoutMs),
          "a pending connect keeps the gate until didConnect / didFailToConnect")
  }

  static func discoveryRestartsTheBudget() {
    var gate = ProtectionConnectionPreparation()
    _ = gate.begin(tag, now: 0)
    gate.startDiscovery(tag, now: 14_000)  // slow connect, then discovery
    check(!gate.begin(tag, now: 14_000 + 5_000), "discovery gets its own full budget")
  }

  static func rediscoveryIsRateLimited() {
    var gate = ProtectionConnectionPreparation()
    gate.noteRediscovery(now: 0)
    gate.finish(tag)  // discovery failed fast
    check(!gate.shouldRediscover(
      armed: true, poweredOn: true, peripheralConnected: true,
      servicesDiscovered: false, subscriptionsActive: false,
      hasCommandCharacteristic: false, now: 500),
      "a failed rediscovery is not repeated at frame rate")
    check(gate.shouldRediscover(
      armed: true, poweredOn: true, peripheralConnected: true,
      servicesDiscovered: false, subscriptionsActive: false,
      hasCommandCharacteristic: false, now: ProtectionConnectionPreparation.timeoutMs + 1),
      "retried after the timeout")
  }
}
