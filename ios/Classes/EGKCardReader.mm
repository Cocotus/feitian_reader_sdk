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

/**
 * Alternative: Read PD using Extended APDU (single command)
 * Matches C# implementation behavior from CardReader_PCSC.cs
 */
- (nullable NSString *)lesePatientendatenExtended;

/**
 * Alternative: Read VD using Extended APDU (single command)
 * Matches C# implementation behavior from CardReader_PCSC.cs
 */
- (nullable NSString *)leseVersichertendatenExtended;

/**
 * Multi-strategy GZIP stream repair for corrupted or incomplete GZIP data
 * @param data Potentially corrupted GZIP data
 * @return Repaired GZIP data or nil if repair failed
 */
- (nullable NSData *)tryRepairGZIPStream:(NSData *)data;

/**
 * Test if GZIP data can be successfully decompressed
 * @param data GZIP data to test
 * @return YES if decompression succeeds, NO otherwise
 */
- (BOOL)testGZIPDecompression:(NSData *)data;

/**
 * Try partial decompression with Z_SYNC_FLUSH as fallback
 * @param data GZIP data to decompress
 * @return Partially decompressed data or nil
 */
- (nullable NSData *)tryPartialDecompression:(NSData *)data;

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
    // Note: Use lesePatientendatenExtended for single-read Extended APDU approach
    //  NSString *pdXml = [self lesePatientendaten];  // Chunked approach (current)
   NSString *pdXml = [self lesePatientendatenExtended];  // Extended APDU (alternative)
    if (pdXml) {
        cardData.pdXmlRaw = pdXml;
        [self parsePatientendaten:pdXml intoCardData:cardData];
        [self logMessage:@"✅ Patientendaten erfolgreich ausgelesen"];
    } else {
        [self logError:@"⚠️ Warnung: Patientendaten konnten nicht ausgelesen werden"];
    }
    
    // Schritt 9: Read VD (Versichertendaten auslesen)
    // Note: Use leseVersichertendatenExtended for single-read Extended APDU approach
    //  NSString *vdXml = [self leseVersichertendaten];  // Chunked approach (current)
    NSString *vdXml = [self leseVersichertendatenExtended];  // Extended APDU (alternative)
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
    
    // Extract GZIP data from buffer (removes protocol wrappers)
    NSData *cleanedPdData = [self extractGZIPDataFromBuffer:pdData];
    if (!cleanedPdData) {
        [self logError:@"❌ Fehler beim Extrahieren der GZIP-Daten (PD)"];
        return nil;
    }
    
    // GZIP-Dekomprimierung with cleaned data
    NSData *decompressedData = [self dekompromiereGZIP:cleanedPdData];
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
 * Schritt 8 (Alternative): Read PD using Extended APDU - Single command approach
 * This matches the C# reference implementation which reads all PD data in one APDU
 */
- (nullable NSString *)lesePatientendatenExtended {
    [self logMessage:@"📤 APDU: Read PD Length (00 B0 81 00 02) [Extended Mode]"];
    
    // Step 1: Read PD length
    NSData *lengthResponse = [self sendeAPDU:APDU_READ_PD_LENGTH length:sizeof(APDU_READ_PD_LENGTH)];
    if (!lengthResponse || ![self pruefeStatuswort:lengthResponse]) {
        return nil;
    }
    [self logMessage:[NSString stringWithFormat:@"📥 Response: %@", [self dataToHexString:lengthResponse]]];
    
    // Parse length (Big Endian, 2 bytes)
    if (lengthResponse.length < 4) {
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
    
    // Step 2: Read ALL PD data in a SINGLE Extended APDU command
    // Following C# implementation: P1=0x00, P2=0x02, Le=pdLength
    [self logMessage:[NSString stringWithFormat:@"📤 APDU: Read PD Extended (00 B0 00 02) Le=%u [Single Read]", pdLength]];
    
    // Build Extended Length APDU (3-byte Le format)
    // Format: CLA INS P1 P2 Le1 Le2 Le3
    uint8_t readPDExtended[8];
    readPDExtended[0] = 0x00;  // CLA
    readPDExtended[1] = 0xB0;  // INS (READ BINARY)
    readPDExtended[2] = 0x00;  // P1 (high byte of offset = 0)
    readPDExtended[3] = 0x02;  // P2 (low byte of offset = 2)
    readPDExtended[4] = 0x00;  // Le byte 1 (must be 0x00 for extended)
    readPDExtended[5] = (pdLength >> 8) & 0xFF;  // Le byte 2 (high)
    readPDExtended[6] = pdLength & 0xFF;         // Le byte 3 (low)
    
    NSData *pdResponse = [self sendeAPDU:readPDExtended length:7];
    if (!pdResponse || ![self pruefeStatuswort:pdResponse]) {
        [self logError:@"❌ Fehler beim Lesen der PD-Daten (Extended)"];
        return nil;
    }
    
    // Remove status bytes
    NSData *pdData = [pdResponse subdataWithRange:NSMakeRange(0, pdResponse.length - 2)];
    [self logMessage:[NSString stringWithFormat:@"📥 PD gelesen: %lu Bytes (Extended Mode)", (unsigned long)pdData.length]];
    
    // Extract GZIP data
    NSData *cleanedPdData = [self extractGZIPDataFromBuffer:pdData];
    if (!cleanedPdData) {
        [self logError:@"❌ Fehler beim Extrahieren der GZIP-Daten (PD Extended)"];
        return nil;
    }
    
    // Decompress
    NSData *decompressedData = [self dekompromiereGZIP:cleanedPdData];
    if (!decompressedData) {
        [self logError:@"❌ Fehler bei GZIP-Dekomprimierung der PD-Daten (Extended)"];
        return nil;
    }
    
    // Try UTF-8 first
    NSString *xmlString = [[NSString alloc] initWithData:decompressedData encoding:NSUTF8StringEncoding];
    
    // Fallback to ISO-8859-1 if UTF-8 fails
    if (!xmlString) {
        [self logMessage:@"⚠️ UTF-8 decoding failed, trying ISO-8859-1"];
        xmlString = [[NSString alloc] initWithData:decompressedData encoding:NSISOLatin1StringEncoding];
    }
    
    if (!xmlString) {
        [self logError:@"❌ Fehler bei XML-String-Konvertierung (PD Extended)"];
        return nil;
    }
    
    [self logMessage:[NSString stringWithFormat:@"✅ PD-XML erfolgreich dekomprimiert (%lu Bytes) [Extended Mode]", (unsigned long)decompressedData.length]];
    return xmlString;
}

/**
 * Schritt 9: Read VD - Versichertendaten auslesen (zweiteiliger Befehl)
 */
- (nullable NSString *)leseVersichertendaten {
    [self logMessage:@"📤 APDU: Read VD Pointer Structure (00 B0 82 00 08)"];
    
    // Step 1: Read VD pointer structure (8 bytes) from offset 0x8200
    // This returns: VD start offset, VD end offset, GDV start offset, GDV end offset
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
    uint16_t gdvStart = (bytes[4] << 8) | bytes[5];   // GDV container start
    uint16_t gdvEnd = (bytes[6] << 8) | bytes[7];     // GDV container end
    
    // Calculate VD length from pointer structure
    uint16_t vdLength = vdEnd - vdStart;
    
    [self logMessage:[NSString stringWithFormat:@"📊 VD-Container: Start=0x%04X (%u), End=0x%04X (%u), Length=%u bytes", 
                     vdStart, vdStart, vdEnd, vdEnd, vdLength]];
    [self logMessage:[NSString stringWithFormat:@"📊 GDV-Container: Start=0x%04X (%u), End=0x%04X (%u)", 
                     gdvStart, gdvStart, gdvEnd, gdvEnd]];
    
    if (vdLength == 0 || vdLength > MAX_VD_DATA_LENGTH) {
        [self logError:[NSString stringWithFormat:@"❌ Ungültige VD-Länge: %u", vdLength]];
        return nil;
    }
    
    // Step 2: Read VD data from file offset vdStart (matching C# reference implementation)
    // According to C# CardReader_PCSC.cs: P1 = 0x0, P2 = 0x8, Le = VDContainerEndePosition - VDContainerBeginnPosition
    // The VD data starts at file offset indicated by vdStart (typically 0x0008)
    NSMutableData *fullData = [NSMutableData data];
    uint16_t offset = vdStart;  // Start reading from VD container start position (e.g., 0x0008)
    
    while (fullData.length < vdLength) {
        uint16_t remainingBytes = vdLength - (uint16_t)fullData.length;
        uint16_t chunkSize = MIN(256, remainingBytes);
        
        uint8_t p1 = (offset >> 8) & 0xFF;
        uint8_t p2 = offset & 0xFF;
        uint8_t le = (chunkSize == 256) ? 0x00 : (uint8_t)chunkSize;
        
        uint8_t readVDCmd[] = {0x00, 0xB0, p1, p2, le};
        
        [self logMessage:[NSString stringWithFormat:@"📤 APDU: Read VD Chunk (00 B0 %02X %02X %02X)", p1, p2, le]];
        NSData *chunkResponse = [self sendeAPDU:readVDCmd length:sizeof(readVDCmd)];
        if (!chunkResponse || ![self pruefeStatuswort:chunkResponse]) {
            [self logError:[NSString stringWithFormat:@"❌ Failed to read VD chunk at offset %04X", offset]];
            return nil;
        }
        
        NSData *chunk = [chunkResponse subdataWithRange:NSMakeRange(0, chunkResponse.length - 2)];
        
        // Validate chunk boundaries
        if (fullData.length == 0) {
            // First chunk should start with GZIP magic number
            const uint8_t *chunkBytes = (const uint8_t *)chunk.bytes;
            if (chunk.length >= 4) {
                [self logMessage:[NSString stringWithFormat:@"🔍 First chunk header: %02X %02X %02X %02X", 
                                chunkBytes[0], chunkBytes[1], chunkBytes[2], chunkBytes[3]]];
            }
        }
        
        [fullData appendData:chunk];
        offset += chunk.length;
        
        [self logMessage:[NSString stringWithFormat:@"📥 Chunk gelesen: %lu Bytes (gesamt: %lu/%d)", 
                         (unsigned long)chunk.length, 
                         (unsigned long)fullData.length, 
                         vdLength]];
    }
    
    NSData *vdData = fullData;
    
    // Validate total data length
    if (vdData.length != vdLength) {
        [self logError:[NSString stringWithFormat:@"❌ VD data length mismatch: expected %u, got %lu", 
                       vdLength, (unsigned long)vdData.length]];
        // Log the data for debugging
        NSString *hexDump = [self dataToHexString:[vdData subdataWithRange:NSMakeRange(0, MIN(128, vdData.length))]];
        [self logMessage:[NSString stringWithFormat:@"🔍 First 128 bytes of VD data: %@", hexDump]];
    }
    
    // Extract GZIP data from buffer (removes protocol wrappers)
    NSData *cleanedVdData = [self extractGZIPDataFromBuffer:vdData];
    if (!cleanedVdData) {
        [self logError:@"❌ Fehler beim Extrahieren der GZIP-Daten (VD)"];
        return nil;
    }
    
    // ✅ NEW: Try to repair corrupted GZIP stream before decompression
    NSData *repairedData = [self tryRepairGZIPStream:cleanedVdData];
    if (repairedData) {
        [self logMessage:@"✅ GZIP stream repaired, using repaired data"];
        cleanedVdData = repairedData;
    } else {
        // Additional validation: check GZIP stream completeness
        if (![self validateGZIPStream:cleanedVdData]) {
            [self logError:@"⚠️ GZIP stream validation failed, attempting decompression anyway"];
            // Don't return nil here, try decompression anyway
        }
    }
    
    // GZIP-Dekomprimierung with cleaned data
    NSData *decompressedData = [self dekompromiereGZIP:cleanedVdData];
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
 * Schritt 9 (Alternative): Read VD using Extended APDU - Single command approach
 * This matches the C# reference implementation which reads all VD data in one APDU
 */
- (nullable NSString *)leseVersichertendatenExtended {
    [self logMessage:@"📤 APDU: Read VD Length (00 B0 82 00 08) [Extended Mode]"];
    
    // Step 1: Read VD length/pointer structure
    NSData *lengthResponse = [self sendeAPDU:APDU_READ_VD_LENGTH length:sizeof(APDU_READ_VD_LENGTH)];
    if (!lengthResponse || ![self pruefeStatuswort:lengthResponse]) {
        return nil;
    }
    [self logMessage:[NSString stringWithFormat:@"📥 Response: %@", [self dataToHexString:lengthResponse]]];
    
    // Parse pointer structure (8 bytes + 2 status bytes)
    if (lengthResponse.length < 10) {
        [self logError:@"❌ VD-Länge Response zu kurz"];
        return nil;
    }
    
    const uint8_t *bytes = (const uint8_t *)lengthResponse.bytes;
    
    // Parse all 4 offsets
    uint16_t vdStart = (bytes[0] << 8) | bytes[1];
    uint16_t vdEnd = (bytes[2] << 8) | bytes[3];
    uint16_t gdvStart = (bytes[4] << 8) | bytes[5];
    uint16_t gdvEnd = (bytes[6] << 8) | bytes[7];
    
    uint16_t vdLength = vdEnd - vdStart;
    
    [self logMessage:[NSString stringWithFormat:@"📊 VD-Container: Start=%u, End=%u, Length=%u [Extended Mode]", 
                     vdStart, vdEnd, vdLength]];
    [self logMessage:[NSString stringWithFormat:@"📊 GDV-Container: Start=%u, End=%u", 
                     gdvStart, gdvEnd]];
    
    if (vdLength == 0 || vdLength > MAX_VD_DATA_LENGTH) {
        [self logError:[NSString stringWithFormat:@"❌ Ungültige VD-Länge: %u", vdLength]];
        return nil;
    }
    
    // Step 2: Read ALL VD data in a SINGLE Extended APDU command
    // Following C# implementation: P1=0x00, P2=0x08, Le=vdLength
    [self logMessage:[NSString stringWithFormat:@"📤 APDU: Read VD Extended (00 B0 00 08) Le=%u [Single Read]", vdLength]];
    
    // Build Extended Length APDU (7 bytes total, not 8)
    uint8_t readVDExtended[7];
    readVDExtended[0] = 0x00;  // CLA
    readVDExtended[1] = 0xB0;  // INS (READ BINARY)
    readVDExtended[2] = 0x00;  // P1 (high byte of offset = 0)
    readVDExtended[3] = 0x08;  // P2 (low byte of offset = 8, matching vdStart)
    readVDExtended[4] = 0x00;  // Le byte 1 (must be 0x00 for extended)
    readVDExtended[5] = (vdLength >> 8) & 0xFF;  // Le byte 2 (high)
    readVDExtended[6] = vdLength & 0xFF;         // Le byte 3 (low)
    
    // Log the complete APDU command
    [self logMessage:[NSString stringWithFormat:@"🔍 Extended APDU Command: %02X %02X %02X %02X %02X %02X %02X",
                     readVDExtended[0], readVDExtended[1], readVDExtended[2], readVDExtended[3],
                     readVDExtended[4], readVDExtended[5], readVDExtended[6]]];
    
    NSData *vdResponse = [self sendeAPDU:readVDExtended length:7];
    if (!vdResponse || ![self pruefeStatuswort:vdResponse]) {
        [self logError:@"❌ Fehler beim Lesen der VD-Daten (Extended)"];
        return nil;
    }
    
    // Log raw response data (first and last 32 bytes)
    NSUInteger responseLen = vdResponse.length;
    if (responseLen > 0) {
        NSUInteger firstBytes = MIN(32, responseLen);
        NSUInteger lastStart = responseLen > 32 ? responseLen - 32 : 0;
        NSData *firstData = [vdResponse subdataWithRange:NSMakeRange(0, firstBytes)];
        NSData *lastData = lastStart > 0 ? [vdResponse subdataWithRange:NSMakeRange(lastStart, responseLen - lastStart)] : nil;
        
        [self logMessage:[NSString stringWithFormat:@"📦 Raw vdResponse length: %lu bytes", (unsigned long)responseLen]];
        [self logMessage:[NSString stringWithFormat:@"📦 First 32 bytes: %@", [self dataToHexString:firstData]]];
        if (lastData) {
            [self logMessage:[NSString stringWithFormat:@"📦 Last 32 bytes: %@", [self dataToHexString:lastData]]];
        }
    }
    
    // Remove status bytes
    NSData *vdData = [vdResponse subdataWithRange:NSMakeRange(0, vdResponse.length - 2)];
    [self logMessage:[NSString stringWithFormat:@"📥 VD gelesen: %lu Bytes (Extended Mode)", (unsigned long)vdData.length]];
    
    // Log hex dump of vdData (first 128 bytes, 16 bytes per line)
    if (vdData.length > 0) {
        NSUInteger dumpBytes = MIN(128, vdData.length);
        [self logMessage:[NSString stringWithFormat:@"🔍 VD Data hex dump (first %lu bytes):", (unsigned long)dumpBytes]];
        const uint8_t *bytes = (const uint8_t *)vdData.bytes;
        for (NSUInteger i = 0; i < dumpBytes; i += 16) {
            NSMutableString *line = [NSMutableString stringWithFormat:@"  %04lX: ", (unsigned long)i];
            NSUInteger lineEnd = MIN(i + 16, dumpBytes);
            for (NSUInteger j = i; j < lineEnd; j++) {
                [line appendFormat:@"%02X ", bytes[j]];
            }
            [self logMessage:line];
        }
    }
    
    // Extract GZIP data
    [self logMessage:@"🔧 Attempting to extract GZIP data from buffer..."];
    NSData *cleanedVdData = [self extractGZIPDataFromBuffer:vdData];
    if (!cleanedVdData) {
        [self logError:@"❌ Fehler beim Extrahieren der GZIP-Daten (VD Extended)"];
        return nil;
    }
    [self logMessage:[NSString stringWithFormat:@"✅ GZIP data extracted: %lu bytes", (unsigned long)cleanedVdData.length]];
    
    // Decompress
    [self logMessage:@"🔧 Attempting GZIP decompression..."];
    NSData *decompressedData = [self dekompromiereGZIP:cleanedVdData];
    if (!decompressedData) {
        [self logError:@"❌ Fehler bei GZIP-Dekomprimierung der VD-Daten (Extended)"];
        return nil;
    }
    [self logMessage:[NSString stringWithFormat:@"✅ GZIP decompression successful: %lu bytes decompressed", (unsigned long)decompressedData.length]];
    
    // Try UTF-8 first
    [self logMessage:@"🔧 Converting decompressed data to XML string..."];
    NSString *xmlString = [[NSString alloc] initWithData:decompressedData encoding:NSUTF8StringEncoding];
    
    // Fallback to ISO-8859-1 if UTF-8 fails
    if (!xmlString) {
        [self logMessage:@"⚠️ UTF-8 decoding failed, trying ISO-8859-1"];
        xmlString = [[NSString alloc] initWithData:decompressedData encoding:NSISOLatin1StringEncoding];
    }
    
    if (!xmlString) {
        [self logError:@"❌ Fehler bei XML-String-Konvertierung (VD Extended)"];
        return nil;
    }
    
    [self logMessage:[NSString stringWithFormat:@"✅ VD-XML erfolgreich dekomprimiert (%lu Bytes) [Extended Mode]", (unsigned long)decompressedData.length]];
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
    
    // Detect Extended APDU (7 bytes with Le field starting at byte 4)
    BOOL isExtendedAPDU = (length == 7 && apdu[4] == 0x00);
    
    if (isExtendedAPDU) {
        // Log Extended APDU details
        uint16_t extendedLe = (apdu[5] << 8) | apdu[6];
        [self logMessage:[NSString stringWithFormat:@"🔧 Extended APDU detected: CLA=%02X INS=%02X P1=%02X P2=%02X Le=%u", 
                         apdu[0], apdu[1], apdu[2], apdu[3], extendedLe]];
        
        // Pre-delay for BLE connection stability
        [NSThread sleepForTimeInterval:0.1];  // 100ms
    }
    
    // Vorbereitung für SCardTransmit
    // Buffer size increased to 2048 + 128 bytes to match iReader demo
    SCARD_IO_REQUEST pioSendPci = {SCARD_PROTOCOL_T1, sizeof(SCARD_IO_REQUEST)};
    BYTE recvBuffer[2048 + 128];
    memset(recvBuffer, 0, sizeof(recvBuffer));  // Clear buffer to prevent stale data
    DWORD recvLength = sizeof(recvBuffer);
    
    // APDU senden
    LONG ret = SCardTransmit(_cardHandle, &pioSendPci, apdu, (DWORD)length, NULL, recvBuffer, &recvLength);
    
    if (ret != SCARD_S_SUCCESS) {
        [self logError:[NSString stringWithFormat:@"❌ SCardTransmit Fehler: 0x%08lx", ret]];
        return nil;
    }
    
    if (isExtendedAPDU) {
        // Post-delay for BLE packet assembly
        [NSThread sleepForTimeInterval:0.3];  // 300ms for multi-packet assembly
        [self logMessage:[NSString stringWithFormat:@"📦 Extended APDU response received: %lu bytes", (unsigned long)recvLength]];
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
 * Extrahiert GZIP-Daten aus einem Buffer durch Suche nach GZIP Magic Number
 * Matches C# implementation behavior from CardReader_PCSC.cs
 * @param data Rohdaten, die GZIP Magic Number (1F 8B 08 00) enthalten können
 * @return Nur die GZIP-komprimierten Daten ab Magic Number, oder nil wenn nicht gefunden
 */
- (nullable NSData *)extractGZIPDataFromBuffer:(NSData *)data {
    if (data.length < 4) {  // Minimum size for complete GZIP header (1F 8B 08 00)
        [self logError:@"❌ Buffer zu kurz für GZIP-Suche"];
        return nil;
    }
    
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSUInteger gzipStart = 0;
    BOOL foundGzipHeader = NO;
    
    // Search for complete GZIP header signature (1F 8B 08 00)
    // This matches the C# implementation in CardReader_PCSC.cs (ReadEGKVersichertendaten method)
    for (NSUInteger i = 0; i < data.length - 3; i++) {
        if (bytes[i] == 0x1F && 
            bytes[i+1] == 0x8B && 
            bytes[i+2] == 0x08 &&
            bytes[i+3] == 0x00) {
            gzipStart = i;
            foundGzipHeader = YES;
            [self logMessage:[NSString stringWithFormat:@"🔍 Found complete GZIP header (1F 8B 08 00) at offset: %lu", (unsigned long)gzipStart]];
            break;
        }
    }
    
    if (!foundGzipHeader) {
        // Log hex dump for debugging
        NSString *hexDump = [self dataToHexString:[data subdataWithRange:NSMakeRange(0, MIN(32, data.length))]];
        [self logError:[NSString stringWithFormat:@"❌ Complete GZIP header (1F 8B 08 00) not found. First 32 bytes: %@", hexDump]];
        return nil;
    }
    
    // Extract only the GZIP-compressed portion starting from the complete header
    NSData *cleanedData = [data subdataWithRange:NSMakeRange(gzipStart, data.length - gzipStart)];
    [self logMessage:[NSString stringWithFormat:@"🧹 Cleaned data: %lu → %lu bytes", 
                     (unsigned long)data.length, 
                     (unsigned long)cleanedData.length]];
    
    return cleanedData;
}

/**
 * Validates GZIP stream integrity before decompression
 * @param data GZIP compressed data
 * @return YES if stream appears valid, NO otherwise
 */
- (BOOL)validateGZIPStream:(NSData *)data {
    // Minimum valid GZIP: 10-byte header + 8-byte footer = 18 bytes total
    if (data.length < 18) {
        [self logError:[NSString stringWithFormat:@"❌ GZIP data too short: %lu bytes (minimum 18)", (unsigned long)data.length]];
        return NO;
    }
    
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    
    // Check magic number (bytes 0-1)
    if (bytes[0] != 0x1F || bytes[1] != 0x8B) {
        [self logError:[NSString stringWithFormat:@"❌ Invalid GZIP magic: %02X %02X", bytes[0], bytes[1]]];
        return NO;
    }
    
    // Check compression method (byte 2, should be 08 for DEFLATE)
    if (bytes[2] != 0x08) {
        [self logError:[NSString stringWithFormat:@"❌ Invalid compression method: %02X", bytes[2]]];
        return NO;
    }
    
    [self logMessage:[NSString stringWithFormat:@"✅ GZIP stream validation passed (%lu bytes)", (unsigned long)data.length]];
    return YES;
}

/**
 * Multi-strategy GZIP stream repair for corrupted or incomplete GZIP data
 * This method tries multiple strategies to repair GZIP streams that are missing
 * footer bytes or have other corruption issues
 */
- (nullable NSData *)tryRepairGZIPStream:(NSData *)data {
    if (data.length < 18) {
        return nil;
    }
    
    [self logMessage:@"🔧 Attempting GZIP stream repair with multiple strategies..."];
    
    // Strategy 1: Try trimming trailing bytes (1-10 bytes)
    // Some cards append extra status bytes after GZIP footer
    for (NSInteger trimSize = 1; trimSize <= 10; trimSize++) {
        if (data.length <= trimSize) break;
        
        NSData *trimmed = [data subdataWithRange:NSMakeRange(0, data.length - trimSize)];
        if ([self testGZIPDecompression:trimmed]) {
            [self logMessage:[NSString stringWithFormat:@"✅ Repaired by trimming %ld trailing byte(s)", trimSize]];
            return trimmed;
        }
    }
    
    // Strategy 2: Try adding null padding bytes (1-8 bytes)
    // EGK cards sometimes return GZIP streams with incomplete footer
    for (NSInteger padSize = 1; padSize <= 8; padSize++) {
        NSMutableData *padded = [NSMutableData dataWithData:data];
        uint8_t padding[8] = {0};
        [padded appendBytes:padding length:padSize];
        
        if ([self testGZIPDecompression:padded]) {
            [self logMessage:[NSString stringWithFormat:@"✅ Repaired by adding %ld padding byte(s)", padSize]];
            return padded;
        }
    }
    
    // Strategy 3: Replace status word bytes (90 00) with null bytes
    // Card status bytes might interfere with GZIP footer
    if (data.length > 10) {
        const uint8_t *bytes = (const uint8_t *)data.bytes;
        if (bytes[data.length - 2] == 0x90 && bytes[data.length - 1] == 0x00) {
            NSMutableData *fixed = [NSMutableData dataWithData:data];
            uint8_t nullBytes[2] = {0x00, 0x00};
            [fixed replaceBytesInRange:NSMakeRange(fixed.length - 2, 2) withBytes:nullBytes length:2];
            
            if ([self testGZIPDecompression:fixed]) {
                [self logMessage:@"✅ Repaired by replacing status word (90 00) with null bytes"];
                return fixed;
            }
        }
    }
    
    // Strategy 4: Partial decompression with Z_SYNC_FLUSH
    NSData *partial = [self tryPartialDecompression:data];
    if (partial && partial.length > 100) {
        [self logMessage:[NSString stringWithFormat:@"✅ Partial decompression succeeded: %lu bytes", (unsigned long)partial.length]];
        // Return original data, not partial, so main decompressor can use it
        return data;
    }
    
    [self logMessage:@"❌ All repair strategies failed"];
    return nil;
}

/**
 * Test if GZIP data can be successfully decompressed
 */
- (BOOL)testGZIPDecompression:(NSData *)data {
    z_stream stream;
    memset(&stream, 0, sizeof(stream));
    stream.next_in = (Bytef *)data.bytes;
    stream.avail_in = (uInt)data.length;
    
    if (inflateInit2(&stream, 31) != Z_OK) {
        return NO;
    }
    
    BOOL success = YES;
    uint8_t buffer[32768];
    int ret;
    
    do {
        stream.next_out = buffer;
        stream.avail_out = sizeof(buffer);
        ret = inflate(&stream, Z_NO_FLUSH);
        
        if (ret != Z_OK && ret != Z_STREAM_END) {
            success = NO;
            break;
        }
    } while (ret != Z_STREAM_END && stream.avail_in > 0);
    
    inflateEnd(&stream);
    return (success && ret == Z_STREAM_END);
}

/**
 * Try partial decompression with Z_SYNC_FLUSH as fallback
 */
- (nullable NSData *)tryPartialDecompression:(NSData *)data {
    z_stream stream;
    memset(&stream, 0, sizeof(stream));
    stream.next_in = (Bytef *)data.bytes;
    stream.avail_in = (uInt)data.length;
    
    if (inflateInit2(&stream, 31) != Z_OK) {
        return nil;
    }
    
    NSMutableData *decompressed = [NSMutableData dataWithCapacity:data.length * 4];
    uint8_t buffer[32768];
    int ret;
    
    do {
        stream.next_out = buffer;
        stream.avail_out = sizeof(buffer);
        ret = inflate(&stream, Z_SYNC_FLUSH);
        
        if (ret != Z_OK && ret != Z_STREAM_END && ret != Z_BUF_ERROR) {
            break;
        }
        
        NSUInteger have = sizeof(buffer) - stream.avail_out;
        if (have > 0) {
            [decompressed appendBytes:buffer length:have];
        }
        
    } while (stream.avail_in > 0 && ret != Z_STREAM_END);
    
    inflateEnd(&stream);
    
    return decompressed.length > 0 ? [decompressed copy] : nil;
}

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
            // Enhanced error logging with more context
            NSString *errorMsg = [NSString stringWithFormat:@"❌ inflate Fehler: %d", ret];
            if (ret == Z_BUF_ERROR) {
                errorMsg = [errorMsg stringByAppendingString:@" (Z_BUF_ERROR: incomplete or corrupted GZIP data)"];
                // Log the problematic data for debugging
                NSString *hexDump = [self dataToHexString:[compressedData subdataWithRange:NSMakeRange(0, MIN(64, compressedData.length))]];
                [self logError:[NSString stringWithFormat:@"First 64 bytes of compressed data: %@", hexDump]];
            } else if (ret == Z_DATA_ERROR) {
                errorMsg = [errorMsg stringByAppendingString:@" (Z_DATA_ERROR: data integrity error)"];
            } else if (ret == Z_MEM_ERROR) {
                errorMsg = [errorMsg stringByAppendingString:@" (Z_MEM_ERROR: insufficient memory)"];
            }
            inflateEnd(&stream);
            [self logError:errorMsg];
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
