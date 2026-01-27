# orgacare_reader_sdk

Plugin for Flutter using german EGK Cardreader ORGACare 930 over bluetooth.

## Erstellung eines Flutter Plugins Crash Kurs

1. Mittels Konsole plugin-Ordner Template erstellen
```
create --template=plugin --platforms=ios --org de.ckssysteme orgacare_reader_sdk
```

2. Beschreibung in pubspec.yaml und podspec Datei (im iOS-Ordner) anpassen!

3. Implementierungsbeispiel in GITHUB suchen!! Beigelegt wurde Beispielprojekt in Swift mit xcFramework Format. D.h. ich suche auf Github für Beispiele z.B. mit:
```
path:*.podspec vendored_frameworks dependency 'Flutter' xcframework
```

3. podspec Datei (im iOS-Ordner) anpassen, Ergänzen um verfügbares .xcFramework Projekt
```
    # WHCCareKit_iOS framework ORGACare 930
    s.preserve_paths = 'WHCCareKit_iOS.xcframework'
    s.xcconfig = { 'OTHER_LDFLAGS' => '-framework WHCCareKit_iOS' }
    s.vendored_frameworks = 'WHCCareKit_iOS.xcframework'
    s.frameworks = 'WHCCareKit_iOS'
    s.library = 'c++'
```
4. Das beigelegte xcFramwork des Herstellers wird in den iOS Ordner kopiert
5. Ein sdk Ordner im root erstellt um das Demoprojekt des Herstellers gezippt dort miteinzuchecken
6. Das Interface im lib Ordner des SDK entspreched anpassen um die neuen Methoden. 
   Im ios-Ordner müssen swift Dateien angepasst werden. da dies die Brücke zum nativen XCODE/SDK ist. Für Debugging Zwecke print-Ausgaben einbringen, dann kann man in flutter das example Projekt debuggen, und parallel wird das XCODE Projekt(Runner) geöffnet, und die Print-Ausgaben sind in XCODE sichtbar.
7. Implementieren eines Aufrufs aus example app, main.dart des Plugins.
8. Falls alles läuft dann dieses komplette Projekt in Ordner plugins in ceusrd_ios Projekt einchecken
9. Damit ceusrd das Plugin findet ist pubspec.yaml anzupassen z.B. so
```
  orgacare_reader_sdk:
    path: plugins/orgacare_reader_sdk
```
10. Dann kann analog der main.dart im example Projekt die Übernahme des Auslesecodes in ceusrd erfolgen. Z.B für Kartenleser: cardreader_controller.dart