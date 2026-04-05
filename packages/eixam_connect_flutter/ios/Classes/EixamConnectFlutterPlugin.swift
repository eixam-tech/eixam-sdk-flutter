import Flutter
import UIKit

public class EixamConnectFlutterPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    ProtectionRuntimeBridge.register(with: registrar)
  }
}
