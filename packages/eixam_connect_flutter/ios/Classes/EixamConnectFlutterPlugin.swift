import Flutter
import UIKit

public class EixamConnectFlutterPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    ProtectionRuntimeBridge.register(with: registrar)
    FirmwareDfuBridge.register(with: registrar)
    SecureStorageBridge.register(with: registrar)
  }
}
