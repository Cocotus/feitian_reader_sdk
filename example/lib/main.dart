import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:feitian_reader_sdk/feitian_reader_sdk.dart';
import 'package:xml/xml.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  String _platformVersion = 'Unknown';
  String _feedback = 'No feedback yet';
  final _feitianReaderPlugin = FeitianReaderSdk();
  static const platform = MethodChannel('feitian_reader_sdk');
  final List<String> _logs = [];
  final TextEditingController _apduController = TextEditingController();
  String? _deviceName;
  bool _isConnected = false;
  bool _isScanning = false;
  StreamSubscription<Map<dynamic, dynamic>>? _eventSubscription;
  Map<String, dynamic>? _egkData;

  @override
  void initState() {
    super.initState();
    initPlatformState();
    platform.setMethodCallHandler(_handleMethodCall);
    _setupEventStream();
    // Set default APDU command
    _apduController.text = '00A4040007A0000002471001';
    // ❌ REMOVED: Auto-start Bluetooth scan on app launch
  }

  @override
  void dispose() {
    _apduController.dispose();
    _eventSubscription?.cancel();
    super.dispose();
  }

  final List<String> _nodesToDisplay = [
    'geburtsdatum',
    'vorname',
    'nachname',
    'geschlecht',
    'titel',
    'postleitzahl',
    'ort',
    'wohnsitzlaendercode',
    'strasse',
    'hausnummer',
    'beginn',
    'kostentraegerkennung',
    'kostentraegerlaendercode',
    'name',
    'versichertenart',
    'versicherten_id'
  ];

  List<Map<String, String>> _parseAndFilterXmlData(List<String> dataStrings) {
    List<Map<String, String>> nodes = [];
    for (var data in dataStrings) {
      try {
        final document = XmlDocument.parse(data);
        final elements = document.findAllElements('*');
        for (var element in elements) {
          final nodeName = element.name.toString().toLowerCase();
          if (_nodesToDisplay.contains(nodeName)) {
            final nodeContent = element.innerText;
            final formattedContent = _formatNodeContent(nodeName, nodeContent);
            nodes.add({element.name.toString(): formattedContent});
          }
        }
      } catch (e) {
        _logs.insert(0, '⚠️ XML parsing error: $e');
      }
    }
    return nodes;
  }

  String _formatNodeContent(String nodeName, String content) {
    if ((nodeName == 'geburtsdatum' || nodeName == 'beginn') && content.length == 8) {
      final year = content.substring(0, 4);
      final month = content.substring(4, 6);
      final day = content.substring(6, 8);
      return '$day.$month.$year';
    }
    return content;
  }

  void _setupEventStream() {
    _eventSubscription = _feitianReaderPlugin.eventStream.listen((event) {
      setState(() {
        final eventType = event['event'];
        
        if (eventType == 'log') {
          // Add log to display
          _logs.insert(0, event['message']);
          if (_logs.length > 100) {
            _logs.removeLast();
          }
        } else if (eventType == 'deviceDiscovered') {
          _deviceName = event['deviceName'];
          _logs.insert(0, '📱 Device discovered: $_deviceName (RSSI: ${event['rssi']})');
        } else if (eventType == 'readerConnected') {
          _isConnected = true;
          _isScanning = false;
          _logs.insert(0, '✅ Reader connected: ${event['deviceName']}');
          _logs.insert(0, '📋 Available slots: ${event['slots']}');
        } else if (eventType == 'readerDisconnected') {
          _isConnected = false;
          _egkData = null;
          _logs.insert(0, '❌ Reader disconnected');
        } else if (eventType == 'batteryLevel') {
          _logs.insert(0, '🔋 Battery level: ${event['level']}%');
        } else if (eventType == 'cardInserted') {
          _logs.insert(0, '🎴 Card inserted in slot: ${event['slotName']}');
        } else if (eventType == 'cardRemoved') {
          _logs.insert(0, '🎴 Card removed from slot: ${event['slotName']}');
        } else if (eventType == 'egkData') {
          _egkData = Map<String, dynamic>.from(event);
          _logs.insert(0, '💾 EGK data received');
        } else if (eventType == 'apduResponse') {
          _logs.insert(0, '📤 APDU Response: ${event['response']}');
        } else if (eventType == 'error') {
          _logs.insert(0, '⚠️ ERROR: ${event['error']}');
        } else if (eventType == 'data') {
          final dataStrings = List<String>.from(event['data']);
          final filteredDataNodes = _parseAndFilterXmlData(dataStrings);
          _logs.addAll(filteredDataNodes.map((node) => '${node.keys.first}: ${node.values.first}'));
        } else if (eventType == 'noDataMobileMode') {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('❌ Keine Karte eingesteckt!'),
                backgroundColor: Colors.red,
                duration: Duration(seconds: 3),
              ),
            );
          }
        } else if (eventType == 'noBluetooth') {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('❌ Kartenleser nicht verbunden!'),
                backgroundColor: Colors.orange,
                duration: Duration(seconds: 3),
              ),
            );
          }
        } else if (eventType == 'lowBattery') {
          final battery = event['level'] as int;
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('🔋 Batterie niedrig: $battery%'),
                backgroundColor: Colors.deepOrange,
                duration: const Duration(seconds: 5),
              ),
            );
          }
        }
      });
    });
  }

  Future<void> _handleMethodCall(MethodCall call) async {
    // Method call handler for legacy support
    // Most events now come through the event stream
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

  Future<void> _updateFeedback(String methodName, Future<String?> Function() method) async {
    try {
      final result = await method();
      setState(() {
        _feedback = '$methodName: ${result ?? "Success"}';
      });
    } catch (e) {
      setState(() {
        _feedback = '$methodName failed: $e';
      });
    }
  }

  Future<void> _startBluetoothScan() async {
    try {
      setState(() {
        _isScanning = true;
        _feedback = 'Starting Bluetooth scan...';
      });
      await _feitianReaderPlugin.startBluetoothScan();
    } catch (e) {
      setState(() {
        _feedback = 'Scan failed: $e';
        _isScanning = false;
      });
    }
  }

  Future<void> _disconnectReader() async {
    try {
      setState(() {
        _feedback = 'Disconnecting reader...';
      });
      await _feitianReaderPlugin.disconnectReader();
    } catch (e) {
      setState(() {
        _feedback = 'Disconnect failed: $e';
      });
    }
  }

  Future<void> _readEGKCard() async {
    try {
      setState(() {
        _feedback = 'Lese EGK-Karte...';
        _logs.clear(); // Clear logs before reading
      });
      await _feitianReaderPlugin.readEGKCard();
    } catch (e) {
      setState(() {
        _feedback = 'EGK-Lesevorgang fehlgeschlagen: $e';
      });
    }
  }

  Future<void> _sendApdu() async {
    final apdu = _apduController.text.trim();
    if (apdu.isEmpty) {
      setState(() {
        _feedback = 'Error: APDU command is empty';
      });
      return;
    }
    try {
      setState(() {
        _feedback = 'Sending APDU...';
      });
      await _feitianReaderPlugin.sendApduCommand(apdu);
    } catch (e) {
      setState(() {
        _feedback = 'APDU send failed: $e';
      });
    }
  }

  void _clearLogs() {
    setState(() {
      _logs.clear();
    });
  }

  Widget _buildDataRow(String label, dynamic value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text(
        '$label: $value',
        style: const TextStyle(fontSize: 12),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('FEITIAN EGK Card Reader'),
          backgroundColor: Colors.blue,
        ),
        body: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // Connection Status Card
              Card(
                color: _isConnected ? Colors.green.shade50 : (_isScanning ? Colors.orange.shade50 : Colors.grey.shade100),
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            _isConnected ? Icons.check_circle : (_isScanning ? Icons.bluetooth_searching : Icons.bluetooth_disabled),
                            color: _isConnected ? Colors.green : (_isScanning ? Colors.orange : Colors.grey),
                            size: 24,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _isConnected 
                                ? 'Connected to $_deviceName' 
                                : (_isScanning ? 'Scanning for devices...' : 'Not connected'),
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                                color: _isConnected ? Colors.green.shade900 : Colors.black87,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (_feedback.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          _feedback,
                          style: const TextStyle(fontSize: 12, color: Colors.black54),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              
              // Main Action Buttons
              ElevatedButton.icon(
                onPressed: !_isScanning && !_isConnected ? _startBluetoothScan : null,
                icon: const Icon(Icons.bluetooth_searching),
                label: const Text('Suche Kartenleser'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.all(16),
                  disabledBackgroundColor: Colors.grey.shade300,
                ),
              ),
              const SizedBox(height: 8),
              
              ElevatedButton.icon(
                onPressed: _isConnected ? _disconnectReader : null,
                icon: const Icon(Icons.bluetooth_disabled),
                label: const Text('Trenne Kartenleser'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.all(16),
                  disabledBackgroundColor: Colors.grey.shade300,
                ),
              ),
              const SizedBox(height: 8),
              
              ElevatedButton.icon(
                onPressed: _isConnected ? _readEGKCard : null,
                icon: const Icon(Icons.credit_card),
                label: const Text('Lese Karte'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.all(16),
                  disabledBackgroundColor: Colors.grey.shade300,
                ),
              ),
              const SizedBox(height: 16),
              
              // EGK Data Display
              if (_egkData != null) ...[
                Card(
                  color: Colors.blue.shade50,
                  child: Padding(
                    padding: const EdgeInsets.all(12.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '💳 EGK Kartendaten',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                        ),
                        const Divider(),
                        // Display only relevant EGK data fields, not internal metadata
                        if (_egkData!.containsKey('atr'))
                          _buildDataRow('ATR', _egkData!['atr']),
                        if (_egkData!.containsKey('cardType'))
                          _buildDataRow('Card Type', _egkData!['cardType']),
                        if (_egkData!.containsKey('patientName'))
                          _buildDataRow('Patient Name', _egkData!['patientName']),
                        if (_egkData!.containsKey('insuranceNumber'))
                          _buildDataRow('Insurance Number', _egkData!['insuranceNumber']),
                        if (_egkData!.containsKey('insuranceCompany'))
                          _buildDataRow('Insurance Company', _egkData!['insuranceCompany']),
                        if (_egkData!.containsKey('placeholder'))
                          _buildDataRow('Placeholder', _egkData!['placeholder']),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
              
              // APDU Section
              const Text('APDU Befehl senden:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
              const SizedBox(height: 8),
              TextField(
                controller: _apduController,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: 'APDU Hex-Befehl eingeben',
                  helperText: 'Beispiel: 00A4040007A0000002471001',
                  contentPadding: EdgeInsets.all(12),
                ),
                style: const TextStyle(fontFamily: 'Courier', fontSize: 12),
              ),
              const SizedBox(height: 8),
              ElevatedButton.icon(
                onPressed: _isConnected ? _sendApdu : null,
                icon: const Icon(Icons.send),
                label: const Text('Sende APDU'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.all(12),
                  disabledBackgroundColor: Colors.grey.shade300,
                ),
              ),
              const SizedBox(height: 16),
              
              // Event Logs Section
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Event-Protokoll:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                  TextButton(
                    onPressed: _clearLogs,
                    child: const Text('Löschen'),
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
                      ? const Center(child: Text('Keine Ereignisse', style: TextStyle(color: Colors.grey)))
                      : ListView.builder(
                          padding: const EdgeInsets.all(8),
                          itemCount: _logs.length,
                          itemBuilder: (context, index) {
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: Text(
                                _logs[index],
                                style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                              ),
                            );
                          },
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
