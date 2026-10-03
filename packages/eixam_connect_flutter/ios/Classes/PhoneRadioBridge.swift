import CoreTelephony
import Flutter
import Network

/// Reads the serving radio access technology and whether the default data
/// path is cellular. Does not touch `CTCarrier`.
final class PhoneRadioBridge {
  private static let channelName = "dev.eixam.connect_flutter/phone_radio/methods"

  private let telephony = CTTelephonyNetworkInfo()
  private let monitor = NWPathMonitor()
  private let queue = DispatchQueue(label: "dev.eixam.connect.phone-radio")
  private let stateLock = NSLock()
  private var latestPath: NWPath?
  private var channel: FlutterMethodChannel?

  static func register(with registrar: FlutterPluginRegistrar) -> PhoneRadioBridge {
    let bridge = PhoneRadioBridge()
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    bridge.channel = channel
    channel.setMethodCallHandler { call, result in
      guard call.method == "readPhoneRadio" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(bridge.reading())
    }
    bridge.start()
    return bridge
  }

  func detach() {
    monitor.cancel()
    channel?.setMethodCallHandler(nil)
    channel = nil
  }

  private func start() {
    monitor.pathUpdateHandler = { [weak self] path in
      guard let bridge = self else {
        return
      }
      bridge.stateLock.lock()
      bridge.latestPath = path
      bridge.stateLock.unlock()
    }
    monitor.start(queue: queue)
  }

  private func reading() -> [String: Any] {
    var payload: [String: Any] = [:]
    if let technology = radioAccessTechnology() {
      payload["radioAccessTechnology"] = technology
    }
    stateLock.lock()
    let path = latestPath ?? monitor.currentPath
    stateLock.unlock()
    payload["cellularDataConnected"] = cellularDataConnected(path)
    return payload
  }

  private func cellularDataConnected(_ path: NWPath) -> Bool {
    guard path.status == .satisfied else {
      return false
    }
    if let primary = path.availableInterfaces.first {
      return primary.type == .cellular
    }
    return path.usesInterfaceType(.cellular)
  }

  private func radioAccessTechnology() -> String? {
    let technologies = telephony.serviceCurrentRadioAccessTechnology
    if let dataService = telephony.dataServiceIdentifier,
      let technology = technologies?[dataService],
      !technology.isEmpty
    {
      return technology
    }
    return technologies?.values.first { !$0.isEmpty }
  }
}
