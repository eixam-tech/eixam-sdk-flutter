import Flutter
import Foundation

final class ActivityRecordingStorageBridge {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "dev.eixam.connect.flutter/activity_recording_storage",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "prepare" else {
        result(FlutterMethodNotImplemented)
        return
      }
      do {
        result(try ActivityRecordingDirectoryPreparer().prepare().path)
      } catch {
        result(FlutterError(
          code: "E_RECORDING_PERSISTENCE_FAILED",
          message: "Recording storage privacy preparation failed.",
          details: nil
        ))
      }
    }
  }
}
