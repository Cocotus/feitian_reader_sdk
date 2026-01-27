import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'orgacare_reader_sdk_method_channel.dart';

abstract class OrgacareReaderSdkPlatform extends PlatformInterface {
  /// Constructs a OrgacareReaderSdkPlatform.
  OrgacareReaderSdkPlatform() : super(token: _token);

  static final Object _token = Object();

  static OrgacareReaderSdkPlatform _instance = MethodChannelOrgacareReaderSdk();

  /// The default instance of [OrgacareReaderSdkPlatform] to use.
  ///
  /// Defaults to [MethodChannelOrgacareReaderSdk].
  static OrgacareReaderSdkPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [OrgacareReaderSdkPlatform] when
  /// they register themselves.
  static set instance(OrgacareReaderSdkPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }


  Future<String?> loadVSD() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }


  Future<String?> loadNFD() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }


  Future<String?> loadDPE() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }


  Future<String?> loadAMTS() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }

}