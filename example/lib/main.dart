import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:orgacare_reader_sdk/orgacare_reader_sdk.dart';
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
  final _orgacareDemoPlugin = OrgacareReaderSdk();
  static const platform = MethodChannel('orgacare_reader_sdk');
  final List<String> _logsAndData = [];
  bool _isDeviceLocked = false;
  bool _noDataMobileMode = false;

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

  @override
  void initState() {
    super.initState();
    initPlatformState();
    platform.setMethodCallHandler(_handleMethodCall);
  }

  Future<void> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'log':
        setState(() {
          _logsAndData.add(call.arguments);
        });
        break;
      case 'data':
        setState(() {
          final dataStrings = List<String>.from(call.arguments);
          final filteredDataNodes = _parseAndFilterXmlData(dataStrings);
          _logsAndData.addAll(filteredDataNodes.map((node) => '${node.keys.first}: ${node.values.first}'));
        });
        break;
      case 'deviceIsLocked':
        setState(() {
          _isDeviceLocked = true;
        });
        break;
      case 'noDataMobileMode':
        setState(() {
          _noDataMobileMode = true;
        });
        break;
    }
  }

  Future<void> initPlatformState() async {
    String platformVersion;
    try {
      platformVersion = await _orgacareDemoPlugin.getPlatformVersion() ?? 'Unknown platform version';
    } on PlatformException {
      platformVersion = 'Failed to get platform version.';
    }

    if (!mounted) return;

    setState(() {
      _platformVersion = platformVersion;
    });
  }

  Future<void> _updateFeedback(String methodName, Future<String> Function() method) async {
    try {
      final result = await method();
      setState(() {
        _feedback = '$methodName: $result';
      });
    } catch (e) {
      setState(() {
        _feedback = '$methodName failed: $e';
      });
    }
  }

  List<Map<String, String>> _parseAndFilterXmlData(List<String> dataStrings) {
    List<Map<String, String>> nodes = [];
    for (var data in dataStrings) {
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

  void _clearLogsAndData() {
    setState(() {
      _logsAndData.clear();
      _isDeviceLocked = false;
      _noDataMobileMode = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Card Data Manager'),
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Text('Platform Version: $_platformVersion\n'),
              Text('Feedback: $_feedback\n'),
              if (_isDeviceLocked) const Text('Device is locked', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
              if (_noDataMobileMode) const Text('No card inserted', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
              ElevatedButton(
                onPressed: () {
                  _clearLogsAndData();
                  _updateFeedback('Load VSD', () async {
                    final result = await _orgacareDemoPlugin.loadVSD();
                    return result ?? 'No result';
                  });
                },
                child: const Text('Load VSD'),
              ),
              ElevatedButton(
                onPressed: () => _updateFeedback('Load NFD', () async {
                  final result = await _orgacareDemoPlugin.loadNFD();
                  return result ?? 'No result';
                }),
                child: const Text('Load NFD'),
              ),
              ElevatedButton(
                onPressed: () => _updateFeedback('Load DPE', () async {
                  final result = await _orgacareDemoPlugin.loadDPE();
                  return result ?? 'No result';
                }),
                child: const Text('Load DPE'),
              ),
              ElevatedButton(
                onPressed: () => _updateFeedback('Load AMTS', () async {
                  final result = await _orgacareDemoPlugin.loadAMTS();
                  return result ?? 'No result';
                }),
                child: const Text('Load AMTS'),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: _logsAndData.length,
                  itemBuilder: (context, index) {
                    return ListTile(
                      title: Text(_logsAndData[index]),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
