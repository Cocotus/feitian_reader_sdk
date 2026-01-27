import Flutter
import UIKit
import WHCCareKit_iOS

public class OrgacareReaderSdkPlugin: NSObject, FlutterPlugin {
  
  // Singleton Implementierung!
  private static var channel: FlutterMethodChannel?

  public static func register(with registrar: FlutterPluginRegistrar) {
    channel = FlutterMethodChannel(name: "orgacare_reader_sdk", binaryMessenger: registrar.messenger())
    let instance = OrgacareReaderSdkPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel!)
    // Singleton Implementierung!
    CarddataManager.shared.initialize(channel: channel!)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getPlatformVersion":
        let platformVersion = "iOS " + UIDevice.current.systemVersion
        CarddataManager.shared.sendLog("getPlatformVersion called: \(platformVersion)")
        result(platformVersion)
    case "loadVSD":
        CarddataManager.shared.loadVSD()
        result("loadVSD called")
    case "loadNFD":
        CarddataManager.shared.loadNFD()
        result("loadNFD called")
    case "loadDPE":
        CarddataManager.shared.loadDPE()
        result("loadDPE called")
    case "loadAMTS":
        CarddataManager.shared.loadAMTS()
        result("loadAMTS called")
    default:
        result(FlutterMethodNotImplemented)
    }
  }

}