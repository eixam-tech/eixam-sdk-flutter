import Foundation

/// CoreBluetooth callbacks and snapshot requests run on the main queue. Keep
/// one connection/discovery transaction alive across reentrant status reads.
struct ProtectionConnectionPreparation {
  private(set) var peripheral: UUID?

  mutating func begin(_ identifier: UUID) -> Bool {
    guard peripheral == nil else { return false }
    peripheral = identifier
    return true
  }

  mutating func finish(_ identifier: UUID? = nil) {
    if identifier == nil || identifier == peripheral {
      peripheral = nil
    }
  }
}
