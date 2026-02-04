# Bluetooth Peripheral Discovery Fix - Summary

## Problem
Bluetooth peripherals were being discovered in the iReader Demo project but **NOT** in the CardManager Swift implementation (`ios/Classes/FeitianCardManager.swift`). The debug output "didDiscoverPeripheral" was not appearing.

## Root Cause
The `ReaderInterfaceDelegate` implementation in `FeitianCardManager.swift` was incomplete and did not follow the same pattern as the Objective-C++ implementation in the demo project.

## Solution Implemented

### 1. Added Separate Device Lists for Deduplication (like demo)
```swift
// Discovered devices lists for deduplication (like in demo)
private var cbDiscoveredDevices: [String] = []  // Like _discoverdList in demo
private var sdkReportedDevices: [String] = []   // Like _deviceList in demo
private let deviceListQueue = DispatchQueue(label: "com.feitian.devicelist")
```
- `cbDiscoveredDevices`: Tracks devices discovered by CBCentralManager (like `_discoverdList` in demo)
- `sdkReportedDevices`: Tracks devices reported by SDK via findPeripheralReader (like `_deviceList` in demo)
- `deviceListQueue`: Serial dispatch queue for thread-safe access to device lists
- Both lists are cleared when scan stops

### 2. Implemented Advertisement Data Validation
```swift
private func checkFTBLEDeviceByAdv(_ advertisementData: [String: Any]) -> Bool
```
Based on `CheckFTBLEDeviceByAdv()` from demo (lines 156-177):
- Checks for Service UUIDs in advertisement data
- Validates FEITIAN device by UUID
- Only accepts type 1 devices

### 3. Implemented UUID Validation
```swift
private func checkFTBLEDeviceByUUID(_ uuidData: Data, uuidType: inout Int) -> Bool
```
Based on `CheckFTBLEDeviceByUUID()` from demo (lines 179-197):
- Validates UUID is exactly 16 bytes
- Checks for FEITIAN signature: "FT" at start (bytes 0x46, 0x54)
- Verifies 0x02 at position 5
- Extracts device type from position 3
- Returns true only for valid FEITIAN devices

### 4. Enhanced Peripheral Discovery Handler
```swift
func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, 
                   advertisementData: [String : Any], rssi RSSI: NSNumber)
```
Now properly:
- Validates FEITIAN device by advertisement data
- Checks for valid device name
- Prevents duplicates
- Logs discovered peripherals
- Adds devices to discovered list

### 5. Enhanced findPeripheralReader() with Thread Safety
```swift
func findPeripheralReader(_ readerName: String)
```
Now includes:
- Thread-safe duplicate checking using deviceListQueue
- Separate tracking in sdkReportedDevices (like _deviceList in demo)
- Proper logging
- Only notifies Flutter for new devices

## Technical Details

### Two Independent Device Discovery Systems
The demo uses two separate device lists because there are TWO independent discovery mechanisms:

1. **CBCentralManager Discovery** (`didDiscoverPeripheral`)
   - Native iOS Bluetooth scanning
   - Tracks devices in `cbDiscoveredDevices` (like `_discoverdList` in demo)
   - Validates FEITIAN devices by advertisement data
   - Logs discovered devices for debugging

2. **SDK Discovery** (`findPeripheralReader`)
   - FEITIAN SDK internal validation
   - Tracks devices in `sdkReportedDevices` (like `_deviceList` in demo)
   - Called by SDK after it validates device compatibility
   - Notifies Flutter when new devices are found

These systems run independently and maintain separate lists. A device may appear in CBCentralManager but not be reported by the SDK if it fails SDK validation.

### Thread Safety
All access to device lists uses `deviceListQueue.sync {}` to prevent race conditions, since:
- CBCentralManager callbacks occur on a serial queue
- findPeripheralReader may be called from different threads
- stopBluetoothScan can be called from the main thread

### FEITIAN Device Identification
The SDK uses a specific UUID format for FEITIAN Bluetooth devices:
- **UUID Length**: Must be exactly 16 bytes
- **Signature**: First 2 bytes must be "FT" (0x46, 0x54)
- **Protocol Marker**: Byte at position 5 must be 0x02
- **Device Type**: Byte at position 3 indicates device type
  - Type 1: Accepted devices (BR301BLE, BR500, etc.)
  - Other types: Rejected

### Device Discovery Flow
1. **CBCentralManager** scans for BLE peripherals
2. **didDiscover** callback receives peripheral data
3. **checkFTBLEDeviceByAdv()** validates advertisement data
4. **checkFTBLEDeviceByUUID()** validates UUID format
5. Device name is checked and deduplicated
6. **findPeripheralReader()** is called by SDK with validated device
7. Flutter is notified via "deviceFound" method channel

## Testing Instructions

### Prerequisites
- FEITIAN Bluetooth card reader (BR301BLE, BR500, IR301, etc.)
- iOS device with Bluetooth enabled
- Flutter app with the feitian_reader_sdk plugin

### Test Steps
1. Start the app and initiate Bluetooth scan
2. Check for log message: "didDiscoverPeripheral: [device_name] (RSSI: [value])"
3. Verify device appears in the discovered devices list
4. Confirm duplicate devices are not reported multiple times
5. Verify only FEITIAN devices are discovered (devices with "BR" or "IR" in name)

### Expected Log Output
```
FEITIAN: Starte Bluetooth-Scan über ReaderInterface...
FEITIAN: Erstelle PCSC Context...
FEITIAN: PCSC Context erstellt: [context_id]
FEITIAN: Set time out success
FEITIAN: Bluetooth-Scan initialisiert
FEITIAN: Bluetooth ist eingeschaltet
FEITIAN: Starte Bluetooth-Scan nach Peripheriegeräten...
FEITIAN: didDiscoverPeripheral: BR301BLE (RSSI: -45)
FEITIAN: SDK reported device: BR301BLE
```

### What Changed
**Before**: No "didDiscoverPeripheral" log, devices not discovered
**After**: Both "didDiscoverPeripheral" and "SDK reported device" logs appear, devices properly discovered and validated

## Files Modified
- `ios/Classes/FeitianCardManager.swift`
  - Added `cbDiscoveredDevices` and `sdkReportedDevices` arrays (lines 125-126)
  - Added `deviceListQueue` for thread-safe access (line 129)
  - Enhanced `stopBluetoothScan()` to clear both device lists (lines 206-209)
  - Enhanced `findPeripheralReader()` with thread-safe deduplication (lines 733-757)
  - Rewrote `centralManager(_:didDiscover:)` with thread-safe validation (lines 877-908)
  - Added `checkFTBLEDeviceByAdv()` method (lines 914-934)
  - Added `checkFTBLEDeviceByUUID()` method (lines 938-956)

## References
- Demo Project: `sdk/3.5.71/demo/iReader/Classes/ScanDevice/Controller/ScanDeviceController.mm`
  - Lines 133-154: didDiscoverPeripheral implementation
  - Lines 156-177: CheckFTBLEDeviceByAdv implementation
  - Lines 179-197: CheckFTBLEDeviceByUUID implementation
  - Lines 301-316: findPeripheralReader implementation
