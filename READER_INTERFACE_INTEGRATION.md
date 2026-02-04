# ReaderInterface Integration for FEITIAN SDK

## Overview

This document describes the integration of the FEITIAN SDK's `ReaderInterface` class to replace the previous CoreBluetooth-based implementation for proper Bluetooth device detection and event handling.

## Problem Statement

The previous implementation used `CBCentralManagerDelegate` for direct Bluetooth scanning. However, this did not work correctly with the FEITIAN SDK because:

1. The SDK has its own Bluetooth management through the `ReaderInterface` class
2. Device discovery events were not being triggered when card readers were turned on/off
3. The implementation didn't receive proper connection state, card insertion, and battery status events

## Solution

The implementation now uses the FEITIAN SDK's `ReaderInterface` class, following the pattern from the IReaderDemo project (`sdk/3.5.71/demo/iReader/Classes/ScanDevice/Controller/ScanDeviceController.mm`). The demo is written in Objective-C++, but the pattern has been adapted to Swift with proper Objective-C bridging.

## Key Changes

### 1. ReaderInterface Protocol Bridge

Added Objective-C protocol bridge declarations for the FEITIAN SDK classes:

```swift
@objc protocol ReaderInterfaceDelegate: AnyObject {
    @objc optional func findPeripheralReader(_ readerName: String)
    @objc optional func readerInterfaceDidChange(_ attached: Bool, bluetoothID: String, andslotnameArray slotArray: [String])
    @objc optional func cardInterfaceDidDetach(_ attached: Bool, slotname: String)
    @objc optional func didGetBattery(_ battery: Int)
}

@objc class ReaderInterface: NSObject {
    func setDelegate(_ delegate: ReaderInterfaceDelegate?)
    func setAutoPair(_ autoPair: Bool)
    func connectPeripheralReader(_ readerName: String, timeout: Float) -> Bool
    func disConnectCurrentPeripheralReader()
}

@objc class FTDeviceType: NSObject {
    @objc static func setDeviceType(_ type: UInt32)
}
```

### 2. Initialization

Added `setupReaderInterface()` method called during initialization:

```swift
private func setupReaderInterface() {
    readerInterface = ReaderInterface()
    readerInterface?.setDelegate(self)
    readerInterface?.setAutoPair(false) // Manual pairing like in demo
    
    // Support all device types
    FTDeviceType.setDeviceType(IR301_AND_BR301 | BR301BLE_AND_BR500 | LINE_TYPEC)
}
```

### 3. Bluetooth Scanning

Simplified Bluetooth scanning to use the SDK's built-in functionality:

```swift
func startBluetoothScan() {
    sendLog("Starte Bluetooth-Scan über ReaderInterface...")
    isScanning = true
    
    // Bluetooth scanning is automatically handled by the ReaderInterface SDK
    // when setDelegate is called during initialization. The SDK continuously
    // scans for FEITIAN devices and calls findPeripheralReader() for each
    // device discovered. No explicit scan start is needed.
}
```

**How Scanning Works**: Unlike CoreBluetooth which requires explicit `scanForPeripherals()` calls, the FEITIAN SDK's `ReaderInterface` automatically starts scanning for FEITIAN devices as soon as `setDelegate()` is called during initialization. The SDK runs a continuous background scan and invokes the `findPeripheralReader()` delegate method whenever a FEITIAN device is discovered. The `startBluetoothScan()` method now serves primarily as a state flag.

### 4. Reader Connection

Updated to use ReaderInterface methods:

```swift
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
```

### 5. ReaderInterfaceDelegate Implementation

Implemented all four delegate methods:

#### findPeripheralReader
Called when a new FEITIAN device is discovered:
```swift
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
```

**Note on RSSI**: The FEITIAN SDK's `ReaderInterface` API does not provide RSSI (Received Signal Strength Indicator) values. Unlike the previous CoreBluetooth implementation that could access signal strength, the SDK abstraction only provides the device name. The `rssi` field is set to 0 as a placeholder to maintain API compatibility with the Flutter layer. This should not affect functionality since device selection is typically based on name rather than signal strength for FEITIAN readers.

#### readerInterfaceDidChange
Called when reader is connected/disconnected:
```swift
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
        // Handle disconnection with cleanup
    }
}
```

#### cardInterfaceDidDetach
Called when card is inserted/removed:
```swift
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
```

#### didGetBattery
Called when battery status is received:
```swift
func didGetBattery(_ battery: Int) {
    sendLog("Batterie: \(battery)%")
    
    channel?.invokeMethod("batteryLevel", arguments: [
        "level": battery
    ])
}
```

### 6. Removed Code

- Removed `CBCentralManager` and related CoreBluetooth code
- Removed `CBCentralManagerDelegate` extension
- Removed `discoveredPeripherals` dictionary
- Removed simulated `getBatteryLevel()` method
- Removed `import CoreBluetooth`

## Event Flow

1. **App starts** → `setupReaderInterface()` initializes SDK
2. **User clicks "Connect"** → `startBluetoothScan()` enables scanning
3. **Device found** → `findPeripheralReader()` fires → Flutter receives "deviceFound" event
4. **User selects device** → `connectToReader()` initiates connection
5. **Reader connects** → `readerInterfaceDidChange(attached: true)` fires → PCSC context established → Flutter receives "readerConnected" event
6. **Card inserted** → `cardInterfaceDidDetach(attached: true)` fires → Flutter receives "cardConnected" event
7. **Battery status** → `didGetBattery()` fires → Flutter receives "batteryLevel" event
8. **Card removed** → `cardInterfaceDidDetach(attached: false)` fires → PCSC handle cleaned up → Flutter receives "cardDisconnected" event
9. **Reader disconnects** → `readerInterfaceDidChange(attached: false)` fires → PCSC context cleaned up → Flutter receives "readerDisconnected" event

## Flutter Method Channel Events

The following events are sent to Flutter:

| Event | Arguments | Description |
|-------|-----------|-------------|
| `deviceFound` | `{ "name": String, "rssi": Int }` | New FEITIAN device discovered |
| `readerConnected` | `{ "deviceName": String, "connected": Bool, "slots": [String] }` | Reader successfully connected |
| `readerDisconnected` | `nil` | Reader disconnected |
| `cardConnected` | `{ "slot": String }` | Card inserted into reader |
| `cardDisconnected` | `nil` | Card removed from reader |
| `batteryLevel` | `{ "level": Int }` | Battery level percentage |

## Testing Checklist

After implementation, verify these events work correctly:

- [ ] Bluetooth scan starts → `findPeripheralReader` called for each device
- [ ] Reader on/off → `readerInterfaceDidChange` called
- [ ] Card insert/remove → `cardInterfaceDidDetach` called
- [ ] Battery status → `didGetBattery` called
- [ ] PCSC context properly established on reader connection
- [ ] PCSC resources properly cleaned up on disconnection
- [ ] All events properly forwarded to Flutter layer

## Supported Device Types

The implementation supports all FEITIAN device types:

- `IR301_AND_BR301` (0x01) - iR301 and bR301 readers
- `BR301BLE_AND_BR500` (0x02) - bR301 BLE and bR500 readers
- `LINE_TYPEC` (0x04) - Type-C connected readers

## Reference

- IReaderDemo project: `sdk/3.5.71/demo/iReader/Classes/ScanDevice/Controller/ScanDeviceController.mm`
- ReaderInterface header: `sdk/3.5.71/demo/iReader/SDK/include/ReaderInterface.h`
- Implementation file: `ios/Classes/FeitianCardManager.swift`

## Benefits

1. **Proper device detection**: SDK handles Bluetooth management correctly
2. **Real-time events**: Receive actual reader, card, and battery events
3. **Automatic slot detection**: SDK provides available slot information
4. **Battery monitoring**: Receive real battery status updates
5. **Cleaner code**: Removed manual CoreBluetooth management
6. **Follows SDK patterns**: Implementation matches official demo project
