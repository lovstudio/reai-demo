#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, REAIExperienceMode) {
    REAIExperienceModeMusic = 0,
    REAIExperienceModeGame = 1,
    REAIExperienceModeSettings = 2,
};

typedef NS_ENUM(NSInteger, REAISettingsRow) {
    REAISettingsRowBluetoothAutoConnect = 0,
    REAISettingsRowBluetoothReconnect = 1,
    REAISettingsRowBluetoothForget = 2,
    REAISettingsRowDesktopPet = 3,
};

@interface REAIModeOverlayController : NSObject
@property(nonatomic, readonly) BOOL showingSelector;
@property(nonatomic, readonly) BOOL showingGame;
@property(nonatomic, readonly) BOOL showingSettings;
- (void)showSelectorWithMode:(REAIExperienceMode)mode;
- (void)showGame;
- (void)showSettingsWithDesktopPetEnabled:(BOOL)desktopPetEnabled
                bluetoothAutoConnectEnabled:(BOOL)bluetoothAutoConnectEnabled
                           connectionStatus:(NSString *)connectionStatus
                                 deviceName:(nullable NSString *)deviceName;
- (void)updateSettingsWithDesktopPetEnabled:(BOOL)desktopPetEnabled
                  bluetoothAutoConnectEnabled:(BOOL)bluetoothAutoConnectEnabled
                             connectionStatus:(NSString *)connectionStatus
                                   deviceName:(nullable NSString *)deviceName;
- (void)setDesktopPetEnabled:(BOOL)enabled;
- (void)moveSettingsSelectionBy:(NSInteger)delta;
- (REAISettingsRow)selectedSettingsRow;
- (void)setSettingsForgetConfirmation:(BOOL)confirmation;
- (void)hide;
- (void)moveGamePaddleBy:(CGFloat)delta;
- (void)setGameSpeedMultiplier:(CGFloat)multiplier label:(NSString *)label;
- (void)toggleGameAction;
@end

BOOL REAIRenderSettingsPreview(NSString *path);

NS_ASSUME_NONNULL_END
