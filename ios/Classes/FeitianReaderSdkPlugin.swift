import Flutter
import UIKit

public class FeitianReaderSdkPlugin: NSObject, FlutterPlugin {
  
  // Singleton Implementierung!
  private static var channel: FlutterMethodChannel?

  public static func register(with registrar: FlutterPluginRegistrar) {
    channel = FlutterMethodChannel(name: "feitian_reader_sdk", binaryMessenger: registrar.messenger())
    let instance = FeitianReaderSdkPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel!)
    // Singleton Implementierung!
    FeitianCardManager.shared.initialize(channel: channel!)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getPlatformVersion":
        let platformVersion = "iOS " + UIDevice.current.systemVersion
        FeitianCardManager.shared.sendLog("getPlatformVersion called: \(platformVersion)")
        result(platformVersion)
    case "connectReader":
        FeitianCardManager.shared.connectReader()
        result("connectReader called")
    case "disconnectReader":
        FeitianCardManager.shared.disconnectReader()
        result("disconnectReader called")
    case "sendApduCommand":
        if let args = call.arguments as? [String: Any],
           let apdu = args["apdu"] as? String {
            FeitianCardManager.shared.sendCommand(apdu)
            result("sendApduCommand called with APDU: \(apdu)")
        } else {
            result(FlutterError(code: "INVALID_ARGUMENT", 
                               message: "APDU command required", 
                               details: nil))
        }
    case "readUID":
        FeitianCardManager.shared.readUID()
        result("readUID called")
    case "powerOnCard":
        FeitianCardManager.shared.powerOnCard()
        result("powerOnCard called")
    case "powerOffCard":
        FeitianCardManager.shared.powerOffCard()
        result("powerOffCard called")
    default:
        result(FlutterMethodNotImplemented)
    }
  }

}
