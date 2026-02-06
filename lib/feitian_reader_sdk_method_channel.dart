import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'feitian_reader_sdk_platform_interface.dart';

/// An implementation of [FeitianReaderSdkPlatform] that uses method channels.
class MethodChannelFeitianReaderSdk extends FeitianReaderSdkPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('feitian_reader_sdk');

  /// The event channel used to receive events from the native platform.
  @visibleForTesting
  final eventChannel = const EventChannel('feitian_reader_sdk/events');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }

  @override
  Future<String?> startBluetoothScan() async {
    final result = await methodChannel.invokeMethod<String>('startBluetoothScan');
    return result;
  }

  @override
  Future<String?> stopBluetoothScan() async {
    final result = await methodChannel.invokeMethod<String>('stopBluetoothScan');
    return result;
  }

  @override
  Future<String?> connectReader() async {
    final result = await methodChannel.invokeMethod<String>('connectReader');
    return result;
  }

  @override
  Future<String?> disconnectReader() async {
    final result = await methodChannel.invokeMethod<String>('disconnectReader');
    return result;
  }

  @override
  Future<String?> sendApduCommand(String apdu) async {
    final result = await methodChannel.invokeMethod<String>('sendApduCommand', {'apdu': apdu});
    return result;
  }

  @override
  Future<List<String>?> sendApduCommands(List<String> apdus) async {
    final result = await methodChannel.invokeListMethod<String>('sendApduCommands', {'apdus': apdus});
    return result;
  }

  @override
  Future<String?> readUID() async {
    final result = await methodChannel.invokeMethod<String>('readUID');
    return result;
  }

  @override
  Future<String?> readEGKCard() async {
    final result = await methodChannel.invokeMethod<String>('readEGKCard');
    return result;
  }

  @override
  Future<String?> powerOnCard() async {
    final result = await methodChannel.invokeMethod<String>('powerOnCard');
    return result;
  }

  @override
  Future<String?> powerOffCard() async {
    final result = await methodChannel.invokeMethod<String>('powerOffCard');
    return result;
  }

  @override
  Stream<Map<dynamic, dynamic>> get eventStream {
    return eventChannel.receiveBroadcastStream().map((event) => event as Map<dynamic, dynamic>);
  }
}
