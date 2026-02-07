//
//  EGKCardReader.h
//  feitian_reader_sdk
//
//  Implementierung zum Auslesen deutscher eGK-Karten (elektronische Gesundheitskarte)
//  nach offizieller GEMATIK-Spezifikation
//
//  Referenzen:
//  - gemLF_Impl_eGK_V160.pdf (GEMATIK offizielles Dokument)
//  - APDU_Schnittstellenbeschreibung.pdf
//  - CardReader_PCSC.cs (C# Referenzimplementierung)
//

#import <Foundation/Foundation.h>
#import "winscard.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - EGKCardData

/**
 * Datenmodell für eGK-Kartendaten
 * Enthält alle Patientendaten (PD) und Versichertendaten (VD) nach GEMATIK-Spezifikation
 */
@interface EGKCardData : NSObject

// Kartentechnische Daten
@property (nonatomic, strong, nullable) NSString *atr;                    // Answer To Reset
@property (nonatomic, strong, nullable) NSString *cardGeneration;          // Kartengeneration (G1, G2, G2.1)
@property (nonatomic, strong, nullable) NSString *schemaVersion;           // Schema-Version

// Patientendaten (PD) - Persönliche Informationen
@property (nonatomic, strong, nullable) NSString *nachname;                // Nachname
@property (nonatomic, strong, nullable) NSString *vorname;                 // Vorname
@property (nonatomic, strong, nullable) NSString *geburtsdatum;            // Geburtsdatum (Format: JJJJMMTT)
@property (nonatomic, strong, nullable) NSString *geschlecht;              // Geschlecht (M/W/X)
@property (nonatomic, strong, nullable) NSString *titel;                   // Titel (Dr., Prof., etc.)
@property (nonatomic, strong, nullable) NSString *namenszusatz;            // Namenszusatz
@property (nonatomic, strong, nullable) NSString *vorsatzwort;             // Vorsatzwort (von, zu, etc.)

// Patientendaten (PD) - Adresse
@property (nonatomic, strong, nullable) NSString *strasse;                 // Straße
@property (nonatomic, strong, nullable) NSString *hausnummer;              // Hausnummer
@property (nonatomic, strong, nullable) NSString *postleitzahl;            // Postleitzahl
@property (nonatomic, strong, nullable) NSString *ort;                     // Ort/Wohnort
@property (nonatomic, strong, nullable) NSString *wohnsitzlaendercode;     // Länderkennzeichen (z.B. "D" für Deutschland)
@property (nonatomic, strong, nullable) NSString *anschriftzeile1;         // Anschriftzeile 1
@property (nonatomic, strong, nullable) NSString *anschriftzeile2;         // Anschriftzeile 2

// Versichertendaten (VD)
@property (nonatomic, strong, nullable) NSString *versichertenID;          // Versicherten-ID (10-stellig)
@property (nonatomic, strong, nullable) NSString *versichertennummer;      // Krankenversichertennummer
@property (nonatomic, strong, nullable) NSString *kostentraegerkennung;    // Krankenkassenkennung (IK-Nummer)
@property (nonatomic, strong, nullable) NSString *kostentraegername;       // Name der Krankenkasse
@property (nonatomic, strong, nullable) NSString *kostentraegerlaendercode; // Länderkennzeichen Kostenträger
@property (nonatomic, strong, nullable) NSString *versichertenart;         // Versichertenart (1=Mitglied, 3=Familienvers., 5=Rentner)
@property (nonatomic, strong, nullable) NSString *statusergaenzung;        // Statusergänzung
@property (nonatomic, strong, nullable) NSString *beginn;                  // Gültigkeitsbeginn (Format: JJJJMMTT)
@property (nonatomic, strong, nullable) NSString *ende;                    // Gültigkeitsende (Format: JJJJMMTT)

// Rohdaten (optional)
@property (nonatomic, strong, nullable) NSString *pdXmlRaw;                // PD XML Rohdaten (dekomprimiert)
@property (nonatomic, strong, nullable) NSString *vdXmlRaw;                // VD XML Rohdaten (dekomprimiert)

/**
 * Konvertiert die Kartendaten in ein Dictionary für Flutter-Übertragung
 * @return Dictionary mit allen nicht-nil Kartendatenfeldern
 */
- (NSDictionary<NSString *, id> *)toDictionary;

@end

#pragma mark - EGKCardReaderDelegate

/**
 * Protokoll für Callbacks vom EGKCardReader
 * Ermöglicht Logging und Statusmeldungen während des Auslesevorgangs
 */
@protocol EGKCardReaderDelegate <NSObject>

@optional

/**
 * Wird aufgerufen für Log-Nachrichten während des Auslesevorgangs
 * @param reader Die EGKCardReader-Instanz
 * @param message Log-Nachricht
 */
- (void)cardReader:(id)reader didLogMessage:(NSString *)message;

/**
 * Wird aufgerufen bei Fehlern während des Auslesevorgangs
 * @param reader Die EGKCardReader-Instanz
 * @param error Fehlermeldung
 */
- (void)cardReader:(id)reader didReceiveError:(NSString *)error;

/**
 * Wird aufgerufen nach erfolgreichem Auslesen der Kartendaten
 * @param reader Die EGKCardReader-Instanz
 * @param cardData Die ausgelesenen Kartendaten
 */
- (void)cardReader:(id)reader didReadCardData:(EGKCardData *)cardData;

@end

#pragma mark - EGKCardReader

/**
 * Hauptklasse zum Auslesen deutscher eGK-Karten nach GEMATIK-Spezifikation
 * 
 * Implementiert den vollständigen GEMATIK-Workflow:
 * 1. Reset CT (Kartenleser zurücksetzen)
 * 2. Request ICC (Karte anfordern)
 * 3. Select EGK Root (Root Application selektieren)
 * 4. Read EF.ATR (Kartenpuffergröße auslesen)
 * 5. Read EF.Version (Kartengeneration auslesen)
 * 6. Read EF.StatusVD (Schema-Version auslesen)
 * 7. Select HCA (Health Care Application selektieren)
 * 8. Read PD (Patientendaten auslesen)
 * 9. Read VD (Versichertendaten auslesen)
 * 10. Eject ICC (Karte auswerfen)
 *
 * Die XML-Daten werden GZIP-dekomprimiert und geparst.
 */
@interface EGKCardReader : NSObject

@property (nonatomic, weak, nullable) id<EGKCardReaderDelegate> delegate;

/**
 * Initialisiert den EGKCardReader mit einem bestehenden Card Handle
 * @param cardHandle PC/SC Card Handle für die Kommunikation mit der Karte
 * @param context PC/SC Context Handle
 * @return Initialisierte EGKCardReader-Instanz
 */
- (instancetype)initWithCardHandle:(SCARDHANDLE)cardHandle context:(SCARDCONTEXT)context;

/**
 * Führt den kompletten EGK-Auslesevorgang durch
 * Führt alle 10 APDU-Kommandos aus und gibt die Kartendaten zurück
 * @return EGKCardData-Objekt mit allen ausgelesenen Daten, oder nil bei Fehler
 */
- (nullable EGKCardData *)readEGKCard;

@end

NS_ASSUME_NONNULL_END
