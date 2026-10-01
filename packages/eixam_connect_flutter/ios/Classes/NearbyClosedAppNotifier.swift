import Foundation
import UserNotifications
import UIKit

struct NearbyTextNotify {
  let fromNodeId: UInt32
  let destNodeId: UInt32
  let packetId: UInt32
  let groupId: UInt64
  let text: String

  var plaza: Bool {
    groupId == 0 && destNodeId == 0xFFFFFFFF
  }

  var threadKey: String {
    if groupId != 0 {
      return "grp:" + String(groupId, radix: 16).leftPad(to: 16)
    }
    if destNodeId != 0xFFFFFFFF {
      return "dm:" + String(fromNodeId, radix: 16).leftPad(to: 8)
    }
    return "nearby"
  }

  var hardwareLabel: String {
    "EIXAM_" + String(fromNodeId, radix: 16).leftPad(to: 8).uppercased()
  }

  var dedupeKey: String {
    "\(fromNodeId):\(packetId)"
  }

  var payload: String {
    "nearby#\(threadKey)"
  }
}

enum NearbyTextNotifyParser {
  private static let opcode: UInt8 = 0xD8
  private static let headerLength = 22
  private static let maxPayloadBytes = 233
  private static let lengthPad: UInt8 = 0xFF

  static func tryParse(_ payload: [UInt8]) -> NearbyTextNotify? {
    guard payload.count >= headerLength, payload[0] == opcode else {
      return nil
    }
    if isReservedSosOrTelLength(payload.count) {
      return nil
    }
    let utf8 = stripPad(Array(payload[headerLength...]))
    guard !utf8.isEmpty, utf8.count <= maxPayloadBytes else {
      return nil
    }
    guard let text = String(bytes: utf8, encoding: .utf8), !text.isEmpty else {
      return nil
    }
    return NearbyTextNotify(
      fromNodeId: u32le(payload, 1),
      destNodeId: u32le(payload, 5),
      packetId: u32le(payload, 9),
      groupId: u64le(payload, 13),
      text: text
    )
  }

  private static func isReservedSosOrTelLength(_ length: Int) -> Bool {
    length == 6 || length == 7 || length == 10 || length == 12 ||
      length == 13 || length == 16 || length == 18
  }

  private static func stripPad(_ bytes: [UInt8]) -> [UInt8] {
    var end = bytes.count
    while end > 0, bytes[end - 1] == lengthPad {
      end -= 1
    }
    return Array(bytes[..<end])
  }

  private static func u32le(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    UInt32(bytes[offset]) |
      UInt32(bytes[offset + 1]) << 8 |
      UInt32(bytes[offset + 2]) << 16 |
      UInt32(bytes[offset + 3]) << 24
  }

  private static func u64le(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
    UInt64(u32le(bytes, offset)) | UInt64(u32le(bytes, offset + 4)) << 32
  }
}

enum NearbyClosedAppNotifier {
  static let notificationId = 43000
  private static let mutedKey = "flutter.nearby.muted"
  private static let nicknamesKey = "flutter.nearby.nicknames"
  private static let hiddenKey = "flutter.nearby.hiddenNodeIds"
  private static let notifiedKeysKey = "ios_nearby_notified_keys"
  private static let maxNotifiedKeys = 64

  static func maybeNotify(
    payload: [UInt8],
    channelName: String,
    fallbackTitle: String
  ) {
    let run = {
      maybeNotifyOnMain(
        payload: payload,
        channelName: channelName,
        fallbackTitle: fallbackTitle
      )
    }
    if Thread.isMainThread {
      run()
    } else {
      DispatchQueue.main.async(execute: run)
    }
  }

  private static func maybeNotifyOnMain(
    payload: [UInt8],
    channelName: String,
    fallbackTitle: String
  ) {
    guard let parsed = NearbyTextNotifyParser.tryParse(payload) else {
      return
    }
    // BLE callbacks are not on main; applicationState is only valid here.
    if UIApplication.shared.applicationState == .active {
      return
    }
    let flutterDefaults = UserDefaults.standard
    if flutterDefaults.bool(forKey: mutedKey) {
      return
    }
    if parsed.plaza, isHidden(flutterDefaults.string(forKey: hiddenKey), parsed.fromNodeId) {
      return
    }
    guard remember(parsed.dedupeKey) else {
      return
    }
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      guard isNotificationAuthorized(settings.authorizationStatus) else {
        return
      }
      let content = UNMutableNotificationContent()
      content.title = senderLabel(
        nicknamesJson: flutterDefaults.string(forKey: nicknamesKey),
        parsed: parsed,
        fallback: fallbackTitle
      )
      content.body = parsed.text
      content.sound = .default
      content.threadIdentifier = channelName
      content.userInfo = [
        "NotificationId": notificationId,
        "payload": parsed.payload,
        "presentAlert": true,
        "presentSound": true,
        "presentBadge": true,
        "presentBanner": true,
        "presentList": true,
        "source": "ios_nearby_notification",
        "route": "nearby",
      ]
      if #available(iOS 15.0, *) {
        content.interruptionLevel = .active
      }
      // A nil trigger is dropped when iOS suspends the BLE wake before the
      // system takes the request. A one-shot interval is delivered even after
      // this process is frozen, secure lock screen or not.
      let request = UNNotificationRequest(
        identifier: "\(notificationId)",
        content: content,
        trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
      )
      let application = UIApplication.shared
      let task = NearbyNotifyTask()
      task.begin(application)
      UNUserNotificationCenter.current().add(request) { _ in
        task.end(application)
      }
    }
  }

  private static func isNotificationAuthorized(_ status: UNAuthorizationStatus) -> Bool {
    if status == .authorized || status == .provisional {
      return true
    }
    if #available(iOS 14.0, *), status == .ephemeral {
      return true
    }
    return false
  }

  private static func senderLabel(
    nicknamesJson: String?,
    parsed: NearbyTextNotify,
    fallback: String
  ) -> String {
    if let nick = nicknameFor(nicknamesJson, parsed.fromNodeId), !nick.isEmpty {
      return nick
    }
    let label = parsed.hardwareLabel
    return label.isEmpty ? fallback : label
  }

  private static func nicknameFor(_ raw: String?, _ nodeId: UInt32) -> String? {
    guard let raw, let data = raw.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return nil
    }
    let value = (object["\(nodeId)"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return value?.isEmpty == false ? value : nil
  }

  private static func isHidden(_ raw: String?, _ nodeId: UInt32) -> Bool {
    guard let raw, let data = raw.data(using: .utf8),
          let array = try? JSONSerialization.jsonObject(with: data) as? [Any]
    else {
      return false
    }
    return array.contains { item in
      if let number = item as? NSNumber {
        return number.uint32Value == nodeId
      }
      if let value = item as? Int {
        return UInt32(truncatingIfNeeded: value) == nodeId
      }
      return false
    }
  }

  private static func remember(_ key: String) -> Bool {
    let defaults = UserDefaults.standard
    var keys = defaults.stringArray(forKey: notifiedKeysKey) ?? []
    if keys.contains(key) {
      return false
    }
    keys.append(key)
    if keys.count > maxNotifiedKeys {
      keys = Array(keys.suffix(maxNotifiedKeys))
    }
    defaults.set(keys, forKey: notifiedKeysKey)
    return true
  }
}

private final class NearbyNotifyTask {
  private let lock = NSLock()
  private var id = UIBackgroundTaskIdentifier.invalid

  func begin(_ application: UIApplication) {
    let started = application.beginBackgroundTask(withName: "nearby-notify") {
      self.end(application)
    }
    lock.lock()
    id = started
    lock.unlock()
  }

  func end(_ application: UIApplication) {
    lock.lock()
    let current = id
    id = .invalid
    lock.unlock()
    if current != .invalid {
      application.endBackgroundTask(current)
    }
  }
}

private extension String {
  func leftPad(to width: Int, with pad: Character = "0") -> String {
    if count >= width {
      return self
    }
    return String(repeating: String(pad), count: width - count) + self
  }
}
