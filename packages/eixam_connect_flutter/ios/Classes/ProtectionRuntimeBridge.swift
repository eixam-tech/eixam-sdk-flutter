import CoreBluetooth
import Flutter
import UIKit
import UserNotifications

final class ProtectionRuntimeBridge: NSObject, FlutterStreamHandler {
  private static let methodChannelName = "dev.eixam.connect_flutter/protection_runtime/methods"
  private static let eventChannelName = "dev.eixam.connect_flutter/protection_runtime/events"
  private static let prefsName = "eixam_protection_runtime_ios"
  private static let restorationIdentifier = "dev.eixam.connect.flutter.protection.central"
  private static let eixamServiceUuid = CBUUID(string: "EA00")
  private static let telCharacteristicUuid = CBUUID(string: "EA01")
  private static let sosCharacteristicUuid = CBUUID(string: "EA02")
  private static let inetCharacteristicUuid = CBUUID(string: "EA03")
  private static let cmdCharacteristicUuid = CBUUID(string: "EA04")

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

  private func emitEvent(type: String, reason: String?, timestamp: Int? = nil) {
    eventSink?([
      "type": type,
      "timestamp": timestamp ?? Date().millisecondsSince1970,
      "reason": reason,
    ])
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
    ]
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

    if characteristic.value != nil {
      recordBleEvent(type: "packetReceived")
    }
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
