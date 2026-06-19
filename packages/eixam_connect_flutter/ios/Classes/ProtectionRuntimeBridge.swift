import CoreBluetooth
import Flutter
import UIKit
import UserNotifications

final class ProtectionRuntimeBridge: NSObject, FlutterPlugin, FlutterStreamHandler {
  private static let methodChannelName = "dev.eixam.connect_flutter/protection_runtime/methods"
  private static let eventChannelName = "dev.eixam.connect_flutter/protection_runtime/events"
  private static let prefsName = "eixam_protection_runtime_ios"
  private static let restorationIdentifier = "dev.eixam.connect.flutter.protection.central"
  private static let eixamServiceUuid = CBUUID(string: "EA00")
  private static let telCharacteristicUuid = CBUUID(string: "EA01")
  private static let sosCharacteristicUuid = CBUUID(string: "EA02")
  private static let inetCharacteristicUuid = CBUUID(string: "EA03")
  private static let cmdCharacteristicUuid = CBUUID(string: "EA04")
  private static let sosNotificationDedupeWindowMs = 10 * 60 * 1000

  private enum RuntimeState: String {
    case inactive
    case starting
    case active
    case recovering
    case failed
  }

  private enum Keys {
    static let isArmed = "is_armed"
    static let protectedDeviceId = "protected_device_id"
    static let runtimeState = "runtime_state"
    static let lastFailureReason = "last_failure_reason"
    static let lastPlatformEvent = "last_platform_event"
    static let lastPlatformEventAt = "last_platform_event_at"
    static let lastRestorationEvent = "last_restoration_event"
    static let lastRestorationEventAt = "last_restoration_event_at"
    static let lastBleServiceEvent = "last_ble_service_event"
    static let lastBleServiceEventAt = "last_ble_service_event_at"
    static let lastWakeReason = "last_wake_reason"
    static let lastWakeAt = "last_wake_at"
    static let reconnectAttemptCount = "reconnect_attempt_count"
    static let lastReconnectAttemptAt = "last_reconnect_attempt_at"
    static let degradationReason = "degradation_reason"
    static let discoveredBleServicesSummary = "discovered_ble_services_summary"
    static let readinessFailureReason = "readiness_failure_reason"
    static let restorationConfigured = "restoration_configured"
    static let restorationIdentifier = "restoration_identifier"
    static let lastRuntimeError = "last_runtime_error"
    static let lastCommandRoute = "last_command_route"
    static let lastCommandResult = "last_command_result"
    static let lastCommandError = "last_command_error"
    static let iosBleSosSnapshotKind = "ios_ble_sos_snapshot_kind"
    static let iosBleSosPayloadHex = "ios_ble_sos_payload_hex"
    static let iosBleSosSource = "ios_ble_sos_source"
    static let iosBleSosCharacteristicUuid = "ios_ble_sos_characteristic_uuid"
    static let iosBleSosReceivedAt = "ios_ble_sos_received_at"
    static let iosBleSosDeadlineAt = "ios_ble_sos_deadline_at"
    static let iosBleSosNodeId = "ios_ble_sos_node_id"
    static let iosBleSosPacketId = "ios_ble_sos_packet_id"
    static let iosBleSosCycleKey = "ios_ble_sos_cycle_key"
    static let iosBleSosNotifiedKeys = "ios_ble_sos_notified_keys"
    static let notificationProtectionPreSosTitle = "notification_protection_pre_sos_title"
    static let notificationProtectionPreSosBody = "notification_protection_pre_sos_body"
    static let notificationProtectionSosActiveTitle = "notification_protection_sos_active_title"
    static let notificationProtectionSosActiveBody = "notification_protection_sos_active_body"
    static let notificationProtectionSosResolvedTitle = "notification_protection_sos_resolved_title"
    static let notificationProtectionSosResolvedBody = "notification_protection_sos_resolved_body"
    static let notificationProtectionSosCancelledTitle = "notification_protection_sos_cancelled_title"
    static let notificationProtectionSosCancelledBody = "notification_protection_sos_cancelled_body"
  }

  private enum IosBleSosSnapshotKind: String {
    case preSos
    case active
    case cancelled
  }

  private var eventSink: FlutterEventSink?
  private var centralManager: CBCentralManager?
  private var protectedPeripheral: CBPeripheral?
  private var telCharacteristic: CBCharacteristic?
  private var sosCharacteristic: CBCharacteristic?
  private var inetCharacteristic: CBCharacteristic?
  private var cmdCharacteristic: CBCharacteristic?
  private var subscriptionsActive = false
  private var servicesDiscovered = false
  private var restoredLastLaunch = false

  @objc static func register(with registrar: FlutterPluginRegistrar) {
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

  override init() {
    super.init()
    defaults.set(Self.restorationIdentifier, forKey: Keys.restorationIdentifier)
    defaults.set(true, forKey: Keys.restorationConfigured)
    ensureCentralManager()
    if isArmed {
      updateRuntimeState(.recovering)
      recordWake(reason: "plugin_registered")
      attemptProtectionReconnect(trigger: "plugin_registered")
    }
  }

  private var defaults: UserDefaults {
    UserDefaults(suiteName: Self.prefsName) ?? .standard
  }

  private var isArmed: Bool {
    defaults.bool(forKey: Keys.isArmed)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getPlatformSnapshot":
      if isArmed,
         currentRuntimeState == .recovering || protectedPeripheral?.state != .connected || !subscriptionsActive {
        attemptProtectionReconnect(trigger: "snapshot_refresh")
      }
      result(snapshot())
    case "startProtectionRuntime":
      let arguments = call.arguments as? [String: Any]
      let activeDeviceId = (arguments?["activeDeviceId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let activeDeviceId, !activeDeviceId.isEmpty else {
        let failure = "Protection Mode on iOS requires a protected device identifier before the plugin runtime can arm."
        defaults.set(failure, forKey: Keys.lastFailureReason)
        defaults.set(failure, forKey: Keys.readinessFailureReason)
        updateRuntimeState(.failed)
        recordEvent(type: "runtimeError", reason: failure)
        result([
          "success": false,
          "runtimeState": RuntimeState.failed.rawValue,
          "coverageLevel": "none",
          "failureReason": failure,
        ])
        return
      }
      defaults.set(true, forKey: Keys.isArmed)
      defaults.set(activeDeviceId, forKey: Keys.protectedDeviceId)
      storeNotificationTexts(arguments?["notificationTexts"] as? [String: Any])
      defaults.removeObject(forKey: Keys.lastFailureReason)
      defaults.removeObject(forKey: Keys.readinessFailureReason)
      ensureCentralManager()
      subscriptionsActive = false
      servicesDiscovered = false
      protectedPeripheral = nil
      telCharacteristic = nil
      sosCharacteristic = nil
      inetCharacteristic = nil
      cmdCharacteristic = nil
      updateRuntimeState(.starting)
      recordEvent(type: "runtimeStarting", reason: "protection_runtime_start_requested")
      attemptProtectionReconnect(trigger: "start_request")
      result([
        "success": true,
        "runtimeState": currentRuntimeState.rawValue,
        "coverageLevel": currentCoverageLevel(),
        "statusMessage": currentStatusMessage(),
      ])
    case "stopProtectionRuntime":
      stopProtectionRuntime(reason: "protection_runtime_stopped")
      result(nil)
    case "resumeProtectionRuntime":
      let reason = ((call.arguments as? [String: Any])?["reason"] as? String) ?? "app_foreground_resume"
      recordWake(reason: reason)
      if isArmed {
        attemptProtectionReconnect(trigger: reason)
      }
      result(nil)
    case "sendProtectionCommand":
      let arguments = call.arguments as? [String: Any]
      let label = (arguments?["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      let bytes = arguments?["bytes"] as? [NSNumber] ?? []
      let forceCmdCharacteristic = arguments?["forceCmdCharacteristic"] as? Bool ?? false
      result(sendProtectionCommand(
        label: label?.isEmpty == false ? label! : "BLE command",
        bytes: bytes.map(\.intValue),
        forceCmdCharacteristic: forceCmdCharacteristic
      ))
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

  private func ensureCentralManager() {
    if centralManager != nil {
      return
    }
    centralManager = CBCentralManager(
      delegate: self,
      queue: nil,
      options: [
        CBCentralManagerOptionRestoreIdentifierKey: Self.restorationIdentifier,
      ]
    )
  }

  private var currentRuntimeState: RuntimeState {
    RuntimeState(rawValue: defaults.string(forKey: Keys.runtimeState) ?? "") ?? .inactive
  }

  private func updateRuntimeState(_ state: RuntimeState) {
    defaults.set(state.rawValue, forKey: Keys.runtimeState)
  }

  private func stopProtectionRuntime(reason: String) {
    defaults.set(false, forKey: Keys.isArmed)
    subscriptionsActive = false
    servicesDiscovered = false
    telCharacteristic = nil
    sosCharacteristic = nil
    inetCharacteristic = nil
    cmdCharacteristic = nil
    if let peripheral = protectedPeripheral {
      centralManager?.cancelPeripheralConnection(peripheral)
    }
    protectedPeripheral = nil
    updateRuntimeState(.inactive)
    defaults.set("Protection Mode is off on iOS, so the existing Flutter BLE path remains the owner.", forKey: Keys.degradationReason)
    defaults.removeObject(forKey: Keys.readinessFailureReason)
    recordEvent(type: "runtimeStopped", reason: reason)
  }

  private func storeNotificationTexts(_ texts: [String: Any]?) {
    guard let texts else {
      return
    }
    setNotificationText(
      texts["protectionPreSosTitle"] as? String,
      forKey: Keys.notificationProtectionPreSosTitle
    )
    setNotificationText(
      texts["protectionPreSosBody"] as? String,
      forKey: Keys.notificationProtectionPreSosBody
    )
    setNotificationText(
      texts["protectionSosActiveTitle"] as? String,
      forKey: Keys.notificationProtectionSosActiveTitle
    )
    setNotificationText(
      texts["protectionSosActiveBody"] as? String,
      forKey: Keys.notificationProtectionSosActiveBody
    )
    setNotificationText(
      texts["protectionSosResolvedTitle"] as? String,
      forKey: Keys.notificationProtectionSosResolvedTitle
    )
    setNotificationText(
      texts["protectionSosResolvedBody"] as? String,
      forKey: Keys.notificationProtectionSosResolvedBody
    )
    setNotificationText(
      texts["notificationSosCancelledTitle"] as? String,
      forKey: Keys.notificationProtectionSosCancelledTitle
    )
    setNotificationText(
      texts["notificationSosCancelledBody"] as? String,
      forKey: Keys.notificationProtectionSosCancelledBody
    )
  }

  private func setNotificationText(_ value: String?, forKey key: String) {
    let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let normalized, !normalized.isEmpty {
      defaults.set(normalized, forKey: key)
    }
  }

  private func attemptProtectionReconnect(trigger: String) {
    guard isArmed else {
      return
    }
    guard let centralManager else {
      updateRuntimeState(.failed)
      let reason = "The iOS Protection central manager could not be created."
      defaults.set(reason, forKey: Keys.lastFailureReason)
      defaults.set(reason, forKey: Keys.readinessFailureReason)
      recordEvent(type: "runtimeError", reason: reason)
      return
    }
    guard let protectedDeviceId = defaults.string(forKey: Keys.protectedDeviceId),
          let uuid = UUID(uuidString: protectedDeviceId)
    else {
      updateRuntimeState(.failed)
      let reason = "The protected iOS device identifier is missing or invalid."
      defaults.set(reason, forKey: Keys.lastFailureReason)
      defaults.set(reason, forKey: Keys.readinessFailureReason)
      recordEvent(type: "runtimeError", reason: reason)
      return
    }

    recordWake(reason: trigger)

    guard centralManager.state == .poweredOn else {
      updateRuntimeState(.recovering)
      let reason = "CoreBluetooth is not powered on, so the iOS plugin runtime is waiting before it can reconnect."
      defaults.set(reason, forKey: Keys.degradationReason)
      defaults.set(reason, forKey: Keys.readinessFailureReason)
      return
    }

    let nextAttemptCount = defaults.integer(forKey: Keys.reconnectAttemptCount) + 1
    defaults.set(nextAttemptCount, forKey: Keys.reconnectAttemptCount)
    defaults.set(Date().millisecondsSince1970, forKey: Keys.lastReconnectAttemptAt)
    recordEvent(type: "reconnectScheduled", reason: trigger)

    let peripherals = centralManager.retrievePeripherals(withIdentifiers: [uuid])
    guard let peripheral = peripherals.first else {
      updateRuntimeState(.recovering)
      let reason = "The iOS plugin runtime could not retrieve the protected peripheral from CoreBluetooth yet. Launch once in foreground and reconnect manually if needed."
      defaults.set(reason, forKey: Keys.degradationReason)
      defaults.set(reason, forKey: Keys.readinessFailureReason)
      defaults.set(reason, forKey: Keys.lastFailureReason)
      recordEvent(type: "reconnectFailed", reason: reason)
      return
    }

    protectedPeripheral = peripheral
    peripheral.delegate = self
    defaults.set(peripheral.identifier.uuidString, forKey: Keys.protectedDeviceId)
    recordBleEvent(type: "deviceConnecting")

    if peripheral.state == .connected {
      handleConnectedPeripheral(peripheral, restored: trigger.contains("restoration"))
      return
    }

    centralManager.connect(peripheral, options: nil)
  }

  private func handleConnectedPeripheral(_ peripheral: CBPeripheral, restored: Bool) {
    protectedPeripheral = peripheral
    peripheral.delegate = self
    servicesDiscovered = false
    subscriptionsActive = false
    telCharacteristic = nil
    sosCharacteristic = nil
    inetCharacteristic = nil
    cmdCharacteristic = nil
    updateRuntimeState(.recovering)
    defaults.removeObject(forKey: Keys.lastFailureReason)
    defaults.removeObject(forKey: Keys.readinessFailureReason)
    recordBleEvent(type: "deviceConnected")
    if restored {
      recordRestorationEvent(type: "restorationRehydrated", reason: "corebluetooth_restored_connected_peripheral")
    }
    peripheral.discoverServices([Self.eixamServiceUuid])
  }

  private func recordWake(reason: String) {
    defaults.set(Date().millisecondsSince1970, forKey: Keys.lastWakeAt)
    defaults.set(reason, forKey: Keys.lastWakeReason)
    emitEvent(type: "woke", reason: reason)
  }

  private func recordEvent(type: String, reason: String?) {
    let timestamp = Date().millisecondsSince1970
    defaults.set(type, forKey: Keys.lastPlatformEvent)
    defaults.set(timestamp, forKey: Keys.lastPlatformEventAt)
    if type == "runtimeError" || type == "runtimeFailed" {
      defaults.set(reason, forKey: Keys.lastRuntimeError)
      defaults.set(reason, forKey: Keys.lastFailureReason)
    }
    emitEvent(type: type, reason: reason, timestamp: timestamp)
  }

  private func recordRestorationEvent(type: String, reason: String?) {
    let timestamp = Date().millisecondsSince1970
    defaults.set(type, forKey: Keys.lastRestorationEvent)
    defaults.set(timestamp, forKey: Keys.lastRestorationEventAt)
    recordEvent(type: type, reason: reason)
  }

  private func recordBleEvent(type: String) {
    let timestamp = Date().millisecondsSince1970
    defaults.set(type, forKey: Keys.lastBleServiceEvent)
    defaults.set(timestamp, forKey: Keys.lastBleServiceEventAt)
    recordEvent(type: type, reason: nil)
  }

  private func emitEvent(
    type: String,
    reason: String?,
    timestamp: Int? = nil,
    payload: [String: Any]? = nil
  ) {
    var event: [String: Any] = [
      "type": type,
      "timestamp": timestamp ?? Date().millisecondsSince1970,
    ]

    if let reason {
      event["reason"] = reason
    }
    if let payload {
      for (key, value) in payload {
        event[key] = value
      }
    }

    eventSink?(event)
  }

  private func currentCoverageLevel() -> String {
    guard isArmed else {
      return "none"
    }
    if backgroundCapabilityReady(),
       defaults.bool(forKey: Keys.restorationConfigured),
       protectedPeripheral?.state == .connected,
       servicesDiscovered,
       subscriptionsActive,
       currentRuntimeState == .active {
      return "full"
    }
    return "partial"
  }

  private func currentStatusMessage() -> String {
    if let degradationReason = degradationReason(), !degradationReason.isEmpty {
      return degradationReason
    }
    if currentCoverageLevel() == "full" {
      return "The iOS plugin runtime owns the Protection BLE base and has restored the protected device subscriptions."
    }
    return "The iOS plugin runtime is armed, but background BLE recovery is still partial."
  }

  private func degradationReason() -> String? {
    guard isArmed else {
      return "Protection Mode is off on iOS, so the existing Flutter BLE path remains unchanged."
    }
    if !backgroundCapabilityReady() {
      return "The host app is missing the bluetooth-central background capability required for iOS Protection Mode coverage."
    }
    if !(defaults.bool(forKey: Keys.restorationConfigured)) {
      return "The iOS Protection central manager is not configured for state restoration."
    }
    if centralManager?.state != .poweredOn {
      return "CoreBluetooth is not powered on, so the iOS plugin runtime cannot reconnect yet."
    }
    if defaults.string(forKey: Keys.protectedDeviceId)?.isEmpty != false {
      return "No protected iOS device identifier is stored for the plugin runtime yet."
    }
    if protectedPeripheral == nil {
      return defaults.string(forKey: Keys.readinessFailureReason)
        ?? "The iOS plugin runtime is armed, but no protected peripheral has been rehydrated yet."
    }
    if protectedPeripheral?.state != .connected {
      return "The iOS plugin runtime is armed, but the protected peripheral is not connected yet."
    }
    if !servicesDiscovered {
      return "The iOS plugin runtime is connected, but service discovery is still in progress."
    }
    if !subscriptionsActive {
      return "The iOS plugin runtime is connected, but TEL/SOS subscriptions are not active yet."
    }
    return nil
  }

  private func snapshot() -> [String: Any?] {
    let runtimeState = currentRuntimeState
    let degradationReason = degradationReason()
    let readinessFailureReason = defaults.string(forKey: Keys.readinessFailureReason)
    return [
      "backgroundCapabilityReady": backgroundCapabilityReady(),
      "backgroundCapabilityState": backgroundCapabilityState(),
      "restorationConfigured": defaults.bool(forKey: Keys.restorationConfigured),
      "platformRuntimeConfigured": true,
      "runtimeActive": runtimeState == .active || runtimeState == .recovering,
      "bluetoothEnabled": bluetoothEnabled(),
      "notificationsGranted": notificationsGranted(),
      "lastFailureReason": defaults.string(forKey: Keys.lastFailureReason),
      "lastPlatformEvent": defaults.string(forKey: Keys.lastPlatformEvent),
      "lastPlatformEventAt": defaults.object(forKey: Keys.lastPlatformEventAt) as? Int,
      "runtimeState": runtimeState.rawValue,
      "coverageLevel": currentCoverageLevel(),
      "lastWakeAt": defaults.object(forKey: Keys.lastWakeAt) as? Int,
      "lastWakeReason": defaults.string(forKey: Keys.lastWakeReason),
      "bleOwner": isArmed ? "iosPlugin" : "flutter",
      "serviceBleConnected": protectedPeripheral?.state == .connected,
      "serviceBleReady": subscriptionsActive,
      "pendingSosCount": 0,
      "pendingTelemetryCount": 0,
      "lastRestorationEvent": defaults.string(forKey: Keys.lastRestorationEvent),
      "lastRestorationEventAt": defaults.object(forKey: Keys.lastRestorationEventAt) as? Int,
      "lastBleServiceEvent": defaults.string(forKey: Keys.lastBleServiceEvent),
      "lastBleServiceEventAt": defaults.object(forKey: Keys.lastBleServiceEventAt) as? Int,
      "reconnectAttemptCount": defaults.integer(forKey: Keys.reconnectAttemptCount),
      "lastReconnectAttemptAt": defaults.object(forKey: Keys.lastReconnectAttemptAt) as? Int,
      "degradationReason": degradationReason,
      "expectedBleServiceUuid": "ea00",
      "expectedBleCharacteristicUuids": ["ea01", "ea02", "ea03", "ea04"],
      "discoveredBleServicesSummary": defaults.string(forKey: Keys.discoveredBleServicesSummary),
      "readinessFailureReason": readinessFailureReason,
      "nativeBackendConfigValid": true,
      "nativeBackendConfigIssue": nil,
      "protectedDeviceId": defaults.string(forKey: Keys.protectedDeviceId),
      "activeDeviceId": defaults.string(forKey: Keys.protectedDeviceId),
      "lastNativeBackendHandoffError": defaults.string(forKey: Keys.lastRuntimeError),
      "lastCommandRoute": defaults.string(forKey: Keys.lastCommandRoute),
      "lastCommandResult": defaults.string(forKey: Keys.lastCommandResult),
      "lastCommandError": defaults.string(forKey: Keys.lastCommandError),
      "iosBleSosSnapshotKind": defaults.string(forKey: Keys.iosBleSosSnapshotKind),
      "iosBleSosPayloadHex": defaults.string(forKey: Keys.iosBleSosPayloadHex),
      "iosBleSosSource": defaults.string(forKey: Keys.iosBleSosSource),
      "iosBleSosCharacteristicUuid": defaults.string(forKey: Keys.iosBleSosCharacteristicUuid),
      "iosBleSosReceivedAt": defaults.object(forKey: Keys.iosBleSosReceivedAt) as? Int,
      "iosBleSosDeadlineAt": defaults.object(forKey: Keys.iosBleSosDeadlineAt) as? Int,
      "iosBleSosNodeId": defaults.object(forKey: Keys.iosBleSosNodeId) as? Int,
      "iosBleSosPacketId": defaults.object(forKey: Keys.iosBleSosPacketId) as? Int,
      "iosBleSosCycleKey": defaults.string(forKey: Keys.iosBleSosCycleKey),
      "preSosLifecycleState": preSosLifecycleStateFromSnapshot(),
      "preSosCycleKey": defaults.string(forKey: Keys.iosBleSosCycleKey),
      "preSosOwner": "device",
      "preSosStartedAt": preSosStartedAtFromSnapshot(),
      "preSosExpectedActivationAt": preSosExpectedActivationAtFromSnapshot(),
      "preSosRemainingSeconds": preSosRemainingSecondsFromSnapshot(),
      "preSosOriginatorNodeId": defaults.object(forKey: Keys.iosBleSosNodeId) as? Int,
      "preSosPacketId": defaults.object(forKey: Keys.iosBleSosPacketId) as? Int,
    ]
  }

  private func preSosLifecycleStateFromSnapshot() -> String? {
    guard defaults.string(forKey: Keys.iosBleSosSnapshotKind) == IosBleSosSnapshotKind.preSos.rawValue else {
      return nil
    }
    return "preConfirmSeen"
  }

  private func preSosStartedAtFromSnapshot() -> Int? {
    guard defaults.string(forKey: Keys.iosBleSosSnapshotKind) == IosBleSosSnapshotKind.preSos.rawValue,
          let deadlineAt = defaults.object(forKey: Keys.iosBleSosDeadlineAt) as? Int else {
      return nil
    }
    return deadlineAt - 20_000
  }

  private func preSosExpectedActivationAtFromSnapshot() -> Int? {
    guard defaults.string(forKey: Keys.iosBleSosSnapshotKind) == IosBleSosSnapshotKind.preSos.rawValue else {
      return nil
    }
    return defaults.object(forKey: Keys.iosBleSosDeadlineAt) as? Int
  }

  private func preSosRemainingSecondsFromSnapshot() -> Int? {
    guard let deadlineAt = preSosExpectedActivationAtFromSnapshot() else {
      return nil
    }
    return max(0, Int(ceil(Double(deadlineAt - Date().millisecondsSince1970) / 1000.0)))
  }

  private func sendProtectionCommand(
    label: String,
    bytes: [Int],
    forceCmdCharacteristic: Bool
  ) -> [String: Any?] {
    let route = "iosPlugin"
    defaults.set(route, forKey: Keys.lastCommandRoute)

    guard isArmed else {
      let error = "Protection Mode is off on iOS, so the plugin runtime does not own BLE commands."
      defaults.set(error, forKey: Keys.lastCommandError)
      return commandResult(success: false, route: route, result: nil, error: error)
    }
    guard !bytes.isEmpty else {
      let error = "Protection command payload is empty."
      defaults.set(error, forKey: Keys.lastCommandError)
      return commandResult(success: false, route: route, result: nil, error: error)
    }
    guard let peripheral = protectedPeripheral, peripheral.state == .connected else {
      let error = "The iOS Protection runtime is armed, but the protected peripheral is not connected yet."
      defaults.set(error, forKey: Keys.lastCommandError)
      defaults.set(error, forKey: Keys.readinessFailureReason)
      attemptProtectionReconnect(trigger: "native_command_\(label.lowercased())")
      return commandResult(success: false, route: route, result: nil, error: error)
    }

    let payload = Data(bytes.map { UInt8($0 & 0xFF) })
    let shouldUseCmd = forceCmdCharacteristic || payload.count > 20
    guard let characteristic = shouldUseCmd ? (cmdCharacteristic ?? inetCharacteristic) : (inetCharacteristic ?? cmdCharacteristic) else {
      let error = "The iOS Protection runtime does not have a writable command characteristic ready yet."
      defaults.set(error, forKey: Keys.lastCommandError)
      return commandResult(success: false, route: route, result: nil, error: error)
    }

    let result = "\(label) native write accepted via iosPlugin."
    defaults.set(result, forKey: Keys.lastCommandResult)
    defaults.removeObject(forKey: Keys.lastCommandError)
    peripheral.writeValue(payload, for: characteristic, type: .withResponse)
    return commandResult(success: true, route: route, result: result, error: nil)
  }

  private func commandResult(
    success: Bool,
    route: String,
    result: String?,
    error: String?
  ) -> [String: Any?] {
    [
      "success": success,
      "route": route,
      "result": result,
      "error": error,
    ]
  }

  private func bluetoothEnabled() -> Bool {
    centralManager?.state == .poweredOn
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

  private func backgroundCapabilityReady() -> Bool {
    backgroundCapabilityState() == "configured"
  }

  private func backgroundCapabilityState() -> String {
    let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
    return modes.contains("bluetooth-central") ? "configured" : "unavailable"
  }

  private func servicesSummary(from services: [CBService]) -> String {
    services
      .map { service in
        let characteristics = service.characteristics?.map { $0.uuid.uuidString.lowercased() }.joined(separator: ",") ?? ""
        return "\(service.uuid.uuidString.lowercased())[\(characteristics)]"
      }
      .joined(separator: " | ")
  }
}

extension ProtectionRuntimeBridge: CBCentralManagerDelegate {
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    switch central.state {
    case .poweredOn:
      recordEvent(type: "bluetoothTurnedOn", reason: nil)
      if isArmed {
        if protectedPeripheral?.state == .connected && subscriptionsActive {
          updateRuntimeState(.active)
          defaults.removeObject(forKey: Keys.degradationReason)
        } else {
          updateRuntimeState(.recovering)
          attemptProtectionReconnect(trigger: "bluetooth_powered_on")
        }
      }
    case .poweredOff:
      updateRuntimeState(isArmed ? .recovering : .inactive)
      let reason = "CoreBluetooth reported powered off while iOS Protection Mode was armed."
      defaults.set(reason, forKey: Keys.degradationReason)
      defaults.set(reason, forKey: Keys.lastFailureReason)
      recordEvent(type: "bluetoothTurnedOff", reason: reason)
    case .unsupported, .unauthorized, .resetting, .unknown:
      if isArmed {
        updateRuntimeState(.recovering)
      }
    @unknown default:
      if isArmed {
        updateRuntimeState(.recovering)
      }
    }
  }

  func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
    restoredLastLaunch = true
    recordWake(reason: "corebluetooth_restoration")
    recordRestorationEvent(type: "restorationDetected", reason: "corebluetooth_restoration")

    if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
       let restoredPeripheral = peripherals.first {
      protectedPeripheral = restoredPeripheral
      restoredPeripheral.delegate = self
      defaults.set(restoredPeripheral.identifier.uuidString, forKey: Keys.protectedDeviceId)
      if isArmed {
        handleConnectedPeripheral(restoredPeripheral, restored: true)
      }
    } else if isArmed {
      updateRuntimeState(.recovering)
      let reason = "CoreBluetooth restored the iOS Protection runtime without a protected peripheral instance."
      defaults.set(reason, forKey: Keys.degradationReason)
      defaults.set(reason, forKey: Keys.readinessFailureReason)
    }
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    handleConnectedPeripheral(peripheral, restored: restoredLastLaunch)
    restoredLastLaunch = false
  }

  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    updateRuntimeState(.recovering)
    let reason = "The iOS Protection runtime failed to connect the protected peripheral: \(error?.localizedDescription ?? "unknown error")."
    defaults.set(reason, forKey: Keys.lastFailureReason)
    defaults.set(reason, forKey: Keys.readinessFailureReason)
    recordEvent(type: "reconnectFailed", reason: reason)
  }

  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    subscriptionsActive = false
    servicesDiscovered = false
    telCharacteristic = nil
    sosCharacteristic = nil
    inetCharacteristic = nil
    cmdCharacteristic = nil
    updateRuntimeState(isArmed ? .recovering : .inactive)
    let reason = error == nil
      ? "protected_peripheral_disconnected"
      : "protected_peripheral_disconnected: \(error!.localizedDescription)"
    defaults.set(reason, forKey: Keys.degradationReason)
    recordBleEvent(type: "deviceDisconnected")
    if isArmed {
      attemptProtectionReconnect(trigger: "unexpected_disconnect")
    }
  }
}

extension ProtectionRuntimeBridge: CBPeripheralDelegate {
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    if let error {
      updateRuntimeState(.failed)
      let reason = "The iOS Protection runtime failed while discovering services: \(error.localizedDescription)"
      defaults.set(reason, forKey: Keys.lastFailureReason)
      defaults.set(reason, forKey: Keys.readinessFailureReason)
      recordEvent(type: "runtimeFailed", reason: reason)
      return
    }
    let services = peripheral.services ?? []
    servicesDiscovered = true
    defaults.set(servicesSummary(from: services), forKey: Keys.discoveredBleServicesSummary)
    recordBleEvent(type: "servicesDiscovered")

    guard let eixamService = services.first(where: { $0.uuid == Self.eixamServiceUuid }) else {
      updateRuntimeState(.failed)
      let reason = "The connected iOS Protection peripheral does not expose the expected EIXAM service ea00."
      defaults.set(reason, forKey: Keys.lastFailureReason)
      defaults.set(reason, forKey: Keys.readinessFailureReason)
      defaults.set(reason, forKey: Keys.degradationReason)
      recordEvent(type: "runtimeFailed", reason: reason)
      return
    }
    peripheral.discoverCharacteristics(
      [
        Self.telCharacteristicUuid,
        Self.sosCharacteristicUuid,
        Self.inetCharacteristicUuid,
        Self.cmdCharacteristicUuid,
      ],
      for: eixamService
    )
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    if let error {
      updateRuntimeState(.failed)
      let reason = "The iOS Protection runtime failed while discovering TEL/SOS characteristics: \(error.localizedDescription)"
      defaults.set(reason, forKey: Keys.lastFailureReason)
      defaults.set(reason, forKey: Keys.readinessFailureReason)
      recordEvent(type: "runtimeFailed", reason: reason)
      return
    }

    for characteristic in service.characteristics ?? [] {
      if characteristic.uuid == Self.telCharacteristicUuid {
        telCharacteristic = characteristic
      }
      if characteristic.uuid == Self.sosCharacteristicUuid {
        sosCharacteristic = characteristic
      }
      if characteristic.uuid == Self.inetCharacteristicUuid {
        inetCharacteristic = characteristic
      }
      if characteristic.uuid == Self.cmdCharacteristicUuid {
        cmdCharacteristic = characteristic
      }
    }

    guard let telCharacteristic, let sosCharacteristic, inetCharacteristic != nil || cmdCharacteristic != nil else {
      updateRuntimeState(.failed)
      let reason = "The iOS Protection runtime connected, but required TEL/SOS notify or command characteristics were missing."
      defaults.set(reason, forKey: Keys.lastFailureReason)
      defaults.set(reason, forKey: Keys.readinessFailureReason)
      defaults.set(reason, forKey: Keys.degradationReason)
      recordEvent(type: "runtimeFailed", reason: reason)
      return
    }

    peripheral.setNotifyValue(true, for: telCharacteristic)
    peripheral.setNotifyValue(true, for: sosCharacteristic)
  }

  func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
    if let error {
      updateRuntimeState(.recovering)
      let reason = "The iOS Protection runtime could not enable notifications for \(characteristic.uuid.uuidString.lowercased()): \(error.localizedDescription)"
      defaults.set(reason, forKey: Keys.lastFailureReason)
      defaults.set(reason, forKey: Keys.degradationReason)
      recordEvent(type: "runtimeError", reason: reason)
      return
    }

    let telReady = telCharacteristic?.isNotifying == true
    let sosReady = sosCharacteristic?.isNotifying == true
    subscriptionsActive = telReady && sosReady

    if subscriptionsActive {
      updateRuntimeState(.active)
      defaults.removeObject(forKey: Keys.degradationReason)
      defaults.removeObject(forKey: Keys.readinessFailureReason)
      defaults.removeObject(forKey: Keys.lastFailureReason)
      recordBleEvent(type: "subscriptionsActive")
      recordEvent(type: "runtimeActive", reason: "notifications_restored")
    }
  }

  func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
    if let error {
      let reason = "The iOS Protection runtime received a notify error on \(characteristic.uuid.uuidString.lowercased()): \(error.localizedDescription)"
      defaults.set(reason, forKey: Keys.lastFailureReason)
      recordEvent(type: "runtimeError", reason: reason)
      return
    }

    if let value = characteristic.value {
      recordBleEvent(type: "packetReceived")
      captureBleSosPayload(value, characteristic: characteristic)
    }
  }

  private func captureBleSosPayload(_ data: Data, characteristic: CBCharacteristic) {
    let bytes = [UInt8](data)
    guard !bytes.isEmpty else {
      return
    }
    let source = sourceName(for: characteristic)
    let characteristicUuid = characteristic.uuid.uuidString.lowercased()
    let timestamp = Date().millisecondsSince1970
    let payloadHex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
#if DEBUG
    print("IOS_BLE_SOS_PAYLOAD_RECEIVED source=\(source) characteristic=\(characteristicUuid) len=\(bytes.count) payload=\(payloadHex)")
#endif

    guard let parsed = parseIosBleSosSnapshot(bytes: bytes, receivedAt: timestamp) else {
      return
    }
    if shouldSuppressAfterTerminalSnapshot(parsed: parsed, receivedAt: timestamp) {
#if DEBUG
      print("IOS_BLE_SOS_STALE_ACTIVE_SUPPRESSED source=native_snapshot kind=\(parsed.kind.rawValue) nodeId=\(parsed.nodeId.map(String.init) ?? "none") packetId=\(parsed.packetId.map(String.init) ?? "none")")
#endif
      return
    }
    let previousNotificationContext = currentSosNotificationContext()

    defaults.set(parsed.kind.rawValue, forKey: Keys.iosBleSosSnapshotKind)
    defaults.set(payloadHex, forKey: Keys.iosBleSosPayloadHex)
    defaults.set(source, forKey: Keys.iosBleSosSource)
    defaults.set(characteristicUuid, forKey: Keys.iosBleSosCharacteristicUuid)
    defaults.set(timestamp, forKey: Keys.iosBleSosReceivedAt)
    defaults.set(parsed.nodeId, forKey: Keys.iosBleSosNodeId)
    defaults.set(parsed.packetId, forKey: Keys.iosBleSosPacketId)
    defaults.set(parsed.cycleKey, forKey: Keys.iosBleSosCycleKey)
    if let deadlineAt = parsed.deadlineAt {
      defaults.set(deadlineAt, forKey: Keys.iosBleSosDeadlineAt)
    } else {
      defaults.removeObject(forKey: Keys.iosBleSosDeadlineAt)
    }
    defaults.synchronize()

#if DEBUG
    print("IOS_BLE_SOS_SNAPSHOT_PERSISTED kind=\(parsed.kind.rawValue) nodeId=\(parsed.nodeId.map(String.init) ?? "none") packetId=\(parsed.packetId.map(String.init) ?? "none") cycle=\(parsed.cycleKey ?? "none") deadline=\(parsed.deadlineAt.map(String.init) ?? "none")")
#endif
    requestBackgroundSosNotification(
      for: parsed,
      previous: previousNotificationContext
    )
    var eventPayload: [String: Any] = [
      "payloadHex": payloadHex,
      "source": source,
      "classification": "ownDeviceSos",
      "identity": "own",
    ]
    if let nodeId = parsed.nodeId {
      eventPayload["relayNodeId"] = nodeId
    }
    emitEvent(
      type: "ownDeviceSosLifecycleObserved",
      reason: "ios_ble_sos_snapshot_persisted",
      timestamp: timestamp,
      payload: eventPayload
    )
  }

  private func sourceName(for characteristic: CBCharacteristic) -> String {
    if characteristic.uuid == Self.telCharacteristicUuid {
      return "tel"
    }
    if characteristic.uuid == Self.sosCharacteristicUuid {
      return "sos"
    }
    return characteristic.uuid.uuidString.lowercased()
  }

  private func shouldSuppressAfterTerminalSnapshot(
    parsed: (kind: IosBleSosSnapshotKind, nodeId: Int?, packetId: Int?, cycleKey: String?, deadlineAt: Int?),
    receivedAt: Int
  ) -> Bool {
    guard parsed.kind != .cancelled,
          defaults.string(forKey: Keys.iosBleSosSnapshotKind) == IosBleSosSnapshotKind.cancelled.rawValue,
          let cancelledAt = defaults.object(forKey: Keys.iosBleSosReceivedAt) as? Int,
          receivedAt - cancelledAt <= 30_000 else {
      return false
    }
    let cancelledNodeId = defaults.object(forKey: Keys.iosBleSosNodeId) as? Int
    let cancelledCycleKey = defaults.string(forKey: Keys.iosBleSosCycleKey)
    if let parsedNodeId = parsed.nodeId,
       let cancelledNodeId,
       parsedNodeId == cancelledNodeId {
      return true
    }
    if let parsedCycleKey = parsed.cycleKey,
       let cancelledCycleKey,
       parsedCycleKey == cancelledCycleKey || parsedCycleKey.hasPrefix("\(cancelledCycleKey):") {
      return true
    }
    return false
  }

  private func requestBackgroundSosNotification(
    for parsed: (kind: IosBleSosSnapshotKind, nodeId: Int?, packetId: Int?, cycleKey: String?, deadlineAt: Int?),
    previous: (kind: IosBleSosSnapshotKind?, nodeId: Int?, cycleKey: String?)
  ) {
#if DEBUG
    print("IOS_SOS_NOTIFICATION_REQUESTED kind=\(parsed.kind.rawValue) cycle=\(parsed.cycleKey ?? "none") nodeId=\(parsed.nodeId.map(String.init) ?? "none")")
#endif
    guard parsed.kind == .preSos || parsed.kind == .active || parsed.kind == .cancelled else {
#if DEBUG
      print("IOS_SOS_NOTIFICATION_SKIPPED kind=\(parsed.kind.rawValue) reason=unsupported_kind")
#endif
      return
    }
    guard shouldNotifySosSnapshot(parsed, previous: previous) else {
      return
    }
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      guard self.isNotificationAuthorized(settings.authorizationStatus) else {
#if DEBUG
        print("IOS_SOS_NOTIFICATION_PERMISSION_MISSING kind=\(parsed.kind.rawValue) cycle=\(parsed.cycleKey ?? "none") status=\(settings.authorizationStatus.rawValue)")
#endif
        return
      }
      let dedupeKey = self.sosNotificationDedupeKey(for: parsed)
      guard self.rememberSosNotificationKey(dedupeKey) else {
#if DEBUG
        print("IOS_SOS_NOTIFICATION_DEDUPED kind=\(parsed.kind.rawValue) cycle=\(parsed.cycleKey ?? "none") key=\(dedupeKey)")
#endif
        return
      }
      let content = UNMutableNotificationContent()
      content.sound = .default
      content.categoryIdentifier = "ios_sos_notification"
      content.userInfo = [
        "NotificationId": self.sosNotificationId(for: parsed.kind),
        "payload": "sos:\(parsed.kind.rawValue)",
        "presentAlert": true,
        "presentSound": true,
        "presentBadge": true,
        "presentBanner": true,
        "presentList": true,
        "source": "ios_sos_notification",
        "route": "sos",
        "kind": parsed.kind.rawValue,
        "cycleKey": parsed.cycleKey ?? "",
        "nodeId": parsed.nodeId.map(String.init) ?? "",
      ]
      if #available(iOS 15.0, *) {
        content.interruptionLevel = parsed.kind == .active ? .timeSensitive : .active
      }
      let text = self.sosNotificationText(for: parsed.kind)
      content.title = text.title
      content.body = text.body
      let identifier = "\(self.sosNotificationId(for: parsed.kind))"
      let request = UNNotificationRequest(
        identifier: identifier,
        content: content,
        trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
      )
      UNUserNotificationCenter.current().add(request) { error in
        if let error {
#if DEBUG
          print("IOS_SOS_NOTIFICATION_SKIPPED kind=\(parsed.kind.rawValue) cycle=\(parsed.cycleKey ?? "none") reason=schedule_failed error=\(error.localizedDescription)")
#endif
        } else {
#if DEBUG
          print("IOS_SOS_NOTIFICATION_SCHEDULED kind=\(parsed.kind.rawValue) cycle=\(parsed.cycleKey ?? "none") identifier=\(identifier)")
#endif
        }
      }
    }
  }

  private func currentSosNotificationContext() -> (
    kind: IosBleSosSnapshotKind?,
    nodeId: Int?,
    cycleKey: String?
  ) {
    let rawKind = defaults.string(forKey: Keys.iosBleSosSnapshotKind)
    return (
      rawKind.flatMap(IosBleSosSnapshotKind.init(rawValue:)),
      defaults.object(forKey: Keys.iosBleSosNodeId) as? Int,
      defaults.string(forKey: Keys.iosBleSosCycleKey)
    )
  }

  private func shouldNotifySosSnapshot(
    _ parsed: (kind: IosBleSosSnapshotKind, nodeId: Int?, packetId: Int?, cycleKey: String?, deadlineAt: Int?),
    previous: (kind: IosBleSosSnapshotKind?, nodeId: Int?, cycleKey: String?)
  ) -> Bool {
    if parsed.kind != .cancelled {
      return true
    }
    guard previous.kind == .preSos || previous.kind == .active else {
#if DEBUG
      print("IOS_SOS_NOTIFICATION_SKIPPED kind=\(parsed.kind.rawValue) reason=terminal_without_open_cycle cycle=\(parsed.cycleKey ?? "none")")
#endif
      return false
    }
    if let parsedNodeId = parsed.nodeId, let previousNodeId = previous.nodeId {
      if parsedNodeId == previousNodeId {
        return true
      }
#if DEBUG
      print("IOS_SOS_NOTIFICATION_SKIPPED kind=\(parsed.kind.rawValue) reason=terminal_node_mismatch incomingNodeId=\(parsedNodeId) previousNodeId=\(previousNodeId)")
#endif
      return false
    }
    if let parsedCycle = parsed.cycleKey, let previousCycle = previous.cycleKey {
      if parsedCycle == previousCycle || previousCycle.hasPrefix(parsedCycle) || parsedCycle.hasPrefix(previousCycle) {
        return true
      }
#if DEBUG
      print("IOS_SOS_NOTIFICATION_SKIPPED kind=\(parsed.kind.rawValue) reason=terminal_cycle_mismatch incomingCycle=\(parsedCycle) previousCycle=\(previousCycle)")
#endif
      return false
    }
    return true
  }

  private func isNotificationAuthorized(_ status: UNAuthorizationStatus) -> Bool {
    if status == .authorized || status == .provisional {
      return true
    }
    if #available(iOS 14.0, *), status == .ephemeral {
      return true
    }
    return false
  }

  private func sosNotificationDedupeKey(
    for parsed: (kind: IosBleSosSnapshotKind, nodeId: Int?, packetId: Int?, cycleKey: String?, deadlineAt: Int?)
  ) -> String {
    let identity = parsed.cycleKey ?? parsed.nodeId.map(String.init) ?? "unknown"
    return "\(parsed.kind.rawValue)-\(identity)"
  }

  private func sosNotificationId(for kind: IosBleSosSnapshotKind) -> Int {
    switch kind {
    case .preSos:
      return 42001
    case .active:
      return 42002
    case .cancelled:
      return 42004
    }
  }

  private func rememberSosNotificationKey(_ key: String) -> Bool {
    let now = Date().millisecondsSince1970
    var entries = (defaults.stringArray(forKey: Keys.iosBleSosNotifiedKeys) ?? [])
      .compactMap { entry -> (key: String, timestamp: Int)? in
        let parts = entry.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let timestamp = Int(parts[1]) else {
          return nil
        }
        return now - timestamp <= Self.sosNotificationDedupeWindowMs
          ? (key: parts[0], timestamp: timestamp)
          : nil
      }
    if entries.contains(where: { $0.key == key }) {
      return false
    }
    entries.append((key, now))
    if entries.count > 50 {
      entries = Array(entries.suffix(50))
    }
    defaults.set(
      entries.map { "\($0.key)|\($0.timestamp)" },
      forKey: Keys.iosBleSosNotifiedKeys
    )
    return true
  }

  private func sosNotificationText(for kind: IosBleSosSnapshotKind) -> (title: String, body: String) {
    switch kind {
    case .preSos:
      return (
        notificationText(Keys.notificationProtectionPreSosTitle, fallback: "SOS countdown started"),
        notificationText(Keys.notificationProtectionPreSosBody, fallback: "Your EIXAM device started an SOS countdown.")
      )
    case .active:
      return (
        notificationText(Keys.notificationProtectionSosActiveTitle, fallback: "SOS sent"),
        notificationText(Keys.notificationProtectionSosActiveBody, fallback: "Your EIXAM device reported an active SOS.")
      )
    case .cancelled:
      return (
        notificationText(Keys.notificationProtectionSosCancelledTitle, fallback: notificationText(Keys.notificationProtectionSosResolvedTitle, fallback: "SOS cancelled")),
        notificationText(Keys.notificationProtectionSosCancelledBody, fallback: notificationText(Keys.notificationProtectionSosResolvedBody, fallback: "The SOS incident was cancelled."))
      )
    }
  }

  private func notificationText(_ key: String, fallback: String) -> String {
    let value = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return value?.isEmpty == false ? value! : fallback
  }

  private func parseIosBleSosSnapshot(bytes: [UInt8], receivedAt: Int) -> (kind: IosBleSosSnapshotKind, nodeId: Int?, packetId: Int?, cycleKey: String?, deadlineAt: Int?)? {
    if bytes.count == 6,
       (bytes[0] == 0xE1 || bytes[0] == 0xE2) {
      let nodeId = readUInt32(bytes, offset: 2)
      return (.cancelled, nodeId, nil, nodeId.map { "sos:\($0)" }, nil)
    }

    let packetLength: Int
    if bytes.count == 18 {
      packetLength = 12
    } else if bytes.count == 13 {
      packetLength = 7
    } else {
      packetLength = bytes.count
    }
    guard packetLength == 7 || packetLength == 12,
          let nodeId = readUInt32(bytes, offset: 0) else {
      return nil
    }
    let flagsOffset = packetLength == 12 ? 10 : 4
    let flagsWord = Int(bytes[flagsOffset]) | (Int(bytes[flagsOffset + 1]) << 8)
    let sosType = (flagsWord >> 14) & 0x03
    let packetId = flagsWord & 0x0F
    let cycleKey = "sos:\(nodeId):\(packetId)"
    if sosType == 0 {
      return (.cancelled, nodeId, packetId, cycleKey, nil)
    }
    if sosType == 1 {
      return (.preSos, nodeId, packetId, cycleKey, receivedAt + 20_000)
    }
    return (.active, nodeId, packetId, cycleKey, nil)
  }

  private func readUInt32(_ bytes: [UInt8], offset: Int) -> Int? {
    guard bytes.count >= offset + 4 else {
      return nil
    }
    return Int(bytes[offset])
      | (Int(bytes[offset + 1]) << 8)
      | (Int(bytes[offset + 2]) << 16)
      | (Int(bytes[offset + 3]) << 24)
  }

  func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
    if let error {
      let reason = "The iOS Protection runtime failed to write \(characteristic.uuid.uuidString.lowercased()): \(error.localizedDescription)"
      defaults.set(reason, forKey: Keys.lastCommandError)
      defaults.set(reason, forKey: Keys.lastFailureReason)
      recordEvent(type: "runtimeError", reason: reason)
      return
    }

    if let currentResult = defaults.string(forKey: Keys.lastCommandResult),
       currentResult.contains("accepted via iosPlugin") {
      let finalized = currentResult.replacingOccurrences(of: "accepted via iosPlugin", with: "succeeded via iosPlugin")
      defaults.set(finalized, forKey: Keys.lastCommandResult)
    }
  }
}

private extension Date {
  var millisecondsSince1970: Int {
    Int((timeIntervalSince1970 * 1000.0).rounded())
  }
}
