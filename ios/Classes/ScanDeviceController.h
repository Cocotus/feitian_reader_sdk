//
//  ScanDeviceController.h
//  feitian_reader_sdk
//
//  Simplified non-UI version for Flutter integration
//  Based on FEITIAN demo code
//

#import <Foundation/Foundation.h>
#import "EGKCardReader.h"

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
- (void)scanController:(id)controller didReceiveApduResponse:(NSString *)response;
- (void)scanController:(id)controller didSendCardData:(NSArray<NSString *> *)data;
- (void)scanControllerDidNotifyNoCard:(id)controller;
- (void)scanControllerDidNotifyNoReader:(id)controller;
- (void)scanController:(id)controller didReceiveLowBattery:(NSInteger)level;
@end

/**
 * ScanDeviceController manages Bluetooth scanning, reader connection,
 * and card operations for FEITIAN card readers.
 * This is a non-UI version adapted for Flutter integration.
 */
@interface ScanDeviceController : NSObject <EGKCardReaderDelegate>

@property (nonatomic, weak, nullable) id<ScanDeviceControllerDelegate> delegate;
@property (nonatomic, assign) BOOL batteryLoggedOnce;

- (instancetype)init;
- (void)startScanning;
- (void)stopScanning;
- (void)connectToReader:(NSString *)readerName;
- (void)disconnectReader;
- (void)getBatteryLevel;
- (void)powerOnCard;
- (void)powerOffCard;
- (void)readEGKCard;
- (void)readEGKCardOnDemand;

/**
 * Get the connected reader's model name (e.g., "bR301", "iR301")
 */
- (NSString *)getReaderModelName;

/**
 * Send a single APDU command to the card
 * @param apduString Hex string representation of the APDU command (e.g., "00A4040007A0000002471001")
 */
- (void)sendApduCommand:(NSString *)apduString;

/**
 * Send multiple APDU commands sequentially to the card
 * @param apduCommands Array of hex string APDUs to send in sequence
 * @param completion Completion block called with array of response strings or error
 */
- (void)sendApduCommands:(NSArray<NSString *> *)apduCommands 
          withCompletion:(void (^)(NSArray<NSString *> *responses, NSError *error))completion;

@end

NS_ASSUME_NONNULL_END
