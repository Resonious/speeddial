import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var shareBridge: ShareBridge?
  private var clipboardChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    shareBridge = ShareBridge(messenger: engineBridge.applicationRegistrar.messenger())
    clipboardChannel = FlutterMethodChannel(
      name: "sh.speeddial/clipboard", binaryMessenger: engineBridge.applicationRegistrar.messenger())
    clipboardChannel?.setMethodCallHandler { call, result in
      guard call.method == "writeHtml" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let args = call.arguments as? [String: Any],
            let text = args["text"] as? String,
            let html = args["html"] as? String else {
        result(FlutterError(code: "invalid_arguments", message: "Expected text and html strings", details: nil))
        return
      }
      UIPasteboard.general.setItems([[
        "public.utf8-plain-text": Data(text.utf8),
        "public.html": Data(html.utf8)
      ]])
      result(nil)
    }
  }
}
