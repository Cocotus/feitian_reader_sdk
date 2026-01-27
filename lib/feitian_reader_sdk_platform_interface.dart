import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'feitian_reader_sdk_method_channel.dart';

abstract class FeitianReaderSdkPlatform extends PlatformInterface {
  /// Constructs a FeitianReaderSdkPlatform.
  FeitianReaderSdkPlatform() : super(token: _token);

  static final Object _token = Object();

  static FeitianReaderSdkPlatform _instance = MethodChannelFeitianReaderSdk();

  /// The default instance of [FeitianReaderSdkPlatform] to use.
  ///
  /// Defaults to [MethodChannelFeitianReaderSdk].
  static FeitianReaderSdkPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [FeitianReaderSdkPlatform] when
  /// they register themselves.
  static set instance(FeitianReaderSdkPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('getPlatformVersion() has not been implemented.');
  }

  Future<String?> connectReader() {
    throw UnimplementedError('connectReader() has not been implemented.');
  }

  Future<String?> disconnectReader() {
    throw UnimplementedError('disconnectReader() has not been implemented.');
  }

  Future<String?> sendApduCommand(String apdu) {
    throw UnimplementedError('sendApduCommand() has not been implemented.');
  }

  Future<String?> readUID() {
    throw UnimplementedError('readUID() has not been implemented.');
  }

  Future<String?> powerOnCard() {
    throw UnimplementedError('powerOnCard() has not been implemented.');
  }

  Future<String?> powerOffCard() {
    throw UnimplementedError('powerOffCard() has not been implemented.');
  }
}
