# feitian_reader_sdk

Flutter plugin for FEITIAN cardreader over bluetooth with PCSC interface.

## Overview

This plugin provides a Flutter interface to FEITIAN card readers (iR301, bR301, bR301 BLE, bR500, etc.) using the PCSC (Personal Computer/Smart Card) interface. It enables communication with smart cards via APDU (Application Protocol Data Unit) commands.

## Features

- **Reader Connection Management**: Connect and disconnect from FEITIAN card readers
- **Card Power Control**: Power on/off smart cards (SCardConnect/SCardDisconnect)
- **APDU Command Execution**: Send standard APDU commands to smart cards
- **Card UID Reading**: Read unique identifier from cards
- **PCSC Interface**: Full support for PCSC smart card communication
- **Bluetooth Communication**: Wireless connection to FEITIAN readers

## Installation

Add this to your package's `pubspec.yaml` file:

```yaml
dependencies:
  feitian_reader_sdk:
    path: ../  # Adjust path as needed
```

### iOS Configuration

For iOS apps, you must add the following to your `Info.plist` file to support communication with FEITIAN card readers via the External Accessory framework:

```xml
<key>UISupportedExternalAccessoryProtocols</key>
<array>
    <string>com.ftsafe.bR301</string>
    <string>com.ftsafe.iR301</string>
</array>
```

You should also add Bluetooth permissions:

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>This app needs Bluetooth access to connect to FEITIAN card readers</string>
<key>NSBluetoothPeripheralUsageDescription</key>
<string>This app needs Bluetooth access to connect to FEITIAN card readers</string>
```

These entries are required for the app to communicate with FEITIAN iR301 and bR301 card readers.

## Usage

### Basic Example

```dart
import 'package:feitian_reader_sdk/feitian_reader_sdk.dart';
import 'package:flutter/services.dart';

class CardReaderExample {
  final _feitianPlugin = FeitianReaderSdk();
  static const platform = MethodChannel('feitian_reader_sdk');

  Future<void> setupCardReader() async {
    // Set up callback handlers
    platform.setMethodCallHandler(_handleMethodCall);
    
    // Connect to reader
    await _feitianPlugin.connectReader();
    
    // Power on card
    await _feitianPlugin.powerOnCard();
    
    // Send APDU command (e.g., select application)
    await _feitianPlugin.sendApduCommand('00A4040007A0000002471001');
    
    // Read card UID
    await _feitianPlugin.readUID();
    
    // Power off card
    await _feitianPlugin.powerOffCard();
    
    // Disconnect reader
    await _feitianPlugin.disconnectReader();
  }

  Future<void> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'log':
        print('Log: ${call.arguments}');
        break;
      case 'data':
        print('Data: ${call.arguments}');
        break;
      case 'apduResponse':
        print('APDU Response: ${call.arguments}');
        break;
    }
  }
}
```

### Common APDU Commands

```dart
// Select application
await plugin.sendApduCommand('00A4040007A0000002471001');

// Get challenge (8 bytes)
await plugin.sendApduCommand('0084000008');

// Read binary data
await plugin.sendApduCommand('00B00000FF');
```

## API Reference

### Methods

- `Future<String?> getPlatformVersion()` - Get iOS platform version
- `Future<String?> connectReader()` - Connect to FEITIAN card reader
- `Future<String?> disconnectReader()` - Disconnect from card reader
- `Future<String?> powerOnCard()` - Power on smart card (SCardConnect)
- `Future<String?> powerOffCard()` - Power off smart card (SCardDisconnect)
- `Future<String?> sendApduCommand(String apdu)` - Send APDU command to card
- `Future<String?> readUID()` - Read card unique identifier

### Callbacks (Method Channel)

The plugin sends callbacks via method channel `'feitian_reader_sdk'`:

- `log` - Log messages from native layer
- `data` - Data received from card
- `apduResponse` - Response from APDU command execution

## Architecture

```
Flutter Dart Layer
    ↓
feitian_reader_sdk.dart (Public API)
    ↓
feitian_reader_sdk_platform_interface.dart (Abstract Interface)
    ↓
feitian_reader_sdk_method_channel.dart (Method Channel Implementation)
    ↓
iOS Native Layer
    ↓
FeitianReaderSdkPlugin.swift (Flutter Bridge)
    ↓
FeitianCardManager.swift (PCSC Manager)
    ↓
FEITIAN SDK (winscard.h, ft301u.h)
```

## PCSC Interface

This plugin uses the PCSC (PC/SC) standard for smart card communication:

- **SCardEstablishContext** - Initialize PCSC context
- **SCardConnect** - Connect to smart card
- **SCardTransmit** - Send APDU commands
- **SCardControl** - Send control commands to reader
- **SCardDisconnect** - Disconnect from card
- **SCardReleaseContext** - Release PCSC context

## FEITIAN Demo Project Reference

The implementation is based on the FEITIAN SDK demo project located at:
`sdk/3.5.71/demo/iReader`

Key reference files:
- `OperationViewController.m/.mm` - Main card reader logic
- `winscard.h` - PCSC interface definitions
- `ft301u.h` - FEITIAN-specific functions

## Requirements

- **Flutter**: >= 3.3.0
- **Dart**: >= 3.4.3
- **iOS**: >= 12.0
- **FEITIAN SDK**: Version 3.5.71 or later

## Platform Support

Currently supports:
- ✅ iOS (12.0+)
- ❌ Android (planned for future release)

## Notes

- The FEITIAN SDK framework is required for full functionality
- PCSC communication requires proper card reader initialization
- APDU commands must be valid hex strings (minimum 5 characters, even length)
- Some functions (like readUID) may not be supported on all FEITIAN reader models

## Additional Documentation

See [FEITIAN_IMPLEMENTATION.md](FEITIAN_IMPLEMENTATION.md) for detailed technical implementation notes.

## License

See LICENSE file for details.

## Support

For issues and questions, please refer to the FEITIAN SDK documentation in `sdk/3.5.71/demo/`.