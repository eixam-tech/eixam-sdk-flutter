import Foundation
import UserNotifications

/// F17c ambiguous TAG SOS prompt: the local notification and its two actions.
/// Foundation + UserNotifications only, so it runs under `swiftc` tests.
///
/// Owner decision (Roger, 16/11/2026): a normal local notification. No
/// time-sensitive interruption level (no entitlement), interruption level
/// `.active`. "Send SOS" is one tap without unlock; "No, stop the TAG" needs the
/// device unlocked (`.authenticationRequired`). The native 30 s timer sends the
/// SOS when nobody answers.
enum IosSosPromptNotification {
  static let categoryIdentifier = "eixam_sos_prompt"
  static let requestIdentifier = "eixam_sos_prompt"
  static let stoppedRequestIdentifier = "eixam_sos_prompt_stopped"
  static let sendActionIdentifier = "eixam_sos_prompt_send"
  static let stopActionIdentifier = "eixam_sos_prompt_stop"
  static let source = "ios_sos_prompt_notification"

  struct Texts: Equatable {
    var title = "Your TAG is still in SOS"
    var body = "You stopped an SOS, but your TAG didn't get it. Is this a new emergency? If you don't answer, we'll send the SOS in 30 s."
    var sendAction = "Send SOS"
    var stopAction = "No, stop the TAG"
    var stopped = "TAG stopped. No SOS was sent."
  }

  /// "Send SOS" first (primary). No `.foreground`: answered in the background
  /// without opening the app; no `.authenticationRequired`: works locked.
  static func actions(texts: Texts) -> [UNNotificationAction] {
    [
      UNNotificationAction(identifier: sendActionIdentifier, title: texts.sendAction, options: []),
      UNNotificationAction(
        identifier: stopActionIdentifier,
        title: texts.stopAction,
        options: [.authenticationRequired]
      ),
    ]
  }

  static func category(texts: Texts) -> UNNotificationCategory {
    UNNotificationCategory(
      identifier: categoryIdentifier,
      actions: actions(texts: texts),
      intentIdentifiers: [],
      options: []
    )
  }

  /// Keeps the host's categories (e.g. flutter_local_notifications) and
  /// replaces only this one.
  static func merged(_ existing: Set<UNNotificationCategory>, texts: Texts) -> Set<UNNotificationCategory> {
    var result = existing.filter { $0.identifier != categoryIdentifier }
    result.insert(category(texts: texts))
    return result
  }

  static func content(texts: Texts, terminal: String, deadlineAtMs: Int) -> UNMutableNotificationContent {
    let content = UNMutableNotificationContent()
    content.title = texts.title
    content.body = texts.body
    content.sound = .default
    content.categoryIdentifier = categoryIdentifier
    content.userInfo = [
      "source": source,
      "route": "sos_prompt",
      "payload": "sos:prompt",
      "terminal": terminal,
      "deadlineAtMs": deadlineAtMs,
    ]
    if #available(iOS 15.0, macOS 12.0, *) {
      // Owner decision: never `.timeSensitive` (no entitlement).
      content.interruptionLevel = .active
    }
    return content
  }

  static func stoppedContent(texts: Texts) -> UNMutableNotificationContent {
    let content = UNMutableNotificationContent()
    content.title = texts.stopped
    content.userInfo = ["source": source, "route": "sos_prompt", "payload": "sos:prompt_stopped"]
    if #available(iOS 15.0, macOS 12.0, *) {
      content.interruptionLevel = .active
    }
    return content
  }

  /// The user's choice for a notification action; nil for the default tap
  /// (opens the app, which shows the full-screen prompt) or another action.
  static func choice(forActionIdentifier identifier: String) -> String? {
    switch identifier {
    case sendActionIdentifier: return "sendSos"
    case stopActionIdentifier: return "stopTag"
    default: return nil
    }
  }

  static func isPrompt(userInfo: [AnyHashable: Any], identifier: String) -> Bool {
    identifier == requestIdentifier || identifier == stoppedRequestIdentifier ||
      userInfo["source"] as? String == source
  }
}
