# FEITIAN Reader SDK Implementation Details

## Overview

This document provides detailed technical information about the FEITIAN Reader SDK Flutter plugin implementation, including PCSC function mappings, APDU command examples, and debugging tips.

## Architecture

The plugin follows a layered architecture pattern:

```
┌─────────────────────────────────────────┐
│         Flutter Application             │
│     (example/lib/main.dart)             │
└─────────────────┬───────────────────────┘
                  │
┌─────────────────▼───────────────────────┐
│      Dart Interface Layer (lib/)        │
│  - feitian_reader_sdk.dart              │
│  - feitian_reader_sdk_platform_interface│
│  - feitian_reader_sdk_method_channel    │
└─────────────────┬───────────────────────┘
                  │ Method Channel
┌─────────────────▼───────────────────────┐
│   iOS Native Layer (ios/Classes/)       │
│  - FeitianReaderSdkPlugin.swift         │
│  - FeitianCardManager.swift             │
└─────────────────┬───────────────────────┘
                  │
┌─────────────────▼───────────────────────┐
│         FEITIAN SDK Framework           │
│  - winscard.h (PCSC functions)          │
│  - ft301u.h (FEITIAN-specific)          │
└─────────────────────────────────────────┘
```

## PCSC Function Mapping

### Core PCSC Functions

The plugin wraps the following PCSC (PC/SC) functions from `winscard.h`:

| PCSC Function | Plugin Method | Description |
|---------------|---------------|-------------|
| `SCardEstablishContext` | Part of `connectReader()` | Initialize PCSC context |
| `SCardListReaders` | Part of `connectReader()` | List available readers |
| `SCardConnect` | `powerOnCard()` | Connect to smart card |
| `SCardTransmit` | `sendApduCommand()` | Send APDU to card |
| `SCardControl` | `sendControlCommand()` | Send control command to reader |
| `SCardDisconnect` | `powerOffCard()` | Disconnect from card |
| `SCardReleaseContext` | Part of `disconnectReader()` | Release PCSC context |

### FEITIAN-Specific Functions

From `ft301u.h`:

| FEITIAN Function | Plugin Method | Description |
|------------------|---------------|-------------|
| `FtGetReaderName` | `getReaderName()` | Get reader name string |
| `FtGetDeviceUID` | `readUID()` | Read device unique ID |

## Global Variables

The FEITIAN SDK uses global variables for context and card handles:

```objective-c
extern SCARDCONTEXT gContxtHandle;  // Global PCSC context
extern SCARDHANDLE gCardHandle;     // Global card handle
extern NSString *gBluetoothID;      // Bluetooth device ID
```

In Swift implementation, these are managed as instance variables in `FeitianCardManager`:

```swift
private var contextHandle: UInt = 0
private var cardHandle: UInt = 0
```

## APDU Command Structure

### APDU Format

APDU commands follow ISO 7816-4 structure:

```
CLA INS P1 P2 [Lc Data] [Le]
```

- **CLA** (1 byte): Class byte
- **INS** (1 byte): Instruction byte
- **P1** (1 byte): Parameter 1
- **P2** (1 byte): Parameter 2
- **Lc** (1 byte, optional): Length of command data
- **Data** (Lc bytes, optional): Command data
- **Le** (1 byte, optional): Expected response length

### APDU Cases

| Case | Structure | Example |
|------|-----------|---------|
| Case 1 | CLA INS P1 P2 | `00A4000C` |
| Case 2 | CLA INS P1 P2 Le | `0084000008` |
| Case 3 | CLA INS P1 P2 Lc Data | `00A4040007A0000002471001` |
| Case 4 | CLA INS P1 P2 Lc Data Le | `00A404000AA000000167414301FF00` |

## Example APDU Commands

### Common Smart Card Commands

```dart
// SELECT FILE/APPLICATION
// Select application with AID A0000002471001
'00A4040007A0000002471001'
// Response: 9000 (OK)

// GET CHALLENGE
// Request 8 random bytes from card
'0084000008'
// Response: [8 random bytes] 9000

// READ BINARY
// Read 255 bytes from current file
'00B00000FF'
// Response: [data] 9000

// VERIFY PIN
// Verify PIN code
'0020000008' + [PIN_BYTES]

// GET RESPONSE
// Get additional response data
'00C0000000'
```

### FEITIAN-Specific Examples

Based on the demo project (`OperationViewController`):

```objective-c
// Example from demo project
NSString *selectApdu = @"00A4040007A0000002471001";
[self sendCommand:selectApdu];

// Read binary data
NSString *readApdu = @"00B00000FF";
[self sendCommand:readApdu];
```

## sendCommand Implementation

### Objective-C Reference (from OperationViewController.m)

```objective-c
- (long)sendCommand:(NSString *)apdu
{
    unsigned int capdulen;
    unsigned char capdu[2048 + 128];
    unsigned char resp[2048 + 128];
    unsigned int resplen = sizeof(resp);
    
    // 1. Validate APDU length
    if((apdu.length < 5) || (apdu.length % 2 != 0)) {
        return SCARD_E_INVALID_PARAMETER;
    }
    
    // 2. Convert hex string to bytes
    NSData *apduData = [[Tools shareTools] hexFromString:apdu];
    [apduData getBytes:capdu length:apduData.length];
    capdulen = (unsigned int)[apduData length];
    
    // 3. Validate APDU structure
    if (![[Tools shareTools] isApduValid:capdu apduLen:capdulen]) {
        return SCARD_E_INVALID_PARAMETER;
    }
    
    // 4. Send APDU using SCardTransmit
    SCARD_IO_REQUEST pioSendPci;
    iRet = SCardTransmit(gCardHandle, &pioSendPci, 
                         capdu, capdulen, 
                         NULL, resp, &resplen);
    
    // 5. Process response
    if (iRet == 0) {
        NSMutableData *RevData = [NSMutableData data];
        [RevData appendBytes:resp length:resplen];
        // Return response as hex string
    }
    
    return iRet;
}
```

### Swift Implementation (FeitianCardManager.swift)

```swift
func sendCommand(_ apdu: String) {
    // Validate format
    guard apdu.count >= 5, apdu.count % 2 == 0 else {
        sendLog("Fehler: Ungültiges APDU Format")
        return
    }
    
    // Convert to Data
    guard let apduData = hexStringToData(apdu) else {
        sendLog("Fehler: APDU Konvertierung fehlgeschlagen")
        return
    }
    
    // Validate APDU structure
    guard isApduValid(apduData) else {
        sendLog("Fehler: APDU Validierung fehlgeschlagen")
        return
    }
    
    // TODO: Call SCardTransmit when framework is integrated
}
```

## Control Commands

### SCardControl Usage (from OperationViewController.mm)

```objective-c
DWORD dwControlCode = 3549;
DWORD dwReturn = 0;
unsigned char capdu[2048 + 128];
unsigned char resp[2048 + 128];
unsigned int resplen = sizeof(resp);

iRet = SCardControl(gCardHandle, dwControlCode,
                    capdu, capdulen,
                    resp, resplen, &dwReturn);
```

Control code `3549` is FEITIAN-specific for escape/control commands.

## APDU Validation

### Validation Logic (from Tools class)

```swift
private func isApduValid(_ apduData: Data) -> Bool {
    guard apduData.count >= 4 else { return false }
    
    let bytes = [UInt8](apduData)
    
    // Case 1: CLA INS P1 P2 (4 bytes)
    if apduData.count == 4 { return true }
    
    // Case 2: CLA INS P1 P2 Le (5 bytes)
    if apduData.count == 5 { return true }
    
    // Case 3/4: With Lc and Data
    if apduData.count > 5 {
        let lc = Int(bytes[4])
        
        // Case 3: CLA INS P1 P2 Lc Data
        if apduData.count == 5 + lc { return true }
        
        // Case 4: CLA INS P1 P2 Lc Data Le
        if apduData.count == 5 + lc + 1 { return true }
    }
    
    return false
}
```

## Response Codes

### Standard Status Words (SW1 SW2)

| Status Word | Meaning |
|-------------|---------|
| `9000` | Success |
| `6200` | Warning: No information given |
| `6281` | Part of returned data may be corrupted |
| `6300` | Warning: More data available |
| `6700` | Wrong length |
| `6981` | Command incompatible with file structure |
| `6982` | Security status not satisfied |
| `6983` | Authentication method blocked |
| `6984` | Referenced data invalidated |
| `6985` | Conditions of use not satisfied |
| `6986` | Command not allowed |
| `6A80` | Incorrect parameters in data field |
| `6A81` | Function not supported |
| `6A82` | File not found |
| `6A83` | Record not found |
| `6A84` | Not enough memory space |
| `6A86` | Incorrect P1 P2 |

### PCSC Error Codes

From `winscard.h`:

```c
#define SCARD_S_SUCCESS                 0x00000000
#define SCARD_E_INVALID_PARAMETER       0x80100004
#define SCARD_E_NO_SMARTCARD            0x8010000C
#define SCARD_E_UNKNOWN_CARD            0x8010000D
#define SCARD_E_READER_UNAVAILABLE      0x80100017
#define SCARD_E_TIMEOUT                 0x8010000A
#define SCARD_W_REMOVED_CARD            0x80100069
```

## Error Handling

### Error Mapping (from Tools.shareTools.mapErrorCode)

```swift
func mapErrorCode(_ errorCode: Int) -> String {
    switch errorCode {
    case 0x00000000:
        return "Success"
    case 0x80100004:
        return "Invalid parameter"
    case 0x8010000C:
        return "No smart card inserted"
    case 0x8010000D:
        return "Unknown card"
    case 0x80100017:
        return "Reader unavailable"
    case 0x8010000A:
        return "Timeout"
    case 0x80100069:
        return "Card removed"
    default:
        return "Error code: 0x\(String(format: "%08X", errorCode))"
    }
}
```

## Debugging Tips

### 1. Enable Verbose Logging

In Swift code:
```swift
func sendLog(_ message: String) {
    print("FEITIAN: \(message)")  // Console output
    channel?.invokeMethod("log", arguments: message)  // Flutter
}
```

### 2. Xcode Console Monitoring

When debugging the example app:
1. Open the example project in Xcode (`example/ios/Runner.xcodeproj`)
2. Run the Flutter app: `flutter run`
3. Monitor Xcode console for native logs
4. Set breakpoints in Swift code

### 3. APDU Command Testing

Test APDU commands incrementally:

```dart
// Start simple
await plugin.sendApduCommand('00A4000C');  // SELECT

// Add complexity
await plugin.sendApduCommand('00A4040007A0000002471001');

// Verify responses
platform.setMethodCallHandler((call) async {
  if (call.method == 'apduResponse') {
    print('Response: ${call.arguments}');
  }
});
```

### 4. Common Issues

| Issue | Cause | Solution |
|-------|-------|----------|
| "Invalid APDU" | Wrong format | Check hex string is even length, >= 5 chars |
| "Reader not connected" | No initialization | Call `connectReader()` first |
| "Card not powered" | Card not activated | Call `powerOnCard()` before sending APDU |
| Response "6A82" | File not found | Check AID/file selector is correct |
| Response "6700" | Wrong length | Check Lc field matches data length |

## Reader Connection Flow

```
1. connectReader()
   ├─→ SCardEstablishContext(SCARD_SCOPE_SYSTEM, ...)
   ├─→ SCardListReaders(...) // Find available readers
   └─→ Store contextHandle

2. powerOnCard()
   ├─→ SCardConnect(contextHandle, readerName, ...)
   └─→ Store cardHandle

3. sendApduCommand(apdu)
   ├─→ Validate APDU format
   ├─→ Convert hex string to bytes
   ├─→ SCardTransmit(cardHandle, apdu, ...)
   └─→ Return response

4. powerOffCard()
   └─→ SCardDisconnect(cardHandle, SCARD_LEAVE_CARD)

5. disconnectReader()
   └─→ SCardReleaseContext(contextHandle)
```

## FEITIAN Reader Models

Supported reader types (from demo project):

```objective-c
typedef NS_ENUM(NSInteger, FTReaderType) {
    FTReaderiR301 = 0,      // USB reader
    FTReaderbR301 = 1,      // Bluetooth reader
    FTReaderbR301BLE = 2,   // Bluetooth Low Energy reader
    FTReaderbR500 = 3,      // Advanced Bluetooth reader
    FTReaderBLE = 4         // Generic BLE reader
};
```

## Bluetooth Connection

For Bluetooth readers, the connection process includes:

1. Bluetooth device discovery
2. Pairing/connection establishment
3. PCSC context initialization
4. Reader enumeration

Note: Bluetooth details are abstracted by the FEITIAN SDK framework.

## Future Enhancements

Potential improvements for the plugin:

1. **Android Support**: Port to Android using FEITIAN Android SDK
2. **Multi-Reader Support**: Handle multiple connected readers
3. **Extended APDU**: Support for extended length APDU (> 255 bytes)
4. **Async Operations**: Non-blocking APDU transmission
5. **Reader Events**: Notify on card insertion/removal
6. **Firmware Updates**: Support for reader firmware updates via plugin

## References

- **FEITIAN SDK Demo**: `sdk/3.5.71/demo/iReader/`
- **OperationViewController**: Main implementation reference
- **PCSC Specification**: PC/SC Workgroup specifications
- **ISO 7816-4**: Smart card APDU protocol standard

## Contact

For technical questions about FEITIAN SDK integration, refer to FEITIAN Technologies documentation or contact their support team.
