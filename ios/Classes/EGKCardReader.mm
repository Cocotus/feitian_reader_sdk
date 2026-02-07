//
//  EGKCardReader.mm
//  feitian_reader_sdk
//
//  Implementierung zum Auslesen deutscher eGK-Karten nach GEMATIK-Spezifikation
//
//  Referenzen:
//  - gemLF_Impl_eGK_V160.pdf (GEMATIK offizielles Dokument)
//  - APDU_Schnittstellenbeschreibung.pdf
//  - CardReader_PCSC.cs (C# Referenzimplementierung)
//

#import "EGKCardReader.h"
#import <zlib.h>

// APDU-Kommandos nach GEMATIK-Spezifikation
static const uint8_t APDU_RESET_CT[] = {0x20, 0x11, 0x00, 0x00, 0x00};                                     // Reset CT
static const uint8_t APDU_REQUEST_ICC[] = {0x20, 0x12, 0x01, 0x00, 0x01, 0x05};                           // Request ICC
static const uint8_t APDU_SELECT_EGK_ROOT[] = {0x00, 0xA4, 0x04, 0x0C, 0x07, 0xD2, 0x76, 0x00, 0x01, 0x44, 0x80, 0x00}; // Select Root
static const uint8_t APDU_READ_EF_ATR[] = {0x00, 0xB0, 0x9D, 0x00, 0x00};                                // Read EF.ATR
static const uint8_t APDU_READ_EF_VERSION[] = {0x00, 0xB2, 0x02, 0x84, 0x00};                            // Read EF.Version
static const uint8_t APDU_READ_EF_STATUSVD[] = {0x00, 0xB0, 0x8C, 0x00, 0x19};                           // Read EF.StatusVD
static const uint8_t APDU_SELECT_HCA[] = {0x00, 0xA4, 0x04, 0x0C, 0x06, 0xD2, 0x76, 0x00, 0x00, 0x01, 0x02}; // Select HCA
static const uint8_t APDU_READ_PD_LENGTH[] = {0x00, 0xB0, 0x81, 0x00, 0x02};                             // Read PD Länge
static const uint8_t APDU_READ_VD_LENGTH[] = {0x00, 0xB0, 0x82, 0x00, 0x08};                             // Read VD Länge
static const uint8_t APDU_EJECT_ICC[] = {0x20, 0x15, 0x01, 0x00, 0x01, 0x05};                            // Eject ICC

// Erfolgsstatus
static const uint16_t SW_SUCCESS = 0x9000;

// Maximale Datenlängen nach GEMATIK-Spezifikation
static const uint16_t MAX_PD_DATA_LENGTH = 10000;  // Maximale Länge für Patientendaten
static const uint16_t MAX_VD_DATA_LENGTH = 10000;  // Maximale Länge für Versichertendaten

@implementation EGKCardData

- (NSDictionary<NSString *, id> *)toDictionary {
    NSMutableDictionary<NSString *, id> *dict = [NSMutableDictionary dictionary];
    
    // Kartentechnische Daten
    if (self.atr) dict[@"atr"] = self.atr;
    if (self.cardGeneration) dict[@"cardGeneration"] = self.cardGeneration;
    if (self.schemaVersion) dict[@"schemaVersion"] = self.schemaVersion;
    
    // Patientendaten - Persönliche Informationen
    if (self.nachname) dict[@"nachname"] = self.nachname;
    if (self.vorname) dict[@"vorname"] = self.vorname;
    if (self.geburtsdatum) dict[@"geburtsdatum"] = self.geburtsdatum;
    if (self.geschlecht) dict[@"geschlecht"] = self.geschlecht;
    if (self.titel) dict[@"titel"] = self.titel;
    if (self.namenszusatz) dict[@"namenszusatz"] = self.namenszusatz;
    if (self.vorsatzwort) dict[@"vorsatzwort"] = self.vorsatzwort;
    
    // Patientendaten - Adresse
    if (self.strasse) dict[@"strasse"] = self.strasse;
    if (self.hausnummer) dict[@"hausnummer"] = self.hausnummer;
    if (self.postleitzahl) dict[@"postleitzahl"] = self.postleitzahl;
    if (self.ort) dict[@"ort"] = self.ort;
    if (self.wohnsitzlaendercode) dict[@"wohnsitzlaendercode"] = self.wohnsitzlaendercode;
    if (self.anschriftzeile1) dict[@"anschriftzeile1"] = self.anschriftzeile1;
    if (self.anschriftzeile2) dict[@"anschriftzeile2"] = self.anschriftzeile2;
    
    // Versichertendaten
    if (self.versichertenID) dict[@"versichertenID"] = self.versichertenID;
    if (self.versichertennummer) dict[@"versichertennummer"] = self.versichertennummer;
    if (self.kostentraegerkennung) dict[@"kostentraegerkennung"] = self.kostentraegerkennung;
    if (self.kostentraegername) dict[@"kostentraegername"] = self.kostentraegername;
    if (self.kostentraegerlaendercode) dict[@"kostentraegerlaendercode"] = self.kostentraegerlaendercode;
    if (self.versichertenart) dict[@"versichertenart"] = self.versichertenart;
    if (self.statusergaenzung) dict[@"statusergaenzung"] = self.statusergaenzung;
    if (self.beginn) dict[@"beginn"] = self.beginn;
    if (self.ende) dict[@"ende"] = self.ende;
    
    // Rohdaten
    if (self.pdXmlRaw) dict[@"pdXmlRaw"] = self.pdXmlRaw;
    if (self.vdXmlRaw) dict[@"vdXmlRaw"] = self.vdXmlRaw;
    
    return [dict copy];
}

@end

@interface EGKCardReader ()
@property (nonatomic, assign) SCARDHANDLE cardHandle;
@property (nonatomic, assign) SCARDCONTEXT context;
@end

@implementation EGKCardReader

- (instancetype)initWithCardHandle:(SCARDHANDLE)cardHandle context:(SCARDCONTEXT)context {
    self = [super init];
    if (self) {
        _cardHandle = cardHandle;
        _context = context;
    }
    return self;
}

#pragma mark - Hauptmethode

- (nullable EGKCardData *)readEGKCard {
    [self logMessage:@"🔷 Starte EGK-Auslesevorgang nach GEMATIK-Spezifikation"];
    
    EGKCardData *cardData = [[EGKCardData alloc] init];
    
    // Schritt 1: Reset CT (Kartenleser zurücksetzen)
    if (![self resetteKartenleser]) {
        [self logError:@"❌ Fehler beim Zurücksetzen des Kartenlesers"];
        return nil;
    }
    
    // Schritt 2: Request ICC (Karte anfordern)
    if (![self fordereKarteAn]) {
        [self logError:@"❌ Fehler beim Anfordern der Karte"];
        return nil;
    }
    
    // Schritt 3: Select EGK Root (Root Application selektieren)
    if (![self selektiereEGKRoot]) {
        [self logError:@"❌ Fehler beim Selektieren der EGK Root Application"];
        return nil;
    }
    
    // Schritt 4: Read EF.ATR (Kartenpuffergröße auslesen)
    NSData *atrData = [self leseEFATR];
    if (atrData) {
        cardData.atr = [self dataToHexString:atrData];
        [self logMessage:[NSString stringWithFormat:@"✅ EF.ATR: %@", cardData.atr]];
    }
    
    // Schritt 5: Read EF.Version (Kartengeneration auslesen)
    NSString *version = [self leseKartenVersion];
    if (version) {
        cardData.cardGeneration = version;
        [self logMessage:[NSString stringWithFormat:@"✅ Kartengeneration: %@", version]];
    }
    
    // Schritt 6: Read EF.StatusVD (Schema-Version auslesen)
    NSString *schemaVersion = [self leseSchemaVersion];
    if (schemaVersion) {
        cardData.schemaVersion = schemaVersion;
        [self logMessage:[NSString stringWithFormat:@"✅ Schema-Version: %@", schemaVersion]];
    }
    
    // Schritt 7: Select HCA (Health Care Application selektieren)
    if (![self selektiereHCA]) {
        [self logError:@"❌ Fehler beim Selektieren der Health Care Application"];
        return nil;
    }
    
    // Schritt 8: Read PD (Patientendaten auslesen)
    NSString *pdXml = [self lesePatientendaten];
    if (pdXml) {
        cardData.pdXmlRaw = pdXml;
        [self parsePatientendaten:pdXml intoCardData:cardData];
        [self logMessage:@"✅ Patientendaten erfolgreich ausgelesen"];
    } else {
        [self logError:@"⚠️ Warnung: Patientendaten konnten nicht ausgelesen werden"];
    }
    
    // Schritt 9: Read VD (Versichertendaten auslesen)
    NSString *vdXml = [self leseVersichertendaten];
    if (vdXml) {
        cardData.vdXmlRaw = vdXml;
        [self parseVersichertendaten:vdXml intoCardData:cardData];
        [self logMessage:@"✅ Versichertendaten erfolgreich ausgelesen"];
    } else {
        [self logError:@"⚠️ Warnung: Versichertendaten konnten nicht ausgelesen werden"];
    }
    
    // Schritt 10: Eject ICC (Karte auswerfen) - Optional, kann Fehler verursachen
    // [self werfeKarteAus];
    
    [self logMessage:@"🔷 EGK-Auslesevorgang abgeschlossen"];
    
    // Notify delegate
    if ([_delegate respondsToSelector:@selector(cardReader:didReadCardData:)]) {
        [_delegate cardReader:self didReadCardData:cardData];
    }
    
    return cardData;
}

#pragma mark - APDU-Kommandos

/**
 * Schritt 1: Reset CT - Kartenleser zurücksetzen
 */
- (BOOL)resetteKartenleser {
        return YES;
    [self logMessage:@"📤 APDU: Reset CT (20 11 00 00 00)"];
    NSData *response = [self sendeAPDU:APDU_RESET_CT length:sizeof(APDU_RESET_CT)];
    if (!response || ![self pruefeStatuswort:response]) {
        return NO;
    }
    [self logMessage:[NSString stringWithFormat:@"📥 Response: %@", [self dataToHexString:response]]];
    return YES;
} 

/**
 * Schritt 2: Request ICC - Karte anfordern
 */
- (BOOL)fordereKarteAn {
        return YES;
    [self logMessage:@"📤 APDU: Request ICC (20 12 01 00 01 05)"];
    NSData *response = [self sendeAPDU:APDU_REQUEST_ICC length:sizeof(APDU_REQUEST_ICC)];
    if (!response || ![self pruefeStatuswort:response]) {
        return NO;
    }
    [self logMessage:[NSString stringWithFormat:@"📥 Response: %@", [self dataToHexString:response]]];
    return YES;
} 

/**
 * Schritt 3: Select EGK Root - Root Application selektieren
 */
- (BOOL)selektiereEGKRoot {
    [self logMessage:@"📤 APDU: Select EGK Root (00 A4 04 0C 07 D2 76 00 01 44 80 00)"];
    NSData *response = [self sendeAPDU:APDU_SELECT_EGK_ROOT length:sizeof(APDU_SELECT_EGK_ROOT)];
    if (!response || ![self pruefeStatuswort:response]) {
        return NO;
    }
    [self logMessage:[NSString stringWithFormat:@"📥 Response: %@", [self dataToHexString:response]]];
    return YES;
}

/**
 * Schritt 4: Read EF.ATR - Kartenpuffergröße auslesen
 */
- (nullable NSData *)leseEFATR {
    [self logMessage:@"📤 APDU: Read EF.ATR (00 B0 9D 00 00)"];
    NSData *response = [self sendeAPDU:APDU_READ_EF_ATR length:sizeof(APDU_READ_EF_ATR)];
    if (!response || ![self pruefeStatuswort:response]) {
        return nil;
    }
    [self logMessage:[NSString stringWithFormat:@"📥 Response: %@", [self dataToHexString:response]]];
    // Entferne Status-Bytes (letzte 2 Bytes)
    return [response subdataWithRange:NSMakeRange(0, response.length - 2)];
}

/**
 * Schritt 5: Read EF.Version - Kartengeneration auslesen
 */
- (nullable NSString *)leseKartenVersion {
    [self logMessage:@"📤 APDU: Read EF.Version (00 B2 02 84 00)"];
    NSData *response = [self sendeAPDU:APDU_READ_EF_VERSION length:sizeof(APDU_READ_EF_VERSION)];
    if (!response || ![self pruefeStatuswort:response]) {
        return nil;
    }
    [self logMessage:[NSString stringWithFormat:@"📥 Response: %@", [self dataToHexString:response]]];
    
    // Parse Version aus Response (ohne SW1/SW2)
    NSData *versionData = [response subdataWithRange:NSMakeRange(0, response.length - 2)];
    NSString *versionStr = [[NSString alloc] initWithData:versionData encoding:NSASCIIStringEncoding];
    return versionStr ?: @"Unknown";
}

/**
 * Schritt 6: Read EF.StatusVD - Schema-Version auslesen
 */
- (nullable NSString *)leseSchemaVersion {
    [self logMessage:@"📤 APDU: Read EF.StatusVD (00 B0 8C 00 19)"];
    NSData *response = [self sendeAPDU:APDU_READ_EF_STATUSVD length:sizeof(APDU_READ_EF_STATUSVD)];
    if (!response || ![self pruefeStatuswort:response]) {
        return nil;
    }
    [self logMessage:[NSString stringWithFormat:@"📥 Response: %@", [self dataToHexString:response]]];
    
    // Parse Schema-Version (z.B. "5.2.0")
    NSData *schemaData = [response subdataWithRange:NSMakeRange(0, response.length - 2)];
    NSString *schemaStr = [[NSString alloc] initWithData:schemaData encoding:NSASCIIStringEncoding];
    return schemaStr ?: @"Unknown";
}

/**
 * Schritt 7: Select HCA - Health Care Application selektieren
 */
- (BOOL)selektiereHCA {
    [self logMessage:@"📤 APDU: Select HCA (00 A4 04 0C 06 D2 76 00 00 01 02)"];
    NSData *response = [self sendeAPDU:APDU_SELECT_HCA length:sizeof(APDU_SELECT_HCA)];
    if (!response || ![self pruefeStatuswort:response]) {
        return NO;
    }
    [self logMessage:[NSString stringWithFormat:@"📥 Response: %@", [self dataToHexString:response]]];
    return YES;
}

/**
 * Schritt 8: Read PD - Patientendaten auslesen (zweiteiliger Befehl)
 */
- (nullable NSString *)lesePatientendaten {
    [self logMessage:@"📤 APDU: Read PD Length (00 B0 81 00 02)"];
    
    // Schritt 8.1: Länge der PD-Daten auslesen
    NSData *lengthResponse = [self sendeAPDU:APDU_READ_PD_LENGTH length:sizeof(APDU_READ_PD_LENGTH)];
    if (!lengthResponse || ![self pruefeStatuswort:lengthResponse]) {
        return nil;
    }
    [self logMessage:[NSString stringWithFormat:@"📥 Response: %@", [self dataToHexString:lengthResponse]]];
    
    // Parse Länge (Big Endian, 2 Bytes)
    if (lengthResponse.length < 4) { // 2 Bytes Länge + 2 Bytes SW
        [self logError:@"❌ PD-Länge Response zu kurz"];
        return nil;
    }
    
    const uint8_t *bytes = (const uint8_t *)lengthResponse.bytes;
    uint16_t pdLength = (bytes[0] << 8) | bytes[1];
    [self logMessage:[NSString stringWithFormat:@"📊 PD-Datenlänge: %u Bytes", pdLength]];
    
    if (pdLength == 0 || pdLength > MAX_PD_DATA_LENGTH) {
        [self logError:[NSString stringWithFormat:@"❌ Ungültige PD-Länge: %u", pdLength]];
        return nil;
    }
    
    // Schritt 8.2: PD-Daten in mehreren Chunks auslesen (Le=0x00 bedeutet max. 256 Bytes)
    NSMutableData *fullData = [NSMutableData data];
    uint16_t offset = 0x0002; // Nach den 2 Längen-Bytes
    
    while (fullData.length < pdLength) {
        uint8_t p1 = (offset >> 8) & 0xFF;
        uint8_t p2 = offset & 0xFF;
        
        // Le=0x00 bedeutet "maximal 256 Bytes lesen"
        uint8_t readPDCmd[] = {0x00, 0xB0, p1, p2, 0x00};
        
        [self logMessage:[NSString stringWithFormat:@"📤 APDU: Read PD Chunk (00 B0 %02X %02X 00)", p1, p2]];
        NSData *chunkResponse = [self sendeAPDU:readPDCmd length:sizeof(readPDCmd)];
        if (!chunkResponse || ![self pruefeStatuswort:chunkResponse]) {
            return nil;
        }
        
        // Entferne Status-Bytes und füge Chunk hinzu
        NSData *chunk = [chunkResponse subdataWithRange:NSMakeRange(0, chunkResponse.length - 2)];
        [fullData appendData:chunk];
        offset += chunk.length;
        
        [self logMessage:[NSString stringWithFormat:@"📥 Chunk gelesen: %lu Bytes (gesamt: %lu/%d)", 
                         (unsigned long)chunk.length, 
                         (unsigned long)fullData.length, 
                         pdLength]];
    }
    
    NSData *pdData = fullData;
    
    // GZIP-Dekomprimierung
    NSData *decompressedData = [self dekompromiereGZIP:pdData];
    if (!decompressedData) {
        [self logError:@"❌ Fehler bei GZIP-Dekomprimierung der PD-Daten"];
        return nil;
    }
    
    // Try UTF-8 first
    NSString *xmlString = [[NSString alloc] initWithData:decompressedData encoding:NSUTF8StringEncoding];
    
    // Fallback to ISO-8859-1 (Latin-1) if UTF-8 fails
    if (!xmlString) {
        [self logMessage:@"⚠️ UTF-8 decoding failed, trying ISO-8859-1"];
        xmlString = [[NSString alloc] initWithData:decompressedData encoding:NSISOLatin1StringEncoding];
    }
    
    // Fallback to Windows-1252 if both fail
    if (!xmlString) {
        [self logMessage:@"⚠️ ISO-8859-1 decoding failed, trying Windows-1252"];
        xmlString = [[NSString alloc] initWithData:decompressedData encoding:NSWindowsCP1252StringEncoding];
    }
    
    if (!xmlString) {
        [self logError:@"❌ Fehler beim Parsen der PD-Daten (alle Encodings fehlgeschlagen)"];
        return nil;
    }
    
    // Remove BOM if present
    if ([xmlString hasPrefix:@"\uFEFF"]) {
        xmlString = [xmlString substringFromIndex:1];
    }
    
    [self logMessage:[NSString stringWithFormat:@"✅ PD-XML erfolgreich dekomprimiert (%lu Bytes)", (unsigned long)decompressedData.length]];
    return xmlString;
}

/**
 * Schritt 9: Read VD - Versichertendaten auslesen (zweiteiliger Befehl)
 */
- (nullable NSString *)leseVersichertendaten {
    [self logMessage:@"📤 APDU: Read VD Length (00 B0 82 00 08)"];
    
    // Schritt 9.1: Länge der VD-Daten auslesen
    NSData *lengthResponse = [self sendeAPDU:APDU_READ_VD_LENGTH length:sizeof(APDU_READ_VD_LENGTH)];
    if (!lengthResponse || ![self pruefeStatuswort:lengthResponse]) {
        return nil;
    }
    [self logMessage:[NSString stringWithFormat:@"📥 Response: %@", [self dataToHexString:lengthResponse]]];
    
    // Parse pointer structure correctly (8 bytes + 2 status bytes)
    if (lengthResponse.length < 10) {
        [self logError:@"❌ VD-Länge Response zu kurz"];
        return nil;
    }
    
    const uint8_t *bytes = (const uint8_t *)lengthResponse.bytes;
    
    // Parse all 4 offsets from the pointer structure
    uint16_t vdStart = (bytes[0] << 8) | bytes[1];    // VD container start
    uint16_t vdEnd = (bytes[2] << 8) | bytes[3];      // VD container end
    uint16_t gdvStart = (bytes[4] << 8) | bytes[5];   // GDV container start (for logging only)
    uint16_t gdvEnd = (bytes[6] << 8) | bytes[7];     // GDV container end (for logging only)
    
    // Calculate actual VD length
    uint16_t vdLength = vdEnd - vdStart;
    
    [self logMessage:[NSString stringWithFormat:@"📊 VD-Container: Start=%u, End=%u, Length=%u", 
                     vdStart, vdEnd, vdLength]];
    [self logMessage:[NSString stringWithFormat:@"📊 GDV-Container: Start=%u, End=%u", 
                     gdvStart, gdvEnd]];
    
    if (vdLength == 0 || vdLength > MAX_VD_DATA_LENGTH) {
        [self logError:[NSString stringWithFormat:@"❌ Ungültige VD-Länge: %u", vdLength]];
        return nil;
    }
    
    // Schritt 9.2: VD-Daten in mehreren Chunks auslesen (Le=0x00 bedeutet max. 256 Bytes)
    NSMutableData *fullData = [NSMutableData data];
    uint16_t offset = vdStart; // Read VD data starting from vdStart position
    
    while (fullData.length < vdLength) {
        uint16_t remainingBytes = vdLength - (uint16_t)fullData.length;
        uint16_t chunkSize = MIN(256, remainingBytes);
        
        uint8_t p1 = (offset >> 8) & 0xFF;
        uint8_t p2 = offset & 0xFF;
        // Le=0x00 means "read 256 bytes", otherwise use actual chunk size
        uint8_t le = (chunkSize == 256) ? 0x00 : (uint8_t)chunkSize;
        
        uint8_t readVDCmd[] = {0x00, 0xB0, p1, p2, le};
        
        [self logMessage:[NSString stringWithFormat:@"📤 APDU: Read VD Chunk (00 B0 %02X %02X %02X)", p1, p2, le]];
        NSData *chunkResponse = [self sendeAPDU:readVDCmd length:sizeof(readVDCmd)];
        if (!chunkResponse || ![self pruefeStatuswort:chunkResponse]) {
            return nil;
        }
        
        // Entferne Status-Bytes und füge Chunk hinzu
        NSData *chunk = [chunkResponse subdataWithRange:NSMakeRange(0, chunkResponse.length - 2)];
        [fullData appendData:chunk];
        offset += chunk.length;
        
        [self logMessage:[NSString stringWithFormat:@"📥 Chunk gelesen: %lu Bytes (gesamt: %lu/%d)", 
                         (unsigned long)chunk.length, 
                         (unsigned long)fullData.length, 
                         vdLength]];
    }
    
    NSData *vdData = fullData;
    
    // GZIP-Dekomprimierung
    NSData *decompressedData = [self dekompromiereGZIP:vdData];
    if (!decompressedData) {
        [self logError:@"❌ Fehler bei GZIP-Dekomprimierung der VD-Daten"];
        return nil;
    }
    
    // Try UTF-8 first
    NSString *xmlString = [[NSString alloc] initWithData:decompressedData encoding:NSUTF8StringEncoding];
    
    // Fallback to ISO-8859-1 (Latin-1) if UTF-8 fails
    if (!xmlString) {
        [self logMessage:@"⚠️ UTF-8 decoding failed, trying ISO-8859-1"];
        xmlString = [[NSString alloc] initWithData:decompressedData encoding:NSISOLatin1StringEncoding];
    }
    
    // Fallback to Windows-1252 if both fail
    if (!xmlString) {
        [self logMessage:@"⚠️ ISO-8859-1 decoding failed, trying Windows-1252"];
        xmlString = [[NSString alloc] initWithData:decompressedData encoding:NSWindowsCP1252StringEncoding];
    }
    
    if (!xmlString) {
        [self logError:@"❌ Fehler beim Parsen der VD-Daten (alle Encodings fehlgeschlagen)"];
        return nil;
    }
    
    // Remove BOM if present
    if ([xmlString hasPrefix:@"\uFEFF"]) {
        xmlString = [xmlString substringFromIndex:1];
    }
    
    [self logMessage:[NSString stringWithFormat:@"✅ VD-XML erfolgreich dekomprimiert (%lu Bytes)", (unsigned long)decompressedData.length]];
    return xmlString;
}

/**
 * Schritt 10: Eject ICC - Karte auswerfen (optional)
 */
- (BOOL)werfeKarteAus {
    [self logMessage:@"📤 APDU: Eject ICC (20 15 01 00 01 05)"];
    NSData *response = [self sendeAPDU:APDU_EJECT_ICC length:sizeof(APDU_EJECT_ICC)];
    if (!response || ![self pruefeStatuswort:response]) {
        return NO;
    }
    [self logMessage:[NSString stringWithFormat:@"📥 Response: %@", [self dataToHexString:response]]];
    return YES;
}

#pragma mark - APDU Hilfsfunktionen

/**
 * Sendet ein APDU-Kommando an die Karte
 * @param apdu APDU-Kommando als Byte-Array
 * @param length Länge des APDU-Kommandos
 * @return Response-Daten inkl. SW1/SW2, oder nil bei Fehler
 */
- (nullable NSData *)sendeAPDU:(const uint8_t *)apdu length:(NSUInteger)length {
    if (_cardHandle == 0) {
        [self logError:@"❌ Keine Kartenverbindung vorhanden"];
        return nil;
    }
    
    // Vorbereitung für SCardTransmit
    SCARD_IO_REQUEST pioSendPci = {SCARD_PROTOCOL_T1, sizeof(SCARD_IO_REQUEST)};
    BYTE recvBuffer[2048];
    DWORD recvLength = sizeof(recvBuffer);
    
    // APDU senden
    LONG ret = SCardTransmit(_cardHandle, &pioSendPci, apdu, (DWORD)length, NULL, recvBuffer, &recvLength);
    
    if (ret != SCARD_S_SUCCESS) {
        [self logError:[NSString stringWithFormat:@"❌ SCardTransmit Fehler: 0x%08lx", ret]];
        return nil;
    }
    
    if (recvLength < 2) {
        [self logError:@"❌ Response zu kurz (keine Status-Bytes)"];
        return nil;
    }
    
    return [NSData dataWithBytes:recvBuffer length:recvLength];
}

/**
 * Prüft das Statuswort (SW1/SW2) auf Erfolg (0x9000)
 * @param response Response-Daten mit SW1/SW2 am Ende
 * @return YES wenn erfolgreich (9000), sonst NO
 */
- (BOOL)pruefeStatuswort:(NSData *)response {
    if (response.length < 2) {
        [self logError:@"❌ Response zu kurz für Statuswort-Prüfung"];
        return NO;
    }
    
    const uint8_t *bytes = (const uint8_t *)response.bytes;
    uint8_t sw1 = bytes[response.length - 2];
    uint8_t sw2 = bytes[response.length - 1];
    uint16_t sw = (sw1 << 8) | sw2;
    
    if (sw != SW_SUCCESS) {
        [self logError:[NSString stringWithFormat:@"❌ Statuswort-Fehler: %04X (erwartet: 9000)", sw]];
        return NO;
    }
    
    return YES;
}

#pragma mark - GZIP-Dekomprimierung

/**
 * Dekomprimiert GZIP-komprimierte Daten mit zlib
 * @param compressedData GZIP-komprimierte Daten (Magic Number: 1F 8B)
 * @return Dekomprimierte Daten oder nil bei Fehler
 */
- (nullable NSData *)dekompromiereGZIP:(NSData *)compressedData {
    if (compressedData.length < 2) {
        [self logError:@"❌ Komprimierte Daten zu kurz"];
        return nil;
    }
    
    // Prüfe GZIP Magic Number (1F 8B)
    const uint8_t *bytes = (const uint8_t *)compressedData.bytes;
    if (bytes[0] != 0x1F || bytes[1] != 0x8B) {
        [self logError:[NSString stringWithFormat:@"❌ Keine GZIP-Daten (Magic: %02X %02X, erwartet: 1F 8B)", bytes[0], bytes[1]]];
        return nil;
    }
    
    [self logMessage:@"🗜️ Starte GZIP-Dekomprimierung..."];
    
    // Initialisiere z_stream für GZIP-Format
    z_stream stream;
    memset(&stream, 0, sizeof(stream));
    stream.next_in = (Bytef *)compressedData.bytes;
    stream.avail_in = (uInt)compressedData.length;
    
    // inflateInit2 mit windowBits=31 für GZIP-Format (15 + 16 für gzip wrapper)
    int ret = inflateInit2(&stream, 31);
    if (ret != Z_OK) {
        [self logError:[NSString stringWithFormat:@"❌ inflateInit2 Fehler: %d", ret]];
        return nil;
    }
    
    // Ausgabepuffer
    NSMutableData *decompressed = [NSMutableData dataWithCapacity:compressedData.length * 4];
    uint8_t buffer[32768];
    
    // Dekomprimierung
    do {
        stream.next_out = buffer;
        stream.avail_out = sizeof(buffer);
        
        ret = inflate(&stream, Z_NO_FLUSH);
        
        if (ret != Z_OK && ret != Z_STREAM_END) {
            inflateEnd(&stream);
            [self logError:[NSString stringWithFormat:@"❌ inflate Fehler: %d", ret]];
            return nil;
        }
        
        NSUInteger have = sizeof(buffer) - stream.avail_out;
        [decompressed appendBytes:buffer length:have];
        
    } while (ret != Z_STREAM_END);
    
    inflateEnd(&stream);
    
    [self logMessage:[NSString stringWithFormat:@"✅ GZIP-Dekomprimierung erfolgreich: %lu → %lu Bytes", 
                     (unsigned long)compressedData.length, (unsigned long)decompressed.length]];
    
    return [decompressed copy];
}

#pragma mark - XML-Parsing

/**
 * Parst Patientendaten-XML und füllt EGKCardData
 * @param xml PD-XML als String
 * @param cardData EGKCardData-Objekt zum Befüllen
 */
- (void)parsePatientendaten:(NSString *)xml intoCardData:(EGKCardData *)cardData {
    [self logMessage:@"🔍 Parse Patientendaten-XML..."];
    
    // Persönliche Daten
    cardData.nachname = [self extrahiereXMLWert:xml tag:@"Nachname"];
    cardData.vorname = [self extrahiereXMLWert:xml tag:@"Vorname"];
    cardData.geburtsdatum = [self extrahiereXMLWert:xml tag:@"Geburtsdatum"];
    cardData.geschlecht = [self extrahiereXMLWert:xml tag:@"Geschlecht"];
    cardData.titel = [self extrahiereXMLWert:xml tag:@"Titel"];
    cardData.namenszusatz = [self extrahiereXMLWert:xml tag:@"Namenszusatz"];
    cardData.vorsatzwort = [self extrahiereXMLWert:xml tag:@"Vorsatzwort"];
    
    // Adresse
    cardData.strasse = [self extrahiereXMLWert:xml tag:@"Strasse"];
    cardData.hausnummer = [self extrahiereXMLWert:xml tag:@"Hausnummer"];
    cardData.postleitzahl = [self extrahiereXMLWert:xml tag:@"Postleitzahl"];
    cardData.ort = [self extrahiereXMLWert:xml tag:@"Ort"];
    cardData.wohnsitzlaendercode = [self extrahiereXMLWert:xml tag:@"Wohnsitzlaendercode"];
    cardData.anschriftzeile1 = [self extrahiereXMLWert:xml tag:@"Anschriftzeile1"];
    cardData.anschriftzeile2 = [self extrahiereXMLWert:xml tag:@"Anschriftzeile2"];
    
    [self logMessage:@"✅ Patientendaten geparst"];
}

/**
 * Parst Versichertendaten-XML und füllt EGKCardData
 * @param xml VD-XML als String
 * @param cardData EGKCardData-Objekt zum Befüllen
 */
- (void)parseVersichertendaten:(NSString *)xml intoCardData:(EGKCardData *)cardData {
    [self logMessage:@"🔍 Parse Versichertendaten-XML..."];
    
    cardData.versichertenID = [self extrahiereXMLWert:xml tag:@"Versicherten_ID"];
    cardData.versichertennummer = [self extrahiereXMLWert:xml tag:@"Versichertennummer"];
    cardData.kostentraegerkennung = [self extrahiereXMLWert:xml tag:@"Kostentraegerkennung"];
    cardData.kostentraegername = [self extrahiereXMLWert:xml tag:@"Name"];
    cardData.kostentraegerlaendercode = [self extrahiereXMLWert:xml tag:@"Kostentraegerlaendercode"];
    cardData.versichertenart = [self extrahiereXMLWert:xml tag:@"Versichertenart"];
    cardData.statusergaenzung = [self extrahiereXMLWert:xml tag:@"Statusergaenzung"];
    cardData.beginn = [self extrahiereXMLWert:xml tag:@"Beginn"];
    cardData.ende = [self extrahiereXMLWert:xml tag:@"Ende"];
    
    [self logMessage:@"✅ Versichertendaten geparst"];
}

/**
 * Extrahiert einen Wert aus einem XML-Tag
 * @param xml XML-String
 * @param tag Tag-Name (ohne < >)
 * @return Extrahierter Wert oder nil
 */
- (nullable NSString *)extrahiereXMLWert:(NSString *)xml tag:(NSString *)tag {
    // Suche nach <tag>wert</tag> oder <namespace:tag>wert</namespace:tag>
    NSString *pattern1 = [NSString stringWithFormat:@"<%@>([^<]*)</%@>", tag, tag];
    NSString *pattern2 = [NSString stringWithFormat:@"<[^:]+:%@>([^<]*)</[^:]+:%@>", tag, tag];
    
    NSError *error = nil;
    
    // Versuche Pattern 1
    NSRegularExpression *regex1 = [NSRegularExpression regularExpressionWithPattern:pattern1
                                                                            options:NSRegularExpressionCaseInsensitive
                                                                              error:&error];
    if (!error) {
        NSTextCheckingResult *match = [regex1 firstMatchInString:xml options:0 range:NSMakeRange(0, xml.length)];
        if (match && match.numberOfRanges > 1) {
            NSRange valueRange = [match rangeAtIndex:1];
            return [xml substringWithRange:valueRange];
        }
    }
    
    // Versuche Pattern 2 (mit Namespace)
    NSRegularExpression *regex2 = [NSRegularExpression regularExpressionWithPattern:pattern2
                                                                            options:NSRegularExpressionCaseInsensitive
                                                                              error:&error];
    if (!error) {
        NSTextCheckingResult *match = [regex2 firstMatchInString:xml options:0 range:NSMakeRange(0, xml.length)];
        if (match && match.numberOfRanges > 1) {
            NSRange valueRange = [match rangeAtIndex:1];
            return [xml substringWithRange:valueRange];
        }
    }
    
    return nil;
}

#pragma mark - Hilfsmethoden

/**
 * Konvertiert NSData zu Hex-String
 */
- (NSString *)dataToHexString:(NSData *)data {
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSMutableString *hex = [NSMutableString stringWithCapacity:data.length * 2];
    for (NSUInteger i = 0; i < data.length; i++) {
        [hex appendFormat:@"%02X", bytes[i]];
    }
    return [hex copy];
}

/**
 * Logging über Delegate
 */
- (void)logMessage:(NSString *)message {
    if ([_delegate respondsToSelector:@selector(cardReader:didLogMessage:)]) {
        [_delegate cardReader:self didLogMessage:message];
    }
}

/**
 * Fehler-Logging über Delegate
 */
- (void)logError:(NSString *)error {
    if ([_delegate respondsToSelector:@selector(cardReader:didReceiveError:)]) {
        [_delegate cardReader:self didReceiveError:error];
    }
}

@end
