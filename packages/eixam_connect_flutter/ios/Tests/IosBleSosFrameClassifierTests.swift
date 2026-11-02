import Foundation
import Darwin

/// Run with swiftc alongside Classes/IosBleSosFrameClassifier.swift and
/// Classes/TelAggregateReassembler.swift:
///   swiftc -parse-as-library -o /tmp/ios_sos_frame_tests \
///     Classes/IosBleSosFrameClassifier.swift \
///     Classes/TelAggregateReassembler.swift \
///     Tests/IosBleSosFrameClassifierTests.swift && /tmp/ios_sos_frame_tests
///
/// Byte fixtures mirror Android's ProtectionBleSosOverTelClassifierTest and
/// ProtectionBleSosIdentityClassifierTest.
@main
struct IosBleSosFrameClassifierTests {
  private static var failures = 0

  // Firmware 12 B SOS: node 0x12345678, packetId 7, sosType 3, bit 5 clear.
  private static let modernSos12: [UInt8] = [
    0x78, 0x56, 0x34, 0x12, 0x48, 0xCD, 0x1B, 0x34, 0x44, 0x28, 0x07, 0xC0,
  ]
  // Node 0x594B1AA8, sosType 3.
  private static let sos7Active: [UInt8] = [0xA8, 0x1A, 0x4B, 0x59, 0x00, 0xC0, 0x00]

  static func main() {
    setbuf(stdout, nil)
    nonSosTelFrames()
    tel12ByteGate()
    sosCharacteristicUnchanged()
    sevenByteSemantics()
    sosEventsUnchanged()
    removedWrappedLengths()
    nearbyOwnerNameStructure()
    otherCharacteristicsNeverSos()
    if failures > 0 {
      print("FAILED: \(failures)")
      exit(1)
    }
    print("OK")
  }

  private static func expect(_ condition: Bool, _ name: String) {
    if !condition {
      failures += 1
      print("FAIL: \(name)")
    }
  }

  private static func parse(
    _ bytes: [UInt8],
    _ characteristic: IosBleSosCharacteristic
  ) -> IosBleSosParsedSnapshot? {
    IosBleSosFrameClassifier.parse(
      bytes: bytes,
      characteristic: characteristic,
      receivedAt: 1_000
    )
  }

  /// [0xD3][count=1][16 B record]; the old 18 -> 12 mapping read the flags from
  /// record bytes 8-9 and the node id from `D3 01 r0 r1`.
  private static func liveBatchSingle(flagsLow: UInt8, flagsHigh: UInt8) -> [UInt8] {
    var bytes: [UInt8] = [0xD3, 0x01]
    bytes += [UInt8](repeating: 0x11, count: 16)
    bytes[10] = flagsLow
    bytes[11] = flagsHigh
    return bytes
  }

  private static func nonSosTelFrames() {
    for (name, flagsHigh) in [("active", UInt8(0xC0)), ("preSos", UInt8(0x40)), ("cancel", UInt8(0x00))] {
      let frame = liveBatchSingle(flagsLow: 0x07, flagsHigh: flagsHigh)
      expect(frame.count == 18, "0xD3 fixture is 18 B")
      expect(parse(frame, .tel) == nil, "0xD3 single record (\(name) bits) is not SOS on TEL")
      expect(parse(frame, .sos) == nil, "18 B frame is not SOS on the SOS characteristic")
    }
    var twoRecords: [UInt8] = [0xD3, 0x02]
    twoRecords += [UInt8](repeating: 0xC0, count: 32)
    expect(parse(twoRecords, .tel) == nil, "0xD3 two records is not SOS")

    let statusReply: [UInt8] = [0xE9, 0x78, 0x02, 0x01, 0x02, 0x03, 0x00,
                                0x78, 0x56, 0x34, 0x12, 0x64, 0x78, 0x00]
    expect(statusReply.count == 14, "0x23 reply fixture is 14 B")
    expect(parse(statusReply, .tel) == nil, "0x23 reply is not SOS")
    expect(parse([0xE9, 0x7A, 0x23, 0x00, 0x00, 0x00], .tel) == nil, "CMD result (E9 7A) is not SOS")
    expect(parse([0xDA, 0x01, 0x00, 0x00, 0x00, 0x00], .tel) == nil, "0xDA status is not SOS")

    // 0xD0 aggregate fragment whose total size matches an SOS wire (12 B).
    let fragment: [UInt8] = [0xD0, 0x20, 0x00, 0x00, 0x00, 0x78, 0x56, 0x34, 0x12, 0x00, 0xC0, 0x00]
    expect(fragment.count == 12, "0xD0 fixture is 12 B")
    expect(parse(fragment, .tel) == nil, "0xD0 fragment is not SOS")

    expect(parse([UInt8](repeating: 0xD2, count: 27), .tel) == nil, "0xD2 relay is not SOS")
    expect(parse([0xD8] + [UInt8](repeating: 0x41, count: 24), .tel) == nil, "0xD8 text is not SOS")
    for (subtype, length) in [(UInt8(1), 14), (2, 24), (3, 10), (4, 5)] {
      var backlog = [UInt8](repeating: 0xC0, count: length)
      backlog[0] = 0xD1
      backlog[1] = subtype
      backlog[2] = 0x05
      expect(parse(backlog, .tel) == nil, "0xD1 backlog subtype \(subtype) is not SOS")
    }
  }

  private static func tel12ByteGate() {
    let modern = parse(modernSos12, .tel)
    expect(modern?.kind == .active, "12 B modern SOS on TEL is active")
    expect(modern?.nodeId == 0x1234_5678, "12 B modern SOS node id")
    expect(modern?.packetId == 7, "12 B modern SOS packet id")
    expect(modern?.cycleKey == "sos:\(0x1234_5678):7", "12 B modern SOS cycle key")

    // Position at speed >= 10.8 km/h: format bit 5 set, speed nibble in sosType.
    var position = modernSos12
    position[10] = 0x27
    position[11] = 0x85
    expect(parse(position, .tel) == nil, "12 B position with bit 5 set is not SOS on TEL")

    var bit5WithType3 = modernSos12
    bit5WithType3[10] = 0x27
    expect(parse(bit5WithType3, .tel) == nil, "12 B sosType 3 with bit 5 set is not SOS on TEL")

    var legacy = modernSos12
    legacy[11] = 0x40
    expect(parse(legacy, .tel) == nil, "12 B sosType 1 without hop proof is not SOS on TEL")
    legacy[11] = 0x80
    expect(parse(legacy, .tel) == nil, "12 B sosType 2 without hop proof is not SOS on TEL")

    var type0 = modernSos12
    type0[11] = 0x00
    type0[10] = 0x07
    expect(parse(type0, .tel) == nil, "12 B sosType 0 on TEL is not SOS and not a cancellation")
  }

  private static func sosCharacteristicUnchanged() {
    expect(parse(modernSos12, .sos)?.kind == .active, "12 B sosType 3 on SOS characteristic is active")
    var position = modernSos12
    position[10] = 0x27
    position[11] = 0x85
    expect(parse(position, .sos)?.kind == .active, "12 B sosType 2 with bit 5 set stays SOS on SOS characteristic")
    var pre = modernSos12
    pre[11] = 0x40
    let preSnapshot = parse(pre, .sos)
    expect(preSnapshot?.kind == .preSos, "12 B sosType 1 on SOS characteristic is pre-SOS")
    expect(preSnapshot?.deadlineAt == 21_000, "pre-SOS deadline is receivedAt + 20 s")
    var cancelled = modernSos12
    cancelled[11] = 0x00
    expect(parse(cancelled, .sos)?.kind == .cancelled, "12 B sosType 0 on SOS characteristic is cancelled")
  }

  private static func sevenByteSemantics() {
    for characteristic in [IosBleSosCharacteristic.tel, .sos] {
      expect(parse(sos7Active, characteristic)?.kind == .active, "7 B sosType 3 is active")
      var pre = sos7Active
      pre[5] = 0x40
      expect(parse(pre, characteristic)?.kind == .preSos, "7 B sosType 1 is pre-SOS")
      var two = sos7Active
      two[5] = 0x80
      expect(parse(two, characteristic)?.kind == .active, "7 B sosType 2 is active")
      var clear = sos7Active
      clear[5] = 0x00
      expect(parse(clear, characteristic)?.kind == .cancelled, "7 B sosType 0 is a clear")
    }
    expect(parse(sos7Active, .tel)?.nodeId == 0x594B_1AA8, "7 B node id")
  }

  private static func sosEventsUnchanged() {
    let cancel = parse([0xE1, 0x02, 0xA8, 0x1A, 0x4B, 0x59], .tel)
    expect(cancel?.kind == .cancelled, "E1 is a cancellation")
    expect(cancel?.nodeId == 0x594B_1AA8, "E1 node id")
    expect(parse([0xE2, 0x02, 0xA8, 0x1A, 0x4B, 0x59], .sos)?.kind == .cancelled, "E2 is a cancellation")
    expect(parse([0xE3, 0x01, 0xA8, 0x1A, 0x4B, 0x59], .tel)?.kind == .resolved, "E3 is resolved, not a cancel")
  }

  private static func removedWrappedLengths() {
    // 13 B (7 + 6) and 18 B (12 + 6) used to be mapped to 7 / 12 B SOS.
    let wrapped13 = sos7Active + [0x01, 0x02, 0x03, 0x04, 0x05, 0x06]
    expect(wrapped13.count == 13, "13 B fixture")
    expect(parse(wrapped13, .tel) == nil, "13 B is not SOS on TEL")
    expect(parse(wrapped13, .sos) == nil, "13 B is not SOS on the SOS characteristic")
    let wrapped18 = modernSos12 + [0x01, 0x02, 0x03, 0x04, 0x05, 0x06]
    expect(wrapped18.count == 18, "18 B fixture")
    expect(parse(wrapped18, .tel) == nil, "18 B is not SOS on TEL")
    expect(parse(wrapped18, .sos) == nil, "18 B is not SOS on the SOS characteristic")
    expect(parse([], .tel) == nil, "empty frame")
    expect(parse([0x01, 0x02, 0x03], .sos) == nil, "short frame")
  }

  /// INET (ea03) and CMD (ea04) notifications are never SOS candidates, even
  /// when their bytes look like a 7 / 12 B SOS or an E1/E2/E3 event.
  private static func otherCharacteristicsNeverSos() {
    let frames: [(String, [UInt8])] = [
      ("12 B sosType 3", modernSos12),
      ("7 B sosType 3", sos7Active),
      ("7 B sosType 1", [0xA8, 0x1A, 0x4B, 0x59, 0x00, 0x40, 0x00]),
      ("12 B sosType 0", Array(modernSos12.prefix(11)) + [0x00]),
      ("E1 event", [0xE1, 0x02, 0xA8, 0x1A, 0x4B, 0x59]),
      ("E3 event", [0xE3, 0x01, 0xA8, 0x1A, 0x4B, 0x59]),
    ]
    for (name, bytes) in frames {
      expect(parse(bytes, .other) == nil, "\(name) on INET/CMD is not SOS")
      expect(parse(bytes, .sos) != nil, "\(name) on the SOS characteristic is still parsed")
    }
  }

  private static func nearbyOwnerNameStructure() {
    // 7 B owner name "Jo": the bytes after the 5 B header read as flags
    // sosType 1 (pre-SOS) without the structural check.
    let shortName: [UInt8] = [0xDB, 0x11, 0x22, 0x33, 0x44, 0x4A, 0x6F]
    expect(shortName.count == 7, "0xDB 7 B fixture")
    expect(parse(shortName, .tel) == nil, "0xDB owner name (7 B) is not SOS")
    let longName: [UInt8] = [0xDB, 0x11, 0x22, 0x33, 0x44] + Array("Sergi M".utf8)
    expect(longName.count == 12, "0xDB 12 B fixture")
    expect(parse(longName, .tel) == nil, "0xDB owner name (12 B) is not SOS")

    // A real SOS whose node id happens to start with 0xDB is not valid UTF-8
    // after the header (sosType 3 lead byte), so it stays an SOS.
    var sosFromDbNode = sos7Active
    sosFromDbNode[0] = 0xDB
    expect(parse(sosFromDbNode, .tel)?.kind == .active, "7 B SOS from a node id starting 0xDB is still SOS")
    var modernFromDbNode = modernSos12
    modernFromDbNode[0] = 0xDB
    expect(parse(modernFromDbNode, .tel)?.kind == .active, "12 B SOS from a node id starting 0xDB is still SOS")
  }
}
