import 'feitian_reader_sdk_platform_interface.dart';

class FeitianReaderSdk {
  Future<String?> getPlatformVersion() {
    return FeitianReaderSdkPlatform.instance.getPlatformVersion();
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

  Future<String?> readUID() {
    return FeitianReaderSdkPlatform.instance.readUID();
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
