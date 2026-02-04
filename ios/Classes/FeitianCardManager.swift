import Flutter
import UIKit
import Compression

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
// These classes are implemented in the FEITIAN SDK framework (libiRockey301_ccid.a)
// and are bridged here for Swift interoperability
@objc protocol ReaderInterfaceDelegate: AnyObject {
    @objc optional func findPeripheralReader(_ readerName: String)
    @objc optional func readerInterfaceDidChange(_ attached: Bool, bluetoothID: String, andslotnameArray slotArray: [String])
    @objc optional func cardInterfaceDidDetach(_ attached: Bool, slotname: String)
    @objc optional func didGetBattery(_ battery: Int)
}

// ReaderInterface class from FEITIAN SDK Framework
// These methods are provided by the SDK's native implementation
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
    private var scardContext: SCARDCONTEXT = 0
    private var scardHandle: SCARDHANDLE = 0
    private var activeProtocol: UInt32 = 0
    
    // ReaderInterface from FEITIAN SDK
    private var readerInterface: ReaderInterface?
    
    // Reader state
    private var isReaderConnected = false
    private var connectedReaderName: String?
    private var isScanning = false
    
    // EGK Card data
    private var cardGeneration: String = ""
    private var schemaVersion: String = ""
    private var maxBufferSize: UInt16 = 0
    
    private override init() {
        super.init()
        setupReaderInterface()
    }
    
    private func setupReaderInterface() {
        readerInterface = ReaderInterface()
        readerInterface?.setDelegate(self)
        readerInterface?.setAutoPair(false) // Manual pairing like in demo
        
        // Support all device types
        FTDeviceType.setDeviceType(IR301_AND_BR301 | BR301BLE_AND_BR500 | LINE_TYPEC)
    }
    
    func initialize(channel: FlutterMethodChannel) {
        self.channel = channel
        sendLog("FEITIAN Reader SDK initialisiert")
 
    }
    
    // MARK: - Bluetooth Scanning (via ReaderInterface SDK)
    
    func startBluetoothScan() {
        sendLog("Starte Bluetooth-Scan über ReaderInterface...")
        isScanning = true
        
        // Bluetooth scanning is automatically handled by the ReaderInterface SDK
        // when setDelegate is called during initialization. The SDK continuously
        // scans for FEITIAN devices and calls findPeripheralReader() for each
        // device discovered. No explicit scan start is needed.
    }
    
    func stopBluetoothScan() {
        sendLog("Stoppe Bluetooth-Scan...")
        isScanning = false
        sendLog("Bluetooth-Scan gestoppt")
    }
    
    // MARK: - Reader Connection
    
    func connectToReader(deviceName: String) {
        sendLog("Verbinde mit Reader: \(deviceName)")
        
        guard let readerInterface = readerInterface else {
            sendLog("ERROR: ReaderInterface nicht initialisiert")
            return
        }
        
        // SDK connection with timeout (like in demo)
        let success = readerInterface.connectPeripheralReader(deviceName, timeout: 15.0)
        
        if success {
            connectedReaderName = deviceName
            sendLog("Verbindung zu \(deviceName) wird hergestellt...")
        } else {
            sendLog("ERROR: Verbindung zu \(deviceName) fehlgeschlagen")
        }
    }
    
    func disconnectReader() {
        sendLog("Trenne Reader...")
        
        if scardHandle != 0 {
            SCardDisconnect(scardHandle, SCARD_LEAVE_CARD)
            scardHandle = 0
        }
        
        if scardContext != 0 {
            SCardReleaseContext(scardContext)
            scardContext = 0
        }
        
        readerInterface?.disConnectCurrentPeripheralReader()
        
        isReaderConnected = false
        connectedReaderName = nil
        
        sendLog("Reader getrennt")
        channel?.invokeMethod("readerDisconnected", arguments: nil)
    }
    
    // MARK: - PCSC Context
    
    private func establishContext() {
        sendLog("Erstelle PCSC Context...")
        
        var context: SCARDCONTEXT = 0
        let ret = SCardEstablishContext(SCARD_SCOPE_SYSTEM, nil, nil, &context)
        
        if ret == SCARD_S_SUCCESS {
            scardContext = context
            sendLog("PCSC Context erstellt: \(context)")
            
            // Set timeout like in demo (50 seconds)
            FtSetTimeout(scardContext, 50000)
        } else {
            sendLog("Fehler beim Erstellen des PCSC Context: \(mapErrorCode(ret))")
        }
    }
    
    // MARK: - Card Operations
    
    func powerOnCard() {
        guard isReaderConnected else {
            sendLog("Fehler: Kein Reader verbunden")
            return
        }
        
        sendLog("Schalte Karte ein...")
        
        // Get reader name
        guard let readerName = getReaderName() else {
            sendLog("Fehler: Kann Reader-Name nicht abrufen")
            return
        }
        
        sendLog("Verbinde mit Karte über Reader: \(readerName)")
        
        var cardHandle: SCARDHANDLE = 0
        var cardProtocol: UInt32 = 0
        
        let ret = readerName.withCString { readerCString in
            SCardConnect(
                scardContext,
                readerCString,
                SCARD_SHARE_SHARED,
                SCARD_PROTOCOL_T0 | SCARD_PROTOCOL_T1,
                &cardHandle,
                &cardProtocol
            )
        }
        
        if ret == SCARD_S_SUCCESS {
            scardHandle = cardHandle
            activeProtocol = cardProtocol
            sendLog("Karte eingeschaltet - Protokoll: T\(cardProtocol == SCARD_PROTOCOL_T0 ? "0" : "1")")
            
            channel?.invokeMethod("cardPoweredOn", arguments: [
                "protocol": cardProtocol == SCARD_PROTOCOL_T0 ? "T0" : "T1"
            ])
        } else {
            sendLog("Fehler beim Einschalten der Karte: \(mapErrorCode(ret))")
        }
    }
    
    func powerOffCard() {
        guard scardHandle != 0 else {
            sendLog("Keine Karte verbunden")
            return
        }
        
        sendLog("Schalte Karte aus...")
        
        let ret = SCardDisconnect(scardHandle, SCARD_LEAVE_CARD)
        
        if ret == SCARD_S_SUCCESS {
            scardHandle = 0
            sendLog("Karte ausgeschaltet")
            channel?.invokeMethod("cardPoweredOff", arguments: nil)
        } else {
            sendLog("Fehler beim Ausschalten der Karte: \(mapErrorCode(ret))")
        }
    }
    
    func getBatteryLevel() {
        sendLog("Batteriestand wird abgefragt...")
        
        // Send APDU command to query battery level
        // The SDK will asynchronously call didGetBattery() with the result
        if sendAPDU("0084000008") == nil {
            sendLog("Fehler: Batteriestand-Abfrage konnte nicht gesendet werden")
        }
    }
    
    // MARK: - APDU Communication
    
    private func sendAPDU(_ apduHex: String) -> [UInt8]? {
        guard scardHandle != 0 else {
            sendLog("Fehler: Keine Karte verbunden")
            return nil
        }
        
        // Convert hex string to bytes
        guard let apduBytes = hexStringToBytes(apduHex) else {
            sendLog("Fehler: Ungültiges APDU-Format: \(apduHex)")
            return nil
        }
        
        sendLog("→ APDU: \(apduHex)")
        
        var receiveBuffer = [UInt8](repeating: 0, count: 512)
        var receiveLength: UInt32 = UInt32(receiveBuffer.count)
        
        var ioRequest = SCARD_IO_REQUEST(cardProtocol: activeProtocol)
        
        let ret = apduBytes.withUnsafeBytes { apduPtr in
            receiveBuffer.withUnsafeMutableBytes { receivePtr in
                SCardTransmit(
                    scardHandle,
                    &ioRequest,
                    apduPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    UInt32(apduBytes.count),
                    nil,
                    receivePtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    &receiveLength
                )
            }
        }
        
        guard ret == SCARD_S_SUCCESS else {
            sendLog("Fehler beim Senden des APDU: \(mapErrorCode(ret))")
            return nil
        }
        
        let response = Array(receiveBuffer.prefix(Int(receiveLength)))
        let responseHex = bytesToHexString(response)
        sendLog("← Response: \(responseHex)")
        
        return response
    }
    
    // MARK: - EGK Card Reading
    
    func readEGKCard() {
        sendLog("=== Starte EGK-Kartenauslesung ===")
        
        guard isReaderConnected else {
            sendLog("Fehler: Kartenleser nicht verbunden")
            return
        }
        
        var egkData: [String: String] = [:]
        
        // 1. Select EGK Root
        guard selectEGKRoot() else {
            sendLog("Fehler: EGK Root nicht selektierbar")
            return
        }
        
        _ = readCardBufferSize()
        _ = readCardVersion()
        
        egkData["cardGeneration"] = cardGeneration
        egkData["schemaVersion"] = schemaVersion
        egkData["maxBufferSize"] = String(maxBufferSize)
        
        // 2. Select HCA and read patient data
        guard selectHCA() else {
            sendLog("Fehler: HCA nicht selektierbar")
            return
        }
        
        if let patientData = readPatientData() {
            egkData.merge(patientData) { _, new in new }
        }
        
        if let insuranceData = readInsuranceData() {
            egkData.merge(insuranceData) { _, new in new }
        }
        
        sendLog("=== EGK-Kartenauslesung abgeschlossen ===")
        
        // Send to Flutter
        DispatchQueue.main.async {
            self.channel?.invokeMethod("egkDataRead", arguments: egkData)
        }
    }
    
    private func selectEGKRoot() -> Bool {
        sendLog("Selektiere EGK Root...")
        guard let response = sendAPDU("00A4040C07D276000144800000") else {
            return false
        }
        return checkSW(response) == "9000"
    }
    
    private func selectHCA() -> Bool {
        sendLog("Selektiere HCA...")
        guard let response = sendAPDU("00A4040C06D27600000102") else {
            return false
        }
        return checkSW(response) == "9000"
    }
    
    private func readCardBufferSize() -> Bool {
        guard let response = sendAPDU("00B09D0000") else {
            return false
        }
        
        if response.count >= 4 {
            maxBufferSize = UInt16(response[0]) << 8 | UInt16(response[1])
            sendLog("Kartenpuffer: \(maxBufferSize) Bytes")
        }
        
        return true
    }
    
    private func readCardVersion() -> Bool {
        guard let response = sendAPDU("00B2028400") else {
            return false
        }
        
        if response.count > 2 {
            let versionData = response.prefix(response.count - 2)
            cardGeneration = String(bytes: versionData, encoding: .isoLatin1) ?? ""
            sendLog("Kartengeneration: \(cardGeneration)")
        }
        
        return true
    }
    
    private func readPatientData() -> [String: String]? {
        sendLog("Lese Patientendaten (PD)...")
        
        // Read PD length
        guard let lengthResponse = sendAPDU("00B081000200"),
              lengthResponse.count >= 4 else {
            return nil
        }
        
        let pdLength = Int(lengthResponse[0]) << 8 | Int(lengthResponse[1])
        sendLog("PD Länge: \(pdLength) Bytes")
        
        // Read PD data
        let hi = String(format: "%02X", (pdLength >> 8) & 0xFF)
        let lo = String(format: "%02X", pdLength & 0xFF)
        
        guard let pdData = sendAPDU("00B00002000\(hi)\(lo)"),
              pdData.count > 2 else {
            return nil
        }
        
        let dataWithoutSW = Array(pdData.dropLast(2))
        
        // Decompress GZIP
        guard let decompressed = decompressGZIP(dataWithoutSW) else {
            sendLog("Fehler: PD-Daten konnten nicht dekomprimiert werden")
            return nil
        }
        
        let xml = String(data: decompressed, encoding: .isoLatin1) ?? ""
        sendLog("PD XML dekomprimiert: \(xml.prefix(200))...")
        
        return parsePatientDataXML(xml)
    }
    
    private func readInsuranceData() -> [String: String]? {
        sendLog("Lese Versicherungsdaten (VD)...")
        
        // Read VD pointers
        guard let pointerResponse = sendAPDU("00B082000800"),
              pointerResponse.count >= 10 else {
            return nil
        }
        
        let vdLength = Int(pointerResponse[0]) << 8 | Int(pointerResponse[1])
        sendLog("VD Länge: \(vdLength) Bytes")
        
        // Read VD data
        let hi = String(format: "%02X", (vdLength >> 8) & 0xFF)
        let lo = String(format: "%02X", vdLength & 0xFF)
        
        guard let vdData = sendAPDU("00B00008000\(hi)\(lo)"),
              vdData.count > 2 else {
            return nil
        }
        
        let dataWithoutSW = Array(vdData.dropLast(2))
        
        // Decompress GZIP
        guard let decompressed = decompressGZIP(dataWithoutSW) else {
            sendLog("Fehler: VD-Daten konnten nicht dekomprimiert werden")
            return nil
        }
        
        let xml = String(data: decompressed, encoding: .isoLatin1) ?? ""
        sendLog("VD XML dekomprimiert: \(xml.prefix(200))...")
        
        return parseInsuranceDataXML(xml)
    }
    
    // MARK: - GZIP Decompression
    // Ersetzen Sie die decompressGZIP Funktion (ab Zeile ~470) mit dieser korrigierten Version:

// MARK: - GZIP Decompression

private func decompressGZIP(_ data: [UInt8]) -> Data? {
    // Find GZIP header (1F 8B 08 00)
    let gzipHeader: [UInt8] = [0x1F, 0x8B, 0x08, 0x00]
    
    var gzipStart: Int?
    for i in 0..<(data.count - 3) {
        if data[i] == gzipHeader[0] &&
           data[i+1] == gzipHeader[1] &&
           data[i+2] == gzipHeader[2] &&
           data[i+3] == gzipHeader[3] {
            gzipStart = i
            break
        }
    }
    
    guard let startIndex = gzipStart else {
        sendLog("GZIP-Header nicht gefunden")
        return nil
    }
    
    let gzipData = Array(data[startIndex...])
    
    var stream = z_stream()
    stream.avail_in = UInt32(gzipData.count)
    
    var result = Data()
    
    gzipData.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
        stream.next_in = UnsafeMutablePointer<Bytef>(mutating: bytes.baseAddress!.assumingMemoryBound(to: Bytef.self))
        
        let ret = inflateInit2_(&stream, MAX_WBITS + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        
        guard ret == Z_OK else {
            sendLog("inflateInit2 Fehler: \(ret)")
            return
        }
        
        var buffer = [UInt8](repeating: 0, count: 32768)
        
        repeat {
            stream.avail_out = UInt32(buffer.count)
            buffer.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
                stream.next_out = bytes.baseAddress!.assumingMemoryBound(to: Bytef.self)
            }
            
            let ret = inflate(&stream, Z_SYNC_FLUSH)
            
            let have = buffer.count - Int(stream.avail_out)
            result.append(contentsOf: buffer.prefix(have))
            
            if ret == Z_STREAM_END {
                break
            }
            
            guard ret == Z_OK else {
                sendLog("inflate Fehler: \(ret)")
                break
            }
            
        } while stream.avail_out == 0
        
        inflateEnd(&stream)
    }
    
    return result.isEmpty ? nil : result
}
    
    // MARK: - XML Parsing
    
    private func parsePatientDataXML(_ xml: String) -> [String: String] {
        var result: [String: String] = [:]
        
        result["vorname"] = extractXMLValue(xml, tag: "Vorname") ?? ""
        result["nachname"] = extractXMLValue(xml, tag: "Nachname") ?? ""
        result["geburtsdatum"] = extractXMLValue(xml, tag: "Geburtsdatum") ?? ""
        result["strasse"] = extractXMLValue(xml, tag: "Strasse") ?? ""
        result["hausnummer"] = extractXMLValue(xml, tag: "Hausnummer") ?? ""
        result["plz"] = extractXMLValue(xml, tag: "Postleitzahl") ?? ""
        result["ort"] = extractXMLValue(xml, tag: "Ort") ?? ""
        
        sendLog("Patientendaten geparst: \(result.count) Felder")
        return result
    }
    
    private func parseInsuranceDataXML(_ xml: String) -> [String: String] {
        var result: [String: String] = [:]
        
        result["versichertennummer"] = extractXMLValue(xml, tag: "Versicherten_ID") ?? ""
        result["krankenkasse"] = extractXMLValue(xml, tag: "Kostentraegerkennung") ?? ""
        result["versichertenstatus"] = extractXMLValue(xml, tag: "Versicherungsschutz") ?? ""
        result["ablaufdatum"] = extractXMLValue(xml, tag: "Ende") ?? ""
        
        sendLog("Versicherungsdaten geparst: \(result.count) Felder")
        return result
    }
    
    private func extractXMLValue(_ xml: String, tag: String) -> String? {
        let openTag = "<\(tag)>"
        let closeTag = "</\(tag)>"
        
        guard let startRange = xml.range(of: openTag),
              let endRange = xml.range(of: closeTag, range: startRange.upperBound..<xml.endIndex) else {
            return nil
        }
        
        let value = String(xml[startRange.upperBound..<endRange.lowerBound])
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // MARK: - Helper Functions
    
    private func getReaderName() -> String? {
        var readerLen: UInt32 = 0
        
        // Get required buffer size
        var ret = SCardListReaders(scardContext, nil, nil, &readerLen)
        
        guard ret == SCARD_S_SUCCESS, readerLen > 0 else {
            return nil
        }
        
        // Allocate buffer
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(readerLen))
        defer { buffer.deallocate() }
        
        // Get reader names
        ret = SCardListReaders(scardContext, nil, buffer, &readerLen)
        
        guard ret == SCARD_S_SUCCESS else {
            return nil
        }
        
        return String(cString: buffer)
    }
    
    private func checkSW(_ response: [UInt8]) -> String {
        guard response.count >= 2 else { return "" }
        let sw1 = response[response.count - 2]
        let sw2 = response[response.count - 1]
        return String(format: "%02X%02X", sw1, sw2)
    }
    
    private func hexStringToBytes(_ hex: String) -> [UInt8]? {
        let cleaned = hex.replacingOccurrences(of: " ", with: "")
        guard cleaned.count % 2 == 0 else { return nil }
        
        var bytes = [UInt8]()
        var index = cleaned.startIndex
        
        while index < cleaned.endIndex {
            let nextIndex = cleaned.index(index, offsetBy: 2)
            let byteString = cleaned[index..<nextIndex]
            guard let byte = UInt8(byteString, radix: 16) else { return nil }
            bytes.append(byte)
            index = nextIndex
        }
        
        return bytes
    }
    
    private func bytesToHexString(_ bytes: [UInt8]) -> String {
        return bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
    
private func mapErrorCode(_ errorCode: Int32) -> String {
    let unsignedCode = UInt32(bitPattern: errorCode)
    
    switch unsignedCode {
    case 0x00000000: return "Success"
    case 0x80100004: return "Invalid parameter"
    case 0x8010000C: return "No smart card inserted"
    case 0x8010000D: return "Unknown card"
    case 0x80100017: return "Reader unavailable"
    case 0x8010000A: return "Timeout"
    case 0x80100069: return "Card removed"
    default: return String(format: "Error 0x%08X", unsignedCode)
    }
}
    
    private func sendLog(_ message: String) {
        print("FEITIAN: \(message)")
        channel?.invokeMethod("log", arguments: message)
    }
}

// MARK: - ReaderInterfaceDelegate Implementation
extension FeitianCardManager: ReaderInterfaceDelegate {
    
    func findPeripheralReader(_ readerName: String) {
        sendLog("Gerät gefunden: \(readerName)")
        
        // Notify Flutter
        // Note: RSSI (signal strength) is not available through the ReaderInterface API
        // The SDK only provides device name. Setting rssi to 0 as a placeholder.
        channel?.invokeMethod("deviceFound", arguments: [
            "name": readerName,
            "rssi": 0
        ])
    }
    
    func readerInterfaceDidChange(_ attached: Bool, bluetoothID: String, andslotnameArray slotArray: [String]) {
        if attached {
            sendLog("Reader verbunden: \(bluetoothID)")
            sendLog("Verfügbare Slots: \(slotArray)")
            
            isReaderConnected = true
            connectedReaderName = bluetoothID
            
            // Establish PCSC context
            if scardContext == 0 {
                establishContext()
            }
            
            // Notify Flutter
            channel?.invokeMethod("readerConnected", arguments: [
                "deviceName": bluetoothID,
                "connected": true,
                "slots": slotArray
            ])
            
        } else {
            sendLog("Reader getrennt")
            
            isReaderConnected = false
            
            // Cleanup
            if scardHandle != 0 {
                SCardDisconnect(scardHandle, SCARD_LEAVE_CARD)
                scardHandle = 0
            }
            
            if scardContext != 0 {
                SCardReleaseContext(scardContext)
                scardContext = 0
            }
            
            // Notify Flutter
            channel?.invokeMethod("readerDisconnected", arguments: nil)
        }
    }
    
    func cardInterfaceDidDetach(_ attached: Bool, slotname: String) {
        if attached {
            sendLog("Karte erkannt in Slot: \(slotname)")
            
            channel?.invokeMethod("cardConnected", arguments: [
                "slot": slotname
            ])
            
        } else {
            sendLog("Karte entfernt aus Slot: \(slotname)")
            
            if scardHandle != 0 {
                SCardDisconnect(scardHandle, SCARD_LEAVE_CARD)
                scardHandle = 0
            }
            
            channel?.invokeMethod("cardDisconnected", arguments: nil)
        }
    }
    
    func didGetBattery(_ battery: Int) {
        sendLog("Batterie: \(battery)%")
        
        channel?.invokeMethod("batteryLevel", arguments: [
            "level": battery
        ])
    }
}
