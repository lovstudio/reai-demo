#import <Cocoa/Cocoa.h>
#import <IOKit/hidsystem/IOHIDLib.h>
#import <AudioToolbox/AudioHardwareService.h>
#import <CoreAudio/CoreAudio.h>
#import <hidapi.h>
#import <hidapi_darwin.h>
#import "reai-bluetooth-bridge.h"
#import "reai-mode-ui.h"
#import "reai-voice-companion.h"

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct __MRSystemAppPlaybackQueue *MRSystemAppPlaybackQueueRef;
extern MRSystemAppPlaybackQueueRef MRSystemAppPlaybackQueueCreate(CFAllocatorRef allocator, int type);
extern void MRSystemAppPlaybackQueueSetTracklistStoreIDs(MRSystemAppPlaybackQueueRef queue,
                                                          CFArrayRef storeIDs);
extern void MRSystemAppPlaybackQueueSetRadioStationIDType(MRSystemAppPlaybackQueueRef queue,
                                                           int identifierType);
extern void MRSystemAppPlaybackQueueSetRadioStationStringIdentifier(
    MRSystemAppPlaybackQueueRef queue, CFStringRef identifier);
extern void MRSystemAppPlaybackQueueSetFirstItemGenericTrackIdentifier(
    MRSystemAppPlaybackQueueRef queue, CFStringRef identifier);
extern void MRSystemAppPlaybackQueueSetIsRequestingImmediatePlayback(
    MRSystemAppPlaybackQueueRef queue, bool immediatePlayback);
extern void MRSystemAppPlaybackQueueSetReplaceIntent(MRSystemAppPlaybackQueueRef queue, int intent);
extern void MRSystemAppPlaybackQueueDestroy(MRSystemAppPlaybackQueueRef queue);
extern void MRMediaRemoteSetSystemAppPlaybackQueue(MRSystemAppPlaybackQueueRef queue,
                                                    NSDictionary *options,
                                                    id completion);

enum {
    REAI_VENDOR_ID = 0x363C,
    REAI_PRODUCT_ID = 0xED20,
    REAI_CONSUMER_USAGE_PAGE = 0x000C,
    REAI_CONSUMER_REPORT_ID = 0x0C,
    REAI_CONFIG_USAGE_PAGE = 0xFFA0,
    REAI_CONFIG_USAGE = 0x0002,
    REAI_CONFIG_INPUT_REPORT_ID = 0x0A,
    REAI_CONFIG_OUTPUT_REPORT_ID = 0x0B,
    REAI_CMD_STATUS = 0x12,
    REAI_CMD_WORK_MODE_DATA = 0xC9,
    REAI_KEY_TAB = 0x0F01,
    REAI_KEY_NEW = 0x0F02,
    REAI_KEY_ESCAPE = 0x0F03,
    REAI_KEY_VOICE = 0x0F04,
    REAI_KEY_ACTION = 0x0F05,
    REAI_KEY_ENTER = 0x0F06,
    REAI_VOLUME_MUTE = 0x00E2,
    REAI_VOLUME_UP = 0x00E9,
    REAI_VOLUME_DOWN = 0x00EA,
    REAI_KNOB_COUNTERCLOCKWISE = 0x0F07,
    REAI_KNOB_CLOCKWISE = 0x0F08,
    REAI_KNOB_PRESS = 0x0F09,
    REAI_MODE_YOLO = 0x0F0A,
    REAI_MODE_PLAN = 0x0F0B,
    REAI_MODE_CHAT = 0x0F0C,
    REAI_KEY_VOICE_MARK = 0x0F99,
};

static NSString *const YoloRadioStationID = @"ra.q-MK3VCQ";
static NSString *const ChatRadioStationID = @"ra.q-MMLEBw";
static NSString *const PlanCatalogPlaylistID = @"pl.998d1aa71ae64e1f9199d0a112067149";
static NSString *const AppleMusicStorefront = @"cn";
static NSString *const DesktopPetEnabledDefaultsKey = @"desktop-pet-enabled";
static NSString *const VoiceConversationEnabledDefaultsKey = @"voice-conversation-enabled";

static NSString *experience_mode_name(REAIExperienceMode mode) {
    switch (mode) {
        case REAIExperienceModeMusic: return @"音乐";
        case REAIExperienceModeGame: return @"游戏";
        case REAIExperienceModeSettings: return @"设置";
    }
    return @"未知";
}

static uint16_t decode_consumer_value(const unsigned char *report, int length) {
    if (length >= 3 && report[0] == REAI_CONSUMER_REPORT_ID) {
        return (uint16_t)report[1] | ((uint16_t)report[2] << 8);
    }
    if (length >= 2) {
        return (uint16_t)report[0] | ((uint16_t)report[1] << 8);
    }
    return 0;
}

static NSString *controller_log_path(void) {
    NSString *logsDirectory = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs"];
    return [logsDirectory stringByAppendingPathComponent:@"REAI Music Controller.log"];
}

static NSString *controller_mode_path(void) {
    NSString *supportDirectory = [NSHomeDirectory() stringByAppendingPathComponent:
                                  @"Library/Application Support/REAI Music Controller"];
    [[NSFileManager defaultManager] createDirectoryAtPath:supportDirectory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return [supportDirectory stringByAppendingPathComponent:@"current-mode"];
}

static bool get_default_output_device(AudioDeviceID *device) {
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    UInt32 size = sizeof(*device);
    return AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, device) == noErr &&
           *device != kAudioObjectUnknown;
}

static bool get_output_volume(Float32 *volume) {
    AudioDeviceID device;
    if (!get_default_output_device(&device)) return false;
    AudioObjectPropertyAddress address = {
        kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        kAudioDevicePropertyScopeOutput,
        kAudioObjectPropertyElementMain,
    };
    UInt32 size = sizeof(*volume);
    return AudioObjectGetPropertyData(device, &address, 0, NULL, &size, volume) == noErr;
}

static bool set_output_volume(Float32 volume) {
    AudioDeviceID device;
    if (!get_default_output_device(&device)) return false;
    AudioObjectPropertyAddress address = {
        kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        kAudioDevicePropertyScopeOutput,
        kAudioObjectPropertyElementMain,
    };
    Boolean settable = false;
    if (AudioObjectIsPropertySettable(device, &address, &settable) != noErr || !settable) return false;
    volume = MAX(0.0f, MIN(1.0f, volume));
    return AudioObjectSetPropertyData(device, &address, 0, NULL, sizeof(volume), &volume) == noErr;
}

static bool change_output_volume(Float32 delta, Float32 *result) {
    Float32 volume = 0;
    if (!get_output_volume(&volume)) return false;
    volume = MAX(0.0f, MIN(1.0f, volume + delta));
    if (!set_output_volume(volume)) return false;
    if (result != NULL) *result = volume;
    return true;
}

static bool toggle_output_mute(bool *mutedResult) {
    AudioDeviceID device;
    if (!get_default_output_device(&device)) return false;
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyMute,
        kAudioDevicePropertyScopeOutput,
        kAudioObjectPropertyElementMain,
    };
    UInt32 muted = 0;
    UInt32 size = sizeof(muted);
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &muted) != noErr) return false;
    muted = muted ? 0 : 1;
    if (AudioObjectSetPropertyData(device, &address, 0, NULL, sizeof(muted), &muted) != noErr) return false;
    if (mutedResult != NULL) *mutedResult = muted != 0;
    return true;
}

static void controller_log(NSString *level, NSString *message) {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    NSString *line = [NSString stringWithFormat:@"%@ [%@] %@\n",
                      [formatter stringFromDate:[NSDate date]], level, message];
    fputs(line.UTF8String, stderr);

    @synchronized ([NSApplication class]) {
        NSString *path = controller_log_path();
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [NSData.data writeToFile:path atomically:YES];
        }
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (handle != nil) {
            [handle seekToEndOfFile];
            [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [handle closeFile];
        }
    }
}

static hid_device *open_consumer_interface(void) {
    struct hid_device_info *devices = hid_enumerate(REAI_VENDOR_ID, REAI_PRODUCT_ID);
    struct hid_device_info *current = devices;
    hid_device *device = NULL;
    while (current != NULL) {
        if (current->usage_page == REAI_CONSUMER_USAGE_PAGE) {
            device = hid_open_path(current->path);
            if (device != NULL) break;
        }
        current = current->next;
    }
    hid_free_enumeration(devices);
    return device;
}

static hid_device *open_config_interface(void) {
    struct hid_device_info *devices = hid_enumerate(REAI_VENDOR_ID, REAI_PRODUCT_ID);
    struct hid_device_info *current = devices;
    hid_device *device = NULL;
    while (current != NULL) {
        if (current->usage_page == REAI_CONFIG_USAGE_PAGE && current->usage == REAI_CONFIG_USAGE) {
            device = hid_open_path(current->path);
            if (device != NULL) break;
        }
        current = current->next;
    }
    hid_free_enumeration(devices);
    return device;
}

static int query_work_mode(void) {
    hid_device *device = open_config_interface();
    if (device == NULL) return -1;

    unsigned char command[64] = {0};
    command[0] = REAI_CONFIG_OUTPUT_REPORT_ID;
    command[1] = REAI_CMD_STATUS;
    command[2] = 0x04;
    command[3] = REAI_CMD_WORK_MODE_DATA;
    if (hid_write(device, command, sizeof(command)) < 0) {
        hid_close(device);
        return -1;
    }

    unsigned char response[64] = {0};
    int mode = -1;
    for (int attempt = 0; attempt < 30; attempt++) {
        int length = hid_read_timeout(device, response, sizeof(response), 100);
        if (length < 0) break;
        if (length >= 5 && response[0] == REAI_CONFIG_INPUT_REPORT_ID &&
            response[1] == REAI_CMD_STATUS && response[3] == REAI_CMD_WORK_MODE_DATA) {
            if (response[4] <= 2) mode = response[4];
            break;
        }
    }
    hid_close(device);
    return mode;
}

@interface REAIAppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSMenuItem *statusMenuItem;
@property(nonatomic, strong) NSMenuItem *modeMenuItem;
@property(nonatomic, strong) NSMenuItem *experienceMenuItem;
@property(nonatomic, strong) NSMenuItem *companionMenuItem;
@property(nonatomic, strong) NSMenuItem *voiceConversationMenuItem;
@property(nonatomic, assign) BOOL listenerStarted;
@property(nonatomic, assign) BOOL stopping;
@property(nonatomic, assign) BOOL permissionDenialLogged;
@property(nonatomic, copy) NSString *currentMode;
@property(nonatomic, copy) NSString *catalogDeveloperToken;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *catalogPlaylistCache;
@property(nonatomic, strong) REAIModeOverlayController *modeOverlay;
@property(nonatomic, strong) REAIVoiceCompanionController *voiceCompanion;
@property(nonatomic, strong) REAIBluetoothBridge *bluetoothBridge;
@property(nonatomic, assign) REAIExperienceMode activeExperienceMode;
@property(nonatomic, assign) REAIExperienceMode selectedExperienceMode;
@property(nonatomic, assign) REAIExperienceMode selectorReturnMode;
@property(nonatomic, assign) BOOL desktopPetEnabled;
@property(nonatomic, assign) BOOL voiceConversationEnabled;
@property(nonatomic, assign) BOOL bluetoothVoiceKeyHeld;
@property(nonatomic, assign) BOOL bluetoothNonVoicePulseWhileVoiceHeld;
@property(nonatomic, assign) uint16_t bluetoothPreviousValue;
@property(nonatomic, assign) uint16_t bluetoothActiveModeEndpoint;
@property(nonatomic, assign) BOOL bluetoothInitialModePending;
@property(nonatomic, assign) BOOL bluetoothConnected;
@property(nonatomic, assign) BOOL boardUSBConnected;
@property(nonatomic, assign) BOOL settingsForgetConfirmation;
@property(nonatomic, copy) NSString *bluetoothConnectionDetail;
- (void)setWorkMode:(NSString *)mode triggerPlaylist:(BOOL)triggerPlaylist;
- (void)playPlaylistForMode:(NSString *)mode;
- (void)handleConsumerValue:(uint16_t)value;
- (void)applyDesktopPetEnabled:(BOOL)enabled;
- (void)applyVoiceConversationEnabled:(BOOL)enabled;
- (void)handleVoiceKeyReleased;
- (void)navigateBack;
- (void)handleBluetoothConsumerValue:(uint16_t)value;
- (void)showSettingsOverlay;
- (void)refreshSettingsOverlay;
- (void)activateSelectedSetting;
- (void)updateUSBConnectionState:(BOOL)connected;
@end

@implementation REAIAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    id storedDesktopPetSetting = [[NSUserDefaults standardUserDefaults]
        objectForKey:DesktopPetEnabledDefaultsKey];
    self.desktopPetEnabled = storedDesktopPetSetting == nil
        ? YES
        : [storedDesktopPetSetting boolValue];
    id storedVoiceConversationSetting = [[NSUserDefaults standardUserDefaults]
        objectForKey:VoiceConversationEnabledDefaultsKey];
    self.voiceConversationEnabled = storedVoiceConversationSetting == nil
        ? YES
        : [storedVoiceConversationSetting boolValue];
    [self configureStatusMenu];
    controller_log(@"READY", @"REAI Music Controller 已启动");
    self.catalogPlaylistCache = [NSMutableDictionary dictionary];
    self.activeExperienceMode = REAIExperienceModeMusic;
    self.selectedExperienceMode = REAIExperienceModeMusic;
    self.selectorReturnMode = REAIExperienceModeMusic;
    self.modeOverlay = [[REAIModeOverlayController alloc] init];
    self.bluetoothConnectionDetail = @"正在初始化蓝牙";
    __weak REAIAppDelegate *weakSelf = self;
    self.voiceCompanion = [[REAIVoiceCompanionController alloc]
        initWithLogHandler:^(NSString *level, NSString *message) {
            controller_log(level, message);
        }
        statusHandler:^(NSString *status) {
            [weakSelf setStatus:status];
        }];
    self.bluetoothBridge = [[REAIBluetoothBridge alloc]
        initWithConsumerHandler:^(uint16_t value) {
            [weakSelf handleBluetoothConsumerValue:value];
        }
        modeHandler:^(uint8_t mode) {
            BOOL triggerPlaylist = !weakSelf.bluetoothInitialModePending;
            weakSelf.bluetoothInitialModePending = NO;
            [weakSelf applyQueriedWorkMode:mode triggerPlaylist:triggerPlaylist];
        }
        connectionHandler:^(BOOL connected, NSString *detail) {
            weakSelf.bluetoothConnected = connected;
            weakSelf.bluetoothConnectionDetail = detail;
            if (connected) {
                weakSelf.bluetoothInitialModePending = YES;
            }
            if (!connected && weakSelf.bluetoothVoiceKeyHeld) {
                weakSelf.bluetoothVoiceKeyHeld = NO;
                weakSelf.bluetoothNonVoicePulseWhileVoiceHeld = NO;
                [weakSelf handleVoiceKeyReleased];
            }
            if (!connected) weakSelf.bluetoothInitialModePending = NO;
            [weakSelf refreshSettingsOverlay];
            [weakSelf setStatus:detail];
        }
        logHandler:^(NSString *level, NSString *message) {
            controller_log(level, message);
        }];
    [self.bluetoothBridge start];
    if (self.desktopPetEnabled) {
        [self.voiceCompanion show];
    } else {
        [self.voiceCompanion hide];
    }
    [self.modeOverlay setDesktopPetEnabled:self.desktopPetEnabled];
    [self.modeOverlay setVoiceConversationEnabled:self.voiceConversationEnabled];
    [[NSDistributedNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(simulatedSettingNotification:)
               name:@"com.shougongchuan.reai.simulate-setting"
             object:nil];
    [[NSDistributedNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(simulatedKeyNotification:)
               name:@"com.shougongchuan.reai.simulate-key"
             object:nil];
    [[NSDistributedNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(simulatedTranscriptNotification:)
               name:@"com.shougongchuan.reai.simulate-transcript"
             object:nil];
    [[NSDistributedNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(simulatedRealtimeAudioNotification:)
               name:@"com.shougongchuan.reai.simulate-realtime-audio"
             object:nil];
    [[NSDistributedNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(showConversationNotification:)
               name:@"com.shougongchuan.reai.show-conversation"
             object:nil];
    [self requestMusicAutomationAccess];
    [self ensureInputMonitoringAccess];
    [NSTimer scheduledTimerWithTimeInterval:1.0
                                     target:self
                                   selector:@selector(permissionTimerFired:)
                                   userInfo:nil
                                    repeats:YES];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    self.stopping = YES;
    [self.bluetoothBridge stop];
    [self.voiceCompanion cancelVoiceInteraction];
    [[NSDistributedNotificationCenter defaultCenter] removeObserver:self];
    controller_log(@"STOPPED", @"REAI Music Controller 已退出");
}

- (void)simulatedKeyNotification:(NSNotification *)notification {
    NSNumber *value = notification.userInfo[@"value"];
    if ([value isKindOfClass:NSNumber.class]) {
        uint16_t rawValue = (uint16_t)value.unsignedShortValue;
        if (rawValue == 0) {
            [self handleVoiceKeyReleased];
        } else if (rawValue == REAI_MODE_YOLO) {
            [self setWorkMode:@"YOLO" triggerPlaylist:YES];
        } else if (rawValue == REAI_MODE_CHAT) {
            [self setWorkMode:@"CHAT" triggerPlaylist:YES];
        } else if (rawValue == REAI_MODE_PLAN) {
            [self setWorkMode:@"PLAN" triggerPlaylist:YES];
        } else {
            [self handleConsumerValue:rawValue];
        }
    }
}

- (void)simulatedSettingNotification:(NSNotification *)notification {
    NSString *setting = notification.userInfo[@"setting"];
    NSNumber *enabled = notification.userInfo[@"enabled"];
    if (![setting isKindOfClass:NSString.class] || ![enabled isKindOfClass:NSNumber.class]) return;
    if ([setting isEqualToString:@"desktop-pet"]) {
        [self applyDesktopPetEnabled:enabled.boolValue];
    } else if ([setting isEqualToString:@"voice-conversation"]) {
        [self applyVoiceConversationEnabled:enabled.boolValue];
    }
}

- (void)simulatedTranscriptNotification:(NSNotification *)notification {
    if (!self.voiceConversationEnabled) {
        controller_log(@"VOICE_DISABLED", @"语音对话已关闭，忽略测试转录");
        return;
    }
    NSString *transcript = notification.userInfo[@"text"];
    NSNumber *speak = notification.userInfo[@"speak"];
    if ([transcript isKindOfClass:NSString.class]) {
        [self.voiceCompanion acceptTranscriptForTesting:transcript speak:speak.boolValue];
    }
}

- (void)simulatedRealtimeAudioNotification:(NSNotification *)notification {
    if (!self.voiceConversationEnabled) {
        controller_log(@"VOICE_DISABLED", @"语音对话已关闭，忽略测试音频");
        return;
    }
    NSString *path = notification.userInfo[@"path"];
    if (![path isKindOfClass:NSString.class]) return;
    NSData *audio = [NSData dataWithContentsOfFile:path];
    if (audio.length == 0 || audio.length % 2 != 0) {
        controller_log(@"REALTIME_TEST", @"测试 PCM 文件无效");
        return;
    }
    [self.voiceCompanion acceptRealtimePCMForTesting:audio];
}

- (void)showConversationNotification:(NSNotification *)notification {
    (void)notification;
    [self.voiceCompanion showConversation];
}

- (void)configureStatusMenu {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"REAI";
    self.statusItem.button.toolTip = @"REAI Vibe Board · Apple Music";

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"REAI Music Controller"];
    self.statusMenuItem = [[NSMenuItem alloc] initWithTitle:@"正在初始化…"
                                                     action:nil
                                              keyEquivalent:@""];
    self.statusMenuItem.enabled = NO;
    [menu addItem:self.statusMenuItem];
    self.modeMenuItem = [[NSMenuItem alloc] initWithTitle:@"模式：待检测"
                                                   action:nil
                                            keyEquivalent:@""];
    self.modeMenuItem.enabled = NO;
    [menu addItem:self.modeMenuItem];
    self.experienceMenuItem = [[NSMenuItem alloc] initWithTitle:@"工作模式：音乐"
                                                         action:nil
                                                  keyEquivalent:@""];
    self.experienceMenuItem.enabled = NO;
    [menu addItem:self.experienceMenuItem];
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItemWithTitle:@"打开日志" action:@selector(openLog:) keyEquivalent:@""];
    self.companionMenuItem = [menu addItemWithTitle:
        (self.desktopPetEnabled ? @"桌宠桌面显示：开启" : @"桌宠桌面显示：关闭")
                                               action:@selector(toggleCompanion:)
                                        keyEquivalent:@""];
    self.voiceConversationMenuItem = [menu addItemWithTitle:
        (self.voiceConversationEnabled ? @"语音对话：开启" : @"语音对话：关闭")
                                               action:@selector(toggleVoiceConversation:)
                                        keyEquivalent:@""];
    [menu addItemWithTitle:@"查看对话记录" action:@selector(showCompanionConversation:) keyEquivalent:@""];
    [menu addItemWithTitle:@"打开桌宠记忆" action:@selector(openCompanionMemory:) keyEquivalent:@""];
    [menu addItemWithTitle:@"配置豆包实时语音…" action:@selector(configureCompanionTTS:) keyEquivalent:@""];
    [menu addItemWithTitle:@"退出" action:@selector(quit:) keyEquivalent:@"q"];
    self.statusItem.menu = menu;
}

- (void)setStatus:(NSString *)status {
    self.statusMenuItem.title = status;
    self.statusItem.button.toolTip = [NSString stringWithFormat:@"REAI Vibe Board · %@", status];
}

- (NSString *)bluetoothSettingsStatus {
    if (self.boardUSBConnected) return @"USB 已连接 · 蓝牙待机";
    return self.bluetoothConnectionDetail.length > 0
        ? self.bluetoothConnectionDetail
        : (self.bluetoothConnected ? @"蓝牙已连接" : @"蓝牙未连接");
}

- (void)showSettingsOverlay {
    self.settingsForgetConfirmation = NO;
    [self.modeOverlay setSettingsForgetConfirmation:NO];
    [self.modeOverlay showSettingsWithDesktopPetEnabled:self.desktopPetEnabled
                             voiceConversationEnabled:self.voiceConversationEnabled
                            bluetoothAutoConnectEnabled:self.bluetoothBridge.autoConnectEnabled
                                       connectionStatus:[self bluetoothSettingsStatus]
                                             deviceName:self.bluetoothBridge.rememberedDeviceName];
}

- (void)refreshSettingsOverlay {
    if (!self.modeOverlay.showingSettings) return;
    [self.modeOverlay updateSettingsWithDesktopPetEnabled:self.desktopPetEnabled
                               voiceConversationEnabled:self.voiceConversationEnabled
                              bluetoothAutoConnectEnabled:self.bluetoothBridge.autoConnectEnabled
                                         connectionStatus:[self bluetoothSettingsStatus]
                                               deviceName:self.bluetoothBridge.rememberedDeviceName];
}

- (NSString *)selectedSettingsRowName {
    switch (self.modeOverlay.selectedSettingsRow) {
        case REAISettingsRowBluetoothAutoConnect: return @"蓝牙自动连接";
        case REAISettingsRowBluetoothReconnect: return @"重新扫描 / 连接";
        case REAISettingsRowBluetoothForget: return @"忘记蓝牙设备";
        case REAISettingsRowDesktopPet: return @"桌宠桌面显示";
        case REAISettingsRowVoiceConversation: return @"语音对话";
    }
    return @"设置";
}

- (void)activateSelectedSetting {
    switch (self.modeOverlay.selectedSettingsRow) {
        case REAISettingsRowBluetoothAutoConnect: {
            BOOL enabled = !self.bluetoothBridge.autoConnectEnabled;
            [self.bluetoothBridge setAutoConnectEnabled:enabled];
            [self setStatus:enabled ? @"蓝牙自动连接已开启" : @"蓝牙自动连接已关闭"];
            [self refreshSettingsOverlay];
            break;
        }
        case REAISettingsRowBluetoothReconnect:
            self.settingsForgetConfirmation = NO;
            [self.modeOverlay setSettingsForgetConfirmation:NO];
            controller_log(@"SETTINGS", self.boardUSBConnected
                ? @"重新扫描 / 连接：USB 正在使用"
                : @"重新扫描 / 连接：开始扫描蓝牙");
            [self.bluetoothBridge reconnect];
            [self setStatus:self.boardUSBConnected
                ? @"USB 正在使用 · 拔线后可连接蓝牙"
                : @"正在重新扫描 REAI 蓝牙"];
            break;
        case REAISettingsRowBluetoothForget:
            if (!self.settingsForgetConfirmation) {
                self.settingsForgetConfirmation = YES;
                [self.modeOverlay setSettingsForgetConfirmation:YES];
                [self setStatus:@"再次按下以确认忘记蓝牙设备"];
                controller_log(@"SETTINGS", @"忘记设备：等待二次确认");
            } else {
                self.settingsForgetConfirmation = NO;
                [self.modeOverlay setSettingsForgetConfirmation:NO];
                self.bluetoothConnected = NO;
                [self.bluetoothBridge forgetDevice];
                [self refreshSettingsOverlay];
            }
            break;
        case REAISettingsRowDesktopPet:
            self.settingsForgetConfirmation = NO;
            [self.modeOverlay setSettingsForgetConfirmation:NO];
            [self applyDesktopPetEnabled:!self.desktopPetEnabled];
            break;
        case REAISettingsRowVoiceConversation:
            self.settingsForgetConfirmation = NO;
            [self.modeOverlay setSettingsForgetConfirmation:NO];
            [self applyVoiceConversationEnabled:!self.voiceConversationEnabled];
            break;
    }
}

- (void)updateUSBConnectionState:(BOOL)connected {
    if (self.boardUSBConnected == connected) return;
    self.boardUSBConnected = connected;
    [self refreshSettingsOverlay];
}

- (void)setWorkMode:(NSString *)mode triggerPlaylist:(BOOL)triggerPlaylist {
    BOOL modeChanged = ![self.currentMode isEqualToString:mode];
    self.currentMode = mode;
    self.modeMenuItem.title = [NSString stringWithFormat:@"模式：%@", mode];
    self.statusItem.button.title = [NSString stringWithFormat:@"REAI·%@", mode];
    [mode writeToFile:controller_mode_path()
           atomically:YES
             encoding:NSUTF8StringEncoding
                error:nil];
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:@"com.shougongchuan.reai.mode-change"
                      object:nil
                    userInfo:@{@"mode": mode}
          deliverImmediately:YES];
    controller_log(@"MODE", [NSString stringWithFormat:@"推杆 → %@", mode]);
    if (self.modeOverlay.showingSettings) {
        [self setStatus:[NSString stringWithFormat:@"设置 · %@", [self selectedSettingsRowName]]];
    } else if (self.activeExperienceMode == REAIExperienceModeGame) {
        CGFloat multiplier = 1.0;
        NSString *speed = @"NORMAL";
        NSString *speedChinese = @"标准";
        if ([mode isEqualToString:@"YOLO"]) {
            multiplier = 1.45;
            speed = @"FAST";
            speedChinese = @"快速";
        } else if ([mode isEqualToString:@"PLAN"]) {
            multiplier = 0.70;
            speed = @"SLOW";
            speedChinese = @"慢速";
        }
        [self.modeOverlay setGameSpeedMultiplier:multiplier label:speed];
        NSString *status = [NSString stringWithFormat:@"游戏速度 · %@", speedChinese];
        [self setStatus:status];
        controller_log(@"ACTION", [NSString stringWithFormat:@"游戏 · 推杆调速 → %@ (%.2fx)",
                                    speed, multiplier]);
    } else if (triggerPlaylist && modeChanged) {
        [self playPlaylistForMode:mode];
    }
}

- (void)showOrCycleModeSelector {
    if (self.modeOverlay.showingSelector) {
        self.selectedExperienceMode = (REAIExperienceMode)((self.selectedExperienceMode + 1) % 3);
    } else if (self.modeOverlay.showingSettings) {
        self.selectorReturnMode = REAIExperienceModeSettings;
        self.selectedExperienceMode = REAIExperienceModeSettings;
    } else if (self.modeOverlay.showingGame) {
        self.selectorReturnMode = REAIExperienceModeGame;
        self.selectedExperienceMode = REAIExperienceModeGame;
    } else {
        self.selectorReturnMode = REAIExperienceModeMusic;
        self.selectedExperienceMode = self.activeExperienceMode;
    }
    [self.modeOverlay showSelectorWithMode:self.selectedExperienceMode];
    NSString *name = experience_mode_name(self.selectedExperienceMode);
    [self setStatus:[NSString stringWithFormat:@"待进入：%@模式", name]];
    controller_log(@"UI", [NSString stringWithFormat:@"模式选择器 → %@", name]);
}

- (void)navigateBack {
    if (self.modeOverlay.showingSettings) {
        if (self.settingsForgetConfirmation) {
            self.settingsForgetConfirmation = NO;
            [self.modeOverlay setSettingsForgetConfirmation:NO];
            [self setStatus:@"已取消忘记设备"];
            return;
        }
        self.selectedExperienceMode = REAIExperienceModeSettings;
        [self.modeOverlay showSelectorWithMode:self.selectedExperienceMode];
        [self setStatus:@"待进入：设置模式"];
        controller_log(@"UI", @"回退：设置 → App 选择器");
        return;
    }
    if (self.modeOverlay.showingGame) {
        self.selectedExperienceMode = REAIExperienceModeGame;
        [self.modeOverlay showSelectorWithMode:self.selectedExperienceMode];
        [self setStatus:@"待进入：游戏模式"];
        controller_log(@"UI", @"回退：游戏 → App 选择器");
        return;
    }
    if (!self.modeOverlay.showingSelector) {
        controller_log(@"UI", @"回退：已在音乐主层");
        return;
    }

    if (self.selectorReturnMode == REAIExperienceModeSettings) {
        self.experienceMenuItem.title = @"工作模式：设置";
        [self showSettingsOverlay];
        [self setStatus:[NSString stringWithFormat:@"设置 · %@", [self selectedSettingsRowName]]];
        controller_log(@"UI", @"回退：App 选择器 → 设置");
    } else if (self.selectorReturnMode == REAIExperienceModeGame) {
        self.experienceMenuItem.title = @"工作模式：游戏 · 打砖块";
        [self.modeOverlay showGame];
        [self setWorkMode:self.currentMode ?: @"CHAT" triggerPlaylist:NO];
        controller_log(@"UI", @"回退：App 选择器 → 游戏");
    } else {
        self.activeExperienceMode = REAIExperienceModeMusic;
        self.selectedExperienceMode = REAIExperienceModeMusic;
        self.experienceMenuItem.title = @"工作模式：音乐";
        [self.modeOverlay hide];
        [self setStatus:@"音乐模式"];
        controller_log(@"UI", @"回退：App 选择器 → 音乐");
    }
}

- (void)enterSelectedExperienceMode {
    if (self.modeOverlay.showingSettings) {
        [self activateSelectedSetting];
        return;
    }
    if (!self.modeOverlay.showingSelector) return;
    if (self.selectedExperienceMode == REAIExperienceModeSettings) {
        self.experienceMenuItem.title = @"工作模式：设置";
        [self showSettingsOverlay];
        [self setStatus:[NSString stringWithFormat:@"设置 · %@", [self selectedSettingsRowName]]];
        controller_log(@"UI", @"已进入设置");
        return;
    }
    self.activeExperienceMode = self.selectedExperienceMode;
    if (self.activeExperienceMode == REAIExperienceModeMusic) {
        self.experienceMenuItem.title = @"工作模式：音乐";
        [self.modeOverlay hide];
        [self setStatus:@"音乐模式"];
        controller_log(@"UI", @"已进入音乐模式");
        return;
    }

    self.experienceMenuItem.title = @"工作模式：游戏 · 打砖块";
    [self setWorkMode:self.currentMode ?: @"CHAT" triggerPlaylist:NO];
    [self.modeOverlay showGame];
    controller_log(@"UI", @"已进入游戏模式 · 打砖块");
}

- (void)applyQueriedWorkMode:(int)mode triggerPlaylist:(BOOL)triggerPlaylist {
    switch (mode) {
        case 0:
            [self setWorkMode:@"CHAT" triggerPlaylist:triggerPlaylist];
            break;
        case 1:
            [self setWorkMode:@"YOLO" triggerPlaylist:triggerPlaylist];
            break;
        case 2:
            [self setWorkMode:@"PLAN" triggerPlaylist:triggerPlaylist];
            break;
        default:
            controller_log(@"ERROR", @"无法读取推杆当前模式");
            break;
    }
}

- (void)openLog:(id)sender {
    (void)sender;
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:controller_log_path()]];
}

- (void)toggleCompanion:(id)sender {
    (void)sender;
    [self applyDesktopPetEnabled:!self.desktopPetEnabled];
}

- (void)applyDesktopPetEnabled:(BOOL)enabled {
    self.desktopPetEnabled = enabled;
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:DesktopPetEnabledDefaultsKey];
    if (enabled) {
        [self.voiceCompanion show];
    } else {
        [self.voiceCompanion hide];
    }
    if (self.modeOverlay.showingSettings) {
        [self refreshSettingsOverlay];
    } else {
        [self.modeOverlay setDesktopPetEnabled:enabled];
    }
    self.companionMenuItem.title = enabled
        ? @"桌宠桌面显示：开启" : @"桌宠桌面显示：关闭";
    NSString *status = enabled ? @"桌宠桌面显示已开启" : @"桌宠桌面显示已关闭";
    [self setStatus:status];
    controller_log(@"SETTINGS", status);
}

- (void)toggleVoiceConversation:(id)sender {
    (void)sender;
    [self applyVoiceConversationEnabled:!self.voiceConversationEnabled];
}

- (void)applyVoiceConversationEnabled:(BOOL)enabled {
    self.voiceConversationEnabled = enabled;
    [[NSUserDefaults standardUserDefaults] setBool:enabled
                                            forKey:VoiceConversationEnabledDefaultsKey];
    if (!enabled) [self.voiceCompanion cancelVoiceInteraction];
    if (self.modeOverlay.showingSettings) {
        [self refreshSettingsOverlay];
    } else {
        [self.modeOverlay setVoiceConversationEnabled:enabled];
    }
    self.voiceConversationMenuItem.title = enabled ? @"语音对话：开启" : @"语音对话：关闭";
    NSString *status = enabled ? @"语音对话已开启" : @"语音对话已关闭";
    [self setStatus:status];
    controller_log(@"SETTINGS", status);
}

- (void)handleVoiceKeyReleased {
    if (!self.voiceConversationEnabled) return;
    [self.voiceCompanion voiceKeyReleased];
}

- (void)openCompanionMemory:(id)sender {
    (void)sender;
    if (![[NSFileManager defaultManager] fileExistsAtPath:self.voiceCompanion.memoryPath]) {
        [NSData.data writeToFile:self.voiceCompanion.memoryPath atomically:YES];
    }
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:self.voiceCompanion.memoryPath]];
}

- (void)showCompanionConversation:(id)sender {
    (void)sender;
    [self.voiceCompanion showConversation];
}

- (void)configureCompanionTTS:(id)sender {
    (void)sender;
    [self.voiceCompanion configureVolcengineTTS];
}

- (void)quit:(id)sender {
    (void)sender;
    [NSApp terminate:nil];
}

- (void)permissionTimerFired:(NSTimer *)timer {
    (void)timer;
    [self ensureInputMonitoringAccess];
}

- (void)ensureInputMonitoringAccess {
    if (self.listenerStarted || self.stopping) return;

    IOHIDAccessType access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent);
    if (access == kIOHIDAccessTypeUnknown) {
        controller_log(@"PERMISSION", @"正在请求“输入监控”权限");
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent);
        [self setStatus:@"等待输入监控权限"];
        return;
    }
    if (access == kIOHIDAccessTypeDenied) {
        if (!self.permissionDenialLogged) {
            controller_log(@"PERMISSION", @"“输入监控”权限未开启；请在系统设置中允许此 App");
            self.permissionDenialLogged = YES;
        }
        [self setStatus:@"输入监控权限未开启"];
        return;
    }

    self.listenerStarted = YES;
    self.permissionDenialLogged = NO;
    [self setStatus:@"正在连接键盘"];
    controller_log(@"PERMISSION", @"已获得“输入监控”权限");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self listenForBoardEvents];
    });
}

- (void)requestMusicAutomationAccess {
    NSString *source = @"tell application \"Music\" to get player state as text";
    NSAppleScript *script = [[NSAppleScript alloc] initWithSource:source];
    NSDictionary *error = nil;
    NSAppleEventDescriptor *result = [script executeAndReturnError:&error];
    if (result == nil) {
        controller_log(@"MUSIC", [NSString stringWithFormat:@"Apple Music 自动化权限检查失败: %@", error]);
    } else {
        controller_log(@"MUSIC", [NSString stringWithFormat:@"Apple Music 已授权，当前状态: %@", result.stringValue ?: @"unknown"]);
    }
}

- (NSString *)playlistScript:(NSString *)playlistName playlistClass:(NSString *)playlistClass {
    NSString *escapedName = [playlistName stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    escapedName = [escapedName stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    NSString *appleScriptName = [NSString stringWithFormat:@"\"%@\"", escapedName];
    return [NSString stringWithFormat:
            @"tell application \"Music\"\n"
             "if not (exists %@ %@) then error \"找不到歌单: \" & %@\n"
             "set expectedTrackName to name of track 1 of %@ %@ as text\n"
             "stop\n"
             "delay 0.3\n"
             "play %@ %@\n"
             "repeat with attempt from 1 to 24\n"
             "delay 0.25\n"
             "try\n"
             "if player state is playing and (name of current track as text) is expectedTrackName then return (player state as text) & \"|\" & expectedTrackName\n"
             "end try\n"
             "end repeat\n"
             "error \"歌单启动超时: \" & %@\n"
             "end tell",
            playlistClass,
            appleScriptName,
            appleScriptName,
            playlistClass,
            appleScriptName,
            playlistClass,
            appleScriptName,
            appleScriptName];
}

- (NSData *)httpDataForURL:(NSURL *)url
                   headers:(NSDictionary<NSString *, NSString *> *)headers
                     error:(NSError **)error {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:15.0];
    [headers enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
        (void)stop;
        [request setValue:value forHTTPHeaderField:key];
    }];

    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSData *responseData = nil;
    __block NSError *responseError = nil;
    __block NSInteger statusCode = 0;
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
                                           completionHandler:^(NSData *data,
                                                               NSURLResponse *response,
                                                               NSError *taskError) {
        responseData = data;
        responseError = taskError;
        if ([response isKindOfClass:NSHTTPURLResponse.class]) {
            statusCode = ((NSHTTPURLResponse *)response).statusCode;
        }
        dispatch_semaphore_signal(semaphore);
    }];
    [task resume];
    long waitResult = dispatch_semaphore_wait(semaphore,
                                               dispatch_time(DISPATCH_TIME_NOW,
                                                             (int64_t)(16.0 * NSEC_PER_SEC)));
    [session finishTasksAndInvalidate];
    if (waitResult != 0) {
        [task cancel];
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"REAIAppleMusicCatalog"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Apple Music 请求超时"}];
        }
        return nil;
    }
    if (responseError != nil) {
        if (error != NULL) *error = responseError;
        return nil;
    }
    if (statusCode < 200 || statusCode >= 300) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"REAIAppleMusicCatalog"
                                         code:statusCode
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    [NSString stringWithFormat:@"Apple Music HTTP %ld",
                                                                               (long)statusCode]}];
        }
        return nil;
    }
    return responseData;
}

- (NSString *)appleMusicDeveloperToken:(NSError **)error {
    if (self.catalogDeveloperToken.length > 0) return self.catalogDeveloperToken;

    NSDictionary *webHeaders = @{ @"User-Agent": @"Mozilla/5.0" };
    NSData *homeData = [self httpDataForURL:[NSURL URLWithString:@"https://music.apple.com/"]
                                    headers:webHeaders
                                      error:error];
    if (homeData == nil) return nil;
    NSString *homeHTML = [[NSString alloc] initWithData:homeData encoding:NSUTF8StringEncoding];
    NSRegularExpression *assetRegex =
        [NSRegularExpression regularExpressionWithPattern:@"/assets/index~[A-Za-z0-9]+\\.js"
                                                  options:0
                                                    error:error];
    NSTextCheckingResult *assetMatch =
        [assetRegex firstMatchInString:homeHTML options:0 range:NSMakeRange(0, homeHTML.length)];
    if (assetMatch == nil) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"REAIAppleMusicCatalog"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"找不到 Apple Music Web 资源"}];
        }
        return nil;
    }

    NSString *assetPath = [homeHTML substringWithRange:assetMatch.range];
    NSURL *assetURL = [NSURL URLWithString:[@"https://music.apple.com" stringByAppendingString:assetPath]];
    NSData *assetData = [self httpDataForURL:assetURL headers:webHeaders error:error];
    if (assetData == nil) return nil;
    NSString *javascript = [[NSString alloc] initWithData:assetData encoding:NSUTF8StringEncoding];
    NSRegularExpression *tokenRegex =
        [NSRegularExpression regularExpressionWithPattern:@"\\$c=\"([^\"]+)\""
                                                  options:0
                                                    error:error];
    NSTextCheckingResult *tokenMatch =
        [tokenRegex firstMatchInString:javascript options:0 range:NSMakeRange(0, javascript.length)];
    if (tokenMatch == nil || tokenMatch.numberOfRanges < 2) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"REAIAppleMusicCatalog"
                                         code:3
                                     userInfo:@{NSLocalizedDescriptionKey: @"找不到 Apple Music 目录令牌"}];
        }
        return nil;
    }
    self.catalogDeveloperToken = [javascript substringWithRange:[tokenMatch rangeAtIndex:1]];
    return self.catalogDeveloperToken;
}

- (NSDictionary *)catalogPlaylist:(NSString *)playlistID error:(NSError **)error {
    NSDictionary *cached = self.catalogPlaylistCache[playlistID];
    if (cached != nil) return cached;

    NSString *token = [self appleMusicDeveloperToken:error];
    if (token == nil) return nil;
    NSString *urlString = [NSString stringWithFormat:
        @"https://api.music.apple.com/v1/catalog/%@/playlists/%@?include=tracks&limit%%5Btracks%%5D=100",
        AppleMusicStorefront, playlistID];
    NSDictionary *headers = @{
        @"Authorization": [@"Bearer " stringByAppendingString:token],
        @"Origin": @"https://music.apple.com",
        @"User-Agent": @"Mozilla/5.0"
    };
    NSData *data = [self httpDataForURL:[NSURL URLWithString:urlString] headers:headers error:error];
    if (data == nil) return nil;

    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    NSDictionary *playlist = [json[@"data"] firstObject];
    NSArray *tracks = playlist[@"relationships"][@"tracks"][@"data"];
    if (![tracks isKindOfClass:NSArray.class] || tracks.count == 0) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"REAIAppleMusicCatalog"
                                         code:4
                                     userInfo:@{NSLocalizedDescriptionKey: @"Apple Music 歌单没有可播放曲目"}];
        }
        return nil;
    }

    NSMutableArray<NSString *> *storeIDs = [NSMutableArray arrayWithCapacity:tracks.count];
    NSMutableArray<NSString *> *trackNames = [NSMutableArray arrayWithCapacity:tracks.count];
    for (NSDictionary *track in tracks) {
        NSString *storeID = track[@"id"];
        NSString *trackName = track[@"attributes"][@"name"];
        if ([storeID isKindOfClass:NSString.class] && storeID.length > 0) {
            [storeIDs addObject:storeID];
            if ([trackName isKindOfClass:NSString.class] && trackName.length > 0) {
                [trackNames addObject:trackName];
            }
        }
    }
    if (storeIDs.count == 0) return nil;
    NSString *playlistName = playlist[@"attributes"][@"name"] ?: playlistID;
    NSDictionary *result = @{
        @"name": playlistName,
        @"storeIDs": storeIDs,
        @"trackNames": trackNames
    };
    self.catalogPlaylistCache[playlistID] = result;
    return result;
}

- (BOOL)playCatalogPlaylistID:(NSString *)playlistID successMessage:(NSString *)successMessage {
    NSError *error = nil;
    NSDictionary *playlist = [self catalogPlaylist:playlistID error:&error];
    NSArray<NSString *> *storeIDs = playlist[@"storeIDs"];
    if (storeIDs.count == 0) {
        controller_log(@"ERROR", [NSString stringWithFormat:@"%@ 目录读取失败: %@",
                                   successMessage, error.localizedDescription ?: @"unknown"]);
        [self setStatus:@"Apple Music 目录读取失败"];
        return NO;
    }

    NSAppleScript *stopScript = [[NSAppleScript alloc]
        initWithSource:@"tell application \"Music\" to stop"];
    [stopScript executeAndReturnError:nil];
    MRSystemAppPlaybackQueueRef queue = MRSystemAppPlaybackQueueCreate(kCFAllocatorDefault, 3);
    if (queue == NULL) {
        controller_log(@"ERROR", [successMessage stringByAppendingString:@" 队列创建失败"]);
        [self setStatus:@"Apple Music 队列创建失败"];
        return NO;
    }
    MRSystemAppPlaybackQueueSetTracklistStoreIDs(queue, (__bridge CFArrayRef)storeIDs);
    MRSystemAppPlaybackQueueSetFirstItemGenericTrackIdentifier(
        queue, (__bridge CFStringRef)storeIDs.firstObject);
    MRSystemAppPlaybackQueueSetIsRequestingImmediatePlayback(queue, true);
    MRSystemAppPlaybackQueueSetReplaceIntent(queue, 1);
    MRMediaRemoteSetSystemAppPlaybackQueue(queue, nil, nil);

    NSSet<NSString *> *expectedNames = [NSSet setWithArray:playlist[@"trackNames"] ?: @[]];
    NSString *actualTrack = nil;
    BOOL started = NO;
    for (int attempt = 0; attempt < 40; attempt++) {
        usleep(250000);
        NSAppleScript *stateScript = [[NSAppleScript alloc] initWithSource:
            @"tell application \"Music\"\n"
             "try\n"
             "return (player state as text) & \"|\" & (name of current track as text)\n"
             "on error\n"
             "return (player state as text) & \"|\"\n"
             "end try\n"
             "end tell"];
        NSAppleEventDescriptor *state = [stateScript executeAndReturnError:nil];
        NSArray<NSString *> *parts = [state.stringValue componentsSeparatedByString:@"|"];
        if (parts.count >= 2 && [parts.firstObject isEqualToString:@"playing"]) {
            actualTrack = parts[1];
            if (expectedNames.count == 0 || [expectedNames containsObject:actualTrack]) {
                started = YES;
                break;
            }
        }
    }
    MRSystemAppPlaybackQueueDestroy(queue);
    if (!started) {
        controller_log(@"ERROR", [NSString stringWithFormat:@"%@ 启动超时；当前曲目=%@",
                                   successMessage, actualTrack ?: @"none"]);
        [self setStatus:@"Apple Music 歌单启动超时"];
        return NO;
    }
    controller_log(@"ACTION", [NSString stringWithFormat:@"%@；Music=playing|%@",
                                successMessage, actualTrack]);
    [self setStatus:successMessage];
    return YES;
}

- (BOOL)playRadioStationID:(NSString *)stationID successMessage:(NSString *)successMessage {
    NSAppleScript *stopScript = [[NSAppleScript alloc]
        initWithSource:@"tell application \"Music\" to stop"];
    [stopScript executeAndReturnError:nil];

    MRSystemAppPlaybackQueueRef queue = MRSystemAppPlaybackQueueCreate(kCFAllocatorDefault, 2);
    if (queue == NULL) {
        controller_log(@"ERROR", [successMessage stringByAppendingString:@" 电台队列创建失败"]);
        [self setStatus:@"Apple Music 电台队列创建失败"];
        return NO;
    }
    MRSystemAppPlaybackQueueSetRadioStationIDType(queue, 2);
    MRSystemAppPlaybackQueueSetRadioStationStringIdentifier(
        queue, (__bridge CFStringRef)stationID);
    MRSystemAppPlaybackQueueSetIsRequestingImmediatePlayback(queue, true);
    MRSystemAppPlaybackQueueSetReplaceIntent(queue, 1);
    MRMediaRemoteSetSystemAppPlaybackQueue(queue, nil, nil);

    NSString *actualTrack = nil;
    BOOL started = NO;
    for (int attempt = 0; attempt < 60; attempt++) {
        usleep(250000);
        NSAppleScript *stateScript = [[NSAppleScript alloc] initWithSource:
            @"tell application \"Music\"\n"
             "try\n"
             "return (player state as text) & \"|\" & (name of current track as text)\n"
             "on error\n"
             "return (player state as text) & \"|\"\n"
             "end try\n"
             "end tell"];
        NSAppleEventDescriptor *state = [stateScript executeAndReturnError:nil];
        NSArray<NSString *> *parts = [state.stringValue componentsSeparatedByString:@"|"];
        if (parts.count >= 2 && [parts.firstObject isEqualToString:@"playing"] &&
            [parts[1] length] > 0) {
            actualTrack = parts[1];
            started = YES;
            break;
        }
    }
    MRSystemAppPlaybackQueueDestroy(queue);
    if (!started) {
        controller_log(@"ERROR", [NSString stringWithFormat:@"%@ 启动超时", successMessage]);
        [self setStatus:@"Apple Music 电台启动超时"];
        return NO;
    }
    controller_log(@"ACTION", [NSString stringWithFormat:@"%@；Music=playing|%@",
                                successMessage, actualTrack]);
    [self setStatus:successMessage];
    return YES;
}

- (BOOL)runMusicScript:(NSString *)source successMessage:(NSString *)successMessage {
    NSAppleScript *script = [[NSAppleScript alloc] initWithSource:source];
    NSDictionary *error = nil;
    NSAppleEventDescriptor *result = [script executeAndReturnError:&error];
    if (result == nil) {
        NSString *message = [NSString stringWithFormat:@"%@ 失败: %@", successMessage, error];
        controller_log(@"ERROR", message);
        [self setStatus:@"Apple Music 控制失败"];
        return NO;
    }
    controller_log(@"ACTION", [NSString stringWithFormat:@"%@；Music=%@", successMessage,
                                result.stringValue ?: @"ok"]);
    [self setStatus:successMessage];
    return YES;
}

- (void)playPlaylistForMode:(NSString *)mode {
    if ([mode isEqualToString:@"YOLO"]) {
        [self playRadioStationID:YoloRadioStationID
                  successMessage:@"YOLO · high · Relax Radio Station"];
    } else if ([mode isEqualToString:@"CHAT"]) {
        [self playRadioStationID:ChatRadioStationID
                  successMessage:@"CHAT · middle · Focus Radio Station"];
    } else if ([mode isEqualToString:@"PLAN"]) {
        [self playCatalogPlaylistID:PlanCatalogPlaylistID
                     successMessage:@"PLAN · low · Classical Sleep"];
    }
}

- (void)handleConsumerValue:(uint16_t)value {
    switch (value) {
        case REAI_KNOB_COUNTERCLOCKWISE:
        case REAI_VOLUME_DOWN:
            if (self.modeOverlay.showingSettings) {
                self.settingsForgetConfirmation = NO;
                [self.modeOverlay moveSettingsSelectionBy:-1];
                [self setStatus:[NSString stringWithFormat:@"设置 · %@", [self selectedSettingsRowName]]];
                controller_log(@"UI", [NSString stringWithFormat:@"设置选中 → %@", [self selectedSettingsRowName]]);
            } else if (self.activeExperienceMode == REAIExperienceModeGame) {
                [self.modeOverlay moveGamePaddleBy:-38.0];
                [self setStatus:@"游戏 · 挡板向左"];
                controller_log(@"ACTION", @"游戏 · 旋钮左转");
            } else if (value == REAI_KNOB_COUNTERCLOCKWISE) {
                Float32 volume = 0;
                if (change_output_volume(-0.04f, &volume)) {
                    NSString *status = [NSString stringWithFormat:@"系统音量 %.0f%%", volume * 100.0f];
                    [self setStatus:status];
                    controller_log(@"ACTION", status);
                }
            }
            break;
        case REAI_KNOB_CLOCKWISE:
        case REAI_VOLUME_UP:
            if (self.modeOverlay.showingSettings) {
                self.settingsForgetConfirmation = NO;
                [self.modeOverlay moveSettingsSelectionBy:1];
                [self setStatus:[NSString stringWithFormat:@"设置 · %@", [self selectedSettingsRowName]]];
                controller_log(@"UI", [NSString stringWithFormat:@"设置选中 → %@", [self selectedSettingsRowName]]);
            } else if (self.activeExperienceMode == REAIExperienceModeGame) {
                [self.modeOverlay moveGamePaddleBy:38.0];
                [self setStatus:@"游戏 · 挡板向右"];
                controller_log(@"ACTION", @"游戏 · 旋钮右转");
            } else if (value == REAI_KNOB_CLOCKWISE) {
                Float32 volume = 0;
                if (change_output_volume(0.04f, &volume)) {
                    NSString *status = [NSString stringWithFormat:@"系统音量 %.0f%%", volume * 100.0f];
                    [self setStatus:status];
                    controller_log(@"ACTION", status);
                }
            }
            break;
        case REAI_KNOB_PRESS:
        case REAI_VOLUME_MUTE:
            if (self.modeOverlay.showingSettings) {
                [self activateSelectedSetting];
            } else if (self.activeExperienceMode == REAIExperienceModeGame) {
                [self.modeOverlay toggleGameAction];
                [self setStatus:@"游戏 · 发球/暂停"];
                controller_log(@"ACTION", @"游戏 · 旋钮按下 · 发球/暂停");
            } else if (value == REAI_KNOB_PRESS) {
                bool muted = false;
                if (toggle_output_mute(&muted)) {
                    NSString *status = muted ? @"系统已静音" : @"系统已取消静音";
                    [self setStatus:status];
                    controller_log(@"ACTION", status);
                }
            }
            break;
        case REAI_KEY_VOICE:
        case REAI_KEY_VOICE_MARK:
            if (self.voiceConversationEnabled) {
                [self.voiceCompanion voiceKeyPressed];
                [self setStatus:@"语音对话正在听"];
            } else {
                [self setStatus:@"语音对话已关闭"];
                controller_log(@"VOICE_DISABLED", @"语音键已忽略");
            }
            break;
        case REAI_KEY_TAB:
            [self showOrCycleModeSelector];
            break;
        case REAI_KEY_NEW:
        case REAI_KEY_ENTER:
            [self enterSelectedExperienceMode];
            break;
        case REAI_KEY_ESCAPE:
            [self navigateBack];
            break;
        case REAI_KEY_ACTION:
            if (self.modeOverlay.showingSettings) {
                [self activateSelectedSetting];
            } else if (self.activeExperienceMode == REAIExperienceModeGame) {
                [self.modeOverlay toggleGameAction];
                [self setStatus:@"游戏 · 发球/暂停"];
                controller_log(@"ACTION", @"游戏 · 发球/暂停");
            } else {
                [self runMusicScript:@"tell application \"Music\" to playpause\nreturn \"toggled\""
                      successMessage:@"播放/暂停"];
            }
            break;
        default:
            break;
    }
}

- (void)handleBluetoothConsumerValue:(uint16_t)value {
    BOOL isVoiceValue = value == REAI_KEY_VOICE || value == REAI_KEY_VOICE_MARK;
    if (isVoiceValue) {
        self.bluetoothVoiceKeyHeld = YES;
        self.bluetoothNonVoicePulseWhileVoiceHeld = NO;
    } else if (value != 0 && self.bluetoothVoiceKeyHeld) {
        self.bluetoothNonVoicePulseWhileVoiceHeld = YES;
    } else if (value == 0 && self.bluetoothVoiceKeyHeld) {
        if (self.bluetoothNonVoicePulseWhileVoiceHeld) {
            self.bluetoothNonVoicePulseWhileVoiceHeld = NO;
        } else {
            self.bluetoothVoiceKeyHeld = NO;
            controller_log(@"KEY", @"AI 语音键释放（BLE）");
            [self handleVoiceKeyReleased];
        }
    }

    if (value == REAI_MODE_YOLO || value == REAI_MODE_PLAN || value == REAI_MODE_CHAT) {
        self.bluetoothActiveModeEndpoint = value == REAI_MODE_CHAT ? 0 : value;
        NSString *mode = value == REAI_MODE_YOLO ? @"YOLO" :
                         value == REAI_MODE_PLAN ? @"PLAN" : @"CHAT";
        [self setWorkMode:mode triggerPlaylist:YES];
        self.bluetoothPreviousValue = value;
        return;
    }
    if (value == 0 && self.bluetoothActiveModeEndpoint != 0) {
        [self.bluetoothBridge queryWorkMode];
    }
    if (value != 0 && value != self.bluetoothPreviousValue) {
        controller_log(@"KEY", [NSString stringWithFormat:@"Consumer value=0x%04X（BLE）", value]);
        [self handleConsumerValue:value];
    }
    self.bluetoothPreviousValue = value;
}

- (void)listenForBoardEvents {
    if (hid_init() != 0) {
        controller_log(@"ERROR", @"hidapi 初始化失败");
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setStatus:@"HID 初始化失败"];
        });
        return;
    }
    hid_darwin_set_open_exclusive(0);
    while (!self.stopping) {
        hid_device *device = open_consumer_interface();
        if (device == NULL) {
            [self.bluetoothBridge setUSBConnected:NO];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self updateUSBConnectionState:NO];
                if (self.bluetoothBridge == nil) {
                    [self setStatus:@"等待 REAI Vibe Board"];
                }
            });
            sleep(1);
            continue;
        }

        [self.bluetoothBridge setUSBConnected:YES];
        controller_log(@"CONNECTED", @"已连接 REAI Vibe Board Consumer 接口");
        int initialMode = query_work_mode();
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateUSBConnectionState:YES];
            [self setStatus:@"已连接，按键可用"];
            [self applyQueriedWorkMode:initialMode triggerPlaylist:NO];
        });

        unsigned char report[64];
        uint16_t previousValue = 0;
        BOOL voiceKeyHeld = NO;
        BOOL nonVoicePulseWhileVoiceHeld = NO;
        uint16_t activeModeEndpoint = initialMode == 1 ? REAI_MODE_YOLO :
                                      initialMode == 2 ? REAI_MODE_PLAN : 0;
        while (!self.stopping) {
            int length = hid_read_timeout(device, report, sizeof(report), 250);
            if (length < 0) {
                controller_log(@"DISCONNECTED", @"键盘连接中断，准备重连");
                break;
            }
            if (length == 0) continue;

            uint16_t value = decode_consumer_value(report, length);
            BOOL isVoiceValue = value == REAI_KEY_VOICE || value == REAI_KEY_VOICE_MARK;
            if (isVoiceValue) {
                voiceKeyHeld = YES;
                nonVoicePulseWhileVoiceHeld = NO;
            } else if (value != 0 && voiceKeyHeld) {
                nonVoicePulseWhileVoiceHeld = YES;
            } else if (value == 0 && voiceKeyHeld) {
                if (nonVoicePulseWhileVoiceHeld) {
                    nonVoicePulseWhileVoiceHeld = NO;
                } else {
                    voiceKeyHeld = NO;
                    controller_log(@"KEY", @"AI 语音键释放");
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self handleVoiceKeyReleased];
                    });
                }
            }
            if (value == REAI_MODE_YOLO || value == REAI_MODE_PLAN || value == REAI_MODE_CHAT) {
                activeModeEndpoint = value == REAI_MODE_CHAT ? 0 : value;
                NSString *mode = value == REAI_MODE_YOLO ? @"YOLO" :
                                 value == REAI_MODE_PLAN ? @"PLAN" : @"CHAT";
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self setWorkMode:mode triggerPlaylist:YES];
                });
                previousValue = value;
                continue;
            }
            if (value == 0 && activeModeEndpoint != 0) {
                int currentMode = query_work_mode();
                activeModeEndpoint = currentMode == 1 ? REAI_MODE_YOLO :
                                     currentMode == 2 ? REAI_MODE_PLAN : 0;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self applyQueriedWorkMode:currentMode triggerPlaylist:YES];
                });
            }
            if (value != 0 && value != previousValue) {
                controller_log(@"KEY", [NSString stringWithFormat:@"Consumer value=0x%04X", value]);
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self handleConsumerValue:value];
                });
            }
            previousValue = value;
        }
        if (voiceKeyHeld) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self handleVoiceKeyReleased];
            });
        }
        hid_close(device);
        [self.bluetoothBridge setUSBConnected:NO];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateUSBConnectionState:NO];
        });
        if (!self.stopping) sleep(1);
    }
    hid_exit();
}

@end

static int run_protocol_test(void) {
    const unsigned char tab[] = {0x0C, 0x01, 0x0F};
    const unsigned char newKey[] = {0x0C, 0x02, 0x0F};
    const unsigned char escape[] = {0x0C, 0x03, 0x0F};
    const unsigned char voice[] = {0x0C, 0x04, 0x0F};
    const unsigned char voiceMark[] = {0x0C, 0x99, 0x0F};
    const unsigned char action[] = {0x0C, 0x05, 0x0F};
    const unsigned char enter[] = {0x0C, 0x06, 0x0F};
    const unsigned char knobLeft[] = {0x0C, 0x07, 0x0F};
    const unsigned char knobRight[] = {0x0C, 0x08, 0x0F};
    const unsigned char knobPress[] = {0x0C, 0x09, 0x0F};
    const unsigned char yolo[] = {0x0C, 0x0A, 0x0F};
    const unsigned char plan[] = {0x0C, 0x0B, 0x0F};
    const unsigned char chat[] = {0x0C, 0x0C, 0x0F};
    const unsigned char release[] = {0x0C, 0x00, 0x00};
    bool passed =
        decode_consumer_value(tab, sizeof(tab)) == REAI_KEY_TAB &&
        decode_consumer_value(newKey, sizeof(newKey)) == REAI_KEY_NEW &&
        decode_consumer_value(escape, sizeof(escape)) == REAI_KEY_ESCAPE &&
        decode_consumer_value(voice, sizeof(voice)) == REAI_KEY_VOICE &&
        decode_consumer_value(voiceMark, sizeof(voiceMark)) == REAI_KEY_VOICE_MARK &&
        decode_consumer_value(action, sizeof(action)) == REAI_KEY_ACTION &&
        decode_consumer_value(enter, sizeof(enter)) == REAI_KEY_ENTER &&
        decode_consumer_value(knobLeft, sizeof(knobLeft)) == REAI_KNOB_COUNTERCLOCKWISE &&
        decode_consumer_value(knobRight, sizeof(knobRight)) == REAI_KNOB_CLOCKWISE &&
        decode_consumer_value(knobPress, sizeof(knobPress)) == REAI_KNOB_PRESS &&
        decode_consumer_value(yolo, sizeof(yolo)) == REAI_MODE_YOLO &&
        decode_consumer_value(plan, sizeof(plan)) == REAI_MODE_PLAN &&
        decode_consumer_value(chat, sizeof(chat)) == REAI_MODE_CHAT &&
        decode_consumer_value(release, sizeof(release)) == 0;
    printf("music-controller protocol-test: %s\n", passed ? "passed" : "failed");
    return passed ? 0 : 1;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--tts-parser-test") == 0) {
            BOOL passed = REAIVoiceCompanionRunTTSSelfTest();
            printf("music-controller tts-parser-test: %s\n", passed ? "passed" : "failed");
            return passed ? 0 : 1;
        }
        if (argc == 2 && strcmp(argv[1], "--realtime-transcript-test") == 0) {
            BOOL passed = REAIVoiceCompanionRunRealtimeTranscriptSelfTest();
            printf("music-controller realtime-transcript-test: %s\n",
                   passed ? "passed" : "failed");
            return passed ? 0 : 1;
        }
        if (argc == 2 && strcmp(argv[1], "--protocol-test") == 0) {
            return run_protocol_test();
        }
        if (argc == 2 && strcmp(argv[1], "--ble-protocol-test") == 0) {
            BOOL passed = REAIBluetoothRunProtocolSelfTest();
            printf("music-controller ble-protocol-test: %s\n", passed ? "passed" : "failed");
            return passed ? 0 : 1;
        }
        if (argc == 3 && strcmp(argv[1], "--render-settings-preview") == 0) {
            [NSApplication sharedApplication];
            NSString *path = [[NSString stringWithUTF8String:argv[2]] stringByStandardizingPath];
            BOOL passed = REAIRenderSettingsPreview(path);
            printf("music-controller settings-preview: %s\n", passed ? path.UTF8String : "failed");
            return passed ? 0 : 1;
        }
        if (argc == 3 && strcmp(argv[1], "--simulate-key") == 0) {
            char *end = NULL;
            unsigned long rawValue = strtoul(argv[2], &end, 0);
            if (end == argv[2] || *end != '\0' || rawValue > UINT16_MAX) {
                fprintf(stderr, "用法: %s --simulate-key 0x0F01\n", argv[0]);
                return 2;
            }
            REAIAppDelegate *delegate = [[REAIAppDelegate alloc] init];
            if (rawValue == REAI_MODE_YOLO) {
                [delegate setWorkMode:@"YOLO" triggerPlaylist:YES];
            } else if (rawValue == REAI_MODE_CHAT) {
                [delegate setWorkMode:@"CHAT" triggerPlaylist:YES];
            } else if (rawValue == REAI_MODE_PLAN) {
                [delegate setWorkMode:@"PLAN" triggerPlaylist:YES];
            } else {
                [delegate handleConsumerValue:(uint16_t)rawValue];
            }
            return 0;
        }
        if (argc == 3 && strcmp(argv[1], "--notify-key") == 0) {
            char *end = NULL;
            unsigned long rawValue = strtoul(argv[2], &end, 0);
            if (end == argv[2] || *end != '\0' || rawValue > UINT16_MAX) {
                fprintf(stderr, "用法: %s --notify-key 0x0F01\n", argv[0]);
                return 2;
            }
            [[NSDistributedNotificationCenter defaultCenter]
                postNotificationName:@"com.shougongchuan.reai.simulate-key"
                              object:nil
                            userInfo:@{@"value": @((uint16_t)rawValue)}
                  deliverImmediately:YES];
            return 0;
        }
        if (argc == 4 && strcmp(argv[1], "--notify-setting") == 0) {
            NSString *setting = [NSString stringWithUTF8String:argv[2]];
            BOOL validSetting = [setting isEqualToString:@"desktop-pet"] ||
                                [setting isEqualToString:@"voice-conversation"];
            BOOL enabled = strcmp(argv[3], "on") == 0 ||
                           strcmp(argv[3], "true") == 0 ||
                           strcmp(argv[3], "1") == 0;
            BOOL validValue = enabled || strcmp(argv[3], "off") == 0 ||
                              strcmp(argv[3], "false") == 0 ||
                              strcmp(argv[3], "0") == 0;
            if (!validSetting || !validValue) {
                fprintf(stderr,
                        "用法: %s --notify-setting desktop-pet|voice-conversation on|off\n",
                        argv[0]);
                return 2;
            }
            [[NSDistributedNotificationCenter defaultCenter]
                postNotificationName:@"com.shougongchuan.reai.simulate-setting"
                              object:nil
                            userInfo:@{@"setting": setting, @"enabled": @(enabled)}
                  deliverImmediately:YES];
            return 0;
        }
        if ((argc == 3 || argc == 4) && strcmp(argv[1], "--notify-transcript") == 0) {
            BOOL speak = argc == 4 && strcmp(argv[3], "--speak") == 0;
            [[NSDistributedNotificationCenter defaultCenter]
                postNotificationName:@"com.shougongchuan.reai.simulate-transcript"
                              object:nil
                            userInfo:@{@"text": [NSString stringWithUTF8String:argv[2]],
                                       @"speak": @(speak)}
                  deliverImmediately:YES];
            return 0;
        }
        if (argc == 3 && strcmp(argv[1], "--notify-realtime-audio") == 0) {
            NSString *path = [[NSString stringWithUTF8String:argv[2]] stringByStandardizingPath];
            [[NSDistributedNotificationCenter defaultCenter]
                postNotificationName:@"com.shougongchuan.reai.simulate-realtime-audio"
                              object:nil
                            userInfo:@{@"path": path}
                  deliverImmediately:YES];
            return 0;
        }
        if (argc == 2 && strcmp(argv[1], "--notify-conversation") == 0) {
            [[NSDistributedNotificationCenter defaultCenter]
                postNotificationName:@"com.shougongchuan.reai.show-conversation"
                              object:nil
                            userInfo:nil
                  deliverImmediately:YES];
            return 0;
        }
        NSApplication *application = [NSApplication sharedApplication];
        REAIAppDelegate *delegate = [[REAIAppDelegate alloc] init];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
