import CoreBluetooth
import Flutter
import NordicDFU
import UIKit

final class FirmwareDfuBridge: NSObject, FlutterPlugin, FlutterStreamHandler {
  private static let methodChannelName = "dev.eixam.connect_flutter/firmware_dfu/methods"
  private static let eventChannelName = "dev.eixam.connect_flutter/firmware_dfu/events"

  private var eventSink: FlutterEventSink?
  private var centralManager: CBCentralManager?
  private var pendingStart: PendingStart?
  private var activeSession: ActiveSession?
  private var dfuController: DFUServiceController?

  @objc static func register(with registrar: FlutterPluginRegistrar) {
    let instance = FirmwareDfuBridge()
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
    centralManager = CBCentralManager(delegate: self, queue: nil)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "startDfu":
      startDfu(arguments: call.arguments as? [String: Any], result: result)
    case "cancelDfu":
      cancelDfu(arguments: call.arguments as? [String: Any], result: result)
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

  private func startDfu(arguments: [String: Any]?, result: @escaping FlutterResult) {
    guard activeSession == nil, pendingStart == nil else {
      result(FlutterError(
        code: "alreadyRunning",
        message: "A firmware DFU session is already running.",
        details: nil
      ))
      return
    }
    let sessionId = (arguments?["sessionId"] as? String)?.trimmed ?? ""
    let deviceId = ((arguments?["deviceRemoteId"] as? String)?.trimmed).nonEmpty
      ?? ((arguments?["deviceId"] as? String)?.trimmed).nonEmpty
      ?? ""
    let firmwareZipPath = (arguments?["firmwareZipPath"] as? String)?.trimmed ?? ""
    let targetVersion = (arguments?["targetVersion"] as? String)?.trimmed

    if sessionId.isEmpty {
      result(FlutterError(code: "invalidSession", message: "DFU session id is missing.", details: nil))
      return
    }
    if deviceId.isEmpty {
      result(FlutterError(code: "deviceNotFound", message: "DFU target device id is missing.", details: nil))
      return
    }
    guard FileManager.default.fileExists(atPath: firmwareZipPath) else {
      result(FlutterError(code: "fileMissing", message: "Firmware ZIP file is missing.", details: nil))
      return
    }
    guard firmwareZipPath.lowercased().hasSuffix(".zip") else {
      result(FlutterError(code: "invalidZip", message: "Firmware artifact must be a DFU ZIP file.", details: nil))
      return
    }

    let pending = PendingStart(
      sessionId: sessionId,
      deviceId: deviceId,
      firmwareZipPath: firmwareZipPath,
      targetVersion: targetVersion,
      result: result
    )
    switch centralManager?.state {
    case .poweredOn:
      beginDfu(pending)
    case .poweredOff:
      result(FlutterError(code: "bluetoothDisabled", message: "Bluetooth is disabled.", details: nil))
    case .unauthorized:
      result(FlutterError(code: "missingPermission", message: "Bluetooth permission is not granted.", details: nil))
    case .unsupported:
      result(FlutterError(code: "bluetoothUnsupported", message: "Bluetooth LE is not supported.", details: nil))
    case .resetting, .unknown, nil:
      pendingStart = pending
      ensureCentralManager()
    @unknown default:
      pendingStart = pending
      ensureCentralManager()
      return
    }
  }

  private func cancelDfu(arguments: [String: Any]?, result: @escaping FlutterResult) {
    let sessionId = (arguments?["sessionId"] as? String)?.trimmed
    guard let activeSession,
          sessionId == nil || sessionId == activeSession.sessionId else {
      result(nil)
      return
    }
    _ = dfuController?.abort()
    emit(
      sessionId: activeSession.sessionId,
      state: "cancelled",
      errorCode: "cancelled",
      errorMessage: "Firmware DFU cancellation requested."
    )
    result(nil)
  }

  private func beginDfu(_ pending: PendingStart) {
    guard let peripheralUuid = UUID(uuidString: pending.deviceId) else {
      pending.result(FlutterError(
        code: "deviceNotFound",
        message: "iOS DFU requires a CoreBluetooth peripheral UUID target.",
        details: nil
      ))
      return
    }
    guard let peripheral = centralManager?.retrievePeripherals(withIdentifiers: [peripheralUuid]).first else {
      pending.result(FlutterError(
        code: "deviceNotFound",
        message: "The target peripheral was not found by iOS.",
        details: nil
      ))
      return
    }

    do {
      let firmware = try DFUFirmware(urlToZipFile: URL(fileURLWithPath: pending.firmwareZipPath))
      activeSession = ActiveSession(
        sessionId: pending.sessionId,
        targetVersion: pending.targetVersion,
        result: pending.result
      )
      let initiator = DFUServiceInitiator(queue: DispatchQueue.main)
      initiator.delegate = self
      initiator.progressDelegate = self
      initiator.logger = self
      initiator.enableUnsafeExperimentalButtonlessServiceInSecureDfu = false
      emit(sessionId: pending.sessionId, state: "transferring", message: "DFU transfer queued.")
      dfuController = initiator.with(firmware: firmware).start(target: peripheral)
    } catch {
      activeSession = nil
      pending.result(FlutterError(
        code: "invalidZip",
        message: error.localizedDescription,
        details: nil
      ))
    }
  }

  private func ensureCentralManager() {
    if centralManager == nil {
      centralManager = CBCentralManager(delegate: self, queue: nil)
    }
  }

  private func completeSuccess() {
    guard let activeSession else { return }
    emit(sessionId: activeSession.sessionId, state: "completed", progressPct: 100)
    let result = activeSession.result
    cleanup()
    result(["success": true])
  }

  private func completeFailure(
    code: String,
    message: String,
    requiresRecovery: Bool = false
  ) {
    guard let activeSession else { return }
    emit(
      sessionId: activeSession.sessionId,
      state: requiresRecovery ? "recoveryRequired" : "failed",
      errorCode: code,
      errorMessage: message,
      requiresRecovery: requiresRecovery
    )
    let result = activeSession.result
    cleanup()
    result([
      "success": false,
      "errorCode": code,
      "errorMessage": message,
      "requiresRecovery": requiresRecovery,
    ])
  }

  private func cleanup() {
    activeSession = nil
    pendingStart = nil
    dfuController = nil
  }

  private func emit(
    sessionId: String,
    state: String,
    progressPct: Int? = nil,
    speedBytesPerSecond: Double? = nil,
    part: Int? = nil,
    totalParts: Int? = nil,
    message: String? = nil,
    errorCode: String? = nil,
    errorMessage: String? = nil,
    requiresRecovery: Bool = false
  ) {
    let rawPayload: [String: Any?] = [
      "sessionId": sessionId,
      "state": state,
      "progressPct": progressPct,
      "speedBytesPerSecond": speedBytesPerSecond,
      "part": part,
      "totalParts": totalParts,
      "message": message,
      "errorCode": errorCode,
      "errorMessage": errorMessage,
      "requiresRecovery": requiresRecovery,
    ]
    let payload = rawPayload.reduce(into: [String: Any]()) { partial, entry in
      if let value = entry.value {
        partial[entry.key] = value
      }
    }
    DispatchQueue.main.async { [weak self] in
      self?.eventSink?(payload)
    }
  }

  private struct PendingStart {
    let sessionId: String
    let deviceId: String
    let firmwareZipPath: String
    let targetVersion: String?
    let result: FlutterResult
  }

  private struct ActiveSession {
    let sessionId: String
    let targetVersion: String?
    let result: FlutterResult
  }
}

extension FirmwareDfuBridge: CBCentralManagerDelegate {
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    guard let pending = pendingStart else { return }
    switch central.state {
    case .poweredOn:
      pendingStart = nil
      beginDfu(pending)
    case .poweredOff:
      pendingStart = nil
      pending.result(FlutterError(code: "bluetoothDisabled", message: "Bluetooth is disabled.", details: nil))
    case .unauthorized:
      pendingStart = nil
      pending.result(FlutterError(code: "missingPermission", message: "Bluetooth permission is not granted.", details: nil))
    case .unsupported:
      pendingStart = nil
      pending.result(FlutterError(code: "bluetoothUnsupported", message: "Bluetooth LE is not supported.", details: nil))
    case .resetting, .unknown:
      break
    @unknown default:
      break
    }
  }
}

extension FirmwareDfuBridge: DFUServiceDelegate {
  func dfuStateDidChange(to state: DFUState) {
    guard let activeSession else { return }
    switch state {
    case .connecting:
      emit(sessionId: activeSession.sessionId, state: "transferring", message: "Connecting to DFU target.")
    case .starting:
      emit(sessionId: activeSession.sessionId, state: "transferring", message: "Starting DFU process.")
    case .enablingDfuMode:
      emit(sessionId: activeSession.sessionId, state: "transferring", message: "Switching device to DFU mode.")
    case .uploading:
      emit(sessionId: activeSession.sessionId, state: "transferring")
    case .validating:
      emit(sessionId: activeSession.sessionId, state: "verifying", message: "Validating firmware.")
    case .disconnecting:
      emit(sessionId: activeSession.sessionId, state: "reconnecting", message: "Device is rebooting after DFU.")
    case .completed:
      completeSuccess()
    case .aborted:
      completeFailure(code: "cancelled", message: "Firmware DFU was cancelled.")
    @unknown default:
      emit(sessionId: activeSession.sessionId, state: "transferring")
    }
  }

  func dfuError(_ error: DFUError, didOccurWithMessage message: String) {
    let mapped = mapDfuError(error: error, message: message)
    completeFailure(
      code: mapped.code,
      message: mapped.message,
      requiresRecovery: mapped.requiresRecovery
    )
  }

  private func mapDfuError(error: DFUError, message: String) -> (code: String, message: String, requiresRecovery: Bool) {
    let normalized = message.lowercased()
    if normalized.contains("permission") {
      return ("missingPermission", message, false)
    }
    if normalized.contains("bluetooth") && normalized.contains("off") {
      return ("bluetoothDisabled", message, false)
    }
    if normalized.contains("file") || normalized.contains("zip") {
      return ("invalidZip", message, false)
    }
    if normalized.contains("disconnect") {
      return ("deviceDisconnected", message, true)
    }
    if normalized.contains("bootloader") {
      return ("recoveryRequired", message, true)
    }
    return ("dfuFailed", message, false)
  }
}

extension FirmwareDfuBridge: DFUProgressDelegate {
  func dfuProgressDidChange(
    for part: Int,
    outOf totalParts: Int,
    to progress: Int,
    currentSpeedBytesPerSecond: Double,
    avgSpeedBytesPerSecond: Double
  ) {
    guard let activeSession else { return }
    emit(
      sessionId: activeSession.sessionId,
      state: "transferring",
      progressPct: progress,
      speedBytesPerSecond: currentSpeedBytesPerSecond,
      part: part,
      totalParts: totalParts
    )
  }
}

extension FirmwareDfuBridge: LoggerDelegate {
  func logWith(_ level: LogLevel, message: String) {
    guard let activeSession else { return }
    emit(sessionId: activeSession.sessionId, state: "transferring", message: message)
  }
}

private extension Optional where Wrapped == String {
  var nonEmpty: String? {
    guard let value = self, !value.isEmpty else { return nil }
    return value
  }
}

private extension String {
  var trimmed: String {
    trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
