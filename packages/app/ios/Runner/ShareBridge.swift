import Flutter
import Foundation

/// Serial actor keeps disk IO and base64 work away from the UI thread.
private actor ShareInboxWorker {
  func takeNext() throws -> [String: String]? { try ShareInbox.shared().takeNext() }
  func publish(_ targets: [[String: String]]) throws {
    try ShareInbox.shared().publishTargets(targets)
  }
}

final class ShareBridge {
  private let channel: FlutterMethodChannel
  private let worker = ShareInboxWorker()

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "sh.speeddial/share", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(FlutterMethodNotImplemented); return }
      switch call.method {
      case "takeInitial":
        Task { @MainActor in
          do { result(try await self.worker.takeNext()) }
          catch { result(FlutterError(code: "share_read", message: error.localizedDescription, details: nil)) }
        }
      case "publishTargets":
        guard let arguments = call.arguments as? [String: Any],
              let targets = arguments["targets"] as? [[String: String]] else {
          result(FlutterError(code: "share_targets", message: "Invalid project list", details: nil))
          return
        }
        Task { @MainActor in
          do { try await self.worker.publish(targets); result(nil) }
          catch { result(FlutterError(code: "share_targets", message: error.localizedDescription, details: nil)) }
        }
      default: result(FlutterMethodNotImplemented)
      }
    }
  }
}
