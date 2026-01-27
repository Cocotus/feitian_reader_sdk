
import 'orgacare_reader_sdk_platform_interface.dart';

class OrgacareReaderSdk {
  Future<String?> getPlatformVersion() {
    return OrgacareReaderSdkPlatform.instance.getPlatformVersion();
  }

  Future<String?> loadVSD()  {
    var result =  OrgacareReaderSdkPlatform.instance.loadVSD();
    return result;
  }

  Future<String?> loadNFD()  {
    return OrgacareReaderSdkPlatform.instance.loadNFD();
  }

  Future<String?> loadDPE()  {
    return OrgacareReaderSdkPlatform.instance.loadDPE();
  }

  Future<String?> loadAMTS() {
    return OrgacareReaderSdkPlatform.instance.loadAMTS();
  }

}