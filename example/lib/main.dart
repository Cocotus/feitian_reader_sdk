import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:feitian_reader_sdk/feitian_reader_sdk.dart';

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
  final List<String> _logsAndData = [];
  final List<String> _logs = [];
  final TextEditingController _apduController = TextEditingController();
  String? _deviceName;
  bool _isConnected = false;

  @override
  void initState() {
    super.initState();
    initPlatformState();
    platform.setMethodCallHandler(_handleMethodCall);
    _setupEventStream();
    // Set default APDU command
    _apduController.text = '00A4040007A0000002471001';
  }

  @override
  void dispose() {
    _apduController.dispose();
    super.dispose();
  }

  void _setupEventStream() {
    _feitianReaderPlugin.eventStream.listen((event) {
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
          _logs.insert(0, 'Device discovered: $_deviceName (RSSI: ${event['rssi']})');
        } else if (eventType == 'readerConnected') {
          _isConnected = true;
          _logs.insert(0, 'Reader connected: ${event['deviceName']}');
          _logs.insert(0, 'Available slots: ${event['slots']}');
        } else if (eventType == 'readerDisconnected') {
          _isConnected = false;
          _logs.insert(0, 'Reader disconnected');
        } else if (eventType == 'batteryLevel') {
          _logs.insert(0, 'Battery level: ${event['level']}%');
        } else if (eventType == 'cardInserted') {
          _logs.insert(0, 'Card inserted in slot: ${event['slotName']}');
        } else if (eventType == 'cardRemoved') {
          _logs.insert(0, 'Card removed from slot: ${event['slotName']}');
        } else if (eventType == 'error') {
          _logs.insert(0, 'ERROR: ${event['error']}');
        }
      });
    });
  }

  Future<void> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'log':
        setState(() {
          _logsAndData.add('LOG: ${call.arguments}');
        });
        break;
      case 'data':
        setState(() {
          final dataStrings = List<String>.from(call.arguments);
          for (var data in dataStrings) {
            _logsAndData.add('DATA: $data');
          }
        });
        break;
      case 'apduResponse':
        setState(() {
          _logsAndData.add('APDU Response: ${call.arguments}');
        });
        break;
    }
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

  void _clearLogsAndData() {
    setState(() {
      _logsAndData.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('FEITIAN Card Reader Demo'),
        ),
        body: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text('Platform: $_platformVersion', style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text('Status: $_feedback', style: const TextStyle(fontSize: 12)),
              const SizedBox(height: 16),
              
              // Reader Connection Buttons
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () {
                        _clearLogsAndData();
                        _updateFeedback('Connect Reader', () async {
                          return await _feitianReaderPlugin.connectReader();
                        });
                      },
                      child: const Text('Connect Reader'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => _updateFeedback('Disconnect Reader', () async {
                        return await _feitianReaderPlugin.disconnectReader();
                      }),
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                      child: const Text('Disconnect'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              
              // Card Power Buttons
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => _updateFeedback('Power On Card', () async {
                        return await _feitianReaderPlugin.powerOnCard();
                      }),
                      child: const Text('Power On Card'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => _updateFeedback('Power Off Card', () async {
                        return await _feitianReaderPlugin.powerOffCard();
                      }),
                      child: const Text('Power Off Card'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              
              // APDU Input Section
              const Text('APDU Command:', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              TextField(
                controller: _apduController,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: 'Enter APDU hex command',
                  helperText: 'Example: 00A4040007A0000002471001',
                ),
                style: const TextStyle(fontFamily: 'Courier'),
              ),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: () {
                  final apdu = _apduController.text.trim();
                  if (apdu.isEmpty) {
                    setState(() {
                      _feedback = 'Error: APDU command is empty';
                    });
                    return;
                  }
                  _updateFeedback('Send APDU', () async {
                    return await _feitianReaderPlugin.sendApduCommand(apdu);
                  });
                },
                child: const Text('Send APDU Command'),
              ),
              const SizedBox(height: 8),
              
              // Quick Commands
              Wrap(
                spacing: 8,
                children: [
                  ElevatedButton(
                    onPressed: () {
                      _apduController.text = '00A4040007A0000002471001';
                    },
                    child: const Text('Select App'),
                  ),
                  ElevatedButton(
                    onPressed: () {
                      _apduController.text = '0084000008';
                    },
                    child: const Text('Get Challenge'),
                  ),
                  ElevatedButton(
                    onPressed: () {
                      _apduController.text = '00B00000FF';
                    },
                    child: const Text('Read Binary'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              
              // Read UID Button
              ElevatedButton(
                onPressed: () => _updateFeedback('Read UID', () async {
                  return await _feitianReaderPlugin.readUID();
                }),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
                child: const Text('Read Card UID'),
              ),
              const SizedBox(height: 16),
              
              // Event Logs Section
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Event Logs:', style: TextStyle(fontWeight: FontWeight.bold)),
                  TextButton(
                    onPressed: () {
                      setState(() {
                        _logs.clear();
                      });
                    },
                    child: const Text('Clear'),
                  ),
                ],
              ),
              const Divider(),
              Container(
                height: 200,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: _logs.isEmpty
                    ? const Center(child: Text('No event logs yet'))
                    : ListView.builder(
                        padding: const EdgeInsets.all(8),
                        itemCount: _logs.length,
                        itemBuilder: (context, index) {
                          return Text(
                            _logs[index],
                            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                          );
                        },
                      ),
              ),
              const SizedBox(height: 16),
              
              // Logs Section
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Logs & Data:', style: TextStyle(fontWeight: FontWeight.bold)),
                  TextButton(
                    onPressed: _clearLogsAndData,
                    child: const Text('Clear'),
                  ),
                ],
              ),
              const Divider(),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: _logsAndData.isEmpty
                      ? const Center(child: Text('No logs yet'))
                      : ListView.builder(
                          itemCount: _logsAndData.length,
                          itemBuilder: (context, index) {
                            return Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              child: Text(
                                _logsAndData[index],
                                style: const TextStyle(fontSize: 12, fontFamily: 'Courier'),
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
