import Foundation
import CoreBluetooth

// MARK: - Delegate Protocol for Communication with Flutter App
@objc protocol FeitianScanControllerDelegate: AnyObject {
    @objc optional func didDiscoverDevice(_ deviceName: String, rssi: Int)
    @objc optional func didConnectReader(_ deviceName: String, slots: [String])
    @objc optional func didDisconnectReader()
    @objc optional func didDetectCard(_ slotName: String)
    @objc optional func didRemoveCard(_ slotName: String)
    @objc optional func didReceiveBattery(_ level: Int)
    @objc optional func didReceiveLog(_ message: String)
}

// MARK: - Standalone FEITIAN Scanner Controller
// Based on IReaderDemo ScanDeviceController.mm
// This class is a complete, unmodified port of the working demo logic
@objc class FeitianScanController: NSObject {
    
    // MARK: - Public Properties
    weak var delegate: FeitianScanControllerDelegate?
    
    // MARK: - Private Properties
    private var scardContext: SCARDCONTEXT = 0
    private var scardHandle: SCARDHANDLE = 0
    
    // ReaderInterface from FEITIAN SDK (from demo line 40)
    private var interface: ReaderInterface?
    
    // CBCentralManager for BLE scanning (from demo line 31)
    private var central: CBCentralManager?
    
    // Device tracking lists (from demo lines 38, 48, 49)
    private var deviceList: [String] = []           // SDK-reported devices (_deviceList)
    private var discoveredList: [ReaderModel] = []  // CB-discovered devices (_discoverdList)
    private var tempList: [ReaderModel] = []        // Display list (_tempList)
    
    // Connection state
    private var selectedDeviceName: String?
    private var connectedBluetoothID: String?
    private var slotArray: [String]?
    
    // Auto-connect flag (from demo line 42)
    private var autoConnect: Bool = false
    
    // Timer for device refresh (from demo line 29)
    private var refreshTimer: Timer?
    
    // Serial queue for thread-safe device list access
    private let deviceQueue = DispatchQueue(label: "com.feitian.devicelist")
    
    // MARK: - Initialization
    override init() {
        super.init()
    }
    
    // MARK: - Public API Methods
    
    /// Initialize and start Bluetooth scanning
    /// Equivalent to viewWillAppear + beginScanBLEDevice from demo
    func startScanning() {
        log("Starting FEITIAN Bluetooth scan...")
        
        // Initialize ReaderInterface (from demo line 232-250)
        initReaderInterface()
        
        // Establish PCSC context (from demo line 62-82)
        establishContext()
        
        // Start BLE scanning (from demo line 87-90)
        beginScanBLEDevice()
        
        // Start refresh timer (from demo line 396, 416-419)
        startRefresh()
    }
    
    /// Stop Bluetooth scanning and cleanup
    /// Equivalent to stopScanBLEDevice from demo
    func stopScanning() {
        log("Stopping FEITIAN Bluetooth scan...")
        
        // Stop BLE scanning (from demo line 93-104)
        stopScanBLEDevice()
        
        // Stop refresh timer (from demo line 422-428)
        stopRefresh()
        
        // Cleanup
        deviceQueue.sync {
            deviceList.removeAll()
            discoveredList.removeAll()
            tempList = []
        }
    }
    
    /// Connect to a specific reader by name
    /// Equivalent to connectReader from demo
    func connectToReader(deviceName: String) {
        log("Connecting to reader: \(deviceName)")
        selectedDeviceName = deviceName
        connectReader(deviceName)
    }
    
    /// Disconnect current reader
    func disconnectReader() {
        log("Disconnecting reader...")
        
        if scardHandle != 0 {
            SCardDisconnect(scardHandle, SCARD_LEAVE_CARD)
            scardHandle = 0
        }
        
        interface?.disConnectCurrentPeripheralReader()
        
        connectedBluetoothID = nil
        slotArray = nil
    }
    
    /// Get list of discovered devices
    func getDiscoveredDevices() -> [String] {
        var devices: [String] = []
        deviceQueue.sync {
            devices = tempList.map { $0.name }
        }
        return devices
    }
    
    // MARK: - Private Implementation (From Demo - DO NOT MODIFY)
    
    // MARK: From demo line 232-250
    private func initReaderInterface() {
        interface = ReaderInterface()
        
        // Auto-connect setting
        autoConnect = UserDefaults.standard.bool(forKey: "autoConnect")
        
        // Set auto pair BEFORE SCardEstablishContext (from demo line 242-243)
        interface?.setAutoPair(autoConnect)
        interface?.setDelegate(self)
        
        // Set supported device types (from demo line 248)
        FTDeviceType.setDeviceType(IR301_AND_BR301 | BR301BLE_AND_BR500 | LINE_TYPEC)
    }
    
    // MARK: From demo line 62-82
    private func establishContext() {
        if scardContext == 0 {
            var context: SCARDCONTEXT = 0
            let ret = SCardEstablishContext(SCARD_SCOPE_SYSTEM, nil, nil, &context)
            
            if ret != SCARD_S_SUCCESS {
                log("ERROR: SCardEstablishContext failed: \(mapErrorCode(ret))")
                return
            }
            
            scardContext = context
            log("PCSC Context established: \(context)")
            
            // Set timeout (from demo line 69)
            let timeoutRet = FtSetTimeout(scardContext, 50000)
            if timeoutRet != SCARD_S_SUCCESS {
                log("WARNING: FtSetTimeout failed: \(mapErrorCode(timeoutRet))")
            }
        } else {
            // Release and re-establish (from demo line 72-81)
            SCardReleaseContext(scardContext)
            scardContext = 0
            
            var context: SCARDCONTEXT = 0
            let ret = SCardEstablishContext(SCARD_SCOPE_SYSTEM, nil, nil, &context)
            
            if ret != SCARD_S_SUCCESS {
                log("ERROR: SCardEstablishContext failed: \(mapErrorCode(ret))")
                return
            }
            
            scardContext = context
            FtSetTimeout(scardContext, 50000)
        }
    }
    
    // MARK: From demo line 87-90
    private func beginScanBLEDevice() {
        let centralQueue = DispatchQueue(label: "com.feitian.central", attributes: [])
        central = CBCentralManager(delegate: self, queue: centralQueue)
        log("CBCentralManager initialized")
    }
    
    // MARK: From demo line 93-104
    private func stopScanBLEDevice() {
        DispatchQueue.global().async { [weak self] in
            self?.central?.stopScan()
            self?.central = nil
        }
        
        DispatchQueue.main.async { [weak self] in
            self?.deviceQueue.sync {
                self?.discoveredList.removeAll()
                self?.tempList = []
            }
        }
    }
    
    // MARK: From demo line 416-419
    private func startRefresh() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }
    
    // MARK: From demo line 422-428
    private func stopRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
    
    // MARK: From demo line 431-449
    private func refresh() {
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            
            self.deviceQueue.sync {
                self.tempList = self.discoveredList
                
                for i in (0..<self.tempList.count).reversed() {
                    let model = self.tempList[i]
                    let timeSinceScan = Date().timeIntervalSince(model.date)
                    
                    if timeSinceScan >= 1.0 {
                        self.deviceList.removeAll { $0 == model.name }
                        self.discoveredList.removeAll { $0.name == model.name }
                    }
                }
                
                self.tempList = self.discoveredList
            }
        }
    }
    
    // MARK: From demo line 318-327
    private func connectReader(_ readerName: String) {
        guard let interface = interface else {
            log("ERROR: ReaderInterface not initialized")
            return
        }
        
        log("Connecting to reader: \(readerName)")
        let success = interface.connectPeripheralReader(readerName, timeout: 15.0)
        
        if !success {
            log("ERROR: Failed to connect to reader: \(readerName)")
        }
    }
    
    // MARK: - Helper Functions
    
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
    
    private func log(_ message: String) {
        print("FeitianScanController: \(message)")
        delegate?.didReceiveLog?(message)
    }
}

// MARK: - CBCentralManagerDelegate (From Demo)
extension FeitianScanController: CBCentralManagerDelegate {
    
    // MARK: From demo line 107-123
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            log("Bluetooth powered on")
            scanDevice()
            
        case .poweredOff:
            log("Bluetooth powered off")
            
        case .unsupported:
            log("Bluetooth unsupported")
            
        case .unauthorized:
            log("Bluetooth unauthorized")
            
        case .resetting:
            log("Bluetooth resetting")
            
        case .unknown:
            log("Bluetooth state unknown")
            
        @unknown default:
            log("Bluetooth unknown state")
        }
    }
    
    // MARK: From demo line 125-130
    private func scanDevice() {
        let options: [String: Any] = [
            CBCentralManagerScanOptionAllowDuplicatesKey: true
        ]
        
        DispatchQueue.global().async { [weak self] in
            self?.central?.scanForPeripherals(withServices: nil, options: options)
        }
        
        log("Started scanning for BLE peripherals")
    }
    
    // MARK: From demo line 133-154
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        // Validate FEITIAN device (from demo line 136-138)
        guard checkFTBLEDeviceByAdv(advertisementData) else {
            return
        }
        
        // Check for valid device name (from demo line 140-142)
        guard let deviceName = peripheral.name, !deviceName.isEmpty else {
            return
        }
        
        // Deduplication logic (from demo line 144-153)
        deviceQueue.sync {
            for model in discoveredList {
                if model.name == deviceName {
                    model.date = Date()
                    return
                }
            }
            
            // Add new device
            let model = ReaderModel(name: deviceName, scanDate: Date())
            discoveredList.append(model)
            
            log("Discovered device: \(deviceName) (RSSI: \(RSSI))")
            delegate?.didDiscoverDevice?(deviceName, rssi: RSSI.intValue)
        }
    }
    
    // MARK: From demo line 156-177
    private func checkFTBLEDeviceByAdv(_ advertisementData: [String: Any]) -> Bool {
        guard let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID],
              let serviceUUID = serviceUUIDs.first else {
            return false
        }
        
        var uuidType: Int = 0
        let isFeitianDevice = checkFTBLEDeviceByUUID(serviceUUID.data, uuidType: &uuidType)
        
        // Only accept type 1 devices (from demo line 170-172)
        if isFeitianDevice && uuidType == 1 {
            return true
        }
        
        return false
    }
    
    // MARK: From demo line 179-197
    private func checkFTBLEDeviceByUUID(_ uuidData: Data, uuidType: inout Int) -> Bool {
        guard uuidData.count == 16 else {
            return false
        }
        
        let bytes = [UInt8](uuidData)
        
        // Check for FEITIAN signature: "FT" at start and 0x02 at position 5
        // From demo: memcmp(bServiceUUID, "FT", 2) == 0 && bServiceUUID[5] == 0x02
        if bytes[0] == 0x46 && bytes[1] == 0x54 && bytes[5] == 0x02 {
            uuidType = Int(bytes[3])
            return true
        }
        
        return false
    }
}

// MARK: - ReaderInterfaceDelegate (From Demo)
extension FeitianScanController: ReaderInterfaceDelegate {
    
    // MARK: From demo line 301-316
    func findPeripheralReader(_ readerName: String) {
        guard !readerName.isEmpty else {
            return
        }
        
        deviceQueue.sync {
            if deviceList.contains(readerName) {
                return
            }
            
            deviceList.append(readerName)
            log("SDK reported device: \(readerName)")
        }
    }
    
    // MARK: From demo line 254-286
    func readerInterfaceDidChange(_ attached: Bool, bluetoothID: String, andslotnameArray slotArray: [String]) {
        log("Reader interface changed - attached: \(attached), ID: \(bluetoothID)")
        
        if attached {
            // Stop scanning (from demo line 259-260)
            stopScanBLEDevice()
            stopRefresh()
            
            // Save connection info (from demo line 262-269)
            connectedBluetoothID = bluetoothID
            self.slotArray = slotArray.isEmpty ? nil : slotArray
            
            // Notify delegate
            log("Reader connected: \(bluetoothID), slots: \(slotArray)")
            delegate?.didConnectReader?(bluetoothID, slots: slotArray)
            
        } else {
            log("Reader disconnected")
            connectedBluetoothID = nil
            slotArray = nil
            delegate?.didDisconnectReader?()
        }
    }
    
    // MARK: From demo line 288-297
    func cardInterfaceDidDetach(_ attached: Bool, slotname: String) {
        if attached {
            log("Card detected in slot: \(slotname)")
            delegate?.didDetectCard?(slotname)
        } else {
            log("Card removed from slot: \(slotname)")
            delegate?.didRemoveCard?(slotname)
        }
    }
    
    // Battery callback (not in demo, but part of SDK)
    func didGetBattery(_ battery: Int) {
        log("Battery level: \(battery)%")
        delegate?.didReceiveBattery?(battery)
    }
}

// MARK: - ReaderModel (From Demo line readerModel.h)
class ReaderModel {
    var name: String
    var date: Date
    
    init(name: String, scanDate: Date) {
        self.name = name
        self.date = scanDate
    }
}