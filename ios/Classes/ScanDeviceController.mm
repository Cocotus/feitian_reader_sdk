//
//  ScanDeviceController.mm
//  feitian_reader_sdk
//
//  Simplified non-UI implementation for Flutter integration
//  Based on FEITIAN iReader demo code
//

#import "ScanDeviceController.h"
#import "winscard.h"
#import "ReaderInterface.h"
#import <CoreBluetooth/CoreBluetooth.h>
#import "readerModel.h"

// Global context and card handle
static SCARDCONTEXT gContxtHandle = 0;
static SCARDHANDLE gCardHandle = 0;
static NSString *gBluetoothID = @"";

// Constants for APDU operations
static const NSUInteger MIN_APDU_LENGTH = 8; // Minimum hex string length (4 bytes: CLA INS P1 P2)
static const NSUInteger MAX_APDU_RESPONSE_SIZE = 2048 + 128;
static const NSTimeInterval APDU_COMMAND_DELAY = 0.05; // Delay between sequential commands
static const NSTimeInterval READER_READY_DELAY = 0.5; // Delay before querying battery after connection

@interface ScanDeviceController () <ReaderInterfaceDelegate, CBCentralManagerDelegate>
@property (nonatomic, strong) CBCentralManager *central;
@property (nonatomic, strong) NSArray *slotarray;
@property (nonatomic, strong) ReaderInterface *interface;
@property (nonatomic, strong) NSMutableArray<readerModel *> *discoveredList;
@property (nonatomic, strong) NSMutableArray<NSString *> *deviceList;
@property (nonatomic, strong) NSString *selectedDeviceName;
@property (nonatomic, strong) NSString *connectedReaderName;
@property (nonatomic, assign) BOOL isScanning;
@property (nonatomic, assign) BOOL isReaderInterfaceInitialized;
@property (nonatomic, strong) NSTimer *refreshTimer;
@end

@implementation ScanDeviceController

- (instancetype)init {
    self = [super init];
    if (self) {
        _deviceList = [NSMutableArray array];
        _discoveredList = [NSMutableArray array];
        _isScanning = NO;
        _isReaderInterfaceInitialized = NO;
        // ✅ BUGFIX: Removed [self initReaderInterface] from init
        // It must be called BEFORE SCardEstablishContext in startScanning
    }
    return self;
}

- (void)dealloc {
    [self stopScanning];
    [self disconnectReader];
    if (gContxtHandle != 0) {
        SCardReleaseContext(gContxtHandle);
        gContxtHandle = 0;
    }
}

#pragma mark - Public Methods

- (void)startScanning {
    if (_isScanning) {
        [self logMessage:@"Already scanning"];
        return;
    }
    
    [self logMessage:@"Starting Bluetooth scan"];
    _isScanning = YES;
    
    // ✅ BUGFIX: Initialize ReaderInterface BEFORE SCardEstablishContext
    // This is required according to FEITIAN SDK documentation:
    // "setAutoPair must be invoked before SCardEstablishContext"
    if (!_isReaderInterfaceInitialized) {
        [self initReaderInterface];
        _isReaderInterfaceInitialized = YES;
    }
    
    // Initialize card context if needed (AFTER initReaderInterface)
    if (gContxtHandle == 0) {
        ULONG ret = SCardEstablishContext(SCARD_SCOPE_SYSTEM, NULL, NULL, &gContxtHandle);
        if (ret != 0) {
            [self notifyError:[NSString stringWithFormat:@"Failed to establish card context: 0x%08lx", ret]];
            _isScanning = NO;
            return;
        } else {
            FtSetTimeout(gContxtHandle, 50000);
            [self logMessage:@"Card context established successfully"];
        }
    } else {
        // Context already exists, reset it to ensure proper initialization
        [self logMessage:@"Resetting existing card context"];
        SCardReleaseContext(gContxtHandle);
        gContxtHandle = 0;
        
        ULONG ret = SCardEstablishContext(SCARD_SCOPE_SYSTEM, NULL, NULL, &gContxtHandle);
        if (ret != 0) {
            [self notifyError:[NSString stringWithFormat:@"Failed to re-establish card context: 0x%08lx", ret]];
            _isScanning = NO;
            return;
        } else {
            FtSetTimeout(gContxtHandle, 50000);
            [self logMessage:@"Card context re-established successfully"];
        }
    }
    
    // Start Bluetooth scanning
    [self beginScanBLEDevice];
    
    // Start refresh timer to clean up old devices
    [self startRefreshTimer];
}

- (void)stopScanning {
    if (!_isScanning) {
        return;
    }
    
    [self logMessage:@"Stopping Bluetooth scan"];
    _isScanning = NO;
    [self stopScanBLEDevice];
    [self stopRefreshTimer];
}

- (void)connectToReader:(NSString *)readerName {
    if (!readerName || readerName.length == 0) {
        [self notifyError:@"Reader name is required"];
        return;
    }
    
    // Ensure SDK is properly initialized before connecting
    if (!_isReaderInterfaceInitialized) {
        [self notifyError:@"Reader interface not initialized. Please start scanning first."];
        return;
    }
    
    if (gContxtHandle == 0) {
        [self notifyError:@"Card context not established. Please start scanning first."];
        return;
    }
    
    [self logMessage:[NSString stringWithFormat:@"Connecting to reader: %@", readerName]];
    _selectedDeviceName = readerName;
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BOOL success = [self.interface connectPeripheralReader:readerName timeout:15];
        if (!success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self notifyError:@"Failed to connect to reader"];
            });
        } else {
            [self logMessage:@"Reader connection initiated successfully"];
        }
    });
}

- (void)disconnectReader {
    if (_connectedReaderName) {
        [self logMessage:[NSString stringWithFormat:@"Disconnecting from reader: %@", _connectedReaderName]];
        
        // Disconnect card if connected
        if (gCardHandle != 0) {
            [self logMessage:@"Disconnecting card..."];
            SCardDisconnect(gCardHandle, SCARD_LEAVE_CARD);
            gCardHandle = 0;
        }
        
        // Disconnect Bluetooth reader
        if (_interface && gBluetoothID.length > 0) {
            [self logMessage:[NSString stringWithFormat:@"Disconnecting Bluetooth reader: %@", gBluetoothID]];
            [_interface disconnectPeripheralReader:gBluetoothID];
        }
        
        // Clear state
        _connectedReaderName = nil;
        gBluetoothID = @"";
        _slotarray = nil;
        _batteryLoggedOnce = NO;
        
        // Notify Flutter
        if ([_delegate respondsToSelector:@selector(scanControllerDidDisconnectReader:)]) {
            [_delegate scanControllerDidDisconnectReader:self];
        }
        
        [self logMessage:@"Reader disconnected successfully"];
    } else {
        [self logMessage:@"No reader connected to disconnect"];
    }
}

- (void)getBatteryLevel {
    [self logMessage:@"Getting battery level"];
    // Battery level will be received via didGetBattery: delegate callback
}

- (void)powerOnCard {
    [self logMessage:@"Powering on card"];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self connectCard];
    });
}

- (void)powerOffCard {
    [self logMessage:@"Powering off card"];
    if (gCardHandle != 0) {
        SCardDisconnect(gCardHandle, SCARD_LEAVE_CARD);
        gCardHandle = 0;
    }
}

- (void)readEGKCard {
    [self logMessage:@"Reading EGK card data"];
    
    // Step 1: Connect to card (power on)
    DWORD dwActiveProtocol = -1;
    NSString *reader = [self getReaderList];
    
    if (!reader) {
        [self notifyError:@"No reader available for EGK card reading"];
        return;
    }
    
    [self logMessage:@"Connecting to EGK card..."];
    LONG ret = SCardConnect(gContxtHandle, [reader UTF8String], SCARD_SHARE_SHARED,
                           SCARD_PROTOCOL_T0 | SCARD_PROTOCOL_T1, &gCardHandle, &dwActiveProtocol);
    
    if (ret != SCARD_S_SUCCESS) {
        [self notifyError:[NSString stringWithFormat:@"Failed to connect to EGK card: 0x%08lx", ret]];
        return;
    }
    
    [self logMessage:@"EGK card connected successfully"];
    
    // Step 2: Get ATR (Answer To Reset)
    unsigned char patr[33] = {0};
    DWORD atrLen = sizeof(patr);
    ret = SCardGetAttrib(gCardHandle, NULL, patr, &atrLen);
    if (ret != SCARD_S_SUCCESS) {
        [self logMessage:[NSString stringWithFormat:@"SCardGetAttrib warning: 0x%08lx", ret]];
    }
    
    // Convert ATR to hex string
    NSMutableString *atrHex = [NSMutableString string];
    for (DWORD i = 0; i < atrLen; i++) {
        [atrHex appendFormat:@"%02X", patr[i]];
    }
    [self logMessage:[NSString stringWithFormat:@"Card ATR: %@", atrHex]];
    
    // Step 3: Send EGK-specific APDU commands
    // TODO: Replace these placeholder commands with actual EGK APDU commands
    // Based on eGK specifications from gematik
    
    NSMutableDictionary *egkData = [NSMutableDictionary dictionary];
    egkData[@"atr"] = atrHex;
    egkData[@"cardType"] = @"EGK";
    egkData[@"readSuccess"] = @YES;
    
    // Placeholder APDU 1: Select EGK Root Application
    // Real command would be: SELECT FILE (AID for eGK root application)
    // Example: 00 A4 04 0C 07 D2 76 00 01 44 80 00
    [self logMessage:@"Sending APDU commands to read EGK data..."];
    [self logMessage:@"TODO: Implement actual EGK APDU commands"];
    [self logMessage:@"TODO: Command 1 - Select eGK Root Application"];
    [self logMessage:@"TODO: Command 2 - Select and read personal data (PD)"];
    [self logMessage:@"TODO: Command 3 - Select and read insurance data (VD)"];
    
    // Placeholder data - in real implementation, this would come from APDU responses
    egkData[@"placeholder"] = @"Replace with actual EGK data from APDU responses";
    egkData[@"patientName"] = @"[To be read from card]";
    egkData[@"insuranceNumber"] = @"[To be read from card]";
    egkData[@"insuranceCompany"] = @"[To be read from card]";
    
    [self logMessage:@"EGK card reading completed"];
    
    // Step 4: Notify Flutter with the data
    if ([_delegate respondsToSelector:@selector(scanController:didReadEGKData:)]) {
        [_delegate scanController:self didReadEGKData:egkData];
    }
    
    // Step 5: Auto-disconnect card
    [self logMessage:@"Disconnecting from card..."];
    if (gCardHandle != 0) {
        SCardDisconnect(gCardHandle, SCARD_LEAVE_CARD);
        gCardHandle = 0;
        [self logMessage:@"Card disconnected"];
    }
    
    // Step 6: Auto-disconnect reader
    [self logMessage:@"Disconnecting from reader..."];
    [self disconnectReader];
}

- (void)sendApduCommand:(NSString *)apduString {
    if (!apduString || apduString.length < MIN_APDU_LENGTH) {
        [self notifyError:@"Invalid APDU command"];
        return;
    }
    
    if (gCardHandle == 0) {
        [self notifyError:@"No card connected"];
        return;
    }
    
    [self logMessage:[NSString stringWithFormat:@"Sending APDU: %@", apduString]];
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Convert hex string to bytes
        NSData *apduData = [self hexStringToData:apduString];
        if (!apduData) {
            [self notifyError:@"Failed to parse APDU command"];
            return;
        }
        
        unsigned char *capdu = (unsigned char *)apduData.bytes;
        unsigned int capdulen = (unsigned int)apduData.length;
        
        unsigned char resp[MAX_APDU_RESPONSE_SIZE];
        memset(resp, 0, sizeof(resp));
        unsigned int resplen = sizeof(resp);
        
        // Send APDU to card
        SCARD_IO_REQUEST pioSendPci;
        LONG ret = SCardTransmit(gCardHandle, &pioSendPci, capdu, capdulen, NULL, resp, &resplen);
        
        if (ret != SCARD_S_SUCCESS) {
            [self notifyError:[NSString stringWithFormat:@"APDU transmission failed: 0x%08lx", ret]];
            return;
        }
        
        // Convert response to hex string
        NSMutableString *responseHex = [NSMutableString string];
        for (unsigned int i = 0; i < resplen; i++) {
            [responseHex appendFormat:@"%02X", resp[i]];
        }
        
        [self logMessage:[NSString stringWithFormat:@"APDU Response: %@", responseHex]];
        
        // Notify delegate
        if ([_delegate respondsToSelector:@selector(scanController:didReceiveApduResponse:)]) {
            [_delegate scanController:self didReceiveApduResponse:responseHex];
        }
    });
}

- (void)sendApduCommands:(NSArray<NSString *> *)apduCommands
          withCompletion:(void (^)(NSArray<NSString *> *responses, NSError *error))completion {
    
    if (!apduCommands || apduCommands.count == 0) {
        if (completion) {
            completion(nil, [NSError errorWithDomain:@"FeitianReaderSDK"
                                                code:-1
                                            userInfo:@{NSLocalizedDescriptionKey: @"No APDU commands provided"}]);
        }
        return;
    }
    
    if (gCardHandle == 0) {
        if (completion) {
            completion(nil, [NSError errorWithDomain:@"FeitianReaderSDK"
                                                code:-2
                                            userInfo:@{NSLocalizedDescriptionKey: @"No card connected"}]);
        }
        return;
    }
    
    [self logMessage:[NSString stringWithFormat:@"Sending %lu APDU commands sequentially", (unsigned long)apduCommands.count]];
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableArray *responses = [NSMutableArray array];
        NSError *error = nil;
        
        for (NSString *apduString in apduCommands) {
            // Convert hex string to bytes
            NSData *apduData = [self hexStringToData:apduString];
            if (!apduData) {
                error = [NSError errorWithDomain:@"FeitianReaderSDK"
                                            code:-3
                                        userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to parse APDU: %@", apduString]}];
                break;
            }
            
            unsigned char *capdu = (unsigned char *)apduData.bytes;
            unsigned int capdulen = (unsigned int)apduData.length;
            
            unsigned char resp[MAX_APDU_RESPONSE_SIZE];
            memset(resp, 0, sizeof(resp));
            unsigned int resplen = sizeof(resp);
            
            [self logMessage:[NSString stringWithFormat:@"Sending APDU [%lu/%lu]: %@",
                             (unsigned long)([apduCommands indexOfObject:apduString] + 1),
                             (unsigned long)apduCommands.count,
                             apduString]];
            
            // Send APDU to card
            SCARD_IO_REQUEST pioSendPci;
            LONG ret = SCardTransmit(gCardHandle, &pioSendPci, capdu, capdulen, NULL, resp, &resplen);
            
            if (ret != SCARD_S_SUCCESS) {
                error = [NSError errorWithDomain:@"FeitianReaderSDK"
                                            code:ret
                                        userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"APDU failed: 0x%08lx", ret]}];
                break;
            }
            
            // Convert response to hex string
            NSMutableString *responseHex = [NSMutableString string];
            for (unsigned int i = 0; i < resplen; i++) {
                [responseHex appendFormat:@"%02X", resp[i]];
            }
            
            [responses addObject:responseHex];
            [self logMessage:[NSString stringWithFormat:@"Response [%lu/%lu]: %@",
                             (unsigned long)responses.count,
                             (unsigned long)apduCommands.count,
                             responseHex]];
            
            // Small delay between commands
            [NSThread sleepForTimeInterval:APDU_COMMAND_DELAY];
        }
        
        // Call completion on main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(error ? nil : responses, error);
            }
        });
    });
}

#pragma mark - Private Methods

- (void)initReaderInterface {
    if (_interface) {
        // Already initialized
        [self logMessage:@"ReaderInterface already initialized"];
        return;
    }
    
    [self logMessage:@"Initializing ReaderInterface"];
    _interface = [[ReaderInterface alloc] init];
    
    // ✅ CRITICAL: setAutoPair MUST be called BEFORE SCardEstablishContext
    // This ensures the SDK properly initializes the Bluetooth connection
    // and sends the required WriteSerial command (0x6b04...) to the reader
    [_interface setAutoPair:YES];  // Manual connection mode
    [_interface setDelegate:self];
    
    // Set device types to support
    [FTDeviceType setDeviceType:(FTDEVICETYPE)(IR301_AND_BR301 | BR301BLE_AND_BR500 | LINE_TYPEC)];
    
    [self logMessage:@"ReaderInterface initialized successfully"];
}

- (void)beginScanBLEDevice {
    dispatch_queue_t centralQueue = dispatch_queue_create("com.feitian.ble.scan", DISPATCH_QUEUE_SERIAL);
    self.central = [[CBCentralManager alloc] initWithDelegate:self queue:centralQueue];
}

- (void)stopScanBLEDevice {
    if (_central) {
        [_central stopScan];
        _central = nil;
    }
    
    [_discoveredList removeAllObjects];
    [_deviceList removeAllObjects];
}

- (void)scanDevice {
    NSDictionary *options = @{CBCentralManagerScanOptionAllowDuplicatesKey: @YES};
    [_central scanForPeripheralsWithServices:nil options:options];
}

- (BOOL)checkFTBLEDeviceByAdv:(NSDictionary *)adv {
    BOOL ret = NO;
    NSArray *serviceUUIDs = [adv objectForKey:CBAdvertisementDataServiceUUIDsKey];
    
    if (serviceUUIDs && serviceUUIDs.count > 0) {
        CBUUID *serviceUUID = serviceUUIDs[0];
        NSInteger type = 0;
        ret = [self checkFTBLEDeviceByUUID:serviceUUID.data UUIDType:&type];
        if (ret && type != 1) {
            ret = NO;
        }
    }
    return ret;
}

- (BOOL)checkFTBLEDeviceByUUID:(NSData *)uuidData UUIDType:(NSInteger *)type {
    if (uuidData.length != 16) {
        return NO;
    }
    
    Byte bServiceUUID[16] = {0};
    [uuidData getBytes:bServiceUUID length:16];
    
    if ((memcmp(bServiceUUID, "FT", 2) == 0) && (bServiceUUID[5] == 0x02)) {
        *type = bServiceUUID[3];
        return YES;
    }
    return NO;
}

- (void)connectCard {
    DWORD dwActiveProtocol = -1;
    NSString *reader = [self getReaderList];
    
    if (!reader) {
        [self notifyError:@"No reader available"];
        return;
    }
    
    LONG ret = SCardConnect(gContxtHandle, [reader UTF8String], SCARD_SHARE_SHARED,
                           SCARD_PROTOCOL_T0 | SCARD_PROTOCOL_T1, &gCardHandle, &dwActiveProtocol);
    
    if (ret != 0) {
        [self notifyError:[NSString stringWithFormat:@"Failed to connect to card: 0x%08lx", ret]];
        return;
    }
    
    unsigned char patr[33] = {0};
    DWORD len = sizeof(patr);
    ret = SCardGetAttrib(gCardHandle, NULL, patr, &len);
    if (ret != SCARD_S_SUCCESS) {
        [self logMessage:[NSString stringWithFormat:@"SCardGetAttrib warning: 0x%08lx", ret]];
    }
    
    [self logMessage:@"Card powered on successfully"];
}

- (NSString *)getReaderList {
    DWORD readerLength = 0;
    LONG ret = SCardListReaders(gContxtHandle, nil, nil, &readerLength);
    if (ret != 0) {
        [self notifyError:[NSString stringWithFormat:@"Failed to list readers: 0x%08lx", ret]];
        return nil;
    }
    
    LPSTR readers = (LPSTR)malloc(readerLength * sizeof(char));
    ret = SCardListReaders(gContxtHandle, nil, readers, &readerLength);
    if (ret != 0) {
        [self notifyError:[NSString stringWithFormat:@"Failed to list readers: 0x%08lx", ret]];
        free(readers);
        return nil;
    }
    
    NSString *strReaders = [NSString stringWithUTF8String:readers];
    free(readers);
    return strReaders;
}

- (void)startRefreshTimer {
    __weak typeof(self) weakSelf = self;
    _refreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer * _Nonnull timer) {
        [weakSelf refreshDeviceList];
    }];
}

- (void)stopRefreshTimer {
    if (_refreshTimer) {
        [_refreshTimer invalidate];
        _refreshTimer = nil;
    }
}

- (void)refreshDeviceList {
    // Remove devices that haven't been seen in the last second
    NSArray *tempList = [_discoveredList copy];
    NSDate *now = [NSDate date];
    for (readerModel *model in tempList) {
        NSDate *lastSeen = model.date;
        if ([now timeIntervalSinceDate:lastSeen] >= 1.0) {
            [_deviceList removeObject:model.name];
            [_discoveredList removeObject:model];
        }
    }
}

- (void)logMessage:(NSString *)message {
    NSLog(@"[ScanDeviceController] %@", message);
    if ([_delegate respondsToSelector:@selector(scanController:didReceiveLog:)]) {
        [_delegate scanController:self didReceiveLog:message];
    }
}

- (void)notifyError:(NSString *)error {
    NSLog(@"[ScanDeviceController] ERROR: %@", error);
    if ([_delegate respondsToSelector:@selector(scanController:didReceiveError:)]) {
        [_delegate scanController:self didReceiveError:error];
    }
}

- (NSString *)getReaderModelName {
    if (gContxtHandle == 0) {
        return nil;
    }
    
    unsigned int length = 0;
    char buffer[100] = {0};
    LONG ret = FtGetReaderName(gContxtHandle, &length, buffer);
    
    if (ret != SCARD_S_SUCCESS || length == 0) {
        [self notifyError:[NSString stringWithFormat:@"Failed to get reader name: 0x%08lx", ret]];
        return nil;
    }
    
    return [NSString stringWithUTF8String:buffer];
}

/**
 * Convert a hex string to NSData
 * @param hexString Hex string representation (e.g., "00A4040007A0000002471001")
 *                  Spaces are allowed and will be removed
 * @return NSData containing the bytes, or nil if the string is invalid
 *         Returns nil if:
 *         - The string has an odd number of characters (after removing spaces)
 *         - The string contains non-hex characters
 */
- (NSData *)hexStringToData:(NSString *)hexString {
    NSString *cleanHex = [hexString stringByReplacingOccurrencesOfString:@" " withString:@""];
    cleanHex = [cleanHex uppercaseString];
    
    if (cleanHex.length % 2 != 0) {
        return nil;
    }
    
    NSMutableData *data = [NSMutableData data];
    for (NSUInteger i = 0; i < cleanHex.length; i += 2) {
        NSString *byteString = [cleanHex substringWithRange:NSMakeRange(i, 2)];
        unsigned int byte;
        if ([[NSScanner scannerWithString:byteString] scanHexInt:&byte]) {
            unsigned char byteValue = (unsigned char)byte;
            [data appendBytes:&byteValue length:1];
        } else {
            return nil;
        }
    }
    
    return data;
}

#pragma mark - CBCentralManagerDelegate

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    switch (central.state) {
        case CBManagerStatePoweredOn:
            [self logMessage:@"Bluetooth powered on, starting scan"];
            [self scanDevice];
            break;
        case CBManagerStatePoweredOff:
            [self logMessage:@"Bluetooth powered off"];
            [self notifyError:@"Bluetooth is powered off"];
            break;
        case CBManagerStateUnsupported:
            [self notifyError:@"Bluetooth is not supported on this device"];
            break;
        case CBManagerStateUnauthorized:
            [self notifyError:@"Bluetooth permission not granted"];
            break;
        default:
            break;
    }
}

- (void)centralManager:(CBCentralManager *)central
 didDiscoverPeripheral:(CBPeripheral *)peripheral
     advertisementData:(NSDictionary<NSString *, id> *)advertisementData
                  RSSI:(NSNumber *)RSSI {
    
    NSString *deviceName = peripheral.name;
    
    if (!deviceName || deviceName.length == 0) {
        return;
    }
    
    if (![self checkFTBLEDeviceByAdv:advertisementData]) {
        return;
    }
    
    // Check if device already discovered
    for (readerModel *model in _discoveredList) {
        if ([model.name isEqualToString:deviceName]) {
            model.date = [NSDate date];  // Update last seen time
            return;
        }
    }
    
    // New device discovered
    readerModel *model = [readerModel modelWithName:deviceName scanDate:[NSDate date]];
    [_discoveredList addObject:model];
    [_deviceList addObject:deviceName];
    
    [self logMessage:[NSString stringWithFormat:@"Discovered device: %@ (RSSI: %@)", deviceName, RSSI]];
    
    if ([_delegate respondsToSelector:@selector(scanController:didDiscoverDevice:rssi:)]) {
        [_delegate scanController:self didDiscoverDevice:deviceName rssi:[RSSI integerValue]];
    }
}

#pragma mark - ReaderInterfaceDelegate

- (void)readerInterfaceDidChange:(BOOL)attached
                     bluetoothID:(NSString *)bluetoothID
                andslotnameArray:(NSArray *)slotArray {
    
    [self logMessage:[NSString stringWithFormat:@"Reader interface changed, attached: %d", attached]];
    
    if (attached) {
        [self stopScanBLEDevice];
        [self stopRefreshTimer];
        
        gBluetoothID = bluetoothID;
        _slotarray = slotArray.count > 0 ? slotArray : nil;
        
        // ✅ OPTIMIZATION: Reset battery log flag on new connection
        _batteryLoggedOnce = NO;
        
        // ✅ FIX: Only set _connectedReaderName if _selectedDeviceName is valid
        if (_selectedDeviceName && _selectedDeviceName.length > 0) {
            _connectedReaderName = _selectedDeviceName;
        } else {
            // Fallback to bluetoothID if _selectedDeviceName is not set
            // This happens when AutoPair connects automatically without explicit connectToReader call
            _connectedReaderName = bluetoothID;
            [self logMessage:@"⚠️ Warning: _selectedDeviceName was nil, using bluetoothID instead"];
        }
        
        [self logMessage:@"✅ Reader connected successfully - WriteSerial command should have been sent"];
        
        // Get reader name and battery level
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSString *readerModelName = [self getReaderModelName];
            if (readerModelName) {
                [self logMessage:[NSString stringWithFormat:@"Connected reader model: %@", readerModelName]];
                
                // Update _connectedReaderName with the actual model name if we got it
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.connectedReaderName = readerModelName;
                });
            }
            
            // Wait for reader to be ready before requesting battery
            [NSThread sleepForTimeInterval:READER_READY_DELAY];
            [self getBatteryLevel];
        });
        
        // Notify Flutter about connection
        NSMutableArray<NSString *> *slotNames = [NSMutableArray array];
        for (NSString *slot in slotArray) {
            [slotNames addObject:slot];
        }
        
        [self logMessage:[NSString stringWithFormat:@"Connected to reader: %@", _connectedReaderName]];
        
        // ✅ FIX: Only call delegate if we have a valid reader name
        if (_connectedReaderName && _connectedReaderName.length > 0) {
            if ([_delegate respondsToSelector:@selector(scanController:didConnectReader:slots:)]) {
                [_delegate scanController:self didConnectReader:_connectedReaderName slots:slotNames];
            }
        } else {
            [self notifyError:@"Failed to determine connected reader name"];
        }
    } else {
        // Handle disconnection
        [self logMessage:@"Reader disconnected"];
        [self logMessage:[NSString stringWithFormat:@"Disconnected Bluetooth ID: %@", gBluetoothID]];
        
        [self disconnectReader];
    }
}

- (void)cardInterfaceDidDetach:(BOOL)attached slotname:(NSString *)slotname {
    // ✅ BUGFIX: Nil check for slotname to prevent crash
    NSString *safeSlotName = slotname ?: @"Unknown Slot";
    
    if (attached) {
        [self logMessage:[NSString stringWithFormat:@"Card inserted in slot: %@", safeSlotName]];
        if ([_delegate respondsToSelector:@selector(scanController:didDetectCard:)]) {
            [_delegate scanController:self didDetectCard:safeSlotName];
        }
        
        // ✅ FEATURE: Automatically read EGK card on insertion
        [self logMessage:@"Automatically triggering EGK card read"];
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self readEGKCard];
        });
    } else {
        [self logMessage:[NSString stringWithFormat:@"Card removed from slot: %@", safeSlotName]];
        if ([_delegate respondsToSelector:@selector(scanController:didRemoveCard:)]) {
            [_delegate scanController:self didRemoveCard:safeSlotName];
        }
    }
}

- (void)findPeripheralReader:(NSString *)readerName {
    if (!readerName) {
        return;
    }
    
    if ([_deviceList containsObject:readerName]) {
        return;
    }
    
    [_deviceList addObject:readerName];
    [self logMessage:[NSString stringWithFormat:@"Found peripheral reader: %@", readerName]];
}

- (void)didGetBattery:(NSInteger)battery {
    // ✅ OPTIMIZATION: Only log battery level once per connection
    if (!_batteryLoggedOnce) {
        [self logMessage:[NSString stringWithFormat:@"Battery level: %ld%%", (long)battery]];
        _batteryLoggedOnce = YES;
    }
    
    // Always notify delegate so Flutter can update UI
    if ([_delegate respondsToSelector:@selector(scanController:didReceiveBattery:)]) {
        [_delegate scanController:self didReceiveBattery:battery];
    }
}

@end
