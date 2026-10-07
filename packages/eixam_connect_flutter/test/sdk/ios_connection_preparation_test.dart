import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'production reconnect does not restart discovery on snapshot events',
    () async {
      if (!Platform.isMacOS) return;
      final source = File(
        'ios/Classes/ProtectionRuntimeBridge.swift',
      ).readAsStringSync();
      final attempt = source.substring(
        source.indexOf('  private func attemptProtectionReconnect('),
        source.indexOf('  private func handleConnectedPeripheral('),
      );
      final connected = source.substring(
        source.indexOf('  private func handleConnectedPeripheral('),
        source.indexOf('  private func recordWake('),
      );
      final root = Directory.systemTemp.createTempSync(
        'ios-reentrant-discovery-',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      final main = File('${root.path}/main.swift');
      main.writeAsStringSync(
        r'''
import Foundation
extension Date { var millisecondsSince1970: Int { Int(timeIntervalSince1970 * 1000) } }
enum Keys {
  static let protectedDeviceId = "target", lastFailureReason = "failure", readinessFailureReason = "readiness", degradationReason = "degradation", reconnectAttemptCount = "count", lastReconnectAttemptAt = "time"
}
final class Defaults {
  var values: [String: Any] = [:]
  func set(_ value: Any, forKey key: String) { values[key] = value }
  func string(forKey key: String) -> String? { values[key] as? String }
  func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
  func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}
enum State { case connected, connecting, disconnected, poweredOn, recovering, failed, active }
final class Peripheral {
  let identifier = UUID()
  var state = State.connected
  weak var delegate: AnyObject?
  var discoveries = 0
  func discoverServices(_ services: [UUID]) { discoveries += 1 }
}
typealias CBPeripheral = Peripheral
final class Central {
  var state = State.poweredOn
  let peer = Peripheral()
  func retrievePeripherals(withIdentifiers: [UUID]) -> [Peripheral] { [peer] }
  func connect(_ peripheral: Peripheral, options: Any?) { peripheral.state = .connecting }
}
final class Bridge {
  static let eixamServiceUuid = UUID()
  let defaults = Defaults()
  let isArmed = true
  let centralManager: Central? = Central()
  var protectedPeripheral: Peripheral?
  var servicesDiscovered = false, subscriptionsActive = false, commandQueueHealthy = true
  var telCharacteristic: Int?, sosCharacteristic: Int?, inetCharacteristic: Int?, cmdCharacteristic: Int?
  var connectionPreparation = ProtectionConnectionPreparation()
  var eventDepth = 0
  init() { defaults.set(centralManager!.peer.identifier.uuidString, forKey: Keys.protectedDeviceId) }
  func updateRuntimeState(_ state: State) {}
  func event() {
    if eventDepth < 3 { eventDepth += 1; poll(); eventDepth -= 1 }
  }
  func recordWake(reason: String) { event() }
  func recordEvent(type: String, reason: String?) { event() }
  func recordBleEvent(type: String) { event() }
  func recordRestorationEvent(type: String, reason: String?) { event() }
  func poll() { attemptProtectionReconnect(trigger: "snapshot_refresh") }
  func settle() { servicesDiscovered = true; subscriptionsActive = true; connectionPreparation.finish() }
''' +
            attempt +
            connected +
            r'''
}
let bridge = Bridge()
bridge.poll()
for _ in 0..<2000 { bridge.poll() }
assert(bridge.centralManager!.peer.discoveries == 1)
assert(bridge.defaults.integer(forKey: Keys.reconnectAttemptCount) == 1)
bridge.settle()
for _ in 0..<2000 { bridge.poll() }
assert(bridge.centralManager!.peer.discoveries == 1)
print("production reentrant discovery regression passed")
''',
      );
      final binary = '${root.path}/regression';
      final compile = await Process.run('swiftc', [
        'ios/Classes/ProtectionConnectionPreparation.swift',
        main.path,
        '-o',
        binary,
      ]);
      expect(
        compile.exitCode,
        0,
        reason: '${compile.stdout}\n${compile.stderr}',
      );
      final run = await Process.run(binary, []);
      expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
    },
  );
  test(
    'native preparation survives reentrant snapshots until callbacks settle',
    () async {
      if (!Platform.isMacOS) return;
      final root = Directory.systemTemp.createTempSync('ios-preparation-');
      addTearDown(() => root.deleteSync(recursive: true));
      final main = File('${root.path}/main.swift');
      main.writeAsStringSync(r'''
import Foundation
let target = UUID(uuidString: "97BA8682-44B7-5BA3-2257-381176EB6AAB")!
let unrelated = UUID()
var gate = ProtectionConnectionPreparation()
var starts = 0
func snapshot() {
  if gate.begin(target) { starts += 1 }
}
snapshot() // connection started
for _ in 0..<2000 { snapshot() } // SDK events poll while services are pending
assert(starts == 1)
gate.finish(unrelated) // a late callback for another peripheral cannot release it
snapshot()
assert(starts == 1)
gate.finish(target) // subscriptions settled
snapshot() // a later real disconnect/reconnect is permitted
assert(starts == 2)
gate.finish() // stop/target replacement clears the outstanding transaction
assert(gate.begin(unrelated))
print("native preparation regression passed")
''');
      final binary = '${root.path}/regression';
      final compile = await Process.run('swiftc', [
        'ios/Classes/ProtectionConnectionPreparation.swift',
        main.path,
        '-o',
        binary,
      ]);
      expect(
        compile.exitCode,
        0,
        reason: '${compile.stdout}\n${compile.stderr}',
      );
      final run = await Process.run(binary, []);
      expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
    },
  );
}
