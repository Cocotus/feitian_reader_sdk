# iOS EGK Card Reader Implementation - Usage Guide

## Übersicht

Die vollständige iOS-Implementierung ermöglicht das Auslesen von deutschen elektronischen Gesundheitskarten (eGK) über FEITIAN Bluetooth-Kartenleser.

## Architektur

```
Flutter App
    ↓
FeitianReaderSdkPlugin (Method Channel)
    ↓
FeitianCardManager (Singleton)
    ↓
FEITIAN SDK (PCSC + BLE)
    ↓
bR301-C18 Kartenleser
    ↓
eGK Karte
```

## Verwendung

### 1. Bluetooth-Scan starten

```dart
await FeitianReaderSdk().startBluetoothScan();
```

Der Scan sucht nach FEITIAN Bluetooth-Geräten in der Umgebung.

### 2. Event-Handler registrieren

```dart
static const platform = MethodChannel('feitian_reader_sdk');

@override
void initState() {
  super.initState();
  platform.setMethodCallHandler(_handleMethodCall);
}

Future<void> _handleMethodCall(MethodCall call) async {
  switch (call.method) {
    case 'log':
      print('LOG: ${call.arguments}');
      break;
      
    case 'readerConnected':
      final readerName = call.arguments['name'];
      print('Reader verbunden: $readerName');
      break;
      
    case 'readerDisconnected':
      print('Reader getrennt');
      break;
      
    case 'cardConnected':
      print('Karte verbunden');
      break;
      
    case 'cardDisconnected':
      print('Karte getrennt');
      break;
      
    case 'batteryLevel':
      final level = call.arguments['level'];
      print('Batterie: $level%');
      break;
      
    case 'egkDataRead':
      final data = Map<String, String>.from(call.arguments);
      print('EGK Daten empfangen:');
      print('Name: ${data['lastName']}, ${data['firstName']}');
      print('Geburtsdatum: ${data['geburtsdatum']}');
      print('Versichertennummer: ${data['kennnummerDerKarte']}');
      // ... weitere Felder
      break;
  }
}
```

### 3. Mit Reader verbinden

```dart
await FeitianReaderSdk().connectToReader(deviceName: 'bR301-XXXXX');
```

Nach erfolgreicher Verbindung wird automatisch:
- PCSC-Kontext initialisiert
- `readerConnected` Event ausgelöst

### 4. Karte einschalten und auslesen

```dart
await FeitianReaderSdk().powerOnCard();
```

Dies führt automatisch folgende Schritte aus:
1. Kartenverbindung herstellen (SCardConnect)
2. Kartenterminal zurücksetzen (CT-API)
3. Karte anfordern (CT-API)
4. EGK-Auslesung starten:
   - EGK Root selektieren
   - Kartenpuffergröße lesen (EF.ATR)
   - Kartenversion lesen (EF.VERSION)
   - Schema-Version lesen (EF.StatusVD)
   - HCA selektieren
   - Patientendaten lesen (EF.PD)
   - Versicherungsdaten lesen (EF.VD)
5. XML-Daten dekomprimieren (GZIP)
6. XML parsen und extrahieren
7. `egkDataRead` Event mit allen Daten senden

### 5. Karte ausschalten

```dart
await FeitianReaderSdk().powerOffCard();
```

Wirft die Karte aus und trennt die Verbindung.

### 6. Reader trennen

```dart
await FeitianReaderSdk().disconnectReader();
```

### 7. Batterie-Status abfragen

```dart
await FeitianReaderSdk().getBatteryLevel();
```

## EGK Datenfelder

Das `egkDataRead` Event enthält folgende Felder:

### Allgemeine Karteninformationen
- `cardGeneration`: Kartengeneration (G1, G1Plus, G2)
- `schemaVersion`: CDM Schema-Version
- `maxBufferSize`: Max. APDU-Puffergröße

### Patientendaten (EF.PD)
- `lastName`: Nachname
- `firstName`: Vorname
- `geburtsdatum`: Geburtsdatum
- `geschlecht`: Geschlecht
- `persoenlicheKennnummer`: Versicherten-ID

### Versicherungsdaten (EF.VD)
- `kennnummerDerKarte`: Versichertennummer
- `kennnummerDesTraegers`: Kostenträgerkennung
- `nameDesTraegers`: Name der Krankenkasse
- `ablaufdatum`: Gültigkeitsdatum der Karte

## Fehlerbehandlung

Alle Fehler werden über das `log` Event zurückgemeldet:

```dart
case 'log':
  final message = call.arguments as String;
  if (message.contains('Fehler')) {
    // Fehler behandeln
    showErrorDialog(message);
  }
  break;
```

### Häufige Fehlermeldungen

- `"Fehler: Kartenleser nicht verbunden"` → `connectToReader()` aufrufen
- `"Fehler: Keine Kartenverbindung"` → `powerOnCard()` aufrufen
- `"Keine Karte vorhanden"` → Karte einstecken
- `"HCA nicht gefunden"` → Keine gültige eGK-Karte
- `"GZIP-Header nicht gefunden"` → Kartendaten beschädigt

## APDU-Befehle (Referenz)

Die folgenden APDU-Befehle werden automatisch intern verwendet:

### CT-API Terminal-Befehle
```
20 11 00 00 00        - Reset CT
20 12 01 00 01 05     - Request ICC (1s timeout)
20 15 01 00 01 05     - Eject ICC
```

### EGK Root
```
00 A4 04 0C 07 D2 76 00 01 44 80 00  - Select EGK Root
00 B0 9D 00 00                        - Read EF.ATR
00 B2 02 84 00                        - Read EF.VERSION
00 B0 8C 00 19                        - Read EF.StatusVD
```

### HCA (Health Care Application)
```
00 A4 04 0C 06 D2 76 00 00 01 02     - Select HCA
00 B0 81 00 02                        - Read PD length
00 B0 00 02 00 [Hi] [Lo]              - Read PD data
00 B0 82 00 08                        - Read VD pointers
00 B0 00 08 00 [Hi] [Lo]              - Read VD data
```

## Abhängigkeiten

### iOS Frameworks
- CoreBluetooth (für BLE-Verbindung)
- Foundation
- zlib (für GZIP-Dekomprimierung)

### FEITIAN SDK
- libiRockey301_ccid.a (statische Bibliothek)
- SDK-Version: 3.5.71

## Systemanforderungen

- iOS 12.0 oder höher
- Bluetooth LE
- FEITIAN bR301-C18 Kartenleser oder kompatibel

## Berechtigungen

In `Info.plist` müssen folgende Berechtigungen eingetragen sein:

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Bluetooth wird benötigt um mit dem Kartenleser zu kommunizieren</string>
<key>NSBluetoothPeripheralUsageDescription</key>
<string>Bluetooth wird benötigt um mit dem Kartenleser zu kommunizieren</string>
```

## Debugging

Alle Log-Nachrichten werden über:
1. Flutter Method Channel (`log` Event)
2. iOS Console (`print("FEITIAN: ...")`)

ausgegeben.

## Implementierungsdetails

### PCSC-Workflow
1. `SCardEstablishContext` → PCSC-Kontext erstellen
2. `FtGetReaderName` → Reader-Namen abrufen
3. `SCardConnect` → Karte verbinden (T0/T1 Protokoll)
4. `SCardTransmit` → APDU-Befehle senden
5. `SCardDisconnect` → Karte trennen
6. `SCardReleaseContext` → PCSC-Kontext freigeben

### GZIP-Dekomprimierung
- Header-Suche: `1F 8B 08 00`
- Dekomprimierung mit zlib (`inflateInit2_`, `inflate`, `inflateEnd`)
- Encoding: ISO-8859-15 (Latin-1) mit UTF-8 Fallback

### XML-Parsing
Einfaches String-Matching für XML-Tags:
```swift
<TagName>Wert</TagName>
```

## Sicherheit

⚠️ **Wichtig**: Die Implementierung liest nur öffentlich zugängliche Daten der eGK-Karte. Geschützte Bereiche (z.B. GDV) werden nicht ausgelesen.

## Bekannte Einschränkungen

1. Nur ein Kartenleser gleichzeitig unterstützt
2. Keine PIN-Eingabe implementiert (für geschützte Bereiche)
3. XML-Parsing ist einfach gehalten (kein vollständiger XML-Parser)
4. Bluetooth-Pairing muss manuell über iOS-Einstellungen erfolgen (je nach Reader-Modell)

## Troubleshooting

### Reader wird nicht gefunden
- Bluetooth aktivieren
- Reader einschalten
- Ggf. Reader in iOS-Bluetooth-Einstellungen pairen

### Kartenverbindung fehlschlägt
- Karte richtig eingesteckt?
- Reader mit iOS-Gerät verbunden?
- PCSC-Kontext erfolgreich initialisiert?

### Daten können nicht gelesen werden
- Ist es eine gültige eGK-Karte?
- Karte nicht beschädigt?
- Log-Meldungen auf konkrete Fehler prüfen

## Weitere Informationen

- FEITIAN SDK Demo: `sdk/3.5.71/demo/iReader/`
- PCSC Spezifikation: PC/SC Workgroup
- ISO 7816-4: Smart Card APDU Protocol
- eGK Spezifikation: gematik Fachportal
