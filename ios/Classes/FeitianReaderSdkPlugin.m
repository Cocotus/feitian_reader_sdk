//
//  FeitianReaderSdkPlugin.m
//  feitian_reader_sdk
//
//  Objective-C implementation of Flutter plugin for FEITIAN card readers
//

#import "FeitianReaderSdkPlugin.h"
#import "ScanDeviceController.h"
#import "readerModel.h"
#import <UIKit/UIKit.h>

@interface FeitianReaderSdkPlugin () <ScanDeviceControllerDelegate, FlutterStreamHandler>
@property (nonatomic, strong) FlutterMethodChannel *channel;
@property (nonatomic, strong) FlutterEventChannel *eventChannel;
@property (nonatomic, strong) ScanDeviceController *scanController;
@property (nonatomic, copy) FlutterEventSink eventSink;
@end

@implementation FeitianReaderSdkPlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
    FlutterMethodChannel* channel = [FlutterMethodChannel
                                     methodChannelWithName:@"feitian_reader_sdk"
                                     binaryMessenger:[registrar messenger]];
    FlutterEventChannel* eventChannel = [FlutterEventChannel
                                        eventChannelWithName:@"feitian_reader_sdk/events"
                                        binaryMessenger:[registrar messenger]];
    FeitianReaderSdkPlugin* instance = [[FeitianReaderSdkPlugin alloc] init];
    instance.channel = channel;
    instance.eventChannel = eventChannel;
    [registrar addMethodCallDelegate:instance channel:channel];
    [eventChannel setStreamHandler:instance];
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _scanController = [[ScanDeviceController alloc] init];
        _scanController.delegate = self;
    }
    return self;
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    if ([@"getPlatformVersion" isEqualToString:call.method]) {
        result([@"iOS " stringByAppendingString:[[UIDevice currentDevice] systemVersion]]);
        
    } else if ([@"startBluetoothScan" isEqualToString:call.method]) {
        [self.scanController startScanning];
        result(@"Bluetooth scan started");
        
    } else if ([@"stopBluetoothScan" isEqualToString:call.method]) {
        [self.scanController stopScanning];
        result(@"Bluetooth scan stopped");
        
    } else if ([@"connectToReader" isEqualToString:call.method]) {
        NSString *deviceName = call.arguments[@"deviceName"];
        if (deviceName) {
            [self.scanController connectToReader:deviceName];
            result([NSString stringWithFormat:@"Connecting to reader: %@", deviceName]);
        } else {
            result([FlutterError errorWithCode:@"INVALID_ARGUMENT"
                                       message:@"Device name required"
                                       details:nil]);
        }
        
    } else if ([@"disconnectReader" isEqualToString:call.method]) {
        [self.scanController disconnectReader];
        result(@"Reader disconnected");
        
    } else if ([@"getBatteryLevel" isEqualToString:call.method]) {
        [self.scanController getBatteryLevel];
        result(@"Getting battery level");
        
    } else if ([@"powerOnCard" isEqualToString:call.method]) {
        [self.scanController powerOnCard];
        result(@"Card power on initiated");
        
    } else if ([@"powerOffCard" isEqualToString:call.method]) {
        [self.scanController powerOffCard];
        result(@"Card powered off");
        
    } else if ([@"readEGKCard" isEqualToString:call.method]) {
        [self.scanController readEGKCard];
        result(@"EGK card reading initiated");
        
    } else if ([@"readEGKCardOnDemand" isEqualToString:call.method]) {
        [self.scanController readEGKCardOnDemand];
        result(@"On-demand EGK card reading initiated");
        
    } else if ([@"sendApduCommand" isEqualToString:call.method]) {
        NSString *apduCommand = call.arguments[@"apdu"];
        if (apduCommand) {
            [self.scanController sendApduCommand:apduCommand];
            result(@"APDU command sent");
        } else {
            result([FlutterError errorWithCode:@"INVALID_ARGUMENT"
                                       message:@"APDU command required"
                                       details:nil]);
        }
        
    } else if ([@"sendApduCommands" isEqualToString:call.method]) {
        NSArray *apduCommands = call.arguments[@"apdus"];
        if (apduCommands && [apduCommands isKindOfClass:[NSArray class]]) {
            [self.scanController sendApduCommands:apduCommands withCompletion:^(NSArray<NSString *> *responses, NSError *error) {
                if (error) {
                    result([FlutterError errorWithCode:@"APDU_ERROR"
                                               message:error.localizedDescription
                                               details:nil]);
                } else {
                    result(responses);
                }
            }];
        } else {
            result([FlutterError errorWithCode:@"INVALID_ARGUMENT"
                                       message:@"Array of APDU commands required"
                                       details:nil]);
        }
        
    } else if ([@"connectReader" isEqualToString:call.method]) {
        // Legacy method - map to startBluetoothScan
        [self.scanController startScanning];
        result(@"Bluetooth scan started (legacy method)");
        
    } else if ([@"readUID" isEqualToString:call.method]) {
        result(@"UID reading not implemented in current version");
        
    } else {
        result(FlutterMethodNotImplemented);
    }
}

#pragma mark - ScanDeviceControllerDelegate

- (void)scanController:(id)controller didDiscoverDevice:(NSString *)deviceName rssi:(NSInteger)rssi {
    NSDictionary *eventData = @{
        @"event": @"deviceDiscovered",
        @"deviceName": deviceName,
        @"rssi": @(rssi)
    };
    [self sendEventToFlutter:eventData];
}

- (void)scanController:(id)controller didConnectReader:(NSString *)deviceName slots:(NSArray<NSString *> *)slots {
    NSDictionary *eventData = @{
        @"event": @"readerConnected",
        @"deviceName": deviceName,
        @"slots": slots
    };
    [self sendEventToFlutter:eventData];
}

- (void)scanControllerDidDisconnectReader:(id)controller {
    NSDictionary *eventData = @{
        @"event": @"readerDisconnected"
    };
    [self sendEventToFlutter:eventData];
}

- (void)scanController:(id)controller didDetectCard:(NSString *)slotName {
    // ✅ BUGFIX: Nil check for slotName to prevent crash
    NSDictionary *eventData = @{
        @"event": @"cardInserted",
        @"slotName": slotName ?: @"Unknown Slot"
    };
    [self sendEventToFlutter:eventData];
}

- (void)scanController:(id)controller didRemoveCard:(NSString *)slotName {
    // ✅ BUGFIX: Nil check for slotName to prevent crash
    NSDictionary *eventData = @{
        @"event": @"cardRemoved",
        @"slotName": slotName ?: @"Unknown Slot"
    };
    [self sendEventToFlutter:eventData];
}

- (void)scanController:(id)controller didReceiveBattery:(NSInteger)level {
    NSDictionary *eventData = @{
        @"event": @"batteryLevel",
        @"level": @(level)
    };
    [self sendEventToFlutter:eventData];
}

- (void)scanController:(id)controller didReceiveLog:(NSString *)message {
    NSDictionary *eventData = @{
        @"event": @"log",
        @"message": message
    };
    [self sendEventToFlutter:eventData];
}

- (void)scanController:(id)controller didReadEGKData:(NSDictionary *)data {
    NSMutableDictionary *eventData = [NSMutableDictionary dictionaryWithDictionary:data];
    eventData[@"event"] = @"egkData";
    [self sendEventToFlutter:eventData];
}

- (void)scanController:(id)controller didReceiveError:(NSString *)error {
    NSDictionary *eventData = @{
        @"event": @"error",
        @"error": error
    };
    [self sendEventToFlutter:eventData];
}

- (void)scanController:(id)controller didReceiveApduResponse:(NSString *)response {
    NSDictionary *eventData = @{
        @"event": @"apduResponse",
        @"response": response ?: @""
    };
    [self sendEventToFlutter:eventData];
}

- (void)scanController:(id)controller didSendCardData:(NSArray<NSString *> *)data {
    NSDictionary *eventData = @{
        @"event": @"data",
        @"data": data
    };
    [self sendEventToFlutter:eventData];
}

- (void)scanControllerDidNotifyNoCard:(id)controller {
    NSDictionary *eventData = @{
        @"event": @"noDataMobileMode"
    };
    [self sendEventToFlutter:eventData];
}

- (void)scanControllerDidNotifyNoReader:(id)controller {
    NSDictionary *eventData = @{
        @"event": @"noBluetooth"
    };
    [self sendEventToFlutter:eventData];
}

- (void)scanController:(id)controller didReceiveLowBattery:(NSInteger)level {
    NSDictionary *eventData = @{
        @"event": @"lowBattery",
        @"level": @(level)
    };
    [self sendEventToFlutter:eventData];
}

- (void)sendEventToFlutter:(NSDictionary *)eventData {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.eventSink) {
            self.eventSink(eventData);
        }
    });
}

#pragma mark - FlutterStreamHandler

- (FlutterError *)onListenWithArguments:(id)arguments eventSink:(FlutterEventSink)events {
    self.eventSink = events;
    return nil;
}

- (FlutterError *)onCancelWithArguments:(id)arguments {
    self.eventSink = nil;
    return nil;
}

@end
