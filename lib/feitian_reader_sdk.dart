import 'feitian_reader_sdk_platform_interface.dart';

class FeitianReaderSdk {
  Future<String?> getPlatformVersion() {
    return FeitianReaderSdkPlatform.instance.getPlatformVersion();
  }

  Future<String?> startBluetoothScan() {
    return FeitianReaderSdkPlatform.instance.startBluetoothScan();
  }

  Future<String?> stopBluetoothScan() {
    return FeitianReaderSdkPlatform.instance.stopBluetoothScan();
  }

  Future<String?> connectReader() {
    return FeitianReaderSdkPlatform.instance.connectReader();
  }

  Future<String?> disconnectReader() {
    return FeitianReaderSdkPlatform.instance.disconnectReader();
  }

  Future<String?> sendApduCommand(String apdu) {
    return FeitianReaderSdkPlatform.instance.sendApduCommand(apdu);
  }

  Future<List<String>?> sendApduCommands(List<String> apdus) {
    return FeitianReaderSdkPlatform.instance.sendApduCommands(apdus);
  }

  Future<String?> readUID() {
    return FeitianReaderSdkPlatform.instance.readUID();
  }

  Future<String?> readEGKCard() {
    return FeitianReaderSdkPlatform.instance.readEGKCard();
  }

  Future<String?> powerOnCard() {
    return FeitianReaderSdkPlatform.instance.powerOnCard();
  }

  Future<String?> powerOffCard() {
    return FeitianReaderSdkPlatform.instance.powerOffCard();
  }

  Stream<Map<dynamic, dynamic>> get eventStream {
    return FeitianReaderSdkPlatform.instance.eventStream;
  }
}
