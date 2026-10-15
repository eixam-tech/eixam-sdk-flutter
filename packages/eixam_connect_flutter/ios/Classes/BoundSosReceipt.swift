import Foundation

// New Eixam v1 relay envelope; this is remote evidence, never a local SOS event.
enum BoundSosReceipt {
  static func body(_ bytes: [UInt8]) -> [UInt8]? {
    guard bytes.count == 15 || bytes.count == 20 else { return nil }
    guard bytes[0] == 0xE4, bytes[1] == 1, bytes[7] == 1,
          Int(bytes[6]) + 8 == bytes.count, bytes[6] == 7 || bytes[6] == 12,
          bytes[2...5].contains(where: { $0 != 0 }) else { return nil }
    return Array(bytes.dropFirst(8))
  }
}
