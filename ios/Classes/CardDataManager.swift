import WHCCareKit_iOS
import Flutter

/// Eigentliche Code Logik zum Anspreachen des Kartenlesers. Code basiert auf SAMPLE Projekt des Herstellers (ViewController.swift aus CareTaskManager Demo Projekt)
// Nachrichten, Results der Delegat-Methoden werden über Dispatcher über neu in swift definierte Methoden in dieser Klasse (sendDataToFlutter, sendLog, Event notifyDeviceIsLocked,...) an main.dart der Flutter App weitergeleitet

class CarddataManager {
    static let shared = CarddataManager()

    private let bluetoothManager = CareBluetoothManager()
    private var taskManager: CareTaskManager?
    private var channel: FlutterMethodChannel?

    private init() {}

    func initialize(channel: FlutterMethodChannel) {
        self.channel = channel
        bluetoothManager.delegate = self
        sendLog("Initialisiere Kartenleser Plugin")
    }

    @discardableResult
    func startBluetoothDiscovery() -> Bool {
        sendLog("Starte ORGA Kartenleser-Suche...")
        guard let firstDevice = bluetoothManager.discoveredPeripheralNames.first else {
/*                    sendLog("Kein ORGA Kartenleser gefunden...")
                   notifyNoBluetooth() */

            return false
        }
        bluetoothManager.connectToDevice(deviceIndex: 0)
        sendLog("ORGA Kartenleser verbunden: \(firstDevice)")
        return true
    }

    func loadVSD() {
        startBluetoothDiscovery()
        taskManager?.loadVSD()
        print("Lese VSD Daten aus....")
    }

    func loadNFD() {
        taskManager?.loadNFD(targetEnvironment: .productive, emergencyIndicator: false, updateIndicator: false)
        sendLog("Lese NFD Daten aus....")
    }

    func loadDPE() {
        taskManager?.loadDPE(targetEnvironment: .productive, emergencyIndicator: false, updateIndicator: false)
        sendLog("Lese DPE Daten aus....")
    }

    func loadAMTS() {
        taskManager?.loadAMTS(targetEnvironment: .productive)
        sendLog("Lese AMTS Daten aus....")
    }

    func cleanupAndDisconnect() {
        taskManager?.cleanup {
            self.bluetoothManager.disconnectFromDevice()
            self.sendLog("Trenne Bluetooth Verbindung!")
        }
    }

    func sendLog(_ message: String) {
        DispatchQueue.main.async {
            self.channel?.invokeMethod("log", arguments: message)
        }
    }

    func sendDataToFlutter(_ data: [String]) {
        DispatchQueue.main.async {
            self.channel?.invokeMethod("data", arguments: data)
        }
    }

    func notifyDeviceIsLocked() {
        DispatchQueue.main.async {
            self.sendLog("Kartenleser ist gesperrt! Auslesen nicht möglich")
            self.channel?.invokeMethod("deviceIsLocked", arguments: nil)
        }
    }

    func notifyNoDataMobileMode() {
        DispatchQueue.main.async {
            self.sendLog("Keine Karte gefunden!")
            self.channel?.invokeMethod("noDataMobileMode", arguments: nil)
        }
    }

   func notifyNoBluetooth() {
            DispatchQueue.main.async {
                self.sendLog("Kartenleser nicht verbunden!")
                self.channel?.invokeMethod("noBluetooth", arguments: nil)
            }
        }
}

extension CarddataManager: CareBluetoothManagerDelegate {
    func careBluetoothManager(didUpdateState state: CareBluetoothManagerStates) {
        print("careBluetoothManager Status: \(state)")
    }

    func careBluetoothManager(didThrowMessage message: CareBluetoothManagerMessages) {
        print("careBluetoothManager Nachricht: \(message)")
    }

    func careBluetoothManager(didConnect ctapi: CTorgios) {
        taskManager = CareTaskManager(ctapi: ctapi, delegate: self) {
            self.taskManager?.loadVSD()
            print("Karte wird ausgelesen....")
        }
    }
}

extension CarddataManager: CareTaskManagerDelegate {
    func careTaskManager(didUpdateState currentAction: CareTaskManagerActions) {
        print("careTaskManager Status: \(currentAction)")
    }

    func careTaskManager(didThrowMessage message: CareTaskManagerMessages) {
        print("careTaskManager Nachricht: \(message)")
        switch message {
        case .deviceIsLocked:
            notifyDeviceIsLocked()
        case .noDataMobileMode:
            notifyNoDataMobileMode()
       // case .taskExecutionFails:
        //    notifyNoBluetooth()
        default:
            break
        }
        cleanupAndDisconnect()
    }

    func careTaskManager(didLoadVSD dataset: [Data]) {
        handleLoadedData(Array(dataset.dropFirst()), title: "Sonstiges", doSendLog: false)
    }

    func careTaskManager(didLoadVSD_KVK dataset: Data) {
        handleLoadedData([dataset], title: "KVK Versichertendaten", doSendLog: true)
    }

    func careTaskManager(didLoadNFD dataset: [Data]) {
        handleLoadedData(dataset, title: "NFD Daten", doSendLog: true)
    }

    func careTaskManager(didLoadDPE dataset: [Data]) {
        handleLoadedData(dataset, title: "DPE Daten", doSendLog: true)
    }

    func careTaskManager(didLoadAMTS dataset: [Data]) {
        handleLoadedData(dataset, title: "AMTS Daten", doSendLog: true)
    }

    private func handleLoadedData(_ dataset: [Data], title: String, doSendLog: Bool) {
        let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.isoLatin9.rawValue))
        let isoEncoding = String.Encoding(rawValue: encoding)
        var dataStrings: [String] = []

        for data in dataset {
            if let decodedString = String(data: data, encoding: isoEncoding) {
                dataStrings.append(decodedString)
                if doSendLog {
                    print("\(title): \(decodedString)")
                    sendLog("\(title): \(decodedString)")
                } else {
                    print("\(title): \(decodedString)")
                }
            } else {
                sendLog("Fehler beim Dekodieren der Daten")
            }
        }
        sendDataToFlutter(dataStrings)
        cleanupAndDisconnect()
    }
}