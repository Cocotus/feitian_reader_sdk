import Flutter
import UIKit
import Compression
import CoreBluetooth

// Import zlib functions
import func zlib.inflateInit2_
import func zlib.inflate
import func zlib.inflateEnd
import var zlib.Z_OK
import var zlib.Z_STREAM_END
import var zlib.Z_SYNC_FLUSH
import var zlib.MAX_WBITS
import var zlib.ZLIB_VERSION
import struct zlib.z_stream
import typealias zlib.Bytef
import typealias zlib.uInt

// MARK: - PCSC Type Definitions
typealias SCARDCONTEXT = Int
typealias SCARDHANDLE = Int
typealias DWORD = UInt32
typealias LONG = Int32

// MARK: - PCSC Constants
let SCARD_S_SUCCESS: Int32 = 0x00000000
let SCARD_SCOPE_SYSTEM: UInt32 = 0x00000002
let SCARD_SHARE_SHARED: UInt32 = 0x00000002
let SCARD_PROTOCOL_T0: UInt32 = 0x00000001
let SCARD_PROTOCOL_T1: UInt32 = 0x00000002
let SCARD_LEAVE_CARD: UInt32 = 0x00000000
let SCARD_RESET_CARD: UInt32 = 0x00000001

// MARK: - PCSC Structures
struct SCARD_IO_REQUEST {
    var dwProtocol: UInt32
    var cbPciLength: UInt32
    
    init(cardProtocol: UInt32) {
        self.dwProtocol = cardProtocol
        self.cbPciLength = UInt32(MemoryLayout<SCARD_IO_REQUEST>.size)
    }
}

// MARK: - PCSC Function Declarations
@_silgen_name("SCardEstablishContext")
func SCardEstablishContext(_ dwScope: UInt32, _ pvReserved1: UnsafeRawPointer?, _ pvReserved2: UnsafeRawPointer?, _ phContext: UnsafeMutablePointer<SCARDCONTEXT>) -> Int32

@_silgen_name("SCardReleaseContext")
func SCardReleaseContext(_ hContext: SCARDCONTEXT) -> Int32

@_silgen_name("SCardConnect")
func SCardConnect(_ hContext: SCARDCONTEXT, _ szReader: UnsafePointer<CChar>?, _ dwShareMode: UInt32, _ dwPreferredProtocols: UInt32, _ phCard: UnsafeMutablePointer<SCARDHANDLE>, _ pdwActiveProtocol: UnsafeMutablePointer<UInt32>) -> Int32

@_silgen_name("SCardDisconnect")
func SCardDisconnect(_ hCard: SCARDHANDLE, _ dwDisposition: UInt32) -> Int32

@_silgen_name("SCardTransmit")
func SCardTransmit(_ hCard: SCARDHANDLE, _ pioSendPci: UnsafePointer<SCARD_IO_REQUEST>, _ pbSendBuffer: UnsafePointer<UInt8>, _ cbSendLength: UInt32, _ pioRecvPci: UnsafeMutablePointer<SCARD_IO_REQUEST>?, _ pbRecvBuffer: UnsafeMutablePointer<UInt8>, _ pcbRecvLength: UnsafeMutablePointer<UInt32>) -> Int32

@_silgen_name("SCardListReaders")
func SCardListReaders(_ hContext: SCARDCONTEXT, _ mszGroups: UnsafePointer<CChar>?, _ mszReaders: UnsafeMutablePointer<CChar>?, _ pcchReaders: UnsafeMutablePointer<UInt32>) -> Int32

@_silgen_name("FtGetLibVersion")
func FtGetLibVersion(_ buffer: UnsafeMutablePointer<CChar>)

@_silgen_name("FtSetTimeout")
func FtSetTimeout(_ hContext: SCARDCONTEXT, _ timeout: UInt32) -> Int32

@_silgen_name("FtGetDevVer")
func FtGetDevVer(_ hContext: SCARDCONTEXT, _ firmwareRevision: UnsafeMutablePointer<CChar>, _ hardwareRevision: UnsafeMutablePointer<CChar>) -> Int32

// MARK: - ReaderInterface Protocol Bridge (from FEITIAN SDK)
@objc protocol ReaderInterfaceDelegate: AnyObject {
    @objc optional func findPeripheralReader(_ readerName: String)
    @objc optional func readerInterfaceDidChange(_ attached: Bool, bluetoothID: String, andslotnameArray slotArray: [String])
    @objc optional func cardInterfaceDidDetach(_ attached: Bool, slotname: String)
    @objc optional func didGetBattery(_ battery: Int)
}

// ReaderInterface class from FEITIAN SDK Framework
@objc class ReaderInterface: NSObject {
    func setDelegate(_ delegate: ReaderInterfaceDelegate?) {}
    func setAutoPair(_ autoPair: Bool) {}
    func connectPeripheralReader(_ readerName: String, timeout: Float) -> Bool { return false }
    func disConnectCurrentPeripheralReader() {}
}

// FTDeviceType class from FEITIAN SDK
@objc class FTDeviceType: NSObject {
    @objc static func setDeviceType(_ type: UInt32) {}
}

// Device type constants from SDK
let IR301_AND_BR301: UInt32 = 0x01
let BR301BLE_AND_BR500: UInt32 = 0x02
let LINE_TYPEC: UInt32 = 0x04

// MARK: - FeitianCardManager
class FeitianCardManager: NSObject {
    static let shared = FeitianCardManager()
    
    private var channel: FlutterMethodChannel?
    
    // NEW: Use the standalone scanner controller
    private var scanController: FeitianScanController?
    
    // Keep PCSC handles for card operations only
    private var scardContext: SCARDCONTEXT = 0
    private var scardHandle: SCARDHANDLE = 0
    private var activeProtocol: UInt32 = 0
    
    // Reader state
    private var isReaderConnected = false
    private var connectedReaderName: String?
    
    // EGK Card data
    private var cardGeneration: String = ""
    private var schemaVersion: String = ""
    private var maxBufferSize: UInt16 = 0
    
    private override init() {
        super.init()
    }
    
    func initialize(channel: FlutterMethodChannel) {
        self.channel = channel
        sendLog("FEITIAN Reader SDK initialized")
    }
    
    // MARK: - Bluetooth Scanning (using FeitianScanController)
    
    func startBluetoothScan() {
        sendLog("=== START BLUETOOTH SCAN ===")
        
        // Initialize scanner controller
        scanController = FeitianScanController()
        scanController?.delegate = self
        
        // Start scanning - this encapsulates ALL the demo logic
        scanController?.startScanning()
        
        sendLog("=== SCAN STARTED ===")
    }
    
    func stopBluetoothScan() {
        sendLog("Stopping Bluetooth scan...")
        
        scanController?.stopScanning()
        scanController = nil
        
        sendLog("Bluetooth scan stopped")
    }
    
    func connectToReader(deviceName: String) {
        sendLog("Connecting to reader: \(deviceName)")
        
        // Use the scanner controller's connect method
        scanController?.connectToReader(deviceName: deviceName)
    }
    
    func disconnectReader() {
        sendLog("Disconnecting reader...")
        
        scanController?.disconnectReader()
        
        // Cleanup card handles
        if scardHandle != 0 {
            SCardDisconnect(scardHandle, SCARD_LEAVE_CARD)
            scardHandle = 0
        }
        
        isReaderConnected = false
        connectedReaderName = nil
        
        sendLog("Reader disconnected")
        channel?.invokeMethod("readerDisconnected", arguments: nil)
    }
    
    // MARK: - Card Operations
    // ... (keep ALL your existing card operation methods unchanged) ...
    
    private func sendLog(_ message: String) {
        print("FEITIAN: \(message)")
        channel?.invokeMethod("log", arguments: message)
    }
}

// MARK: - FeitianScanControllerDelegate
extension FeitianCardManager: FeitianScanControllerDelegate {
    
    func didDiscoverDevice(_ deviceName: String, rssi: Int) {
        sendLog("Device found: \(deviceName) (RSSI: \(rssi))")
        
        channel?.invokeMethod("deviceFound", arguments: [
            "name": deviceName,
            "rssi": rssi
        ])
    }
    
    func didConnectReader(_ deviceName: String, slots: [String]) {
        sendLog("Reader connected: \(deviceName)")
        
        isReaderConnected = true
        connectedReaderName = deviceName
        
        // Establish PCSC context for card operations
        if scardContext == 0 {
            var context: SCARDCONTEXT = 0
            let ret = SCardEstablishContext(SCARD_SCOPE_SYSTEM, nil, nil, &context)
            if ret == SCARD_S_SUCCESS {
                scardContext = context
                sendLog("PCSC Context established for card operations")
            }
        }
        
        channel?.invokeMethod("readerConnected", arguments: [
            "deviceName": deviceName,
            "connected": true,
            "slots": slots
        ])
    }
    
    func didDisconnectReader() {
        sendLog("Reader disconnected")
        
        isReaderConnected = false
        connectedReaderName = nil
        
        // Release PCSC context
        if scardContext != 0 {
            SCardReleaseContext(scardContext)
            scardContext = 0
        }
        
        channel?.invokeMethod("readerDisconnected", arguments: nil)
    }
    
    func didDetectCard(_ slotName: String) {
        sendLog("Card detected in slot: \(slotName)")
        
        channel?.invokeMethod("cardConnected", arguments: [
            "slot": slotName
        ])
    }
    
    func didRemoveCard(_ slotName: String) {
        sendLog("Card removed from slot: \(slotName)")
        
        // Cleanup card handle
        if scardHandle != 0 {
            SCardDisconnect(scardHandle, SCARD_LEAVE_CARD)
            scardHandle = 0
        }
        
        channel?.invokeMethod("cardDisconnected", arguments: nil)
    }
    
    func didReceiveBattery(_ level: Int) {
        sendLog("Battery: \(level)%")
        
        channel?.invokeMethod("batteryLevel", arguments: [
            "level": level
        ])
    }
    
    func didReceiveLog(_ message: String) {
        sendLog(message)
    }
}

// ... (keep ALL your existing card operation methods: powerOnCard, readEGKCard, etc.) ...