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

@interface ScanDeviceController () <ReaderInterfaceDelegate, CBCentralManagerDelegate>
@property (nonatomic, strong) CBCentralManager *central;
@property (nonatomic, strong) NSArray *slotarray;
@property (nonatomic, strong) ReaderInterface *interface;
@property (nonatomic, strong) NSMutableArray<readerModel *> *discoveredList;
@property (nonatomic, strong) NSMutableArray<NSString *> *deviceList;
@property (nonatomic, strong) NSString *selectedDeviceName;
@property (nonatomic, strong) NSString *connectedReaderName;
@property (nonatomic, assign) BOOL isScanning;
@property (nonatomic, strong) NSTimer *refreshTimer;
@end

@implementation ScanDeviceController

- (instancetype)init {
    self = [super init];
    if (self) {
        _deviceList = [NSMutableArray array];
        _discoveredList = [NSMutableArray array];
        _isScanning = NO;
        [self initReaderInterface];
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
    
    // Initialize card context if needed
    if (gContxtHandle == 0) {
        ULONG ret = SCardEstablishContext(SCARD_SCOPE_SYSTEM, NULL, NULL, &gContxtHandle);
        if (ret != 0) {
            [self notifyError:[NSString stringWithFormat:@"Failed to establish card context: 0x%08lx", ret]];
            return;
        } else {
            FtSetTimeout(gContxtHandle, 50000);
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
    
    [self logMessage:[NSString stringWithFormat:@"Connecting to reader: %@", readerName]];
    _selectedDeviceName = readerName;
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BOOL success = [self.interface connectPeripheralReader:readerName timeout:15];
        if (!success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self notifyError:@"Failed to connect to reader"];
            });
        }
    });
}

- (void)disconnectReader {
    if (_connectedReaderName) {
        [self logMessage:[NSString stringWithFormat:@"Disconnecting from reader: %@", _connectedReaderName]];
        _connectedReaderName = nil;
        gBluetoothID = @"";
        _slotarray = nil;
        
        if (gCardHandle != 0) {
            SCardDisconnect(gCardHandle, SCARD_LEAVE_CARD);
            gCardHandle = 0;
        }
        
        if ([_delegate respondsToSelector:@selector(scanControllerDidDisconnectReader:)]) {
            [_delegate scanControllerDidDisconnectReader:self];
        }
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
    // Implement EGK card reading logic here
    // This would involve APDU commands specific to EGK cards
    [self notifyError:@"EGK card reading not yet implemented"];
}

- (void)sendApduCommand:(NSString *)apduString {
    if (!apduString || apduString.length < 10) {
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
        
        unsigned char resp[2048 + 128];
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
            
            unsigned char resp[2048 + 128];
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
            [NSThread sleepForTimeInterval:0.05];
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
    _interface = [[ReaderInterface alloc] init];
    [_interface setAutoPair:NO];  // Manual connection mode
    [_interface setDelegate:self];
    
    // Set device types to support
    [FTDeviceType setDeviceType:(FTDEVICETYPE)(IR301_AND_BR301 | BR301BLE_AND_BR500 | LINE_TYPEC)];
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
        _connectedReaderName = _selectedDeviceName;
        
        // Get reader name and battery level
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSString *readerModelName = [self getReaderModelName];
            if (readerModelName) {
                [self logMessage:[NSString stringWithFormat:@"Connected reader model: %@", readerModelName]];
            }
            
            // Wait for reader to be ready before requesting battery
            [NSThread sleepForTimeInterval:0.5];
            [self getBatteryLevel];
        });
        
        // Notify Flutter about connection
        NSMutableArray<NSString *> *slotNames = [NSMutableArray array];
        for (NSString *slot in slotArray) {
            [slotNames addObject:slot];
        }
        
        [self logMessage:[NSString stringWithFormat:@"Connected to reader: %@", _selectedDeviceName]];
        
        if ([_delegate respondsToSelector:@selector(scanController:didConnectReader:slots:)]) {
            [_delegate scanController:self didConnectReader:_selectedDeviceName slots:slotNames];
        }
    } else {
        // Handle disconnection
        [self logMessage:@"Reader disconnected"];
        [self logMessage:[NSString stringWithFormat:@"Disconnected Bluetooth ID: %@", gBluetoothID]];
        
        [self disconnectReader];
    }
}

- (void)cardInterfaceDidDetach:(BOOL)attached slotname:(NSString *)slotname {
    if (attached) {
        [self logMessage:[NSString stringWithFormat:@"Card inserted in slot: %@", slotname]];
        if ([_delegate respondsToSelector:@selector(scanController:didDetectCard:)]) {
            [_delegate scanController:self didDetectCard:slotname];
        }
    } else {
        [self logMessage:[NSString stringWithFormat:@"Card removed from slot: %@", slotname]];
        if ([_delegate respondsToSelector:@selector(scanController:didRemoveCard:)]) {
            [_delegate scanController:self didRemoveCard:slotname];
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
    [self logMessage:[NSString stringWithFormat:@"Battery level: %ld%%", (long)battery]];
    if ([_delegate respondsToSelector:@selector(scanController:didReceiveBattery:)]) {
        [_delegate scanController:self didReceiveBattery:battery];
    }
}

@end
