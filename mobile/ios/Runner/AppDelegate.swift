import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // A keyboard extension cannot present the system microphone-permission
    // prompt itself (extensions can't request permissions). The grant is
    // app-wide, so we trigger it here in the host app: open this app once and
    // tap Allow, after which the AudioProbe keyboard can capture audio under
    // Full Access. See ios/POC_README.md.
    if #available(iOS 17.0, *) {
      AVAudioApplication.requestRecordPermission { _ in }
    } else {
      AVAudioSession.sharedInstance().requestRecordPermission { _ in }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
