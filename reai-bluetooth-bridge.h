#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^REAIBluetoothConsumerHandler)(uint16_t value);
typedef void (^REAIBluetoothModeHandler)(uint8_t mode);
typedef void (^REAIBluetoothConnectionHandler)(BOOL connected, NSString *detail);
typedef void (^REAIBluetoothLogHandler)(NSString *level, NSString *message);

@interface REAIBluetoothBridge : NSObject

@property(nonatomic, readonly) BOOL autoConnectEnabled;
@property(nonatomic, readonly) BOOL connected;
@property(nonatomic, readonly, nullable) NSString *rememberedDeviceName;

- (instancetype)initWithConsumerHandler:(REAIBluetoothConsumerHandler)consumerHandler
                             modeHandler:(REAIBluetoothModeHandler)modeHandler
                       connectionHandler:(REAIBluetoothConnectionHandler)connectionHandler
                              logHandler:(REAIBluetoothLogHandler)logHandler;
- (void)start;
- (void)stop;
- (void)setUSBConnected:(BOOL)connected;
- (void)setAutoConnectEnabled:(BOOL)enabled;
- (void)reconnect;
- (void)forgetDevice;
- (void)queryWorkMode;

@end

BOOL REAIBluetoothRunProtocolSelfTest(void);

NS_ASSUME_NONNULL_END
