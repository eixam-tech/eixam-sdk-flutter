import Foundation

struct TelAggregateFragment {
  let totalLength: Int
  let offset: Int
  let fragmentPayload: [UInt8]

  var fragmentLength: Int { fragmentPayload.count }

  static func tryParse(_ bytes: [UInt8]) -> TelAggregateFragment? {
    guard bytes.count >= 6, bytes[0] == 0xD0 else {
      return nil
    }
    let totalLength = Int(bytes[1]) | (Int(bytes[2]) << 8)
    let offset = Int(bytes[3]) | (Int(bytes[4]) << 8)
    let payload = Array(bytes[5...])
    guard totalLength > 0, !payload.isEmpty, payload.count <= 15 else {
      return nil
    }
    return TelAggregateFragment(
      totalLength: totalLength,
      offset: offset,
      fragmentPayload: payload
    )
  }
}

final class TelAggregateReassembler {
  private var activeTotalLength: Int?
  private var fragmentsByOffset: [Int: [UInt8]] = [:]

  func ingest(_ payload: [UInt8]) -> [UInt8]? {
    guard let fragment = TelAggregateFragment.tryParse(payload) else {
      return payload
    }
    return addFragment(fragment)
  }

  func addFragment(_ fragment: TelAggregateFragment) -> [UInt8]? {
    if fragment.offset < 0 {
      reset()
      return nil
    }
    if let active = activeTotalLength {
      if active != fragment.totalLength {
        reset()
        activeTotalLength = fragment.totalLength
      }
    } else {
      activeTotalLength = fragment.totalLength
    }
    let fragmentEnd = fragment.offset + fragment.fragmentLength
    if fragmentEnd > fragment.totalLength {
      reset()
      return nil
    }
    for (existingStart, existingPayload) in fragmentsByOffset {
      let existingEnd = existingStart + existingPayload.count
      let overlaps = fragment.offset < existingEnd && fragmentEnd > existingStart
      guard overlaps else {
        continue
      }
      let sameRange = existingStart == fragment.offset &&
        existingEnd == fragmentEnd &&
        existingPayload == fragment.fragmentPayload
      if sameRange {
        return tryComplete(fragment.totalLength)
      }
      reset()
      return nil
    }
    fragmentsByOffset[fragment.offset] = fragment.fragmentPayload
    return tryComplete(fragment.totalLength)
  }

  func reset() {
    activeTotalLength = nil
    fragmentsByOffset.removeAll()
  }

  private func tryComplete(_ totalLength: Int) -> [UInt8]? {
    if fragmentsByOffset.isEmpty {
      return nil
    }
    let ordered = fragmentsByOffset.keys.sorted()
    var cursor = 0
    var completed: [UInt8] = []
    completed.reserveCapacity(totalLength)
    for offset in ordered {
      if offset != cursor {
        return nil
      }
      guard let payload = fragmentsByOffset[offset] else {
        return nil
      }
      completed.append(contentsOf: payload)
      cursor += payload.count
    }
    if cursor != totalLength {
      return nil
    }
    reset()
    return completed
  }
}
