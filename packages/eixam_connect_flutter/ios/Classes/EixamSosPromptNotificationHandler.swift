import Foundation
import UserNotifications

/// F17c ambiguous TAG SOS prompt: the host app's `UNUserNotificationCenter`
/// delegate forwards the prompt notification here (the SDK does not take over
/// the host's delegate).
///
/// ```swift
/// // userNotificationCenter(_:didReceive:withCompletionHandler:)
/// if EixamSosPromptNotificationHandler.handle(response) { completionHandler(); return }
/// // userNotificationCenter(_:willPresent:withCompletionHandler:)
/// if EixamSosPromptNotificationHandler.isPrompt(notification.request) { completionHandler([.banner, .list, .sound]); return }
/// ```
@objc public final class EixamSosPromptNotificationHandler: NSObject {
  /// Whether [request] is the SDK's prompt (or its post-"No" confirmation).
  @objc public static func isPrompt(_ request: UNNotificationRequest) -> Bool {
    IosSosPromptNotification.isPrompt(
      userInfo: request.content.userInfo,
      identifier: request.identifier
    )
  }

  /// Handles a response to the SDK prompt. "Send SOS" and "No, stop the TAG"
  /// (the latter only reachable after the unlock: `.authenticationRequired`)
  /// go to the native prompt; the default tap only opens the app, where the
  /// host shows the full-screen prompt from the SDK. Returns false for any
  /// other notification.
  @objc public static func handle(_ response: UNNotificationResponse) -> Bool {
    guard isPrompt(response.notification.request) else {
      return false
    }
    if let choice = IosSosPromptNotification.choice(forActionIdentifier: response.actionIdentifier) {
      ProtectionRuntimeBridge.answerOwnTagSosPromptFromNotification(choice)
    }
    return true
  }
}
