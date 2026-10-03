import Flutter
import UIKit

public class EixamConnectFlutterPlugin: NSObject, FlutterPlugin {
  private var backgroundLocationBridge: BackgroundLocationBridge?
  private var phoneRadioBridge: PhoneRadioBridge?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let plugin = EixamConnectFlutterPlugin()
    ProtectionRuntimeBridge.register(with: registrar)
    plugin.backgroundLocationBridge =
      BackgroundLocationBridge.register(with: registrar)
    plugin.phoneRadioBridge = PhoneRadioBridge.register(with: registrar)
    FirmwareDfuBridge.register(with: registrar)
    SecureStorageBridge.register(with: registrar)
    registrar.publish(plugin)
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    backgroundLocationBridge?.detach()
    backgroundLocationBridge = nil
    phoneRadioBridge?.detach()
    phoneRadioBridge = nil
  }
}
