//
//  ScanDeviceController.h
//  feitian_reader_sdk
//
//  Simplified non-UI version for Flutter integration
//  Based on FEITIAN demo code
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Protocol for receiving callbacks from ScanDeviceController
 * Implement this protocol to receive events from the FEITIAN SDK
 */
@protocol ScanDeviceControllerDelegate <NSObject>
@optional
- (void)scanController:(id)controller didDiscoverDevice:(NSString *)deviceName rssi:(NSInteger)rssi;
- (void)scanController:(id)controller didConnectReader:(NSString *)deviceName slots:(NSArray<NSString *> *)slots;
- (void)scanControllerDidDisconnectReader:(id)controller;
- (void)scanController:(id)controller didDetectCard:(NSString *)slotName;
- (void)scanController:(id)controller didRemoveCard:(NSString *)slotName;
- (void)scanController:(id)controller didReceiveBattery:(NSInteger)level;
- (void)scanController:(id)controller didReceiveLog:(NSString *)message;
- (void)scanController:(id)controller didReadEGKData:(NSDictionary *)data;
- (void)scanController:(id)controller didReceiveError:(NSString *)error;
@end

/**
 * ScanDeviceController manages Bluetooth scanning, reader connection,
 * and card operations for FEITIAN card readers.
 * This is a non-UI version adapted for Flutter integration.
 */
@interface ScanDeviceController : NSObject

@property (nonatomic, weak, nullable) id<ScanDeviceControllerDelegate> delegate;

- (instancetype)init;
- (void)startScanning;
- (void)stopScanning;
- (void)connectToReader:(NSString *)readerName;
- (void)disconnectReader;
- (void)getBatteryLevel;
- (void)powerOnCard;
- (void)powerOffCard;
- (void)readEGKCard;

/**
 * Get the connected reader's model name (e.g., "bR301", "iR301")
 */
- (NSString *)getReaderModelName;

@end

NS_ASSUME_NONNULL_END
