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
        result(platformVersion)
        
    // Bluetooth Scanner Methods
    case "startBluetoothScan":
        FeitianCardManager.shared.startBluetoothScan()
        result("Bluetooth scan started")
        
    case "stopBluetoothScan":
        FeitianCardManager.shared.stopBluetoothScan()
        result("Bluetooth scan stopped")
        
    case "connectToReader":
        if let args = call.arguments as? [String: Any],
           let deviceName = args["deviceName"] as? String {
            FeitianCardManager.shared.connectToReader(deviceName: deviceName)
            result("Connecting to reader: \(deviceName)")
        } else {
            result(FlutterError(code: "INVALID_ARGUMENT", 
                               message: "Device name required", 
                               details: nil))
        }
        
    case "disconnectReader":
        FeitianCardManager.shared.disconnectReader()
        result("Reader disconnected")
        
    case "getBatteryLevel":
        FeitianCardManager.shared.getBatteryLevel()
        result("Getting battery level")
        
    // Card Operations
    case "powerOnCard":
        FeitianCardManager.shared.powerOnCard()
        result("Card power on initiated")
        
    case "powerOffCard":
        FeitianCardManager.shared.powerOffCard()
        result("Card powered off")
        
    // EGK Reading
    case "readEGKCard":
        FeitianCardManager.shared.readEGKCard()
        result("EGK card reading initiated")
        
    // Legacy Methods (kept for backwards compatibility)
    case "connectReader":
       FeitianCardManager.shared.startBluetoothScan()
        
    case "sendApduCommand":
        result("APDU commands are handled internally during EGK reading")
        
    case "readUID":
        result("UID reading not implemented in current version")
        
    default:
        result(FlutterMethodNotImplemented)
    }
  }

}
