import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:feitian_reader_sdk/feitian_reader_sdk.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String _platformVersion = 'Unknown';
  final _feitianReaderPlugin = FeitianReaderSdk();
  static const platform = MethodChannel('feitian_reader_sdk');
  final List<String> _logs = [];
  String? _deviceName;
  bool _isConnected = false;
  bool _isScanning = false;
  StreamSubscription<Map<dynamic, dynamic>>? _eventSubscription;

  @override
  void initState() {
    super.initState();
    initPlatformState();
    platform.setMethodCallHandler(_handleMethodCall);
    _setupEventStream();
    // Note: Auto-start Bluetooth scan removed to give user full control
    // and to save battery. User must manually trigger EGK reading which
    // will check for reader connectivity and card insertion.
  }

  Future<void> _handleMethodCall(MethodCall call) async {
    // Method call handler for legacy support
    // Most events now come through the event stream
  }

  @override
  void dispose() {
    _eventSubscription?.cancel();
    super.dispose();
  }

  void _setupEventStream() {
    _eventSubscription = _feitianReaderPlugin.eventStream.listen((event) {
      final eventType = event['event'];
      
      // Update state first
      setState(() {
        if (eventType == 'log') {
          // Add log to display
          _logs.insert(0, event['message']);
          if (_logs.length > 200) {
            _logs.removeLast();
          }
        } else if (eventType == 'deviceDiscovered') {
          _deviceName = event['deviceName'];
          _logs.insert(0, '📱 Kartenleser gefunden: $_deviceName (RSSI: ${event['rssi']})');
        } else if (eventType == 'readerConnected') {
          _isConnected = true;
          _isScanning = false;
          _logs.insert(0, '✅ Kartenleser verbunden: ${event['deviceName']}');
        } else if (eventType == 'readerDisconnected') {
          _isConnected = false;
          _logs.insert(0, '❌ Kartenleser getrennt');
        } else if (eventType == 'batteryLevel') {
          _logs.insert(0, '🔋 Batterie: ${event['level']}%');
        } else if (eventType == 'cardInserted') {
          _logs.insert(0, '🎴 Karte eingesteckt in Slot: ${event['slotName']}');
        } else if (eventType == 'cardRemoved') {
          _logs.insert(0, '🎴 Karte entfernt aus Slot: ${event['slotName']}');
        } else if (eventType == 'egkData') {
          _logs.insert(0, '💾 EGK-Daten empfangen:');
          // Log alle EGK-Felder
          final egkData = Map<String, dynamic>.from(event);
          egkData.forEach((key, value) {
            if (key != 'event' && value != null) {
              _logs.insert(0, '  $key: $value');
            }
          });
        } else if (eventType == 'apduResponse') {
          _logs.insert(0, '📤 APDU Response: ${event['response']}');
        } else if (eventType == 'error') {
          _logs.insert(0, '⚠️ FEHLER: ${event['error']}');
        } else if (eventType == 'noDataMobileMode') {
          _logs.insert(0, '❌ Keine Karte eingesteckt!');
        } else if (eventType == 'noBluetooth') {
          _logs.insert(0, '❌ Kartenleser nicht verbunden!');
        } else if (eventType == 'lowBattery') {
          final battery = event['level'] as int;
          _logs.insert(0, '🔋 Batterie niedrig: $battery%');
        }
      });

      // Show Snackbars AFTER setState()
      if (eventType == 'noDataMobileMode') {
        _showSnackBar(
          '❌ Keine Karte eingesteckt!',
          Colors.red,
        );
      } else if (eventType == 'noBluetooth') {
        _showSnackBar(
          '❌ Kartenleser nicht verbunden!',
          Colors.orange,
        );
      } else if (eventType == 'lowBattery') {
        final battery = event['level'] as int;
        _showSnackBar(
          '🔋 Batterie niedrig: $battery%',
          Colors.deepOrange,
          duration: const Duration(seconds: 5),
        );
      }
    });
  }

  Future<void> initPlatformState() async {
    String platformVersion;
    try {
      platformVersion = await _feitianReaderPlugin.getPlatformVersion() ?? 'Unknown platform version';
    } on PlatformException {
      platformVersion = 'Failed to get platform version.';
    }

    if (!mounted) return;

    setState(() {
      _platformVersion = platformVersion;
    });
  }

  void _showSnackBar(String message, Color backgroundColor, {Duration? duration}) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: backgroundColor,
          duration: duration ?? const Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _readEGKCard() async {
    // Connection check is now handled by readEGKCardOnDemand
    // This method will trigger 'noBluetooth' or 'noDataMobileMode' events
    
    try {
      setState(() {
        _logs.clear(); // Clear logs before reading
      });
      _logs.insert(0, '🔷 Starte EGK-Auslesung...');
      // Use readEGKCardOnDemand for complete workflow
      await _feitianReaderPlugin.readEGKCardOnDemand();
    } catch (e) {
      setState(() {
        _logs.insert(0, '❌ EGK-Lesevorgang fehlgeschlagen: $e');
      });
      _showSnackBar('❌ Fehler: $e', Colors.red);
    }
  }

  void _clearLogs() {
    setState(() {
      _logs.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('FEITIAN EGK Kartenleser'),
        backgroundColor: Colors.blue,
      ),
      body: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // Connection Status Card
              Card(
                color: _isConnected ? Colors.green.shade50 : Colors.grey.shade100,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Row(
                    children: [
                      Icon(
                        _isConnected ? Icons.check_circle : Icons.bluetooth_disabled,
                        color: _isConnected ? Colors.green : Colors.grey,
                        size: 32,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _isConnected ? 'Verbunden' : 'Nicht verbunden',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 18,
                                color: _isConnected ? Colors.green.shade900 : Colors.black87,
                              ),
                            ),
                            if (_deviceName != null && _isConnected)
                              Text(
                                _deviceName!,
                                style: const TextStyle(fontSize: 14, color: Colors.black54),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              
              // Main Action Button - EGK Auslesen
              ElevatedButton.icon(
                onPressed: _readEGKCard,
                icon: const Icon(Icons.credit_card, size: 28),
                label: const Text(
                  'EGK Auslesen',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.all(20),
                  disabledBackgroundColor: Colors.grey.shade300,
                  disabledForegroundColor: Colors.grey.shade600,
                ),
              ),
              const SizedBox(height: 8),
              
              const SizedBox(height: 16),
              
              // Event Logs Section
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Event-Protokoll:',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  TextButton.icon(
                    onPressed: _clearLogs,
                    icon: const Icon(Icons.clear_all, size: 18),
                    label: const Text('Löschen'),
                  ),
                ],
              ),
              const Divider(),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey.shade300),
                    borderRadius: BorderRadius.circular(8),
                    color: Colors.grey.shade50,
                  ),
                  child: _logs.isEmpty
                      ? const Center(
                          child: Text(
                            'Keine Ereignisse\n\n💡 Klicken Sie auf "EGK Auslesen" um zu starten',
                            style: TextStyle(color: Colors.grey),
                            textAlign: TextAlign.center,
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.all(8),
                          itemCount: _logs.length,
                          itemBuilder: (context, index) {
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: Text(
                                _logs[index],
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ),
            ],
          ),
        ),
      );
  }
}
