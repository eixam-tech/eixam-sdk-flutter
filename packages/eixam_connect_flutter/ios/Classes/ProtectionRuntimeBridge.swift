import Flutter
import UIKit
import UserNotifications
import CoreBluetooth

final class ProtectionRuntimeBridge: NSObject, FlutterStreamHandler {
  private static let methodChannelName = "dev.eixam.connect_flutter/protection_runtime/methods"
  private static let eventChannelName = "dev.eixam.connect_flutter/protection_runtime/events"
  private static let prefsName = "eixam_protection_runtime_ios"

  private var eventSink: FlutterEventSink?

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = ProtectionRuntimeBridge()
    let methodChannel = FlutterMethodChannel(
      name: methodChannelName,
      binaryMessenger: registrar.messenger()
    )
    let eventChannel = FlutterEventChannel(
      name: eventChannelName,
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(instance, channel: methodChannel)
    eventChannel.setStreamHandler(instance)
  }

  private var defaults: UserDefaults {
    UserDefaults(suiteName: Self.prefsName) ?? .standard
  }

  private let bluetoothManager = CBCentralManager(delegate: nil, queue: nil)

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getPlatformSnapshot":
      result(snapshot())
    case "startProtectionRuntime":
      defaults.set("Protection Mode on iOS is currently scaffolded only. Host app capabilities and future restoration wiring can be validated now, but background BLE ownership is not yet active.", forKey: "degradation_reason")
      defaults.set("runtimeStartRequested", forKey: "last_platform_event")
      defaults.set(Date().millisecondsSince1970, forKey: "last_platform_event_at")
      result([
        "success": true,
        "runtimeState": "inactive",
        "coverageLevel": "partial",
        "statusMessage": "iOS Protection Mode base adapter is present, but real background BLE/runtime ownership is not implemented yet."
      ])
    case "stopProtectionRuntime":
      defaults.set("runtimeStopped", forKey: "last_platform_event")
      defaults.set(Date().millisecondsSince1970, forKey: "last_platform_event_at")
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  private func snapshot() -> [String: Any?] {
    return [
      "backgroundCapabilityReady": false,
      "backgroundCapabilityState": backgroundCapabilityState(),
      "platformRuntimeConfigured": true,
      "runtimeActive": false,
      "bluetoothEnabled": bluetoothEnabled(),
      "notificationsGranted": notificationsGranted(),
      "lastFailureReason": nil,
      "lastPlatformEvent": defaults.string(forKey: "last_platform_event"),
      "lastPlatformEventAt": defaults.object(forKey: "last_platform_event_at") as? Int,
      "runtimeState": "inactive",
      "coverageLevel": "partial",
      "degradationReason": defaults.string(forKey: "degradation_reason")
        ?? "iOS host integration is scaffolded, but background BLE ownership and restoration are not implemented yet."
    ]
  }

  private func bluetoothEnabled() -> Bool {
    bluetoothManager.state == .poweredOn
  }

  private func notificationsGranted() -> Bool {
    let semaphore = DispatchSemaphore(value: 0)
    var granted = false
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      granted = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
      semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 0.2)
    return granted
  }

  private func backgroundCapabilityState() -> String {
    let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
    return modes.contains("bluetooth-central") ? "configured" : "unknown"
  }
}

private extension Date {
  var millisecondsSince1970: Int {
    Int((timeIntervalSince1970 * 1000.0).rounded())
  }
}
