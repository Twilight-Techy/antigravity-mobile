import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Let flutter_local_notifications show notifications and handle taps.
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "BackgroundTaskPlugin") {
      BackgroundTaskPlugin.register(with: registrar)
    }
  }
}

/// Asks iOS for extra time to finish an agent reply after the app goes to
/// the background, so the connection stays open long enough to notify.
class BackgroundTaskPlugin: NSObject, FlutterPlugin {
  private var task: UIBackgroundTaskIdentifier = .invalid

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "antigravity_mobile/background", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(BackgroundTaskPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "begin":
      if task == .invalid {
        task = UIApplication.shared.beginBackgroundTask(withName: "agent-run") { [weak self] in
          self?.end()
        }
      }
      result(nil)
    case "end":
      end()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func end() {
    if task != .invalid {
      UIApplication.shared.endBackgroundTask(task)
      task = .invalid
    }
  }
}
