import Flutter
import Foundation
import Compression

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

@_silgen_name("FtGetReaderName")
func FtGetReaderName(_ hContext: SCARDCONTEXT, _ pcchReaderLen: UnsafeMutablePointer<UInt32>, _ szReaderName: UnsafeMutablePointer<CChar>) -> Int32

@_silgen_name("FtSetTimeout")
func FtSetTimeout(_ hContext: SCARDCONTEXT, _ timeout: UInt32) -> Int32

// MARK: - FEITIAN BLE Function Declarations
@_silgen_name("ft_ble_seach")
func ft_ble_seach() -> Int32

@_silgen_name("ft_ble_seach_stop")
func ft_ble_seach_stop()

@_silgen_name("ft_ble_connect")
func ft_ble_connect(_ deviceName: UnsafePointer<CChar>) -> Int32

@_silgen_name("ft_ble_disconnect")
func ft_ble_disconnect()

@_silgen_name("ft_ble_getbattery")
func ft_ble_getbattery() -> Int32

// MARK: - EGK Card Manager
/// Vollständige FEITIAN Card Manager Implementierung für EGK-Kartenauslesung
/// Basiert auf FEITIAN iReader Demo und PCSC/APDU-Workflow
class FeitianCardManager {
    static let shared = FeitianCardManager()
    
    private var channel: FlutterMethodChannel?
    
    // PCSC Handles
    private var contextHandle: SCARDCONTEXT = 0
    private var cardHandle: SCARDHANDLE = 0
    private var activeProtocol: UInt32 = 0
    
    // Zustands-Flags
    private var isReaderConnected: Bool = false
    private var isCardConnected: Bool = false
    
    // EGK Karten-Informationen
    private var maxBufferSize: Int = 1024  // Sicherer Standardwert
    private var cardGeneration: String = ""
    private var schemaVersion: String = ""
    
    private init() {}
    
    func initialize(channel: FlutterMethodChannel) {
        self.channel = channel
        sendLog("FEITIAN Kartenleser Plugin initialisiert")
    }
    
    // MARK: - Bluetooth Scanner Integration
    
    /// Startet Bluetooth-Scan nach FEITIAN Geräten
    func startBluetoothScan() {
        sendLog("Starte Bluetooth-Scan...")
        
        let ret = ft_ble_seach()
        if ret == 0 {
            sendLog("Bluetooth-Scan gestartet")
        } else {
            sendLog("Fehler beim Starten des Bluetooth-Scans: \(ret)")
        }
    }
    
    /// Stoppt Bluetooth-Scan
    func stopBluetoothScan() {
        sendLog("Stoppe Bluetooth-Scan...")
        ft_ble_seach_stop()
        sendLog("Bluetooth-Scan gestoppt")
    }
    
    /// Verbindet mit einem FEITIAN Bluetooth-Gerät
    func connectToReader(deviceName: String) {
        sendLog("Verbinde mit Gerät: \(deviceName)")
        
        deviceName.withCString { cString in
            let ret = ft_ble_connect(cString)
            if ret == 0 {
                sendLog("Bluetooth-Verbindung erfolgreich")
                isReaderConnected = true
                
                // Establish PCSC context
                establishContext()
                
                // Benachrichtige Flutter
                DispatchQueue.main.async {
                    self.channel?.invokeMethod("readerConnected", arguments: ["name": deviceName])
                }
            } else {
                sendLog("Fehler bei Bluetooth-Verbindung: \(ret)")
            }
        }
    }
    
    /// Trennt Verbindung zum Kartenleser
    func disconnectReader() {
        sendLog("Trenne Kartenleser...")
        
        // Karte ausschalten falls noch verbunden
        if isCardConnected {
            powerOffCard()
        }
        
        // PCSC Context freigeben
        releaseContext()
        
        // Bluetooth trennen
        ft_ble_disconnect()
        isReaderConnected = false
        
        sendLog("Kartenleser getrennt")
        
        // Benachrichtige Flutter
        DispatchQueue.main.async {
            self.channel?.invokeMethod("readerDisconnected", arguments: nil)
        }
    }
    
    /// Liest Batterie-Status
    func getBatteryLevel() {
        guard isReaderConnected else {
            sendLog("Fehler: Kartenleser nicht verbunden")
            return
        }
        
        let batteryLevel = ft_ble_getbattery()
        sendLog("Batterie-Status: \(batteryLevel)%")
        
        DispatchQueue.main.async {
            self.channel?.invokeMethod("batteryLevel", arguments: ["level": Int(batteryLevel)])
        }
    }
    
    // MARK: - PCSC Context Management
    
    /// Initialisiert PCSC-Kontext
    private func establishContext() {
        sendLog("Initialisiere PCSC-Kontext...")
        
        var context: SCARDCONTEXT = 0
        let ret = SCardEstablishContext(SCARD_SCOPE_SYSTEM, nil, nil, &context)
        
        if ret == SCARD_S_SUCCESS {
            contextHandle = context
            // Setze Timeout auf 50 Sekunden
            _ = FtSetTimeout(contextHandle, 50000)
            sendLog("PCSC-Kontext erfolgreich initialisiert")
        } else {
            sendLog("Fehler beim Initialisieren des PCSC-Kontexts: \(mapErrorCode(ret))")
        }
    }
    
    /// Gibt PCSC-Kontext frei
    private func releaseContext() {
        guard contextHandle != 0 else { return }
        
        sendLog("Gebe PCSC-Kontext frei...")
        let ret = SCardReleaseContext(contextHandle)
        
        if ret == SCARD_S_SUCCESS {
            contextHandle = 0
            sendLog("PCSC-Kontext freigegeben")
        } else {
            sendLog("Fehler beim Freigeben des PCSC-Kontexts: \(mapErrorCode(ret))")
        }
    }
    
    // MARK: - Card Connection
    
    /// Stellt Verbindung zur Karte her
    private func connectCard() -> Bool {
        sendLog("Verbinde mit Karte...")
        
        guard contextHandle != 0 else {
            sendLog("Fehler: Kein PCSC-Kontext vorhanden")
            return false
        }
        
        // Reader-Name abrufen
        var readerNameLength: UInt32 = 256
        var readerNameBuffer = [CChar](repeating: 0, count: Int(readerNameLength))
        
        let nameRet = FtGetReaderName(contextHandle, &readerNameLength, &readerNameBuffer)
        guard nameRet == SCARD_S_SUCCESS else {
            sendLog("Fehler beim Abrufen des Reader-Namens: \(mapErrorCode(nameRet))")
            return false
        }
        
        let readerName = String(cString: readerNameBuffer)
        sendLog("Reader-Name: \(readerName)")
        
        // Karte verbinden
        var card: SCARDHANDLE = 0
        var cardProtocol: UInt32 = 0
        
        let ret = SCardConnect(
            contextHandle,
            readerNameBuffer,
            SCARD_SHARE_SHARED,
            SCARD_PROTOCOL_T0 | SCARD_PROTOCOL_T1,
            &card,
            &cardProtocol
        )
        
        if ret == SCARD_S_SUCCESS {
            cardHandle = card
            activeProtocol = cardProtocol
            isCardConnected = true
            sendLog("Karte verbunden (Protokoll: T\(cardProtocol == SCARD_PROTOCOL_T1 ? "1" : "0"))")
            
            // Benachrichtige Flutter
            DispatchQueue.main.async {
                self.channel?.invokeMethod("cardConnected", arguments: nil)
            }
            return true
        } else {
            sendLog("Fehler beim Verbinden der Karte: \(mapErrorCode(ret))")
            return false
        }
    }
    
    /// Trennt Verbindung zur Karte
    private func disconnectCard() {
        guard cardHandle != 0 else { return }
        
        sendLog("Trenne Karte...")
        let ret = SCardDisconnect(cardHandle, SCARD_LEAVE_CARD)
        
        if ret == SCARD_S_SUCCESS {
            cardHandle = 0
            isCardConnected = false
            sendLog("Karte getrennt")
            
            // Benachrichtige Flutter
            DispatchQueue.main.async {
                self.channel?.invokeMethod("cardDisconnected", arguments: nil)
            }
        } else {
            sendLog("Fehler beim Trennen der Karte: \(mapErrorCode(ret))")
        }
    }
    
    // MARK: - APDU Transmission
    
    /// Sendet APDU-Befehl und gibt Response zurück
    private func transmitApdu(_ apdu: [UInt8]) -> [UInt8]? {
        guard cardHandle != 0 else {
            sendLog("Fehler: Keine Kartenverbindung")
            return nil
        }
        
        var recvBuffer = [UInt8](repeating: 0, count: 2048 + 128)
        var recvLength: UInt32 = UInt32(recvBuffer.count)
        
        var pioSendPci = SCARD_IO_REQUEST(cardProtocol: activeProtocol)
        
        let ret = apdu.withUnsafeBufferPointer { apduPtr in
            recvBuffer.withUnsafeMutableBufferPointer { recvPtr in
                SCardTransmit(
                    cardHandle,
                    &pioSendPci,
                    apduPtr.baseAddress!,
                    UInt32(apdu.count),
                    nil,
                    recvPtr.baseAddress!,
                    &recvLength
                )
            }
        }
        
        if ret == SCARD_S_SUCCESS {
            let response = Array(recvBuffer.prefix(Int(recvLength)))
            sendLog("APDU: \(toHex(apdu)) -> \(toHex(response))")
            return response
        } else {
            sendLog("Fehler bei APDU-Übertragung: \(mapErrorCode(ret))")
            return nil
        }
    }
    
    /// Prüft ob APDU Response erfolgreich ist (SW1 SW2 = 9000)
    private func isApduSuccess(_ response: [UInt8]) -> Bool {
        guard response.count >= 2 else { return false }
        let sw1 = response[response.count - 2]
        let sw2 = response[response.count - 1]
        return sw1 == 0x90 && sw2 == 0x00
    }
    
    /// Extrahiert SW1 SW2 aus Response
    private func getStatusWord(_ response: [UInt8]) -> String {
        guard response.count >= 2 else { return "----" }
        let sw1 = response[response.count - 2]
        let sw2 = response[response.count - 1]
        return String(format: "%02X%02X", sw1, sw2)
    }
    
    // MARK: - CT-API Card Terminal Commands
    
    /// Reset CT - Zurücksetzen des Kartenterminals
    /// APDU: 20 11 00 00 00
    private func resetCardTerminal() -> Bool {
        sendLog("Setze Kartenterminal zurück...")
        
        let apdu: [UInt8] = [0x20, 0x11, 0x00, 0x00, 0x00]
        guard let response = transmitApdu(apdu) else {
            sendLog("Fehler: Keine Response vom Terminal")
            return false
        }
        
        let sw = getStatusWord(response)
        if sw == "9000" {
            sendLog("Kartenterminal erfolgreich zurückgesetzt")
            return true
        } else if sw == "6400" {
            sendLog("Fehler beim Zurücksetzen des Terminals")
            return false
        } else {
            sendLog("Unerwartete Response: \(sw)")
            return false
        }
    }
    
    /// Request ICC - Karte anfordern mit 1 Sekunde Timeout
    /// APDU: 20 12 01 00 01 05
    private func requestCard() -> Bool {
        sendLog("Fordere Karte an...")
        
        let apdu: [UInt8] = [0x20, 0x12, 0x01, 0x00, 0x01, 0x05]
        guard let response = transmitApdu(apdu) else {
            sendLog("Fehler: Keine Response beim Anfordern der Karte")
            return false
        }
        
        let sw = getStatusWord(response)
        if sw == "9000" {
            sendLog("Karte vorhanden")
            return true
        } else if sw == "6200" {
            sendLog("Keine Karte vorhanden")
            return false
        } else if sw == "6400" {
            sendLog("Reset fehlgeschlagen")
            return false
        } else {
            sendLog("Unerwartete Response: \(sw)")
            return false
        }
    }
    
    /// Eject ICC - Karte auswerfen mit Signalisierung
    /// APDU: 20 15 01 00 01 05
    private func ejectCard() -> Bool {
        sendLog("Werfe Karte aus...")
        
        let apdu: [UInt8] = [0x20, 0x15, 0x01, 0x00, 0x01, 0x05]
        guard let response = transmitApdu(apdu) else {
            sendLog("Fehler: Keine Response beim Auswerfen")
            return false
        }
        
        let sw = getStatusWord(response)
        if sw == "9000" || sw == "9001" {
            sendLog("Karte ausgeworfen")
            return true
        } else if sw == "6200" {
            sendLog("Warnung beim Auswerfen")
            return true
        } else {
            sendLog("Fehler beim Auswerfen: \(sw)")
            return false
        }
    }
    
    // MARK: - EGK Root Reading
    
    /// Select EGK Root - Selektierung des EGK Root Verzeichnisses
    /// APDU: 00 A4 04 0C 07 D2 76 00 01 44 80 00
    private func selectEGKRoot() -> Bool {
        sendLog("Selektiere EGK Root...")
        
        let apdu: [UInt8] = [0x00, 0xA4, 0x04, 0x0C, 0x07, 0xD2, 0x76, 0x00, 0x01, 0x44, 0x80, 0x00]
        guard let response = transmitApdu(apdu), isApduSuccess(response) else {
            sendLog("Fehler beim Selektieren von EGK Root")
            return false
        }
        
        sendLog("EGK Root selektiert")
        return true
    }
    
    /// Liest EF.ATR - Maximale Puffergröße für APDU-Antworten
    /// APDU: 00 B0 9D 00 00
    private func readCardBufferSize() -> Bool {
        sendLog("Lese Kartenpuffergröße (EF.ATR)...")
        
        let apdu: [UInt8] = [0x00, 0xB0, 0x9D, 0x00, 0x00]
        guard let response = transmitApdu(apdu), isApduSuccess(response) else {
            sendLog("Fehler beim Lesen von EF.ATR")
            return false
        }
        
        // Bytes 12-13 enthalten die maximale Länge
        guard response.count >= 15 else {
            sendLog("EF.ATR Response zu kurz")
            return false
        }
        
        let maxLen = Int(response[12]) << 8 | Int(response[13])
        maxBufferSize = maxLen - 2  // Minus SW1/SW2
        
        sendLog("Maximale Puffergröße: \(maxBufferSize) Bytes")
        return true
    }
    
    /// Liest EF.VERSION - Kartengeneration
    /// APDU: 00 B2 02 84 00
    private func readCardVersion() -> Bool {
        sendLog("Lese Kartenversion (EF.VERSION)...")
        
        let apdu: [UInt8] = [0x00, 0xB2, 0x02, 0x84, 0x00]
        guard let response = transmitApdu(apdu), isApduSuccess(response) else {
            sendLog("Fehler beim Lesen von EF.VERSION")
            return false
        }
        
        // Parse BCD-gepackte Version aus Bytes 1, 2, 4
        guard response.count >= 5 else {
            sendLog("EF.VERSION Response zu kurz")
            return false
        }
        
        let byte1 = response[1]
        let byte2 = response[2]
        let byte4 = response[4]
        
        let versionCode = "\(String(format: "%02X", byte1))\(String(format: "%02X", byte2))\(String(format: "%02X", byte4))"
        
        // Mapping zu Generation
        switch versionCode {
        case "400000":
            cardGeneration = "G2"
        case "300001", "300003":
            cardGeneration = "G1Plus"
        case "300002":
            cardGeneration = "G1"
        case "300000":
            cardGeneration = "G1Plus/G1"
        default:
            cardGeneration = "Unknown (\(versionCode))"
        }
        
        sendLog("Kartengeneration: \(cardGeneration)")
        return true
    }
    
    /// Liest EF.StatusVD - Schema-Version der XML-Dateien
    /// APDU: 00 B0 8C 00 19
    private func readSchemaVersion() -> Bool {
        sendLog("Lese Schema-Version (EF.StatusVD)...")
        
        let apdu: [UInt8] = [0x00, 0xB0, 0x8C, 0x00, 0x19]
        guard let response = transmitApdu(apdu), isApduSuccess(response) else {
            sendLog("Fehler beim Lesen von EF.StatusVD")
            return false
        }
        
        // Parse Bytes 16, 17, 19
        guard response.count >= 20 else {
            sendLog("EF.StatusVD Response zu kurz")
            return false
        }
        
        schemaVersion = "\(response[16]).\(response[17]).\(response[19])"
        sendLog("Schema-Version: \(schemaVersion)")
        return true
    }
    
    // MARK: - HCA Reading (Patient and Insurance Data)
    
    /// Select HCA - Selektierung der Health Care Application
    /// APDU: 00 A4 04 0C 06 D2 76 00 00 01 02
    private func selectHCA() -> Bool {
        sendLog("Selektiere HCA...")
        
        let apdu: [UInt8] = [0x00, 0xA4, 0x04, 0x0C, 0x06, 0xD2, 0x76, 0x00, 0x00, 0x01, 0x02]
        guard let response = transmitApdu(apdu) else {
            sendLog("Fehler beim Selektieren von HCA: Keine Response")
            return false
        }
        
        let sw = getStatusWord(response)
        if sw == "9000" {
            sendLog("HCA selektiert")
            return true
        } else if sw == "6A82" {
            sendLog("HCA nicht gefunden")
            return false
        } else {
            sendLog("Fehler beim Selektieren von HCA: \(sw)")
            return false
        }
    }
    
    /// Liest EF.PD - Patientendaten
    private func readPatientData() -> [String: String]? {
        sendLog("Lese Patientendaten (EF.PD)...")
        
        // Schritt 1: Länge ermitteln (APDU: 00 B0 81 00 02)
        let lengthApdu: [UInt8] = [0x00, 0xB0, 0x81, 0x00, 0x02]
        guard let lengthResponse = transmitApdu(lengthApdu), isApduSuccess(lengthResponse) else {
            sendLog("Fehler beim Lesen der PD-Länge")
            return nil
        }
        
        guard lengthResponse.count >= 4 else {
            sendLog("PD-Längen-Response zu kurz")
            return nil
        }
        
        let containerLength = Int(lengthResponse[0]) << 8 | Int(lengthResponse[1])
        sendLog("PD Container-Länge: \(containerLength) Bytes")
        
        // Validiere Container-Länge
        guard containerLength > 0 && containerLength <= 65535 else {
            sendLog("Ungültige Container-Länge: \(containerLength)")
            return nil
        }
        
        // Prüfe gegen maxBufferSize
        guard containerLength <= maxBufferSize else {
            sendLog("Container-Länge (\(containerLength)) überschreitet max. Puffergröße (\(maxBufferSize))")
            return nil
        }
        
        // Schritt 2: Daten lesen (APDU: 00 B0 00 02 [Länge])
        // Extended Length APDU: 00 B0 00 02 00 [LenHi] [LenLo]
        let lenHi = UInt8((containerLength >> 8) & 0xFF)
        let lenLo = UInt8(containerLength & 0xFF)
        let dataApdu: [UInt8] = [0x00, 0xB0, 0x00, 0x02, 0x00, lenHi, lenLo]
        
        guard let dataResponse = transmitApdu(dataApdu), isApduSuccess(dataResponse) else {
            sendLog("Fehler beim Lesen der PD-Daten")
            return nil
        }
        
        // Entferne SW1/SW2
        let rawData = Array(dataResponse.dropLast(2))
        sendLog("PD Rohdaten gelesen: \(rawData.count) Bytes")
        
        // Schritt 3: GZIP dekomprimieren
        guard let xmlString = decompressGzip(rawData) else {
            sendLog("Fehler beim Dekomprimieren der PD-Daten")
            return nil
        }
        
        sendLog("PD XML dekomprimiert: \(xmlString.count) Zeichen")
        
        // Parse XML
        return parsePatientXML(xmlString)
    }
    
    /// Liest EF.VD - Versicherungsdaten
    private func readInsuranceData() -> [String: String]? {
        sendLog("Lese Versicherungsdaten (EF.VD)...")
        
        // Schritt 1: Zeiger auslesen (APDU: 00 B0 82 00 08)
        let pointerApdu: [UInt8] = [0x00, 0xB0, 0x82, 0x00, 0x08]
        guard let pointerResponse = transmitApdu(pointerApdu), isApduSuccess(pointerResponse) else {
            sendLog("Fehler beim Lesen der VD-Zeiger")
            return nil
        }
        
        guard pointerResponse.count >= 10 else {
            sendLog("VD-Zeiger-Response zu kurz")
            return nil
        }
        
        let vdStart = Int(pointerResponse[0]) << 8 | Int(pointerResponse[1])
        let vdEnd = Int(pointerResponse[2]) << 8 | Int(pointerResponse[3])
        let vdLength = vdEnd - vdStart
        
        sendLog("VD Start: \(vdStart), Ende: \(vdEnd), Länge: \(vdLength)")
        
        // Validiere VD-Länge
        guard vdLength > 0 && vdLength <= 65535 else {
            sendLog("Ungültige VD-Länge: \(vdLength)")
            return nil
        }
        
        // Prüfe gegen maxBufferSize
        guard vdLength <= maxBufferSize else {
            sendLog("VD-Länge (\(vdLength)) überschreitet max. Puffergröße (\(maxBufferSize))")
            return nil
        }
        
        // Schritt 2: Daten lesen (APDU: 00 B0 00 08 [VD-Länge])
        let lenHi = UInt8((vdLength >> 8) & 0xFF)
        let lenLo = UInt8(vdLength & 0xFF)
        let dataApdu: [UInt8] = [0x00, 0xB0, 0x00, 0x08, 0x00, lenHi, lenLo]
        
        guard let dataResponse = transmitApdu(dataApdu), isApduSuccess(dataResponse) else {
            sendLog("Fehler beim Lesen der VD-Daten")
            return nil
        }
        
        // Entferne SW1/SW2
        let rawData = Array(dataResponse.dropLast(2))
        sendLog("VD Rohdaten gelesen: \(rawData.count) Bytes")
        
        // Schritt 3: GZIP dekomprimieren
        guard let xmlString = decompressGzip(rawData) else {
            sendLog("Fehler beim Dekomprimieren der VD-Daten")
            return nil
        }
        
        sendLog("VD XML dekomprimiert: \(xmlString.count) Zeichen")
        
        // Parse XML
        return parseInsuranceXML(xmlString)
    }
    
    // MARK: - GZIP Decompression
    
    /// Dekomprimiert GZIP-Daten
    private func decompressGzip(_ data: [UInt8]) -> String? {
        // Suche nach GZIP-Header (1F 8B 08 00)
        guard let gzipStart = findGzipHeader(data) else {
            sendLog("GZIP-Header nicht gefunden")
            return nil
        }
        
        sendLog("GZIP-Header gefunden bei Offset \(gzipStart)")
        let gzipData = Array(data[gzipStart...])
        
        // Dekomprimiere mit NSData
        let nsData = Data(gzipData)
        guard let decompressed = try? nsData.gunzipped() else {
            sendLog("GZIP-Dekomprimierung fehlgeschlagen")
            return nil
        }
        
        // Dekodiere als ISO-8859-15 (Latin-1)
        if let xmlString = String(data: decompressed, encoding: .isoLatin1) {
            sendLog("XML dekodiert mit ISO-8859-15 Encoding")
            return xmlString
        } else if let xmlString = String(data: decompressed, encoding: .utf8) {
            // Fallback zu UTF-8
            sendLog("XML dekodiert mit UTF-8 Encoding (Fallback)")
            return xmlString
        } else {
            sendLog("XML-Dekodierung fehlgeschlagen")
            return nil
        }
    }
    
    /// Sucht GZIP-Header (1F 8B 08 00) in Daten
    private func findGzipHeader(_ data: [UInt8]) -> Int? {
        let header: [UInt8] = [0x1F, 0x8B, 0x08, 0x00]
        
        for i in 0..<(data.count - header.count + 1) {
            var match = true
            for j in 0..<header.count {
                if data[i + j] != header[j] {
                    match = false
                    break
                }
            }
            if match {
                return i
            }
        }
        
        return nil
    }
    
    // MARK: - XML Parsing
    
    /// Parse Patientendaten aus XML
    private func parsePatientXML(_ xml: String) -> [String: String] {
        var result: [String: String] = [:]
        
        result["lastName"] = extractXMLValue(xml, tag: "Name") ?? ""
        result["firstName"] = extractXMLValue(xml, tag: "Vorname") ?? ""
        result["geburtsdatum"] = extractXMLValue(xml, tag: "Geburtsdatum") ?? ""
        result["geschlecht"] = extractXMLValue(xml, tag: "Geschlecht") ?? ""
        result["persoenlicheKennnummer"] = extractXMLValue(xml, tag: "Versicherten_ID") ?? ""
        
        sendLog("Patientendaten geparst: \(result.count) Felder")
        return result
    }
    
    /// Parse Versicherungsdaten aus XML
    private func parseInsuranceXML(_ xml: String) -> [String: String] {
        var result: [String: String] = [:]
        
        result["kennnummerDerKarte"] = extractXMLValue(xml, tag: "Versichertennummer") ?? ""
        result["kennnummerDesTraegers"] = extractXMLValue(xml, tag: "Kostentraegerkennung") ?? ""
        result["nameDesTraegers"] = extractXMLValue(xml, tag: "Name") ?? ""
        result["ablaufdatum"] = extractXMLValue(xml, tag: "Ende") ?? ""
        
        sendLog("Versicherungsdaten geparst: \(result.count) Felder")
        return result
    }
    
    /// Extrahiert Wert aus XML-Tag
    /// Hinweis: Einfaches String-Matching für EGK-XML-Daten.
    /// Funktioniert für die standardisierten EGK-XML-Strukturen.
    /// Für komplexere XML-Strukturen sollte ein vollständiger XML-Parser verwendet werden.
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
    
    // MARK: - Complete EGK Reading Workflow
    
    /// Hauptmethode zum Auslesen der EGK-Karte
    func readEGKCard() {
        sendLog("=== Starte EGK-Kartenauslesung ===")
        
        guard isReaderConnected else {
            sendLog("Fehler: Kartenleser nicht verbunden")
            return
        }
        
        // Kombiniere alle Daten
        var egkData: [String: String] = [:]
        
        // 1. Selektiere EGK Root und lese Basis-Informationen
        guard selectEGKRoot() else {
            sendLog("EGK-Auslesung abgebrochen: EGK Root nicht selektierbar")
            return
        }
        
        _ = readCardBufferSize()
        _ = readCardVersion()
        _ = readSchemaVersion()
        
        egkData["cardGeneration"] = cardGeneration
        egkData["schemaVersion"] = schemaVersion
        egkData["maxBufferSize"] = String(maxBufferSize)
        
        // 2. Selektiere HCA und lese Patientendaten
        guard selectHCA() else {
            sendLog("EGK-Auslesung abgebrochen: HCA nicht selektierbar")
            return
        }
        
        if let patientData = readPatientData() {
            egkData.merge(patientData) { _, new in new }
        } else {
            sendLog("Warnung: Patientendaten konnten nicht gelesen werden")
        }
        
        // 3. Lese Versicherungsdaten
        if let insuranceData = readInsuranceData() {
            egkData.merge(insuranceData) { _, new in new }
        } else {
            sendLog("Warnung: Versicherungsdaten konnten nicht gelesen werden")
        }
        
        sendLog("=== EGK-Kartenauslesung abgeschlossen ===")
        sendLog("Gelesene Daten: \(egkData.keys.joined(separator: ", "))")
        
        // Sende Daten an Flutter
        DispatchQueue.main.async {
            self.channel?.invokeMethod("egkDataRead", arguments: egkData)
        }
    }
    
    /// Schaltet Karte ein (vollständiger Ablauf)
    func powerOnCard() {
        sendLog("=== Schalte Karte ein ===")
        
        guard isReaderConnected else {
            sendLog("Fehler: Kartenleser nicht verbunden")
            return
        }
        
        // 1. Stelle Kartenverbindung her
        guard connectCard() else {
            sendLog("Fehler: Kartenverbindung konnte nicht hergestellt werden")
            return
        }
        
        // 2. Reset Card Terminal
        guard resetCardTerminal() else {
            sendLog("Warnung: Kartenterminal konnte nicht zurückgesetzt werden")
        }
        
        // 3. Request Card
        guard requestCard() else {
            sendLog("Fehler: Karte konnte nicht angefordert werden")
            disconnectCard()
            return
        }
        
        sendLog("Karte erfolgreich eingeschaltet und bereit")
        
        // Starte automatisch EGK-Auslesung
        readEGKCard()
    }
    
    /// Schaltet Karte aus (vollständiger Ablauf)
    func powerOffCard() {
        sendLog("=== Schalte Karte aus ===")
        
        guard isCardConnected else {
            sendLog("Karte ist bereits ausgeschaltet")
            return
        }
        
        // 1. Werfe Karte aus
        _ = ejectCard()
        
        // 2. Trenne Kartenverbindung
        disconnectCard()
        
        sendLog("Karte ausgeschaltet")
    }
    
    // MARK: - Helper Methods
    
    /// Konvertiert Byte-Array zu Hex-String
    private func toHex(_ data: [UInt8]) -> String {
        return data.map { String(format: "%02X", $0) }.joined()
    }
    
    /// Mapped PCSC Error Code zu lesbarer Nachricht
    private func mapErrorCode(_ errorCode: Int32) -> String {
        switch UInt32(errorCode) {
        case 0x00000000:
            return "Erfolg"
        case 0x80100004:
            return "Ungültiger Parameter"
        case 0x8010000C:
            return "Keine Smartcard eingelegt"
        case 0x8010000D:
            return "Unbekannte Karte"
        case 0x80100017:
            return "Kartenleser nicht verfügbar"
        case 0x8010000A:
            return "Timeout"
        case 0x80100069:
            return "Karte entfernt"
        default:
            return String(format: "Fehlercode: 0x%08X", errorCode)
        }
    }
    
    // MARK: - Flutter Communication
    
    /// Sendet Log-Nachricht an Flutter
    private func sendLog(_ message: String) {
        DispatchQueue.main.async {
            self.channel?.invokeMethod("log", arguments: message)
        }
        print("FEITIAN: \(message)")
    }
}

// MARK: - Data Extension for GZIP
extension Data {
    /// Dekomprimiert GZIP-komprimierte Daten
    func gunzipped() throws -> Data {
        guard self.count > 0 else {
            return self
        }
        
        var stream = z_stream()
        var status: Int32
        
        status = inflateInit2_(&stream, MAX_WBITS + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        
        guard status == Z_OK else {
            throw NSError(domain: "GZIPError", code: Int(status), userInfo: nil)
        }
        
        var decompressed = Data(capacity: self.count * 4)  // 4x für bessere Kompressionsraten
        
        repeat {
            if Int(stream.total_out) >= decompressed.count {
                decompressed.count += self.count  // Verdopple statt halbe Größe
            }
            
            let inputCount = self.count
            let outputCount = decompressed.count
            
            self.withUnsafeBytes { (inputPointer: UnsafeRawBufferPointer) in
                stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inputPointer.bindMemory(to: Bytef.self).baseAddress!)
                stream.avail_in = uint(inputCount)
                
                decompressed.withUnsafeMutableBytes { (outputPointer: UnsafeMutableRawBufferPointer) in
                    stream.next_out = outputPointer.bindMemory(to: Bytef.self).baseAddress!.advanced(by: Int(stream.total_out))
                    stream.avail_out = uInt(outputCount) - uInt(stream.total_out)
                    
                    status = inflate(&stream, Z_SYNC_FLUSH)
                }
            }
            
        } while status == Z_OK
        
        guard inflateEnd(&stream) == Z_OK && status == Z_STREAM_END else {
            throw NSError(domain: "GZIPError", code: Int(status), userInfo: nil)
        }
        
        decompressed.count = Int(stream.total_out)
        
        return decompressed
    }
}
