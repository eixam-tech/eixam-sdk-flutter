import CoreLocation
import Flutter
import UIKit

private enum BackgroundLocationMode: String, Codable {
  case idle
  case sharing
  case dmp
  case sos
}

private struct BackgroundLocationControlState: Codable {
  let schemaVersion: Int
  let requestedActiveContexts: [String]
  let canonicalEffectiveMode: String
}

/// Encoding and validation for the single atomic control-state value.
///
/// This table validates combinations produced by Dart Core. It does not choose
/// a priority or repair contradictory state.
private enum BackgroundLocationControlStateCodec {
  static let schemaVersion = 1

  private static let allowedFields = Set([
    "schemaVersion",
    "requestedActiveContexts",
    "canonicalEffectiveMode",
  ])
  private static let allowedContexts = Set(["sharing", "dmp", "sos"])
  private static let validCombinationModes: [String: BackgroundLocationMode] = [
    "": .idle,
    "sharing": .sharing,
    "dmp": .dmp,
    "sos": .sos,
    "dmp,sharing": .dmp,
    "sharing,sos": .sos,
    "dmp,sos": .sos,
    "dmp,sharing,sos": .sos,
  ]

  static func isValid(
    contexts: [String],
    mode: BackgroundLocationMode
  ) -> Bool {
    let uniqueContexts = Set(contexts)
    guard uniqueContexts.count == contexts.count,
          uniqueContexts.isSubset(of: allowedContexts) else {
      return false
    }
    return validCombinationModes[combinationKey(uniqueContexts)] == mode
  }

  static func encode(
    contexts: Set<String>,
    mode: BackgroundLocationMode
  ) throws -> Data {
    let sortedContexts = contexts.sorted()
    guard isValid(contexts: sortedContexts, mode: mode) else {
      throw ControlStateError.invalidCombination
    }
    let envelope = BackgroundLocationControlState(
      schemaVersion: schemaVersion,
      requestedActiveContexts: sortedContexts,
      canonicalEffectiveMode: mode.rawValue
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(envelope)
  }

  static func decode(
    _ data: Data
  ) throws -> (contexts: Set<String>, mode: BackgroundLocationMode) {
    let rawObject = try JSONSerialization.jsonObject(with: data)
    guard let rawEnvelope = rawObject as? [String: Any],
          Set(rawEnvelope.keys) == allowedFields else {
      throw ControlStateError.invalidEnvelope
    }
    let envelope = try JSONDecoder().decode(
      BackgroundLocationControlState.self,
      from: data
    )
    guard envelope.schemaVersion == schemaVersion,
          let mode = BackgroundLocationMode(
            rawValue: envelope.canonicalEffectiveMode
          ),
          isValid(
            contexts: envelope.requestedActiveContexts,
            mode: mode
          ) else {
      throw ControlStateError.invalidEnvelope
    }
    return (Set(envelope.requestedActiveContexts), mode)
  }

  private static func combinationKey(_ contexts: Set<String>) -> String {
    contexts.sorted().joined(separator: ",")
  }

  private enum ControlStateError: Error {
    case invalidCombination
    case invalidEnvelope
  }
}

/// Process-wide iOS background-location runtime.
///
/// The singleton owns the only CLLocationManager, persisted control state,
/// accepted-sample queue, and native observer registry. It has no native
/// transport; queued samples are acquisition metadata, never delivery proof.
private final class BackgroundLocationService: NSObject {
  static let shared = BackgroundLocationService()

  private static let defaultsSuiteName =
    "dev.eixam.connect_flutter.background_location"
  private static let maximumAcceptedLocationAge: TimeInterval = 5 * 60
  private static let maximumFutureClockSkew: TimeInterval = 60
  private static let maximumQueuedSampleAge: TimeInterval = 7 * 24 * 60 * 60
  private static let maximumQueuedSampleCount = 100

  private enum Keys {
    static let controlState =
      "dev.eixam.connect_flutter.background_location.control_state"
    static let legacyActiveContexts = "active_contexts"
    static let legacyEffectiveMode = "effective_mode"
    static let legacyNativeServiceRunning = "native_service_running"
    static let legacyRestorationMarker = "restoration_marker"
    static let lastAcceptedLocationAt = "last_accepted_location_at"
    static let lastAcceptedLatitude = "last_accepted_latitude"
    static let lastAcceptedLongitude = "last_accepted_longitude"
    static let lastAcceptedHorizontalAccuracy =
      "last_accepted_horizontal_accuracy"
    static let lastAcceptedAltitude = "last_accepted_altitude"
    static let lastErrorCode = "last_error_code"
    static let lastErrorMessage = "last_error_message"
    static let acceptedSampleQueue = "accepted_sample_queue"
  }

  private struct ModeConfiguration {
    let desiredAccuracy: CLLocationAccuracy
    let distanceFilter: CLLocationDistance
    let pausesAutomatically: Bool

    static func forMode(
      _ mode: BackgroundLocationMode
    ) -> ModeConfiguration? {
      switch mode {
      case .idle:
        return nil
      case .sharing:
        return ModeConfiguration(
          desiredAccuracy: kCLLocationAccuracyHundredMeters,
          distanceFilter: 200,
          pausesAutomatically: true
        )
      case .dmp:
        return ModeConfiguration(
          desiredAccuracy: kCLLocationAccuracyHundredMeters,
          distanceFilter: 150,
          pausesAutomatically: true
        )
      case .sos:
        return ModeConfiguration(
          desiredAccuracy: kCLLocationAccuracyBest,
          distanceFilter: 10,
          pausesAutomatically: false
        )
      }
    }
  }

  private struct PersistedSample: Codable {
    let timestamp: TimeInterval
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: Double
    let altitude: Double?
  }

  typealias Observer = ([String: Any]) -> Void

  private let locationManager: CLLocationManager
  private let defaults: UserDefaults
  private var observers = [UUID: Observer]()
  private var requestedContexts = Set<String>()
  private var effectiveMode = BackgroundLocationMode.idle
  private var locationUpdatesStarted = false
  private var wasRestoredAfterRelaunch = false
  private var hasRejectedPersistedControlState = false

  private override init() {
    precondition(
      Thread.isMainThread,
      "BackgroundLocationService must be created on the main thread."
    )
    locationManager = CLLocationManager()
    defaults =
      UserDefaults(suiteName: Self.defaultsSuiteName) ?? UserDefaults.standard
    super.init()
    locationManager.delegate = self
    restorePersistedState()
  }

  static func sharedOnMainThread() -> BackgroundLocationService {
    if Thread.isMainThread {
      return shared
    }
    return DispatchQueue.main.sync {
      shared
    }
  }

  func addObserver(_ observer: @escaping Observer) -> UUID {
    assertMainThread()
    let token = UUID()
    observers[token] = observer
    observer(runtimeStatus())
    return token
  }

  func removeObserver(_ token: UUID) {
    assertMainThread()
    observers.removeValue(forKey: token)
  }

  func getLocationPermissionSnapshot() -> [String: Any] {
    assertMainThread()
    return permissionSnapshot()
  }

  func requestWhenInUse(result: @escaping FlutterResult) {
    assertMainThread()
    guard hasNonEmptyInfoString("NSLocationWhenInUseUsageDescription") else {
      result(FlutterError(
        code: "host_configuration_missing",
        message: "The host app must declare NSLocationWhenInUseUsageDescription.",
        details: nil
      ))
      return
    }
    if currentAuthorizationStatus() == .notDetermined {
      locationManager.requestWhenInUseAuthorization()
    }
    result(permissionSnapshot())
  }

  func requestAlways(result: @escaping FlutterResult) {
    assertMainThread()
    guard hasNonEmptyInfoString(
      "NSLocationAlwaysAndWhenInUseUsageDescription"
    ) else {
      result(FlutterError(
        code: "host_configuration_missing",
        message: "The host app must declare NSLocationAlwaysAndWhenInUseUsageDescription.",
        details: nil
      ))
      return
    }
    if currentAuthorizationStatus() == .authorizedWhenInUse {
      locationManager.requestAlwaysAuthorization()
    }
    result(permissionSnapshot())
  }

  func setBackgroundLocationState(
    arguments: Any?,
    result: @escaping FlutterResult
  ) {
    assertMainThread()
    guard let arguments = arguments as? [String: Any],
          let rawContexts = arguments["requestedContexts"] as? [String],
          let rawMode = arguments["effectiveMode"] as? String,
          let mode = BackgroundLocationMode(rawValue: rawMode),
          BackgroundLocationControlStateCodec.isValid(
            contexts: rawContexts,
            mode: mode
          ) else {
      result(FlutterError(
        code: "invalid_native_payload",
        message: "Background-location state is unsupported or contradictory.",
        details: nil
      ))
      return
    }

    let contexts = Set(rawContexts)
    guard persistControlState(contexts: contexts, mode: mode) else {
      setRuntimeError(
        code: "native_persistence_failed",
        message: "Background-location control state could not be persisted."
      )
      notifyObservers()
      result(FlutterError(
        code: "native_persistence_failed",
        message: "Background-location control state could not be persisted.",
        details: nil
      ))
      return
    }

    requestedContexts = contexts
    effectiveMode = mode
    hasRejectedPersistedControlState = false
    clearRuntimeError()
    reconcileRuntime(emit: true)
    result(runtimeStatus())
  }

  func getBackgroundLocationStatus() -> [String: Any] {
    assertMainThread()
    reconcileRuntime(emit: false)
    return runtimeStatus()
  }

  private func restorePersistedState() {
    assertMainThread()
    requestedContexts = []
    effectiveMode = .idle
    locationUpdatesStarted = false
    wasRestoredAfterRelaunch = false
    hasRejectedPersistedControlState = false
    pruneAndPersistQueue(loadQueue())

    if let storedControlState = defaults.object(forKey: Keys.controlState) {
      guard let data = storedControlState as? Data,
            let restored = try? BackgroundLocationControlStateCodec.decode(
              data
            ) else {
        rejectPersistedControlState()
        return
      }
      requestedContexts = restored.contexts
      effectiveMode = restored.mode
      wasRestoredAfterRelaunch = true
      hasRejectedPersistedControlState = false
      removeLegacyControlState()
      clearRuntimeError()
      reconcileRuntime(emit: false)
      return
    }

    migrateLegacyControlStateIfPresent()
  }

  private func migrateLegacyControlStateIfPresent() {
    let rawContexts = defaults.object(forKey: Keys.legacyActiveContexts)
    let rawMode = defaults.object(forKey: Keys.legacyEffectiveMode)
    let hasLegacyControlState = rawContexts != nil || rawMode != nil

    guard hasLegacyControlState else {
      defaults.removeObject(forKey: Keys.legacyNativeServiceRunning)
      defaults.removeObject(forKey: Keys.legacyRestorationMarker)
      clearRuntimeError()
      return
    }

    guard let contexts = rawContexts as? [String],
          let modeName = rawMode as? String,
          let mode = BackgroundLocationMode(rawValue: modeName),
          BackgroundLocationControlStateCodec.isValid(
            contexts: contexts,
            mode: mode
          ),
          persistControlState(contexts: Set(contexts), mode: mode) else {
      rejectPersistedControlState()
      return
    }

    requestedContexts = Set(contexts)
    effectiveMode = mode
    wasRestoredAfterRelaunch = true
    hasRejectedPersistedControlState = false
    removeLegacyControlState()
    clearRuntimeError()
    reconcileRuntime(emit: false)
  }

  private func rejectPersistedControlState() {
    requestedContexts = []
    effectiveMode = .idle
    if locationUpdatesStarted {
      locationManager.stopUpdatingLocation()
      locationUpdatesStarted = false
    }
    locationManager.allowsBackgroundLocationUpdates = false
    wasRestoredAfterRelaunch = false
    hasRejectedPersistedControlState = true
    if !persistControlState(contexts: [], mode: .idle) {
      defaults.removeObject(forKey: Keys.controlState)
    }
    removeLegacyControlState()
    setRuntimeError(
      code: "persisted_state_invalid",
      message: "Persisted background-location control state was rejected."
    )
  }

  private func persistControlState(
    contexts: Set<String>,
    mode: BackgroundLocationMode
  ) -> Bool {
    guard let data = try? BackgroundLocationControlStateCodec.encode(
      contexts: contexts,
      mode: mode
    ) else {
      return false
    }
    defaults.set(data, forKey: Keys.controlState)
    return defaults.data(forKey: Keys.controlState) == data
  }

  private func removeLegacyControlState() {
    defaults.removeObject(forKey: Keys.legacyActiveContexts)
    defaults.removeObject(forKey: Keys.legacyEffectiveMode)
    defaults.removeObject(forKey: Keys.legacyNativeServiceRunning)
    defaults.removeObject(forKey: Keys.legacyRestorationMarker)
  }

  private func reconcileRuntime(emit: Bool) {
    assertMainThread()
    guard effectiveMode != .idle else {
      stopLocationManager(
        clearError: !hasRejectedPersistedControlState,
        emit: emit
      )
      return
    }
    guard CLLocationManager.locationServicesEnabled() else {
      stopLocationManager(clearError: false, emit: false)
      setRuntimeError(
        code: "location_services_disabled",
        message: "System location services are disabled."
      )
      if emit { notifyObservers() }
      return
    }
    guard hasValidHostBackgroundConfiguration() else {
      stopLocationManager(clearError: false, emit: false)
      setRuntimeError(
        code: "host_configuration_missing",
        message: "The host app must declare background location mode and an Always location usage description."
      )
      if emit { notifyObservers() }
      return
    }

    switch currentAuthorizationStatus() {
    case .authorizedAlways:
      startLocationManager(emit: emit)
    case .notDetermined:
      stopLocationManager(clearError: false, emit: false)
      setRuntimeError(
        code: "authorization_not_determined",
        message: "Location authorization has not been requested."
      )
      if emit { notifyObservers() }
    case .denied:
      stopLocationManager(clearError: false, emit: false)
      setRuntimeError(
        code: "authorization_denied",
        message: "Location authorization was denied."
      )
      if emit { notifyObservers() }
    case .restricted:
      stopLocationManager(clearError: false, emit: false)
      setRuntimeError(
        code: "authorization_restricted",
        message: "Location authorization is restricted."
      )
      if emit { notifyObservers() }
    case .authorizedWhenInUse:
      stopLocationManager(clearError: false, emit: false)
      setRuntimeError(
        code: "background_authorization_required",
        message: "Always authorization is required for background location."
      )
      if emit { notifyObservers() }
    @unknown default:
      stopLocationManager(clearError: false, emit: false)
      setRuntimeError(
        code: "native_start_failed",
        message: "The native location authorization state is unsupported."
      )
      if emit { notifyObservers() }
    }
  }

  private func startLocationManager(emit: Bool) {
    assertMainThread()
    guard let configuration = ModeConfiguration.forMode(effectiveMode) else {
      stopLocationManager(clearError: true, emit: emit)
      return
    }
    locationManager.desiredAccuracy = configuration.desiredAccuracy
    locationManager.distanceFilter = configuration.distanceFilter
    locationManager.pausesLocationUpdatesAutomatically =
      configuration.pausesAutomatically
    locationManager.activityType = .other
    locationManager.allowsBackgroundLocationUpdates = true
    locationManager.showsBackgroundLocationIndicator = true
    clearRuntimeError()
    if !locationUpdatesStarted {
      locationManager.startUpdatingLocation()
      locationUpdatesStarted = true
    }
    if emit { notifyObservers() }
  }

  private func stopLocationManager(clearError: Bool, emit: Bool) {
    assertMainThread()
    if locationUpdatesStarted {
      locationManager.stopUpdatingLocation()
      locationUpdatesStarted = false
    }
    locationManager.allowsBackgroundLocationUpdates = false
    if clearError {
      clearRuntimeError()
    }
    if emit {
      notifyObservers()
    }
  }

  private func permissionSnapshot() -> [String: Any] {
    assertMainThread()
    return [
      "locationServicesEnabled": CLLocationManager.locationServicesEnabled(),
      "authorization": authorizationName(currentAuthorizationStatus()),
      "accuracyAuthorization": accuracyAuthorizationName(),
    ]
  }

  private func runtimeStatus() -> [String: Any] {
    assertMainThread()
    var status: [String: Any] = [
      "activeContexts": Array(requestedContexts).sorted(),
      "effectiveMode": effectiveMode.rawValue,
      "isNativePlatformSupported": true,
      "isNativeServiceRunning": locationUpdatesStarted,
      "permission": permissionSnapshot(),
      "wasRestoredAfterRelaunch": wasRestoredAfterRelaunch,
    ]
    if defaults.object(forKey: Keys.lastAcceptedLocationAt) != nil {
      status["lastAcceptedLocationAt"] =
        Int64(defaults.double(forKey: Keys.lastAcceptedLocationAt) * 1000)
    }
    if let code = defaults.string(forKey: Keys.lastErrorCode) {
      status["lastErrorCode"] = code
    }
    if let message = defaults.string(forKey: Keys.lastErrorMessage) {
      status["lastErrorMessage"] = message
    }
    return status
  }

  private func currentAuthorizationStatus() -> CLAuthorizationStatus {
    assertMainThread()
    if #available(iOS 14.0, *) {
      return locationManager.authorizationStatus
    }
    return CLLocationManager.authorizationStatus()
  }

  private func authorizationName(_ status: CLAuthorizationStatus) -> String {
    switch status {
    case .notDetermined:
      return "notDetermined"
    case .denied:
      return "denied"
    case .restricted:
      return "restricted"
    case .authorizedWhenInUse:
      return "whenInUse"
    case .authorizedAlways:
      return "always"
    @unknown default:
      return "restricted"
    }
  }

  private func accuracyAuthorizationName() -> String {
    assertMainThread()
    if #available(iOS 14.0, *) {
      switch locationManager.accuracyAuthorization {
      case .reducedAccuracy:
        return "reduced"
      case .fullAccuracy:
        return "full"
      @unknown default:
        return "unknown"
      }
    }
    return "unknown"
  }

  private func hasValidHostBackgroundConfiguration() -> Bool {
    let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes")
      as? [String]
    return modes?.contains("location") == true &&
      hasNonEmptyInfoString("NSLocationAlwaysAndWhenInUseUsageDescription")
  }

  private func hasNonEmptyInfoString(_ key: String) -> Bool {
    guard let value = Bundle.main.object(
      forInfoDictionaryKey: key
    ) as? String else {
      return false
    }
    return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func acceptNewestLocation(_ locations: [CLLocation]) {
    assertMainThread()
    let now = Date()
    let accepted = locations
      .filter { location in
        CLLocationCoordinate2DIsValid(location.coordinate) &&
          location.horizontalAccuracy >= 0 &&
          now.timeIntervalSince(location.timestamp) <=
            Self.maximumAcceptedLocationAge &&
          location.timestamp.timeIntervalSince(now) <=
            Self.maximumFutureClockSkew
      }
      .max(by: { $0.timestamp < $1.timestamp })
    guard let location = accepted else {
      return
    }

    let altitude: Double? =
      location.verticalAccuracy >= 0 ? location.altitude : nil
    let timestamp = location.timestamp.timeIntervalSince1970
    defaults.set(timestamp, forKey: Keys.lastAcceptedLocationAt)
    defaults.set(location.coordinate.latitude, forKey: Keys.lastAcceptedLatitude)
    defaults.set(
      location.coordinate.longitude,
      forKey: Keys.lastAcceptedLongitude
    )
    defaults.set(
      location.horizontalAccuracy,
      forKey: Keys.lastAcceptedHorizontalAccuracy
    )
    if let altitude = altitude {
      defaults.set(altitude, forKey: Keys.lastAcceptedAltitude)
    } else {
      defaults.removeObject(forKey: Keys.lastAcceptedAltitude)
    }
    enqueue(PersistedSample(
      timestamp: timestamp,
      latitude: location.coordinate.latitude,
      longitude: location.coordinate.longitude,
      horizontalAccuracy: location.horizontalAccuracy,
      altitude: altitude
    ))
    clearRuntimeError()
    notifyObservers()
  }

  private func enqueue(_ sample: PersistedSample) {
    var queue = loadQueue()
    queue.append(sample)
    pruneAndPersistQueue(queue)
  }

  private func loadQueue() -> [PersistedSample] {
    guard let data = defaults.data(forKey: Keys.acceptedSampleQueue),
          let queue = try? JSONDecoder().decode(
            [PersistedSample].self,
            from: data
          ) else {
      return []
    }
    return queue
  }

  private func pruneAndPersistQueue(_ queue: [PersistedSample]) {
    let cutoff = Date().timeIntervalSince1970 -
      Self.maximumQueuedSampleAge
    let retained = queue
      .filter { $0.timestamp >= cutoff }
      .sorted { $0.timestamp < $1.timestamp }
      .suffix(Self.maximumQueuedSampleCount)
    if let data = try? JSONEncoder().encode(Array(retained)) {
      defaults.set(data, forKey: Keys.acceptedSampleQueue)
    }
  }

  private func setRuntimeError(code: String, message: String) {
    defaults.set(code, forKey: Keys.lastErrorCode)
    defaults.set(message, forKey: Keys.lastErrorMessage)
  }

  private func clearRuntimeError() {
    defaults.removeObject(forKey: Keys.lastErrorCode)
    defaults.removeObject(forKey: Keys.lastErrorMessage)
  }

  private func notifyObservers() {
    assertMainThread()
    let status = runtimeStatus()
    for observer in Array(observers.values) {
      observer(status)
    }
  }

  private func assertMainThread() {
    precondition(
      Thread.isMainThread,
      "BackgroundLocationService must be used on the main thread."
    )
  }
}

extension BackgroundLocationService: CLLocationManagerDelegate {
  func locationManager(
    _ manager: CLLocationManager,
    didUpdateLocations locations: [CLLocation]
  ) {
    acceptNewestLocation(locations)
  }

  func locationManager(
    _ manager: CLLocationManager,
    didFailWithError error: Error
  ) {
    assertMainThread()
    let coreLocationError = error as? CLError
    if coreLocationError?.code == .denied &&
        !CLLocationManager.locationServicesEnabled() {
      stopLocationManager(clearError: false, emit: false)
      setRuntimeError(
        code: "location_services_disabled",
        message: "System location services are disabled."
      )
    } else {
      setRuntimeError(
        code: "native_location_error",
        message: "Core Location reported a native acquisition error."
      )
    }
    notifyObservers()
  }

  @available(iOS 14.0, *)
  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    reconcileRuntime(emit: true)
  }

  func locationManager(
    _ manager: CLLocationManager,
    didChangeAuthorization status: CLAuthorizationStatus
  ) {
    if #available(iOS 14.0, *) {
      return
    }
    reconcileRuntime(emit: true)
  }
}

/// Engine-specific Flutter channels attached to the process-wide service.
final class BackgroundLocationBridge: NSObject, FlutterStreamHandler {
  private static let methodChannelName =
    "dev.eixam.connect_flutter/background_location/methods"
  private static let eventChannelName =
    "dev.eixam.connect_flutter/background_location/events"

  private let service: BackgroundLocationService
  private let methodChannel: FlutterMethodChannel
  private let eventChannel: FlutterEventChannel
  private var eventSink: FlutterEventSink?
  private var observerToken: UUID?

  private init(
    service: BackgroundLocationService,
    methodChannel: FlutterMethodChannel,
    eventChannel: FlutterEventChannel
  ) {
    self.service = service
    self.methodChannel = methodChannel
    self.eventChannel = eventChannel
    super.init()
  }

  @objc static func register(
    with registrar: FlutterPluginRegistrar
  ) -> BackgroundLocationBridge {
    let methodChannel = FlutterMethodChannel(
      name: methodChannelName,
      binaryMessenger: registrar.messenger()
    )
    let eventChannel = FlutterEventChannel(
      name: eventChannelName,
      binaryMessenger: registrar.messenger()
    )
    let instance = BackgroundLocationBridge(
      service: BackgroundLocationService.sharedOnMainThread(),
      methodChannel: methodChannel,
      eventChannel: eventChannel
    )
    methodChannel.setMethodCallHandler { [weak instance] call, result in
      guard let instance = instance else {
        result(FlutterMethodNotImplemented)
        return
      }
      instance.handle(call, result: result)
    }
    eventChannel.setStreamHandler(instance)
    return instance
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in
        guard let self = self else {
          result(FlutterMethodNotImplemented)
          return
        }
        self.handle(call, result: result)
      }
      return
    }

    switch call.method {
    case "getLocationPermissionSnapshot":
      result(service.getLocationPermissionSnapshot())
    case "requestLocationWhenInUsePermission":
      service.requestWhenInUse(result: result)
    case "requestLocationAlwaysPermission":
      service.requestAlways(result: result)
    case "setBackgroundLocationState":
      service.setBackgroundLocationState(
        arguments: call.arguments,
        result: result
      )
    case "getBackgroundLocationStatus":
      result(service.getBackgroundLocationStatus())
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    performOnMainSync {
      removeObserver()
      eventSink = events
      observerToken = service.addObserver { [weak self] status in
        self?.eventSink?(status)
      }
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    performOnMainSync {
      removeObserver()
      eventSink = nil
    }
    return nil
  }

  func detach() {
    let cleanup = { [self] in
      methodChannel.setMethodCallHandler(nil)
      eventChannel.setStreamHandler(nil)
      removeObserver()
      eventSink = nil
    }
    if Thread.isMainThread {
      cleanup()
    } else {
      DispatchQueue.main.async(execute: cleanup)
    }
  }

  private func removeObserver() {
    if let observerToken = observerToken {
      service.removeObserver(observerToken)
      self.observerToken = nil
    }
  }

  private func performOnMainSync(_ work: () -> Void) {
    if Thread.isMainThread {
      work()
    } else {
      DispatchQueue.main.sync(execute: work)
    }
  }
}
