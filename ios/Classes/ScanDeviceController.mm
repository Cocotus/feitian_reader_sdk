//
//  ScanDeviceController.mm
//  feitian_reader_sdk
//
//  Vereinfachte Implementierung ohne UI für Flutter-Integration
//  Basierend auf FEITIAN iReader Demo-Code
//

#import "ScanDeviceController.h"
#import "winscard.h"
#import "ReaderInterface.h"
#import <CoreBluetooth/CoreBluetooth.h>
#import "readerModel.h"

// Globaler Kontext und Kartenhandle
static SCARDCONTEXT gContxtHandle = 0;
static SCARDHANDLE gCardHandle = 0;
static NSString *gBluetoothID = @"";

// Konstanten für APDU-Operationen
static const NSUInteger MIN_APDU_LENGTH = 8; // Minimale Hex-String-Länge (4 Bytes: CLA INS P1 P2)
static const NSUInteger MAX_APDU_RESPONSE_SIZE = 2048 + 128;
static const NSTimeInterval APDU_COMMAND_DELAY = 0.05; // Verzögerung zwischen aufeinanderfolgenden Befehlen
static const NSTimeInterval READER_READY_DELAY = 0.5; // Verzögerung vor Batterieabfrage nach Verbindung

// Konstanten für SDK-Initialisierung und Disconnect-Timing
static const NSTimeInterval SDK_INITIALIZATION_DELAY = 0.5; // 500ms delay for SDK to initialize
static const NSTimeInterval CONTEXT_ESTABLISHMENT_DELAY = 0.3; // 300ms delay for context to establish
static const NSTimeInterval SDK_DISCONNECT_DELAY = 0.3; // 300ms delay for SDK to complete disconnect operations

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

/**
 * Internal method for continuing EGK card reading after SDK initialization delays
 * This is called after giving SDK time to initialize in readEGKCardOnDemand
 */
- (void)continueReadEGKCardOnDemand;

@end

@implementation ScanDeviceController

- (instancetype)init {
    self = [super init];
    if (self) {
        _deviceList = [NSMutableArray array];
        _discoveredList = [NSMutableArray array];
        _isScanning = NO;
        _isReaderInterfaceInitialized = NO;
        // ✅ BUGFIX: [self initReaderInterface] aus init entfernt
        // Es muss VOR SCardEstablishContext in startScanning aufgerufen werden
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
        [self logMessage:@"Scan läuft bereits"];
        return;
    }
    
    [self logMessage:@"Starte Bluetooth-Scan"];
    _isScanning = YES;
    
    // ✅ BUGFIX: ReaderInterface VOR SCardEstablishContext initialisieren
    // Dies ist laut FEITIAN SDK-Dokumentation erforderlich:
    // "setAutoPair muss vor SCardEstablishContext aufgerufen werden"
    if (!_isReaderInterfaceInitialized) {
        [self initReaderInterface];
        _isReaderInterfaceInitialized = YES;
    }
    
    // Kartenkontext initialisieren falls erforderlich (NACH initReaderInterface)
    if (gContxtHandle == 0) {
        ULONG ret = SCardEstablishContext(SCARD_SCOPE_SYSTEM, NULL, NULL, &gContxtHandle);
        if (ret != 0) {
            [self notifyError:[NSString stringWithFormat:@"Fehler beim Herstellen des Kartenkontexts: 0x%08lx", ret]];
            _isScanning = NO;
            return;
        } else {
            FtSetTimeout(gContxtHandle, 50000);
            [self logMessage:@"Kartenkontext erfolgreich hergestellt"];
        }
    } else {
        // Kontext existiert bereits, zurücksetzen um korrekte Initialisierung sicherzustellen
        [self logMessage:@"Setze vorhandenen Kartenkontext zurück"];
        SCardReleaseContext(gContxtHandle);
        gContxtHandle = 0;
        
        ULONG ret = SCardEstablishContext(SCARD_SCOPE_SYSTEM, NULL, NULL, &gContxtHandle);
        if (ret != 0) {
            [self notifyError:[NSString stringWithFormat:@"Fehler beim erneuten Herstellen des Kartenkontexts: 0x%08lx", ret]];
            _isScanning = NO;
            return;
        } else {
            FtSetTimeout(gContxtHandle, 50000);
            [self logMessage:@"Kartenkontext erfolgreich erneut hergestellt"];
        }
    }
    
    // Starte Bluetooth-Scan
    [self beginScanBLEDevice];
    
    // Starte Refresh-Timer um alte Geräte zu entfernen
    [self startRefreshTimer];
}

- (void)stopScanning {
    if (!_isScanning) {
        return;
    }
    
    [self logMessage:@"Stoppe Bluetooth-Scan"];
    _isScanning = NO;
    [self stopScanBLEDevice];
    [self stopRefreshTimer];
}

- (void)connectToReader:(NSString *)readerName {
    if (!readerName || readerName.length == 0) {
        [self notifyError:@"Kartenlesername erforderlich"];
        return;
    }
    
    // Sicherstellen, dass SDK vor Verbindung korrekt initialisiert ist
    if (!_isReaderInterfaceInitialized) {
        [self notifyError:@"Kartenleser-Schnittstelle nicht initialisiert. Bitte starten Sie zuerst den Scan."];
        return;
    }
    
    if (gContxtHandle == 0) {
        [self notifyError:@"Kartenkontext nicht hergestellt. Bitte starten Sie zuerst den Scan."];
        return;
    }
    
    [self logMessage:[NSString stringWithFormat:@"Verbinde mit Kartenleser: %@", readerName]];
    _selectedDeviceName = readerName;
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BOOL success = [self.interface connectPeripheralReader:readerName timeout:15];
        if (!success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self notifyError:@"Verbindung zum Kartenleser fehlgeschlagen"];
            });
        } else {
            [self logMessage:@"Kartenleserverbindung erfolgreich initiiert"];
        }
    });
}

- (void)disconnectReader {
    [self logMessage:@"Starte Trennvorgang..."];
    
    // Step 1: Disconnect card if connected
    if (gCardHandle != 0) {
        [self logMessage:@"Trenne Karte..."];
        SCardDisconnect(gCardHandle, SCARD_LEAVE_CARD);
        gCardHandle = 0;
    }
    
    // Step 2: Disconnect Bluetooth reader
    if (_interface && gBluetoothID.length > 0) {
        [self logMessage:[NSString stringWithFormat:@"Trenne Bluetooth-Kartenleser: %@", gBluetoothID]];
        [_interface disConnectCurrentPeripheralReader];
    }
    
    // Step 3: Stop BLE scanning BEFORE cleanup to prevent new events
    [self stopScanBLEDevice];
    
    // Step 4: Wait for SDK to finish disconnect operations (300ms delay)
    // This prevents race conditions where SDK events arrive after delegate is set to nil
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SDK_DISCONNECT_DELAY * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // Step 5: Clean up ReaderInterface to stop all delegate callbacks
        if (self->_interface) {
            [self logMessage:@"Bereinige ReaderInterface..."];
            [self->_interface setDelegate:nil];
            self->_interface = nil;
            [self logMessage:@"ReaderInterface bereinigt"];
        }
        
        // Step 6: Reset all state flags
        self->_isReaderInterfaceInitialized = NO;
        self->_connectedReaderName = nil;
        gBluetoothID = @"";
        self->_slotarray = nil;
        self->_batteryLoggedOnce = NO;
        
        // Step 7: Notify Flutter about disconnection
        if ([self.delegate respondsToSelector:@selector(scanControllerDidDisconnectReader:)]) {
            [self.delegate scanControllerDidDisconnectReader:self];
        }
        
        [self logMessage:@"✅ Kartenleser erfolgreich getrennt - SDK bereinigt"];
    });
}

- (void)getBatteryLevel {
    [self logMessage:@"Rufe Batteriestand ab"];
    // Batteriestand wird über didGetBattery: Delegate-Callback empfangen
}

- (void)powerOnCard {
    [self logMessage:@"Schalte Karte ein"];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self connectCard];
    });
}

- (void)powerOffCard {
    [self logMessage:@"Schalte Karte aus"];
    if (gCardHandle != 0) {
        SCardDisconnect(gCardHandle, SCARD_LEAVE_CARD);
        gCardHandle = 0;
    }
}

- (void)sendLog:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.delegate respondsToSelector:@selector(scanController:didReceiveLog:)]) {
            [self.delegate scanController:self didReceiveLog:message];
        }
    });
}

- (void)sendDataToFlutter:(NSArray<NSString *> *)data {
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.delegate respondsToSelector:@selector(scanController:didSendCardData:)]) {
            [self.delegate scanController:self didSendCardData:data];
        }
    });
}

- (void)notifyNoDataMobileMode {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self sendLog:@"Keine Karte gefunden!"];
        if ([self.delegate respondsToSelector:@selector(scanControllerDidNotifyNoCard:)]) {
            [self.delegate scanControllerDidNotifyNoCard:self];
        }
    });
}

- (void)notifyNoBluetooth {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self sendLog:@"Kartenleser nicht verbunden!"];
        if ([self.delegate respondsToSelector:@selector(scanControllerDidNotifyNoReader:)]) {
            [self.delegate scanControllerDidNotifyNoReader:self];
        }
    });
}

- (void)notifyBattery:(NSInteger)battery {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (battery < 10) {
            if ([self.delegate respondsToSelector:@selector(scanController:didReceiveLowBattery:)]) {
                [self.delegate scanController:self didReceiveLowBattery:battery];
            }
        }
    });
}


- (void)readEGKCard {
    [self logMessage:@"🔷 Starte EGK-Kartenauslesung mit GEMATIK-Spezifikation"];
    
    // Schritt 1: Kartenverbindung herstellen (power on)
    DWORD dwActiveProtocol = -1;
    NSString *reader = [self getReaderList];
    
    if (!reader) {
        [self notifyError:@"❌ Kein Kartenleser verfügbar"];
        return;
    }
    
    [self logMessage:@"📡 Verbinde mit EGK-Karte..."];
    LONG ret = SCardConnect(gContxtHandle, [reader UTF8String], SCARD_SHARE_SHARED,
                           SCARD_PROTOCOL_T0 | SCARD_PROTOCOL_T1, &gCardHandle, &dwActiveProtocol);
    
    if (ret != SCARD_S_SUCCESS) {
        [self notifyError:[NSString stringWithFormat:@"❌ Fehler bei Kartenverbindung: 0x%08lx", ret]];
        return;
    }
    
    [self logMessage:@"✅ EGK-Karte erfolgreich verbunden"];
    
    // Schritt 2: EGKCardReader erstellen und Auslesevorgang starten
    EGKCardReader *cardReader = [[EGKCardReader alloc] initWithCardHandle:gCardHandle context:gContxtHandle];
    cardReader.delegate = self;
    
    EGKCardData *cardData = [cardReader readEGKCard];
    
    // Schritt 3: Ergebnisse verarbeiten
    if (cardData) {
        [self logMessage:@"✅ EGK-Kartendaten erfolgreich ausgelesen"];
        
        // Konvertiere zu Dictionary und sende an Flutter
        NSDictionary *egkDict = [cardData toDictionary];
        if ([_delegate respondsToSelector:@selector(scanController:didReadEGKData:)]) {
            [_delegate scanController:self didReadEGKData:egkDict];
        }
    } else {
        [self logMessage:@"❌ Fehler beim Auslesen der EGK-Kartendaten"];
    }
    
    // Schritt 4: Auto-Disconnect von Karte
    [self logMessage:@"🔌 Trenne Karte..."];
    if (gCardHandle != 0) {
        SCardDisconnect(gCardHandle, SCARD_LEAVE_CARD);
        gCardHandle = 0;
        [self logMessage:@"✅ Karte getrennt"];
    }
    
    // Schritt 5: Auto-Disconnect von Kartenleser
    [self logMessage:@"🔌 Trenne Kartenleser..."];
    [self disconnectReader];
}

- (void)readEGKCardOnDemand {
    [self logMessage:@"Starte On-Demand EGK-Kartenauslesung"];
    
    // Step 1: Initialize SDK if needed
    if (!_isReaderInterfaceInitialized) {
        [self logMessage:@"Kartenleser-Schnittstelle nicht initialisiert, initialisiere jetzt..."];
        [self initReaderInterface];
        _isReaderInterfaceInitialized = YES;
        
        // ✅ FIX: Give SDK 500ms to initialize before continuing
        [self logMessage:@"⏳ Warte 500ms für SDK-Initialisierung..."];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SDK_INITIALIZATION_DELAY * NSEC_PER_SEC)), 
                      dispatch_get_main_queue(), ^{
            [self continueReadEGKCardOnDemand];
        });
        return;
    }
    
    // Step 2: Establish context if needed
    if (gContxtHandle == 0) {
        [self logMessage:@"Kartenkontext nicht hergestellt, stelle jetzt her..."];
        ULONG ret = SCardEstablishContext(SCARD_SCOPE_SYSTEM, NULL, NULL, &gContxtHandle);
        if (ret != 0) {
            [self notifyError:[NSString stringWithFormat:@"Fehler beim Herstellen des Kartenkontexts: 0x%08lx", ret]];
            return;
        } else {
            FtSetTimeout(gContxtHandle, 50000);
            [self logMessage:@"Kartenkontext erfolgreich hergestellt"];
            
            // ✅ FIX: Give SDK 300ms to establish context before continuing
            [self logMessage:@"⏳ Warte 300ms für Kontext-Etablierung..."];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(CONTEXT_ESTABLISHMENT_DELAY * NSEC_PER_SEC)), 
                          dispatch_get_main_queue(), ^{
                [self continueReadEGKCardOnDemand];
            });
            return;
        }
    }
    
    // Continue with card reading
    [self continueReadEGKCardOnDemand];
}

- (void)continueReadEGKCardOnDemand {
    [self logMessage:@"Fahre mit EGK-Kartenauslesung fort..."];
    
    // Check if reader is connected
    if (!_connectedReaderName || _connectedReaderName.length == 0) {
        [self logMessage:@"Kein Kartenleser verbunden"];
        [self notifyNoBluetooth];
        return;
    }
    
    // Get reader name
    NSString *reader = [self getReaderList];
    if (!reader) {
        [self logMessage:@"Kein Kartenleser für Kartenverbindung verfügbar"];
        [self notifyNoBluetooth];
        return;
    }
    
    // Try to connect to card (fails if no card is inserted)
    DWORD dwActiveProtocol = -1;
    [self logMessage:@"Prüfe auf Karte..."];
    LONG ret = SCardConnect(gContxtHandle, [reader UTF8String], SCARD_SHARE_SHARED,
                           SCARD_PROTOCOL_T0 | SCARD_PROTOCOL_T1, &gCardHandle, &dwActiveProtocol);
    
    if (ret != SCARD_S_SUCCESS) {
        // Differentiate between "no card" and other errors
        if (ret == SCARD_W_REMOVED_CARD || ret == SCARD_E_NO_SMARTCARD) {
            [self logMessage:[NSString stringWithFormat:@"Keine Karte gefunden: 0x%08lx", ret]];
            [self notifyNoDataMobileMode];  // No card inserted
        } else {
            [self logMessage:[NSString stringWithFormat:@"Kartenfehler: 0x%08lx", ret]];
            [self notifyError:[NSString stringWithFormat:@"Kartenverbindungsfehler: 0x%08lx", ret]];
        }
        return;
    }
    
    [self logMessage:@"✅ Karte gefunden und verbunden"];
    
    // Start EGK card reading
    [self readEGKCard];
}

- (void)sendApduCommand:(NSString *)apduString {
    if (!apduString || apduString.length < MIN_APDU_LENGTH) {
        [self notifyError:@"Ungültiger APDU-Befehl"];
        return;
    }
    
    if (gCardHandle == 0) {
        [self notifyError:@"Keine Karte verbunden"];
        return;
    }
    
    [self logMessage:[NSString stringWithFormat:@"Sende APDU: %@", apduString]];
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Konvertiere Hex-String zu Bytes
        NSData *apduData = [self hexStringToData:apduString];
        if (!apduData) {
            [self notifyError:@"Fehler beim Parsen des APDU-Befehls"];
            return;
        }
        
        unsigned char *capdu = (unsigned char *)apduData.bytes;
        unsigned int capdulen = (unsigned int)apduData.length;
        
        unsigned char resp[MAX_APDU_RESPONSE_SIZE];
        memset(resp, 0, sizeof(resp));
        unsigned int resplen = sizeof(resp);
        
        // APDU an Karte senden
        SCARD_IO_REQUEST pioSendPci;
        LONG ret = SCardTransmit(gCardHandle, &pioSendPci, capdu, capdulen, NULL, resp, &resplen);
        
        if (ret != SCARD_S_SUCCESS) {
            [self notifyError:[NSString stringWithFormat:@"APDU-Übertragung fehlgeschlagen: 0x%08lx", ret]];
            return;
        }
        
        // Antwort zu Hex-String konvertieren
        NSMutableString *responseHex = [NSMutableString string];
        for (unsigned int i = 0; i < resplen; i++) {
            [responseHex appendFormat:@"%02X", resp[i]];
        }
        
        [self logMessage:[NSString stringWithFormat:@"APDU-Antwort: %@", responseHex]];
        
        // Delegate benachrichtigen
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
                                            userInfo:@{NSLocalizedDescriptionKey: @"Keine APDU-Befehle angegeben"}]);
        }
        return;
    }
    
    if (gCardHandle == 0) {
        if (completion) {
            completion(nil, [NSError errorWithDomain:@"FeitianReaderSDK"
                                                code:-2
                                            userInfo:@{NSLocalizedDescriptionKey: @"Keine Karte verbunden"}]);
        }
        return;
    }
    
    [self logMessage:[NSString stringWithFormat:@"Sende %lu APDU-Befehle sequenziell", (unsigned long)apduCommands.count]];
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableArray *responses = [NSMutableArray array];
        NSError *error = nil;
        
        for (NSString *apduString in apduCommands) {
            // Konvertiere Hex-String zu Bytes
            NSData *apduData = [self hexStringToData:apduString];
            if (!apduData) {
                error = [NSError errorWithDomain:@"FeitianReaderSDK"
                                            code:-3
                                        userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Fehler beim Parsen des APDU: %@", apduString]}];
                break;
            }
            
            unsigned char *capdu = (unsigned char *)apduData.bytes;
            unsigned int capdulen = (unsigned int)apduData.length;
            
            unsigned char resp[MAX_APDU_RESPONSE_SIZE];
            memset(resp, 0, sizeof(resp));
            unsigned int resplen = sizeof(resp);
            
            [self logMessage:[NSString stringWithFormat:@"Sende APDU [%lu/%lu]: %@",
                             (unsigned long)([apduCommands indexOfObject:apduString] + 1),
                             (unsigned long)apduCommands.count,
                             apduString]];
            
            // Sende APDU an Karte
            SCARD_IO_REQUEST pioSendPci;
            LONG ret = SCardTransmit(gCardHandle, &pioSendPci, capdu, capdulen, NULL, resp, &resplen);
            
            if (ret != SCARD_S_SUCCESS) {
                error = [NSError errorWithDomain:@"FeitianReaderSDK"
                                            code:ret
                                        userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"APDU fehlgeschlagen: 0x%08lx", ret]}];
                break;
            }
            
            // Konvertiere Antwort zu Hex-String
            NSMutableString *responseHex = [NSMutableString string];
            for (unsigned int i = 0; i < resplen; i++) {
                [responseHex appendFormat:@"%02X", resp[i]];
            }
            
            [responses addObject:responseHex];
            [self logMessage:[NSString stringWithFormat:@"Antwort [%lu/%lu]: %@",
                             (unsigned long)responses.count,
                             (unsigned long)apduCommands.count,
                             responseHex]];
            
            // Kurze Verzögerung zwischen Befehlen
            [NSThread sleepForTimeInterval:APDU_COMMAND_DELAY];
        }
        
        // Completion auf Main-Thread aufrufen
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
        // Bereits initialisiert
        [self logMessage:@"ReaderInterface bereits initialisiert"];
        return;
    }
    
    [self logMessage:@"Initialisiere ReaderInterface"];
    _interface = [[ReaderInterface alloc] init];
    
    // ✅ KRITISCH: setAutoPair MUSS VOR SCardEstablishContext aufgerufen werden
    // Dies stellt sicher, dass das SDK die Bluetooth-Verbindung korrekt initialisiert
    // und den erforderlichen WriteSerial-Befehl (0x6b04...) an den Leser sendet
    [_interface setAutoPair:YES];  // Manueller Verbindungsmodus
    [_interface setDelegate:self];
    
    // Unterstützte Gerätetypen festlegen
    [FTDeviceType setDeviceType:(FTDEVICETYPE)(IR301_AND_BR301 | BR301BLE_AND_BR500 | LINE_TYPEC)];
    
    [self logMessage:@"ReaderInterface erfolgreich initialisiert"];
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
        [self notifyError:@"Kein Kartenleser verfügbar"];
        return;
    }
    
    LONG ret = SCardConnect(gContxtHandle, [reader UTF8String], SCARD_SHARE_SHARED,
                           SCARD_PROTOCOL_T0 | SCARD_PROTOCOL_T1, &gCardHandle, &dwActiveProtocol);
    
    if (ret != 0) {
        [self notifyError:[NSString stringWithFormat:@"Verbindung zur Karte fehlgeschlagen: 0x%08lx", ret]];
        return;
    }
    
    unsigned char patr[33] = {0};
    DWORD len = sizeof(patr);
    ret = SCardGetAttrib(gCardHandle, NULL, patr, &len);
    if (ret != SCARD_S_SUCCESS) {
        [self logMessage:[NSString stringWithFormat:@"SCardGetAttrib Warnung: 0x%08lx", ret]];
    }
    
    [self logMessage:@"Karte erfolgreich eingeschaltet"];
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
        [self notifyError:[NSString stringWithFormat:@"Fehler beim Auflisten der Kartenleser: 0x%08lx", ret]];
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
    // Entferne Geräte, die in der letzten Sekunde nicht mehr gesehen wurden
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
        [self notifyError:[NSString stringWithFormat:@"Fehler beim Abrufen des Kartenlesernamens: 0x%08lx", ret]];
        return nil;
    }
    
    return [NSString stringWithUTF8String:buffer];
}

/**
 * Konvertiert einen Hex-String zu NSData
 * @param hexString Hex-String-Darstellung (z.B. "00A4040007A0000002471001")
 *                  Leerzeichen sind erlaubt und werden entfernt
 * @return NSData mit den Bytes, oder nil wenn der String ungültig ist
 *         Gibt nil zurück wenn:
 *         - Der String eine ungerade Anzahl an Zeichen hat (nach Entfernung der Leerzeichen)
 *         - Der String Nicht-Hex-Zeichen enthält
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
            [self logMessage:@"Bluetooth eingeschaltet, starte Scan"];
            [self scanDevice];
            break;
        case CBManagerStatePoweredOff:
            [self logMessage:@"Bluetooth ausgeschaltet"];
            [self notifyError:@"Bluetooth ist ausgeschaltet"];
            break;
        case CBManagerStateUnsupported:
            [self notifyError:@"Bluetooth wird auf diesem Gerät nicht unterstützt"];
            break;
        case CBManagerStateUnauthorized:
            [self notifyError:@"Bluetooth-Berechtigung nicht erteilt"];
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
    
    // Prüfe ob Gerät bereits entdeckt wurde
    for (readerModel *model in _discoveredList) {
        if ([model.name isEqualToString:deviceName]) {
            model.date = [NSDate date];  // Aktualisiere zuletzt gesehen Zeit
            return;
        }
    }
    
    // Neues Gerät entdeckt
    readerModel *model = [readerModel modelWithName:deviceName scanDate:[NSDate date]];
    [_discoveredList addObject:model];
    [_deviceList addObject:deviceName];
    
    [self logMessage:[NSString stringWithFormat:@"Gerät entdeckt: %@ (RSSI: %@)", deviceName, RSSI]];
    
    if ([_delegate respondsToSelector:@selector(scanController:didDiscoverDevice:rssi:)]) {
        [_delegate scanController:self didDiscoverDevice:deviceName rssi:[RSSI integerValue]];
    }
}

#pragma mark - ReaderInterfaceDelegate

- (void)readerInterfaceDidChange:(BOOL)attached
                     bluetoothID:(NSString *)bluetoothID
                andslotnameArray:(NSArray *)slotArray {
    
    // ✅ GUARD: Check if still connected before processing to prevent stale events
    if (!_interface || !_isReaderInterfaceInitialized) {
        [self logMessage:@"⚠️ Ignoriere ReaderInterface-Event: Interface wurde bereits bereinigt"];
        return;
    }
    
    [self logMessage:[NSString stringWithFormat:@"Kartenleser-Schnittstelle geändert, angeschlossen: %d", attached]];
    
    if (attached) {
        [self stopScanBLEDevice];
        [self stopRefreshTimer];
        
        gBluetoothID = bluetoothID;
        _slotarray = slotArray.count > 0 ? slotArray : nil;
        
        // ✅ OPTIMIERUNG: Batterie-Log-Flag bei neuer Verbindung zurücksetzen
        _batteryLoggedOnce = NO;
        
        // ✅ FIX: _connectedReaderName nur setzen wenn _selectedDeviceName gültig ist
        if (_selectedDeviceName && _selectedDeviceName.length > 0) {
            _connectedReaderName = _selectedDeviceName;
        } else {
            // Fallback auf bluetoothID wenn _selectedDeviceName nicht gesetzt ist
            // Dies passiert wenn AutoPair automatisch verbindet ohne expliziten connectToReader-Aufruf
            _connectedReaderName = bluetoothID;
            [self logMessage:@"⚠️ Warnung: _selectedDeviceName war nil, verwende stattdessen bluetoothID"];
        }
        
        [self logMessage:@"✅ Kartenleser erfolgreich verbunden - WriteSerial-Befehl sollte gesendet worden sein"];
        
        // Rufe Kartenlesernamen und Batteriestand ab
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSString *readerModelName = [self getReaderModelName];
            if (readerModelName) {
                [self logMessage:[NSString stringWithFormat:@"Verbundenes Kartenlesermodell: %@", readerModelName]];
                
                // Aktualisiere _connectedReaderName mit dem tatsächlichen Modellnamen falls vorhanden
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.connectedReaderName = readerModelName;
                });
            }
            
            // Warte bis Kartenleser bereit ist vor Batterieanfrage
            [NSThread sleepForTimeInterval:READER_READY_DELAY];
            [self getBatteryLevel];
        });
        
        // Flutter über Verbindung benachrichtigen
        NSMutableArray<NSString *> *slotNames = [NSMutableArray array];
        for (NSString *slot in slotArray) {
            [slotNames addObject:slot];
        }
        
        [self logMessage:[NSString stringWithFormat:@"Verbunden mit Kartenleser: %@", _connectedReaderName]];
        
        // ✅ FIX: Delegate nur aufrufen wenn gültiger Kartenlesername vorhanden ist
        if (_connectedReaderName && _connectedReaderName.length > 0) {
            if ([_delegate respondsToSelector:@selector(scanController:didConnectReader:slots:)]) {
                [_delegate scanController:self didConnectReader:_connectedReaderName slots:slotNames];
            }
        } else {
            [self notifyError:@"Fehler beim Ermitteln des verbundenen Kartenlesernamens"];
        }
    } else {
        // Trennung behandeln
        [self logMessage:@"Kartenleser getrennt"];
        [self logMessage:[NSString stringWithFormat:@"Getrennte Bluetooth-ID: %@", gBluetoothID]];
        
        [self disconnectReader];
    }
}

- (void)cardInterfaceDidDetach:(BOOL)attached slotname:(NSString *)slotname {
    // ✅ GUARD: Check if still connected before processing to prevent stale events
    if (!_interface || !_isReaderInterfaceInitialized) {
        [self logMessage:@"⚠️ Ignoriere CardInterface-Event: Interface wurde bereits bereinigt"];
        return;
    }
    
    // ✅ BUGFIX: Nil-Prüfung für slotname um Absturz zu verhindern
    NSString *safeSlotName = slotname ?: @"Unbekannter Slot";
    
    if (attached) {
        [self logMessage:[NSString stringWithFormat:@"Karte eingesteckt in Slot: %@", safeSlotName]];
        if ([_delegate respondsToSelector:@selector(scanController:didDetectCard:)]) {
            [_delegate scanController:self didDetectCard:safeSlotName];
        }
        
        // ❌ ENTFERNT: Automatisches EGK-Kartenauslesen beim Einstecken
        // Kartenauslesen wird jetzt auf Anfrage über readEGKCardOnDemand-Methode ausgelöst
    } else {
        [self logMessage:[NSString stringWithFormat:@"Karte entfernt aus Slot: %@", safeSlotName]];
        if ([_delegate respondsToSelector:@selector(scanController:didRemoveCard:)]) {
            [_delegate scanController:self didRemoveCard:safeSlotName];
        }
    }
}

- (void)findPeripheralReader:(NSString *)readerName {
    // ✅ GUARD: Check if still connected before processing to prevent stale events
    if (!_interface || !_isReaderInterfaceInitialized) {
        return;
    }
    
    if (!readerName) {
        return;
    }
    
    if ([_deviceList containsObject:readerName]) {
        return;
    }
    
    [_deviceList addObject:readerName];
    [self logMessage:[NSString stringWithFormat:@"Peripheren Kartenleser gefunden: %@", readerName]];
}

- (void)didGetBattery:(NSInteger)battery {
    // ✅ GUARD: Check if still connected before processing to prevent stale events
    if (!_interface || !_isReaderInterfaceInitialized) {
        return;
    }
    
    // ✅ OPTIMIERUNG: Batteriestand nur einmal pro Verbindung loggen
    if (!_batteryLoggedOnce) {
        [self logMessage:[NSString stringWithFormat:@"Batteriestand: %ld%%", (long)battery]];
        _batteryLoggedOnce = YES;
    }
    
    // Batterie-Warnung bei < 10%
    [self notifyBattery:battery];
    
    // Delegate immer benachrichtigen damit Flutter UI aktualisieren kann
    if ([_delegate respondsToSelector:@selector(scanController:didReceiveBattery:)]) {
        [_delegate scanController:self didReceiveBattery:battery];
    }
}

#pragma mark - EGKCardReaderDelegate

- (void)cardReader:(id)reader didLogMessage:(NSString *)message {
    // Weiterleiten an eigenes Logging-System
    [self logMessage:message];
}

- (void)cardReader:(id)reader didReceiveError:(NSString *)error {
    // Weiterleiten an Fehlerbehandlung
    [self notifyError:error];
}

@end
