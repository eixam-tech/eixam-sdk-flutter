import Foundation

enum IosBleSosSnapshotKind: String {
  case preSos
  case active
  case cancelled
  case resolved
}

/// Which GATT characteristic delivered the frame. The 12-byte TEL gate below
/// applies to `.tel` only; the SOS characteristic keeps its own rules.
enum IosBleSosCharacteristic {
  case tel
  case sos
  case other
}

typealias IosBleSosParsedSnapshot = (
  kind: IosBleSosSnapshotKind,
  nodeId: Int?,
  packetId: Int?,
  cycleKey: String?,
  deadlineAt: Int?
)

/// Decides whether a BLE notification is an SOS snapshot. Mirrors Android's
/// `ProtectionBleSosIdentityClassifier` / `ProtectionBleSosOverTelClassifier`
/// (firmware docs 22 §2.3-2.4 and 23 §4.1): only 7 and 12 byte frames are SOS
/// candidates, and a 12 byte frame on TEL is SOS only if
/// `bit5(flags) == 0 && sosType == 3`.
enum IosBleSosFrameClassifier {
  static func parse(
    bytes: [UInt8],
    characteristic: IosBleSosCharacteristic,
    receivedAt: Int
  ) -> IosBleSosParsedSnapshot? {
    // Nearby 0xD8 is chunked as 0xD0. Last fragments of 7/12 bytes match
    // SOS snapshot sizes; treat real TEL fragments as not-SOS so emitTelNotify
    // can reassemble and NearbyClosedAppNotifier can fire with the app killed.
    if TelAggregateFragment.tryParse(bytes) != nil {
      return nil
    }
    if bytes.count == 6,
       (bytes[0] == 0xE1 || bytes[0] == 0xE2 || bytes[0] == 0xE3) {
      let nodeId = readUInt32(bytes, offset: 2)
      // E3 closes the TAG episode through backend resolution. Persist and
      // forward its real packet, preserving the distinction from user cancel.
      let kind: IosBleSosSnapshotKind = bytes[0] == 0xE3 ? .resolved : .cancelled
      return (kind, nodeId, nil, nodeId.map { "sos:\($0)" }, nil)
    }
    // The first byte of an SOS frame is the little-endian node id, so a frame
    // is only ruled out when its whole structure matches a known non-SOS frame.
    if characteristic == .tel, isKnownNonSosTelFrame(bytes) {
      return nil
    }
    // No firmware BLE SOS wire is 13 or 18 bytes.
    guard bytes.count == 7 || bytes.count == 12,
          let nodeId = readUInt32(bytes, offset: 0) else {
      return nil
    }
    let flagsOffset = bytes.count == 12 ? 10 : 4
    let flagsWord = Int(bytes[flagsOffset]) | (Int(bytes[flagsOffset + 1]) << 8)
    let sosType = (flagsWord >> 14) & 0x03
    let packetId = flagsWord & 0x0F
    let cycleKey = "sos:\(nodeId):\(packetId)"
    if characteristic == .tel, bytes.count == 12 {
      // A TEL position frame (bit 5 set, or any other sosType) is not an SOS
      // and never a cancellation.
      guard flagsWord & 0x0020 == 0, sosType == 3 else {
        return nil
      }
      return (.active, nodeId, packetId, cycleKey, nil)
    }
    if sosType == 0 {
      return (.cancelled, nodeId, packetId, cycleKey, nil)
    }
    if sosType == 1 {
      return (.preSos, nodeId, packetId, cycleKey, receivedAt + 20_000)
    }
    return (.active, nodeId, packetId, cycleKey, nil)
  }

  /// Known TEL-characteristic frames, matched by opcode AND structure
  /// (SDK `eixam_*_packet.dart` parsers).
  static func isKnownNonSosTelFrame(_ bytes: [UInt8]) -> Bool {
    guard let opcode = bytes.first else {
      return false
    }
    let count = bytes.count
    switch opcode {
    case 0xD3:
      // Live batch: [0xD3][count 1...24][count x 16 B record].
      guard count >= 2 else { return false }
      let records = Int(bytes[1])
      return records >= 1 && records <= 24 && count == 2 + records * 16
    case 0xD1:
      // Backlog: [0xD1][1 meta|2 chunk|3 end|4 error][session != 0].
      guard count >= 3, bytes[2] != 0 else { return false }
      switch bytes[1] {
      case 0x01: return count == 14
      case 0x02: return count == 24
      case 0x03: return count == 10
      case 0x04: return count == 5
      default: return false
      }
    case 0xD2:
      return count == 27
    case 0xD8:
      return count >= 22
    case 0xDA:
      return count == 6
    case 0xDB:
      // Nearby owner name: 5 B header + 1...39 B valid, non-blank UTF-8.
      guard count > 5, count - 5 <= 39,
            let name = String(bytes: bytes[5...], encoding: .utf8) else {
        return false
      }
      return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case 0xE9:
      // 0x23 runtime status reply (E9 78 02) and CMD result (E9 7A).
      if count == 14 { return bytes[1] == 0x78 && bytes[2] == 0x02 }
      if count == 6 { return bytes[1] == 0x7A }
      return false
    default:
      return false
    }
  }

  private static func readUInt32(_ bytes: [UInt8], offset: Int) -> Int? {
    guard bytes.count >= offset + 4 else {
      return nil
    }
    return Int(bytes[offset])
      | (Int(bytes[offset + 1]) << 8)
      | (Int(bytes[offset + 2]) << 16)
      | (Int(bytes[offset + 3]) << 24)
  }
}
