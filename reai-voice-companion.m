#import "reai-voice-companion.h"

#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudio.h>
#import <QuartzCore/QuartzCore.h>
#import <SceneKit/SceneKit.h>
#import <Security/Security.h>
#import <Speech/Speech.h>

#include <stdlib.h>
#include <string.h>

static NSString *const REAITTSKeychainService =
    @"com.shougongchuan.reai-music-controller.volcengine-tts";
static NSString *const REAITTSKeychainAccount = @"api-key";
static NSString *const REAITTSDefaultResourceID = @"seed-tts-2.0";
static NSString *const REAITTSDefaultSpeaker = @"zh_female_vv_uranus_bigtts";
static NSString *const REAIRealtimeEndpoint =
    @"wss://openspeech.bytedance.com/api/v3/duplex/realtime/dialogue";
static NSString *const REAIRealtimeModel = @"1.2.6.1";
static NSString *const REAIRealtimeSpeaker = @"zh_female_vv_jupiter_bigtts";

static NSString *reai_trimmed_environment_value(NSString *name) {
    NSString *value = NSProcessInfo.processInfo.environment[name];
    return [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString *reai_tts_api_key(void) {
    NSString *environmentKey = reai_trimmed_environment_value(@"MODEL_SPEECH_API_KEY");
    if (environmentKey.length == 0) {
        environmentKey = reai_trimmed_environment_value(@"REAI_VOLCENGINE_TTS_API_KEY");
    }
    if (environmentKey.length > 0) return environmentKey;

    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: REAITTSKeychainService,
        (__bridge id)kSecAttrAccount: REAITTSKeychainAccount,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
    };
    CFTypeRef result = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) != errSecSuccess ||
        result == NULL) {
        if (result != NULL) CFRelease(result);
        return nil;
    }
    NSData *data = CFBridgingRelease(result);
    NSString *key = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return [key stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static BOOL reai_store_tts_api_key(NSString *apiKey) {
    NSData *data = [apiKey dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length == 0) return NO;
    NSDictionary *identity = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: REAITTSKeychainService,
        (__bridge id)kSecAttrAccount: REAITTSKeychainAccount,
    };
    NSDictionary *attributes = @{
        (__bridge id)kSecValueData: data,
        (__bridge id)kSecAttrLabel: @"REAI 桌宠 · 火山大模型 TTS",
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    };
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)identity,
                                    (__bridge CFDictionaryRef)attributes);
    if (status == errSecItemNotFound) {
        NSMutableDictionary *item = [identity mutableCopy];
        [item addEntriesFromDictionary:attributes];
        status = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
    }
    return status == errSecSuccess;
}

static NSData *reai_tts_audio_from_sse(NSData *responseData, NSString **apiError) {
    NSString *response = [[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding];
    if (response.length == 0) {
        if (apiError != NULL) *apiError = @"服务未返回可解析的数据";
        return nil;
    }
    NSMutableData *audio = [NSMutableData data];
    NSArray<NSString *> *lines = [response componentsSeparatedByCharactersInSet:
                                  NSCharacterSet.newlineCharacterSet];
    for (NSString *rawLine in lines) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:
                          NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if ([line hasPrefix:@"data:"]) {
            line = [[line substringFromIndex:5] stringByTrimmingCharactersInSet:
                    NSCharacterSet.whitespaceAndNewlineCharacterSet];
        } else if (![line hasPrefix:@"{"]) {
            continue;
        }
        NSData *jsonData = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *event = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil];
        if (![event isKindOfClass:NSDictionary.class]) continue;
        NSInteger code = [event[@"code"] integerValue];
        if (code != 0 && code != 20000000) {
            if (apiError != NULL) {
                NSString *message = [event[@"message"] isKindOfClass:NSString.class]
                    ? event[@"message"] : @"未知错误";
                *apiError = [NSString stringWithFormat:@"火山返回 %ld：%@", (long)code, message];
            }
            return nil;
        }
        NSString *base64 = [event[@"data"] isKindOfClass:NSString.class] ? event[@"data"] : nil;
        if (base64.length > 0) {
            NSData *chunk = [[NSData alloc] initWithBase64EncodedString:base64
                                                               options:NSDataBase64DecodingIgnoreUnknownCharacters];
            if (chunk.length > 0) [audio appendData:chunk];
        }
    }
    if (audio.length == 0 && apiError != NULL) *apiError = @"火山未返回音频片段";
    return audio.length > 0 ? audio : nil;
}

BOOL REAIVoiceCompanionRunTTSSelfTest(void) {
    NSString *fixture = @"event: message\ndata: {\"code\":0,\"data\":\"UkVBSQ==\"}\n\n"
                         "data: {\"code\":20000000,\"message\":\"OK\"}\n\n";
    NSString *apiError = nil;
    NSData *audio = reai_tts_audio_from_sse([fixture dataUsingEncoding:NSUTF8StringEncoding],
                                             &apiError);
    NSString *decoded = [[NSString alloc] initWithData:audio encoding:NSUTF8StringEncoding];
    return apiError == nil && [decoded isEqualToString:@"REAI"];
}

static NSString *reai_apply_realtime_transcript_snapshot(NSString *current,
                                                          NSString *snapshot) {
    return snapshot.length > 0 ? snapshot : (current ?: @"");
}

BOOL REAIVoiceCompanionRunRealtimeTranscriptSelfTest(void) {
    NSArray<NSString *> *snapshots = @[@"你", @"你好", @"你好川", @"你好川仔"];
    NSString *transcript = @"";
    for (NSString *snapshot in snapshots) {
        transcript = reai_apply_realtime_transcript_snapshot(transcript, snapshot);
    }
    return [transcript isEqualToString:@"你好川仔"] &&
           ![transcript isEqualToString:@"你你好你好川你好川仔"];
}

static NSString *reai_companion_support_directory(void) {
    NSString *directory = [NSHomeDirectory() stringByAppendingPathComponent:
                           @"Library/Application Support/REAI Music Controller"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return directory;
}

static NSColor *reai_companion_color(CGFloat red, CGFloat green, CGFloat blue, CGFloat alpha) {
    return [NSColor colorWithSRGBRed:red green:green blue:blue alpha:alpha];
}

static AudioDeviceID reai_default_input_device(void) {
    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    OSStatus status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &address,
                                                  0, NULL, &size, &device);
    return status == noErr ? device : kAudioObjectUnknown;
}

static AudioDevicePropertyID reai_audio_device_transport(AudioDeviceID device) {
    AudioDevicePropertyID transport = 0;
    UInt32 size = sizeof(transport);
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyTransportType,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &transport);
    return transport;
}

static BOOL reai_audio_device_has_input(AudioDeviceID device) {
    UInt32 size = 0;
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyStreams,
        kAudioDevicePropertyScopeInput,
        kAudioObjectPropertyElementMain,
    };
    OSStatus status = AudioObjectGetPropertyDataSize(device, &address, 0, NULL, &size);
    return status == noErr && size >= sizeof(AudioStreamID);
}

static NSString *reai_audio_device_name(AudioDeviceID device) {
    CFStringRef value = NULL;
    UInt32 size = sizeof(value);
    AudioObjectPropertyAddress address = {
        kAudioObjectPropertyName,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    OSStatus status = AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &value);
    if (status != noErr || value == NULL) return @"未知输入设备";
    return CFBridgingRelease(value);
}

static NSString *reai_audio_device_uid(AudioDeviceID device) {
    CFStringRef value = NULL;
    UInt32 size = sizeof(value);
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyDeviceUID,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    OSStatus status = AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &value);
    if (status != noErr || value == NULL) return nil;
    return CFBridgingRelease(value);
}

static AudioDeviceID reai_preferred_input_device(NSString **deviceName, BOOL *avoidedBluetooth) {
    AudioDeviceID defaultDevice = reai_default_input_device();
    AudioDevicePropertyID defaultTransport = defaultDevice != kAudioObjectUnknown
        ? reai_audio_device_transport(defaultDevice) : 0;
    BOOL defaultIsBluetooth = defaultTransport == kAudioDeviceTransportTypeBluetooth ||
                              defaultTransport == kAudioDeviceTransportTypeBluetoothLE;
    if (!defaultIsBluetooth && defaultDevice != kAudioObjectUnknown &&
        reai_audio_device_has_input(defaultDevice)) {
        if (deviceName != NULL) *deviceName = reai_audio_device_name(defaultDevice);
        if (avoidedBluetooth != NULL) *avoidedBluetooth = NO;
        return defaultDevice;
    }

    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address,
                                       0, NULL, &size) == noErr && size > 0) {
        AudioDeviceID *devices = malloc(size);
        if (devices != NULL && AudioObjectGetPropertyData(kAudioObjectSystemObject, &address,
                                                           0, NULL, &size, devices) == noErr) {
            NSUInteger count = size / sizeof(AudioDeviceID);
            for (NSUInteger index = 0; index < count; index += 1) {
                AudioDeviceID candidate = devices[index];
                if (reai_audio_device_has_input(candidate) &&
                    reai_audio_device_transport(candidate) == kAudioDeviceTransportTypeBuiltIn) {
                    if (deviceName != NULL) *deviceName = reai_audio_device_name(candidate);
                    if (avoidedBluetooth != NULL) *avoidedBluetooth = defaultIsBluetooth;
                    free(devices);
                    return candidate;
                }
            }
        }
        free(devices);
    }

    if (defaultIsBluetooth) {
        if (deviceName != NULL) *deviceName = @"未找到非蓝牙麦克风";
        if (avoidedBluetooth != NULL) *avoidedBluetooth = YES;
        return kAudioObjectUnknown;
    }
    if (deviceName != NULL) *deviceName = reai_audio_device_name(defaultDevice);
    if (avoidedBluetooth != NULL) *avoidedBluetooth = NO;
    return defaultDevice;
}

@interface REAICompanionPanel : NSPanel
@end

@implementation REAICompanionPanel
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

@interface REAIPetSceneView : SCNView
@property(nonatomic, copy) void (^petClickHandler)(void);
@property(nonatomic, assign) NSPoint mouseDownLocation;
@property(nonatomic, assign) NSPoint windowOrigin;
@property(nonatomic, assign) BOOL dragged;
@end

@implementation REAIPetSceneView

- (void)mouseDown:(NSEvent *)event {
    (void)event;
    self.mouseDownLocation = NSEvent.mouseLocation;
    self.windowOrigin = self.window.frame.origin;
    self.dragged = NO;
}

- (void)mouseDragged:(NSEvent *)event {
    (void)event;
    NSPoint current = NSEvent.mouseLocation;
    CGFloat deltaX = current.x - self.mouseDownLocation.x;
    CGFloat deltaY = current.y - self.mouseDownLocation.y;
    if (fabs(deltaX) > 3.0 || fabs(deltaY) > 3.0) self.dragged = YES;
    if (self.dragged) {
        [self.window setFrameOrigin:NSMakePoint(self.windowOrigin.x + deltaX,
                                                 self.windowOrigin.y + deltaY)];
    }
}

- (void)mouseUp:(NSEvent *)event {
    (void)event;
    if (!self.dragged && self.petClickHandler != nil) self.petClickHandler();
}

@end

@interface REAICompanionView : NSView
@property(nonatomic, strong) REAIPetSceneView *sceneView;
@property(nonatomic, strong) SCNNode *petNode;
@property(nonatomic, strong) SCNNode *lookNode;
@property(nonatomic, strong) SCNNode *turnNode;
@property(nonatomic, strong) SCNNode *headNode;
@property(nonatomic, strong) NSMutableArray<SCNNode *> *eyeNodes;
@property(nonatomic, strong) NSTrackingArea *trackingArea;
@property(nonatomic, strong) SCNMaterial *accentMaterial;
@end

@implementation REAICompanionView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self != nil) {
        self.wantsLayer = YES;
        self.layer.backgroundColor = NSColor.clearColor.CGColor;
        [self buildScene];
    }
    return self;
}

- (BOOL)isOpaque { return NO; }

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    self.window.acceptsMouseMovedEvents = YES;
}

- (void)updateTrackingAreas {
    if (self.trackingArea != nil) [self removeTrackingArea:self.trackingArea];
    self.trackingArea = [[NSTrackingArea alloc]
        initWithRect:NSZeroRect
            options:NSTrackingActiveAlways | NSTrackingInVisibleRect |
                    NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited
              owner:self
           userInfo:nil];
    [self addTrackingArea:self.trackingArea];
    [super updateTrackingAreas];
}

- (void)mouseMoved:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSPoint center = NSMakePoint(NSMidX(self.sceneView.frame), NSMidY(self.sceneView.frame));
    CGFloat x = fmax(-1.0, fmin(1.0, (point.x - center.x) / (NSWidth(self.sceneView.frame) * 0.5)));
    CGFloat y = fmax(-1.0, fmin(1.0, (point.y - center.y) / (NSHeight(self.sceneView.frame) * 0.5)));
    [SCNTransaction begin];
    SCNTransaction.animationDuration = 0.28;
    SCNTransaction.animationTimingFunction = [CAMediaTimingFunction
        functionWithName:kCAMediaTimingFunctionEaseOut];
    self.lookNode.eulerAngles = SCNVector3Make(y * 0.10, x * 0.22, -x * 0.035);
    [SCNTransaction commit];
}

- (void)mouseExited:(NSEvent *)event {
    (void)event;
    [SCNTransaction begin];
    SCNTransaction.animationDuration = 0.65;
    self.lookNode.eulerAngles = SCNVector3Make(0, 0, 0);
    [SCNTransaction commit];
}

- (void)buildScene {
    self.sceneView = [[REAIPetSceneView alloc] initWithFrame:self.bounds];
    self.sceneView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.sceneView.backgroundColor = NSColor.clearColor;
    self.sceneView.scene = [SCNScene scene];
    self.sceneView.allowsCameraControl = NO;
    self.sceneView.antialiasingMode = SCNAntialiasingModeMultisampling4X;
    self.sceneView.preferredFramesPerSecond = 60;
    self.sceneView.rendersContinuously = YES;
    self.sceneView.playing = YES;
    [self addSubview:self.sceneView];

    SCNNode *camera = [SCNNode node];
    camera.camera = [SCNCamera camera];
    camera.camera.fieldOfView = 34;
    camera.position = SCNVector3Make(0.18, 0.3, 8.35);
    [self.sceneView.scene.rootNode addChildNode:camera];

    SCNNode *ambient = [SCNNode node];
    ambient.light = [SCNLight light];
    ambient.light.type = SCNLightTypeAmbient;
    ambient.light.color = reai_companion_color(0.38, 0.44, 0.58, 1.0);
    ambient.light.intensity = 520;
    [self.sceneView.scene.rootNode addChildNode:ambient];

    SCNNode *keyLight = [SCNNode node];
    keyLight.light = [SCNLight light];
    keyLight.light.type = SCNLightTypeOmni;
    keyLight.light.color = reai_companion_color(1.0, 0.66, 0.31, 1.0);
    keyLight.light.intensity = 820;
    keyLight.position = SCNVector3Make(-3.5, 4.5, 5.5);
    [self.sceneView.scene.rootNode addChildNode:keyLight];

    SCNNode *rimLight = [SCNNode node];
    rimLight.light = [SCNLight light];
    rimLight.light.type = SCNLightTypeOmni;
    rimLight.light.color = reai_companion_color(0.28, 0.72, 1.0, 1.0);
    rimLight.light.intensity = 680;
    rimLight.position = SCNVector3Make(3.8, 1.8, 2.0);
    [self.sceneView.scene.rootNode addChildNode:rimLight];

    SCNMaterial *clay = [SCNMaterial material];
    clay.diffuse.contents = reai_companion_color(0.11, 0.16, 0.25, 1.0);
    clay.roughness.contents = @0.42;
    clay.metalness.contents = @0.48;

    self.accentMaterial = [SCNMaterial material];
    self.accentMaterial.diffuse.contents = reai_companion_color(1.0, 0.52, 0.20, 1.0);
    self.accentMaterial.emission.contents = reai_companion_color(0.35, 0.07, 0.015, 1.0);
    self.accentMaterial.roughness.contents = @0.28;

    SCNMaterial *face = [SCNMaterial material];
    face.diffuse.contents = reai_companion_color(0.035, 0.050, 0.085, 1.0);
    face.roughness.contents = @0.23;
    face.metalness.contents = @0.62;

    SCNMaterial *eye = [SCNMaterial material];
    eye.diffuse.contents = reai_companion_color(0.42, 0.86, 1.0, 1.0);
    eye.emission.contents = reai_companion_color(0.06, 0.42, 0.78, 1.0);

    self.petNode = [SCNNode node];
    self.petNode.position = SCNVector3Make(0, -0.1, 0);
    [self.sceneView.scene.rootNode addChildNode:self.petNode];

    self.lookNode = [SCNNode node];
    [self.petNode addChildNode:self.lookNode];
    self.turnNode = [SCNNode node];
    [self.lookNode addChildNode:self.turnNode];
    self.eyeNodes = [NSMutableArray arrayWithCapacity:2];

    SCNCapsule *bodyGeometry = [SCNCapsule capsuleWithCapRadius:0.76 height:2.05];
    bodyGeometry.materials = @[clay];
    SCNNode *body = [SCNNode nodeWithGeometry:bodyGeometry];
    body.position = SCNVector3Make(0, -0.52, 0);
    [self.turnNode addChildNode:body];

    SCNSphere *bellyGeometry = [SCNSphere sphereWithRadius:0.46];
    bellyGeometry.segmentCount = 48;
    bellyGeometry.materials = @[self.accentMaterial];
    SCNNode *belly = [SCNNode nodeWithGeometry:bellyGeometry];
    belly.scale = SCNVector3Make(1.0, 1.22, 0.22);
    belly.position = SCNVector3Make(0, -0.47, 0.72);
    [self.turnNode addChildNode:belly];

    self.headNode = [SCNNode node];
    self.headNode.position = SCNVector3Make(0, 0.88, 0);
    [self.turnNode addChildNode:self.headNode];

    SCNSphere *headGeometry = [SCNSphere sphereWithRadius:0.92];
    headGeometry.segmentCount = 64;
    headGeometry.materials = @[clay];
    SCNNode *head = [SCNNode nodeWithGeometry:headGeometry];
    head.scale = SCNVector3Make(1.08, 0.92, 0.92);
    [self.headNode addChildNode:head];

    SCNSphere *visorGeometry = [SCNSphere sphereWithRadius:0.68];
    visorGeometry.segmentCount = 48;
    visorGeometry.materials = @[face];
    SCNNode *visor = [SCNNode nodeWithGeometry:visorGeometry];
    visor.scale = SCNVector3Make(1.08, 0.58, 0.16);
    visor.position = SCNVector3Make(0, 0.06, 0.79);
    [self.headNode addChildNode:visor];

    for (NSInteger side = -1; side <= 1; side += 2) {
        SCNCone *earGeometry = [SCNCone coneWithTopRadius:0.05 bottomRadius:0.39 height:0.72];
        earGeometry.radialSegmentCount = 32;
        earGeometry.materials = @[clay];
        SCNNode *ear = [SCNNode nodeWithGeometry:earGeometry];
        ear.position = SCNVector3Make(side * 0.61, 0.82, 0);
        ear.eulerAngles = SCNVector3Make(0, 0, side * -0.20);
        [self.headNode addChildNode:ear];

        SCNAction *earTwitch = [SCNAction sequence:@[
            [SCNAction waitForDuration:(side < 0 ? 2.1 : 3.0)],
            [SCNAction rotateByX:0 y:0 z:side * 0.16 duration:0.12],
            [SCNAction rotateByX:0 y:0 z:side * -0.16 duration:0.16],
            [SCNAction waitForDuration:2.4]
        ]];
        [ear runAction:[SCNAction repeatActionForever:earTwitch]
                forKey:@"ear-twitch"];

        SCNSphere *eyeGeometry = [SCNSphere sphereWithRadius:0.105];
        eyeGeometry.materials = @[eye];
        SCNNode *eyeNode = [SCNNode nodeWithGeometry:eyeGeometry];
        eyeNode.scale = SCNVector3Make(0.72, 1.25, 0.45);
        eyeNode.position = SCNVector3Make(side * 0.29, 0.11, 0.92);
        [self.headNode addChildNode:eyeNode];
        [self.eyeNodes addObject:eyeNode];

        SCNCapsule *armGeometry = [SCNCapsule capsuleWithCapRadius:0.16 height:0.85];
        armGeometry.materials = @[clay];
        SCNNode *arm = [SCNNode nodeWithGeometry:armGeometry];
        arm.position = SCNVector3Make(side * 0.78, -0.30, 0.05);
        arm.eulerAngles = SCNVector3Make(0, 0, side * -0.42);
        [self.turnNode addChildNode:arm];

        SCNAction *armSwing = [SCNAction sequence:@[
            [SCNAction rotateByX:0.10 y:0 z:side * 0.10 duration:0.75],
            [SCNAction rotateByX:-0.20 y:0 z:side * -0.20 duration:1.50],
            [SCNAction rotateByX:0.10 y:0 z:side * 0.10 duration:0.75]
        ]];
        armSwing.timingMode = SCNActionTimingModeEaseInEaseOut;
        [arm runAction:[SCNAction repeatActionForever:armSwing]
                forKey:@"arm-swing"];

        SCNSphere *footGeometry = [SCNSphere sphereWithRadius:0.28];
        footGeometry.materials = @[clay];
        SCNNode *foot = [SCNNode nodeWithGeometry:footGeometry];
        foot.scale = SCNVector3Make(1.25, 0.62, 1.35);
        foot.position = SCNVector3Make(side * 0.42, -1.44, 0.23);
        [self.turnNode addChildNode:foot];
    }

    SCNTorus *mouthGeometry = [SCNTorus torusWithRingRadius:0.11 pipeRadius:0.025];
    mouthGeometry.materials = @[self.accentMaterial];
    SCNNode *mouth = [SCNNode nodeWithGeometry:mouthGeometry];
    mouth.scale = SCNVector3Make(1.0, 0.45, 1.0);
    mouth.position = SCNVector3Make(0, -0.16, 0.96);
    [self.headNode addChildNode:mouth];

    SCNCapsule *tailGeometry = [SCNCapsule capsuleWithCapRadius:0.10 height:1.05];
    tailGeometry.materials = @[clay];
    SCNNode *tail = [SCNNode nodeWithGeometry:tailGeometry];
    tail.position = SCNVector3Make(0.72, -0.74, -0.42);
    tail.eulerAngles = SCNVector3Make(0.12, 0, -0.78);
    [self.turnNode addChildNode:tail];
    SCNSphere *tailLightGeometry = [SCNSphere sphereWithRadius:0.14];
    tailLightGeometry.materials = @[self.accentMaterial];
    SCNNode *tailLight = [SCNNode nodeWithGeometry:tailLightGeometry];
    tailLight.position = SCNVector3Make(1.08, -0.37, -0.35);
    [self.turnNode addChildNode:tailLight];
    SCNAction *tailSway = [SCNAction sequence:@[
        [SCNAction rotateByX:0 y:0.22 z:0.18 duration:0.85],
        [SCNAction rotateByX:0 y:-0.44 z:-0.36 duration:1.70],
        [SCNAction rotateByX:0 y:0.22 z:0.18 duration:0.85]
    ]];
    tailSway.timingMode = SCNActionTimingModeEaseInEaseOut;
    [tail runAction:[SCNAction repeatActionForever:tailSway] forKey:@"tail-sway"];

    SCNCylinder *shadowGeometry = [SCNCylinder cylinderWithRadius:1.02 height:0.018];
    shadowGeometry.radialSegmentCount = 64;
    SCNMaterial *shadowMaterial = [SCNMaterial material];
    shadowMaterial.diffuse.contents = reai_companion_color(0.02, 0.04, 0.08, 0.36);
    shadowMaterial.lightingModelName = SCNLightingModelConstant;
    shadowGeometry.materials = @[shadowMaterial];
    SCNNode *shadow = [SCNNode nodeWithGeometry:shadowGeometry];
    shadow.scale = SCNVector3Make(1.25, 1.0, 0.62);
    shadow.position = SCNVector3Make(0, -1.67, -0.12);
    [self.sceneView.scene.rootNode addChildNode:shadow];

    SCNAction *floatUp = [SCNAction moveByX:0 y:0.10 z:0 duration:1.65];
    floatUp.timingMode = SCNActionTimingModeEaseInEaseOut;
    SCNAction *floatDown = [floatUp reversedAction];
    [self.petNode runAction:[SCNAction repeatActionForever:
                             [SCNAction sequence:@[floatUp, floatDown]]]
                     forKey:@"idle-float"];

    NSMutableArray<SCNAction *> *turnSteps = [NSMutableArray arrayWithObject:
                                               [SCNAction waitForDuration:0.7]];
    for (NSInteger step = 0; step < 4; step += 1) {
        SCNAction *quarterTurn = [SCNAction rotateByX:0 y:(CGFloat)M_PI_2 z:0 duration:0.95];
        quarterTurn.timingMode = SCNActionTimingModeEaseInEaseOut;
        [turnSteps addObject:quarterTurn];
        [turnSteps addObject:[SCNAction waitForDuration:0.18]];
    }
    [turnSteps addObject:[SCNAction waitForDuration:4.0]];
    SCNAction *turnAround = [SCNAction sequence:turnSteps];
    [self.turnNode runAction:[SCNAction repeatActionForever:turnAround]
                      forKey:@"show-3d-turn"];

    SCNAction *headLook = [SCNAction sequence:@[
        [SCNAction rotateToX:0.055 y:-0.13 z:-0.035 duration:1.15
         shortestUnitArc:YES],
        [SCNAction rotateToX:-0.035 y:0.16 z:0.045 duration:1.45
         shortestUnitArc:YES],
        [SCNAction rotateToX:0 y:0 z:0 duration:0.90 shortestUnitArc:YES]
    ]];
    headLook.timingMode = SCNActionTimingModeEaseInEaseOut;
    [self.headNode runAction:[SCNAction repeatActionForever:headLook]
                      forKey:@"head-look"];

    for (SCNNode *eyeNode in self.eyeNodes) {
        SCNAction *blink = [SCNAction sequence:@[
            [SCNAction waitForDuration:2.6],
            [SCNAction runBlock:^(SCNNode *node) {
                node.scale = SCNVector3Make(0.72, 0.08, 0.45);
            }],
            [SCNAction waitForDuration:0.085],
            [SCNAction runBlock:^(SCNNode *node) {
                node.scale = SCNVector3Make(0.72, 1.25, 0.45);
            }],
            [SCNAction waitForDuration:1.8]
        ]];
        [eyeNode runAction:[SCNAction repeatActionForever:blink] forKey:@"blink"];
    }
}

- (void)setListening:(BOOL)listening {
    if (listening) {
        self.accentMaterial.emission.contents = reai_companion_color(1.0, 0.22, 0.025, 1.0);
        SCNAction *pulse = [SCNAction sequence:@[
            [SCNAction scaleTo:1.055 duration:0.30],
            [SCNAction scaleTo:1.0 duration:0.30]
        ]];
        [self.petNode runAction:[SCNAction repeatActionForever:pulse] forKey:@"listening-pulse"];
    } else {
        [self.petNode removeActionForKey:@"listening-pulse"];
        self.petNode.scale = SCNVector3Make(1, 1, 1);
        self.accentMaterial.emission.contents = reai_companion_color(0.35, 0.07, 0.015, 1.0);
    }
}

@end

@interface REAIConversationView : NSView
@property(nonatomic, strong) NSTextView *historyTextView;
@property(nonatomic, strong) NSTextField *transcriptLabel;
@property(nonatomic, strong) NSTextField *statusLabel;
- (void)renderHistoryEntries:(NSArray<NSDictionary *> *)entries;
@end

@implementation REAIConversationView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self != nil) {
        self.wantsLayer = YES;
        self.layer.backgroundColor = reai_companion_color(0.976, 0.973, 0.953, 1.0).CGColor;

        NSTextField *title = [NSTextField labelWithString:@"川仔的对话记忆"];
        title.frame = NSMakeRect(28, 498, 464, 34);
        title.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
        title.font = [NSFont fontWithName:@"IowanOldStyle-Bold" size:25] ?:
                     [NSFont boldSystemFontOfSize:25];
        title.textColor = reai_companion_color(0.094, 0.094, 0.094, 1.0);
        [self addSubview:title];

        NSTextField *subtitle = [NSTextField labelWithString:@"本地保存 · 按住 AI 语音键继续对话"];
        subtitle.frame = NSMakeRect(30, 476, 460, 18);
        subtitle.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
        subtitle.font = [NSFont fontWithName:@"AvenirNext-Medium" size:11] ?:
                        [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
        subtitle.textColor = reai_companion_color(0.46, 0.45, 0.42, 1.0);
        [self addSubview:subtitle];

        NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(24, 120, 472, 342)];
        scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        scrollView.drawsBackground = NO;
        scrollView.borderType = NSNoBorder;
        scrollView.hasVerticalScroller = YES;
        self.historyTextView = [[NSTextView alloc] initWithFrame:scrollView.bounds];
        self.historyTextView.editable = NO;
        self.historyTextView.selectable = YES;
        self.historyTextView.drawsBackground = NO;
        self.historyTextView.textContainerInset = NSMakeSize(7, 10);
        self.historyTextView.textContainer.widthTracksTextView = YES;
        scrollView.documentView = self.historyTextView;
        [self addSubview:scrollView];

        NSView *liveCard = [[NSView alloc] initWithFrame:NSMakeRect(24, 46, 472, 60)];
        liveCard.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
        liveCard.wantsLayer = YES;
        liveCard.layer.backgroundColor = reai_companion_color(0.941, 0.933, 0.902, 1.0).CGColor;
        liveCard.layer.cornerRadius = 15.0;
        self.transcriptLabel = [NSTextField wrappingLabelWithString:@"点击川仔查看记忆，或按住语音键和它说话。"];
        self.transcriptLabel.frame = NSMakeRect(16, 10, 440, 40);
        self.transcriptLabel.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        self.transcriptLabel.font = [NSFont fontWithName:@"AvenirNext-Medium" size:13] ?:
                                    [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
        self.transcriptLabel.textColor = reai_companion_color(0.094, 0.094, 0.094, 1.0);
        self.transcriptLabel.maximumNumberOfLines = 2;
        [liveCard addSubview:self.transcriptLabel];
        [self addSubview:liveCard];

        self.statusLabel = [NSTextField labelWithString:@"READY · 等待下一句话"];
        self.statusLabel.frame = NSMakeRect(30, 18, 460, 18);
        self.statusLabel.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
        self.statusLabel.font = [NSFont fontWithName:@"Menlo-Bold" size:9] ?:
                                [NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightBold];
        self.statusLabel.textColor = reai_companion_color(0.80, 0.47, 0.36, 1.0);
        [self addSubview:self.statusLabel];
    }
    return self;
}

- (void)renderHistoryEntries:(NSArray<NSDictionary *> *)entries {
    NSMutableAttributedString *history = [[NSMutableAttributedString alloc] init];
    NSFont *bodyFont = [NSFont fontWithName:@"AvenirNext-Regular" size:13] ?:
                       [NSFont systemFontOfSize:13];
    NSFont *roleFont = [NSFont fontWithName:@"AvenirNext-DemiBold" size:11] ?:
                       [NSFont boldSystemFontOfSize:11];
    NSMutableParagraphStyle *bodyStyle = [[NSMutableParagraphStyle alloc] init];
    bodyStyle.lineSpacing = 4.0;
    bodyStyle.paragraphSpacing = 14.0;

    if (entries.count == 0) {
        [history appendAttributedString:[[NSAttributedString alloc]
            initWithString:@"还没有对话记录。\n\n按住 REAI 的 AI 语音键，说出第一句话吧。"
              attributes:@{NSFontAttributeName: bodyFont,
                           NSForegroundColorAttributeName: reai_companion_color(0.46, 0.45, 0.42, 1.0),
                           NSParagraphStyleAttributeName: bodyStyle}]];
    } else {
        NSISO8601DateFormatter *parser = [[NSISO8601DateFormatter alloc] init];
        NSDateFormatter *clock = [[NSDateFormatter alloc] init];
        clock.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
        clock.dateFormat = @"MM月dd日 HH:mm";
        for (NSDictionary *entry in entries) {
            BOOL user = [entry[@"role"] isEqualToString:@"user"];
            NSString *role = user ? @"你" : @"川仔";
            NSDate *date = [parser dateFromString:entry[@"timestamp"] ?: @""];
            NSString *time = date != nil ? [clock stringFromDate:date] : @"";
            NSString *heading = time.length > 0
                ? [NSString stringWithFormat:@"%@   %@\n", role, time]
                : [NSString stringWithFormat:@"%@\n", role];
            NSColor *roleColor = user
                ? reai_companion_color(0.32, 0.35, 0.34, 1.0)
                : reai_companion_color(0.80, 0.47, 0.36, 1.0);
            [history appendAttributedString:[[NSAttributedString alloc]
                initWithString:heading
                  attributes:@{NSFontAttributeName: roleFont,
                               NSForegroundColorAttributeName: roleColor}]];
            NSString *text = [NSString stringWithFormat:@"%@\n\n", entry[@"text"] ?: @""];
            [history appendAttributedString:[[NSAttributedString alloc]
                initWithString:text
                  attributes:@{NSFontAttributeName: bodyFont,
                               NSForegroundColorAttributeName: reai_companion_color(0.094, 0.094, 0.094, 1.0),
                               NSParagraphStyleAttributeName: bodyStyle}]];
        }
    }
    [self.historyTextView.textStorage setAttributedString:history];
    [self.historyTextView scrollRangeToVisible:NSMakeRange(history.length, 0)];
}

@end

@interface REAIVoiceCompanionController () <NSURLSessionWebSocketDelegate,
                                            AVAudioPlayerDelegate,
                                            AVSpeechSynthesizerDelegate>
@property(nonatomic, strong) REAICompanionPanel *panel;
@property(nonatomic, strong) REAICompanionView *companionView;
@property(nonatomic, strong) NSPanel *conversationPanel;
@property(nonatomic, strong) REAIConversationView *conversationView;
@property(nonatomic, strong) NSPanel *transcriptPanel;
@property(nonatomic, strong) NSTextField *transcriptOverlayLabel;
@property(nonatomic, assign) NSUInteger transcriptOverlayGeneration;
@property(nonatomic, assign) AudioQueueRef inputQueue;
@property(nonatomic, strong) AVAudioFormat *inputFormat;
@property(nonatomic, strong) SFSpeechRecognizer *speechRecognizer;
@property(nonatomic, strong) SFSpeechAudioBufferRecognitionRequest *recognitionRequest;
@property(nonatomic, strong) SFSpeechRecognitionTask *recognitionTask;
@property(nonatomic, strong) AVSpeechSynthesizer *speechSynthesizer;
@property(nonatomic, strong) AVAudioPlayer *ttsPlayer;
@property(nonatomic, strong) NSURLSessionDataTask *ttsTask;
@property(nonatomic, assign) NSUInteger ttsGeneration;
@property(nonatomic, copy) REAIVoiceLogHandler logHandler;
@property(nonatomic, copy) REAIVoiceStatusHandler statusHandler;
@property(nonatomic, readwrite, getter=isRecording) BOOL recording;
@property(nonatomic, readwrite, getter=isVisible) BOOL visible;
@property(nonatomic, readwrite, copy) NSString *memoryPath;
@property(nonatomic, copy) NSString *partialTranscript;
@property(nonatomic, assign) NSUInteger recognitionGeneration;
@property(nonatomic, assign) BOOL awaitingFinalResult;
@property(nonatomic, assign) BOOL voiceKeyDown;
@property(nonatomic, strong) NSURLSession *realtimeURLSession;
@property(nonatomic, strong) NSURLSessionWebSocketTask *realtimeSocket;
@property(nonatomic, strong) NSMutableArray<NSData *> *realtimePendingAudio;
@property(nonatomic, copy) NSString *realtimeTranscript;
@property(nonatomic, copy) NSString *realtimeReply;
@property(nonatomic, assign) AudioQueueRef realtimeOutputQueue;
@property(nonatomic, assign) BOOL realtimeOutputStarted;
@property(nonatomic, assign) NSUInteger realtimeOutputBuffersInFlight;
@property(nonatomic, assign) BOOL realtimeOutputFinished;
@property(nonatomic, assign) BOOL realtimeActive;
@property(nonatomic, assign) BOOL realtimeSessionReady;
@property(nonatomic, assign) BOOL realtimeTranscriptStarted;
@property(nonatomic, assign) BOOL realtimeTurnReleased;
@property(nonatomic, assign) BOOL realtimeReplyDelivered;
@property(nonatomic, assign) BOOL realtimeClosing;
@property(nonatomic, assign) BOOL realtimeTestTurn;
@property(nonatomic, assign) NSUInteger realtimeGeneration;
- (void)showConversation;
- (void)toggleConversation;
- (void)showTranscriptOverlayWithText:(NSString *)text;
- (void)hideTranscriptOverlayAfterDelay:(NSTimeInterval)delay;
- (void)hideTranscriptOverlayImmediately;
- (void)reloadConversationHistory;
- (NSString *)systemFactReplyForTranscript:(NSString *)transcript;
- (void)handleInputQueue:(AudioQueueRef)queue buffer:(AudioQueueBufferRef)buffer;
- (void)speakReply:(NSString *)reply;
- (void)speakReplyWithSystemFallback:(NSString *)reply reason:(NSString *)reason;
- (void)startRealtimeTurn;
- (NSDictionary *)realtimeSessionCreateEvent;
- (void)sendRealtimeEvent:(NSDictionary *)event generation:(NSUInteger)generation;
- (void)receiveRealtimeMessageForGeneration:(NSUInteger)generation;
- (void)enqueueRealtimeAudioData:(NSData *)audioData;
- (void)commitRealtimeInput;
- (void)playRealtimePCMData:(NSData *)audioData generation:(NSUInteger)generation;
- (void)handleRealtimeOutputBufferFinishedForQueue:(AudioQueueRef)queue;
- (void)handleRealtimeEvent:(NSDictionary *)event generation:(NSUInteger)generation;
- (void)failRealtimeForGeneration:(NSUInteger)generation reason:(NSString *)reason;
- (void)stopRealtimeAudioImmediately;
- (void)sendRealtimeTestAudio:(NSData *)audioData
                       offset:(NSUInteger)offset
                   generation:(NSUInteger)generation;
@end

static void reai_input_queue_callback(void *userData,
                                      AudioQueueRef queue,
                                      AudioQueueBufferRef buffer,
                                      const AudioTimeStamp *startTime,
                                      UInt32 packetCount,
                                      const AudioStreamPacketDescription *packetDescriptions) {
    (void)startTime;
    (void)packetCount;
    (void)packetDescriptions;
    REAIVoiceCompanionController *controller = (__bridge REAIVoiceCompanionController *)userData;
    [controller handleInputQueue:queue buffer:buffer];
}

static void reai_output_queue_callback(void *userData,
                                       AudioQueueRef queue,
                                       AudioQueueBufferRef buffer) {
    AudioQueueFreeBuffer(queue, buffer);
    REAIVoiceCompanionController *controller =
        (__bridge REAIVoiceCompanionController *)userData;
    dispatch_async(dispatch_get_main_queue(), ^{
        [controller handleRealtimeOutputBufferFinishedForQueue:queue];
    });
}

@implementation REAIVoiceCompanionController

- (instancetype)initWithLogHandler:(REAIVoiceLogHandler)logHandler
                     statusHandler:(REAIVoiceStatusHandler)statusHandler {
    self = [super init];
    if (self != nil) {
        self.logHandler = logHandler;
        self.statusHandler = statusHandler;
        self.memoryPath = [reai_companion_support_directory()
            stringByAppendingPathComponent:@"companion-memory.jsonl"];
        self.speechRecognizer = [[SFSpeechRecognizer alloc]
            initWithLocale:[NSLocale localeWithLocaleIdentifier:@"zh_CN"]];
        self.speechSynthesizer = [[AVSpeechSynthesizer alloc] init];
        self.speechSynthesizer.delegate = self;
        [self buildPanel];
    }
    return self;
}

- (void)buildPanel {
    self.panel = [[REAICompanionPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, 220, 250)
                  styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                    backing:NSBackingStoreBuffered
                      defer:NO];
    self.panel.backgroundColor = NSColor.clearColor;
    self.panel.opaque = NO;
    self.panel.hasShadow = NO;
    self.panel.level = NSFloatingWindowLevel;
    self.panel.hidesOnDeactivate = NO;
    self.panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                    NSWindowCollectionBehaviorFullScreenAuxiliary |
                                    NSWindowCollectionBehaviorStationary;
    self.companionView = [[REAICompanionView alloc] initWithFrame:NSMakeRect(0, 0, 220, 250)];
    self.panel.contentView = self.companionView;

    __weak REAIVoiceCompanionController *weakSelf = self;
    self.companionView.sceneView.petClickHandler = ^{
        [weakSelf toggleConversation];
    };

    self.conversationPanel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, 520, 560)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                            NSWindowStyleMaskNonactivatingPanel | NSWindowStyleMaskFullSizeContentView
                    backing:NSBackingStoreBuffered
                      defer:NO];
    self.conversationPanel.title = @"川仔 · 对话记忆";
    self.conversationPanel.titlebarAppearsTransparent = YES;
    self.conversationPanel.backgroundColor = reai_companion_color(0.976, 0.973, 0.953, 1.0);
    self.conversationPanel.opaque = YES;
    self.conversationPanel.hasShadow = YES;
    self.conversationPanel.level = NSNormalWindowLevel;
    self.conversationPanel.hidesOnDeactivate = NO;
    self.conversationPanel.releasedWhenClosed = NO;
    self.conversationPanel.becomesKeyOnlyIfNeeded = YES;
    self.conversationPanel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                                NSWindowCollectionBehaviorFullScreenAuxiliary;
    self.conversationView = [[REAIConversationView alloc] initWithFrame:NSMakeRect(0, 0, 520, 560)];
    self.conversationPanel.contentView = self.conversationView;

    self.transcriptPanel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, 760, 86)
                  styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                    backing:NSBackingStoreBuffered
                      defer:NO];
    self.transcriptPanel.backgroundColor = NSColor.clearColor;
    self.transcriptPanel.opaque = NO;
    self.transcriptPanel.hasShadow = NO;
    self.transcriptPanel.level = NSFloatingWindowLevel;
    self.transcriptPanel.hidesOnDeactivate = NO;
    self.transcriptPanel.ignoresMouseEvents = YES;
    self.transcriptPanel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                              NSWindowCollectionBehaviorFullScreenAuxiliary;
    NSView *transcriptCanvas = [[NSView alloc]
        initWithFrame:NSMakeRect(0, 0, 760, 86)];
    transcriptCanvas.wantsLayer = YES;
    transcriptCanvas.layer.backgroundColor = NSColor.clearColor.CGColor;
    transcriptCanvas.layer.opaque = NO;
    self.transcriptOverlayLabel = [NSTextField labelWithString:@""];
    self.transcriptOverlayLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.transcriptOverlayLabel.font = [NSFont systemFontOfSize:25.0 weight:NSFontWeightMedium];
    self.transcriptOverlayLabel.alignment = NSTextAlignmentCenter;
    self.transcriptOverlayLabel.maximumNumberOfLines = 2;
    self.transcriptOverlayLabel.lineBreakMode = NSLineBreakByWordWrapping;
    [transcriptCanvas addSubview:self.transcriptOverlayLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.transcriptOverlayLabel.leadingAnchor constraintEqualToAnchor:
            transcriptCanvas.leadingAnchor constant:28.0],
        [self.transcriptOverlayLabel.trailingAnchor constraintEqualToAnchor:
            transcriptCanvas.trailingAnchor constant:-28.0],
        [self.transcriptOverlayLabel.centerYAnchor constraintEqualToAnchor:
            transcriptCanvas.centerYAnchor],
    ]];
    self.transcriptPanel.contentView = transcriptCanvas;
    [self reloadConversationHistory];
}

- (void)show {
    [NSApp unhideWithoutActivation];
    NSScreen *screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    if (!self.visible && screen != nil) {
        NSRect visibleFrame = screen.visibleFrame;
        NSPoint origin = NSMakePoint(NSMaxX(visibleFrame) - NSWidth(self.panel.frame) - 18,
                                    NSMinY(visibleFrame) + 28);
        [self.panel setFrameOrigin:origin];
    }
    [self.panel orderFrontRegardless];
    self.visible = YES;
}

- (void)hide {
    [self.panel orderOut:nil];
    [self.conversationPanel orderOut:nil];
    [self hideTranscriptOverlayImmediately];
    self.visible = NO;
}

- (void)toggleVisible {
    self.visible ? [self hide] : [self show];
}

- (void)voiceKeyPressed {
    self.voiceKeyDown = YES;
    if (self.recording) return;
    [self show];
    [self showTranscriptOverlayWithText:@"正在听…"];
    [self requestPermissionsAndStart];
}

- (void)showTranscriptOverlayWithText:(NSString *)text {
    if (text.length == 0) return;
    self.transcriptOverlayGeneration += 1;
    NSMutableParagraphStyle *paragraphStyle = [[NSMutableParagraphStyle alloc] init];
    paragraphStyle.alignment = NSTextAlignmentCenter;
    paragraphStyle.lineBreakMode = NSLineBreakByWordWrapping;
    NSString *appearanceName = [self.transcriptPanel.effectiveAppearance
        bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
    BOOL darkAppearance = [appearanceName isEqualToString:NSAppearanceNameDarkAqua];
    NSColor *fillColor = darkAppearance
        ? NSColor.whiteColor
        : [NSColor colorWithWhite:0.08 alpha:1.0];
    NSColor *outlineColor = darkAppearance
        ? [NSColor colorWithWhite:0.0 alpha:0.82]
        : [NSColor colorWithWhite:1.0 alpha:0.92];
    self.transcriptOverlayLabel.attributedStringValue = [[NSAttributedString alloc]
        initWithString:text
            attributes:@{
                NSFontAttributeName: [NSFont systemFontOfSize:25.0 weight:NSFontWeightMedium],
                NSForegroundColorAttributeName: fillColor,
                NSStrokeColorAttributeName: outlineColor,
                NSStrokeWidthAttributeName: @(-1.4),
                NSParagraphStyleAttributeName: paragraphStyle,
            }];
    NSScreen *screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    if (screen != nil) {
        NSRect visibleFrame = screen.visibleFrame;
        NSRect frame = self.transcriptPanel.frame;
        NSPoint origin = NSMakePoint(NSMidX(visibleFrame) - NSWidth(frame) * 0.5,
                                    NSMinY(visibleFrame) + 72.0);
        [self.transcriptPanel setFrameOrigin:origin];
    }
    self.transcriptPanel.alphaValue = 1.0;
    [self.transcriptPanel orderFrontRegardless];
}

- (void)hideTranscriptOverlayAfterDelay:(NSTimeInterval)delay {
    NSUInteger generation = self.transcriptOverlayGeneration;
    __weak REAIVoiceCompanionController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        REAIVoiceCompanionController *strongSelf = weakSelf;
        if (strongSelf == nil || generation != strongSelf.transcriptOverlayGeneration) return;
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0.24;
            strongSelf.transcriptPanel.animator.alphaValue = 0.0;
        } completionHandler:^{
            if (generation != strongSelf.transcriptOverlayGeneration) return;
            [strongSelf.transcriptPanel orderOut:nil];
            strongSelf.transcriptPanel.alphaValue = 1.0;
        }];
    });
}

- (void)hideTranscriptOverlayImmediately {
    self.transcriptOverlayGeneration += 1;
    [self.transcriptPanel orderOut:nil];
    self.transcriptPanel.alphaValue = 1.0;
}

- (void)showConversation {
    [self reloadConversationHistory];
    NSScreen *screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    if (screen != nil) {
        NSRect visibleFrame = screen.visibleFrame;
        NSRect frame = self.conversationPanel.frame;
        NSPoint origin = NSMakePoint(NSMidX(visibleFrame) - NSWidth(frame) * 0.5,
                                    NSMidY(visibleFrame) - NSHeight(frame) * 0.5);
        [self.conversationPanel setFrameOrigin:origin];
    }
    [self.conversationPanel orderFrontRegardless];
    self.logHandler(@"COMPANION", [NSString stringWithFormat:
        @"已显示居中对话记忆窗口·普通层级=%ld·桌宠浮动层级=%ld",
        (long)self.conversationPanel.level, (long)self.panel.level]);
}

- (void)toggleConversation {
    self.conversationPanel.isVisible ? [self.conversationPanel orderOut:nil] : [self showConversation];
}

- (void)configureVolcengineTTS {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"启用豆包端到端实时语音";
    alert.informativeText = @"粘贴豆包语音新版控制台的 Speech API Key。密钥只保存在这台 Mac 的 Keychain；默认使用 Seeduplex 1.2.6.1 与 Vivi 实时音色。";
    [alert addButtonWithTitle:@"保存并启用"];
    [alert addButtonWithTitle:@"打开火山控制台"];
    [alert addButtonWithTitle:@"取消"];

    NSView *accessory = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 430, 58)];
    NSTextField *label = [NSTextField labelWithString:@"Speech API Key"];
    label.frame = NSMakeRect(0, 38, 430, 18);
    NSSecureTextField *field = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 4, 430, 28)];
    field.placeholderString = reai_tts_api_key().length > 0
        ? @"已配置；输入新 Key 可替换" : @"在此粘贴 API Key";
    [accessory addSubview:label];
    [accessory addSubview:field];
    alert.accessoryView = accessory;

    NSModalResponse response = [alert runModal];
    if (response == NSAlertSecondButtonReturn) {
        [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:
            @"https://console.volcengine.com/speech/new/setting/apikeys"]];
        return;
    }
    if (response != NSAlertFirstButtonReturn) return;
    NSString *apiKey = [field.stringValue stringByTrimmingCharactersInSet:
                        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (apiKey.length == 0) {
        self.statusHandler(@"未填写火山 Speech API Key");
        self.logHandler(@"TTS", @"未填写 Speech API Key，配置未改变");
        return;
    }
    if (reai_store_tts_api_key(apiKey)) {
        self.statusHandler(@"豆包端到端实时语音已启用");
        self.logHandler(@"REALTIME", @"Speech API Key 已安全保存到 Keychain；Seeduplex 1.2.6.1 · Vivi");
    } else {
        self.statusHandler(@"火山音色配置保存失败");
        self.logHandler(@"TTS", @"Speech API Key 写入 Keychain 失败");
    }
}

- (void)reloadConversationHistory {
    NSData *data = [NSData dataWithContentsOfFile:self.memoryPath];
    if (data.length == 0) {
        [self.conversationView renderHistoryEntries:@[]];
        return;
    }
    NSString *content = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSArray<NSString *> *lines = [content componentsSeparatedByCharactersInSet:
                                  NSCharacterSet.newlineCharacterSet];
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    for (NSString *line in lines) {
        if (line.length == 0) continue;
        NSData *lineData = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *entry = [NSJSONSerialization JSONObjectWithData:lineData options:0 error:nil];
        if ([entry[@"text"] length] > 0 && [entry[@"role"] length] > 0) [entries addObject:entry];
    }
    [self.conversationView renderHistoryEntries:entries];
}

- (void)requestPermissionsAndStart {
    if (!self.voiceKeyDown) return;
    SFSpeechRecognizerAuthorizationStatus speechStatus = SFSpeechRecognizer.authorizationStatus;
    AVAuthorizationStatus microphoneStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    if (speechStatus == SFSpeechRecognizerAuthorizationStatusDenied ||
        speechStatus == SFSpeechRecognizerAuthorizationStatusRestricted ||
        microphoneStatus == AVAuthorizationStatusDenied ||
        microphoneStatus == AVAuthorizationStatusRestricted) {
        [self showPermissionError];
        return;
    }

    if (speechStatus == SFSpeechRecognizerAuthorizationStatusNotDetermined) {
        __weak REAIVoiceCompanionController *weakSelf = self;
        [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (status == SFSpeechRecognizerAuthorizationStatusAuthorized) {
                    [weakSelf requestPermissionsAndStart];
                } else {
                    [weakSelf showPermissionError];
                }
            });
        }];
        return;
    }

    if (microphoneStatus == AVAuthorizationStatusNotDetermined) {
        __weak REAIVoiceCompanionController *weakSelf = self;
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (granted) {
                    [weakSelf requestPermissionsAndStart];
                } else {
                    [weakSelf showPermissionError];
                }
            });
        }];
        return;
    }
    [self startRecording];
}

- (void)showPermissionError {
    self.conversationView.statusLabel.stringValue = @"需要麦克风与语音识别权限";
    self.conversationView.transcriptLabel.stringValue = @"请在系统设置 → 隐私与安全性中允许此 App。";
    self.statusHandler(@"桌宠语音权限未开启");
    self.logHandler(@"VOICE", @"麦克风或语音识别权限未开启");
    [self showTranscriptOverlayWithText:@"需要麦克风与语音识别权限"];
    [self hideTranscriptOverlayAfterDelay:3.0];
}

- (void)sendRealtimeEvent:(NSDictionary *)event generation:(NSUInteger)generation {
    if (!self.realtimeActive || generation != self.realtimeGeneration ||
        self.realtimeSocket == nil) return;
    NSError *jsonError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:event options:0 error:&jsonError];
    NSString *json = data == nil ? nil : [[NSString alloc] initWithData:data
                                                               encoding:NSUTF8StringEncoding];
    if (json.length == 0) {
        [self failRealtimeForGeneration:generation
                                 reason:jsonError.localizedDescription ?: @"事件编码失败"];
        return;
    }
    NSURLSessionWebSocketMessage *message =
        [[NSURLSessionWebSocketMessage alloc] initWithString:json];
    __weak REAIVoiceCompanionController *weakSelf = self;
    [self.realtimeSocket sendMessage:message completionHandler:^(NSError *error) {
        if (error == nil) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf failRealtimeForGeneration:generation reason:error.localizedDescription];
        });
    }];
}

- (NSDictionary *)realtimeSessionCreateEvent {
    NSArray<NSString *> *statements = [self recentUserStatementsWithLimit:8];
    NSString *memory = statements.count > 0
        ? [[[statements reverseObjectEnumerator] allObjects] componentsJoinedByString:@"；"]
        : @"暂无历史对话";
    NSString *instructions = [NSString stringWithFormat:
        @"你是川仔，一只住在 macOS 桌面上的 3D 机械猫伙伴。"
         "你温和、机灵、有一点幽默，始终用简体中文。"
         "回复一到两句、80个汉字以内，适合直接语音播报，不使用 Markdown。"
         "下面的过往记忆都是用户亲口说的；复述姓名、偏好和经历时必须使用‘你’。"
         "用户要求记住时简短确认‘记住了’。过往记忆：%@", memory];
    return @{
        @"type": @"session.create",
        @"event_id": NSUUID.UUID.UUIDString,
        @"session": @{
            @"id": NSUUID.UUID.UUIDString,
            @"model": REAIRealtimeModel,
            @"instructions": instructions,
            @"audio": @{
                @"input": @{ @"format": @{ @"type": @"pcm", @"rate": @16000 } },
                @"output": @{
                    @"format": @{ @"type": @"pcm_s16le", @"rate": @24000 },
                    @"voice": REAIRealtimeSpeaker,
                },
            },
            @"tools": @[],
        },
        @"extension": @{
            @"asr": @{ @"extra": @{} },
            @"tts": @{ @"extra": @{} },
            @"dialog": @{
                @"extra": @{
                    @"enable_loudness_norm": @YES,
                    @"enable_music": @NO,
                },
            },
        },
    };
}

- (void)startRealtimeTurn {
    NSString *apiKey = reai_tts_api_key();
    self.realtimeGeneration += 1;
    [self stopRealtimeAudioImmediately];
    [self.realtimeSocket cancelWithCloseCode:NSURLSessionWebSocketCloseCodeGoingAway reason:nil];
    [self.realtimeURLSession invalidateAndCancel];
    self.realtimeURLSession = nil;
    self.realtimeSocket = nil;
    self.realtimePendingAudio = [NSMutableArray array];
    self.realtimeTranscript = @"";
    self.realtimeReply = @"";
    self.realtimeSessionReady = NO;
    self.realtimeTranscriptStarted = NO;
    self.realtimeTurnReleased = NO;
    self.realtimeReplyDelivered = NO;
    self.realtimeClosing = NO;
    self.realtimeActive = apiKey.length > 0;
    if (!self.realtimeActive) {
        self.logHandler(@"REALTIME", @"未配置 Speech API Key，使用本地对话链路");
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:REAIRealtimeEndpoint]
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15.0];
    [request setValue:apiKey forHTTPHeaderField:@"X-Api-Key"];
    [request setValue:NSUUID.UUID.UUIDString forHTTPHeaderField:@"X-Api-Connect-Id"];
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.timeoutIntervalForRequest = 15.0;
    configuration.timeoutIntervalForResource = 180.0;
    self.realtimeURLSession = [NSURLSession sessionWithConfiguration:configuration
                                                            delegate:self
                                                       delegateQueue:NSOperationQueue.mainQueue];
    self.realtimeSocket = [self.realtimeURLSession webSocketTaskWithRequest:request];
    [self.realtimeSocket resume];
    self.logHandler(@"REALTIME", [NSString stringWithFormat:
        @"正在连接豆包实时语音·%@", REAIRealtimeModel]);

}

- (void)URLSession:(NSURLSession *)session
      webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
 didOpenWithProtocol:(NSString *)protocol {
    (void)session;
    (void)protocol;
    if (webSocketTask != self.realtimeSocket || !self.realtimeActive) return;
    NSUInteger generation = self.realtimeGeneration;
    [self sendRealtimeEvent:[self realtimeSessionCreateEvent] generation:generation];
    [self receiveRealtimeMessageForGeneration:generation];
}

- (void)receiveRealtimeMessageForGeneration:(NSUInteger)generation {
    if (!self.realtimeActive || generation != self.realtimeGeneration ||
        self.realtimeSocket == nil) return;
    __weak REAIVoiceCompanionController *weakSelf = self;
    [self.realtimeSocket receiveMessageWithCompletionHandler:
        ^(NSURLSessionWebSocketMessage *message, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            REAIVoiceCompanionController *strongSelf = weakSelf;
            if (strongSelf == nil || generation != strongSelf.realtimeGeneration) return;
            if (error != nil) {
                [strongSelf failRealtimeForGeneration:generation reason:error.localizedDescription];
                return;
            }
            NSString *text = message.string;
            NSData *data = text.length > 0
                ? [text dataUsingEncoding:NSUTF8StringEncoding] : message.data;
            NSDictionary *event = data.length > 0
                ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            if (![event isKindOfClass:NSDictionary.class]) {
                [strongSelf failRealtimeForGeneration:generation reason:@"服务端事件无法解析"];
                return;
            }
            [strongSelf handleRealtimeEvent:event generation:generation];
            if (strongSelf.realtimeActive && generation == strongSelf.realtimeGeneration &&
                !strongSelf.realtimeClosing) {
                [strongSelf receiveRealtimeMessageForGeneration:generation];
            } else if (strongSelf.realtimeActive && strongSelf.realtimeClosing) {
                [strongSelf receiveRealtimeMessageForGeneration:generation];
            }
        });
    }];
}

- (void)enqueueRealtimeAudioData:(NSData *)audioData {
    if (audioData.length == 0) return;
    NSUInteger generation = self.realtimeGeneration;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.realtimeActive || generation != self.realtimeGeneration ||
            self.realtimeTurnReleased) return;
        if (!self.realtimeSessionReady) {
            if (self.realtimePendingAudio.count >= 300) {
                [self.realtimePendingAudio removeObjectAtIndex:0];
            }
            [self.realtimePendingAudio addObject:audioData];
            return;
        }
        [self sendRealtimeEvent:@{
            @"type": @"input_audio_buffer.append",
            @"audio": [audioData base64EncodedStringWithOptions:0],
        } generation:generation];
    });
}

- (void)commitRealtimeInput {
    BOOL firstRelease = !self.realtimeTurnReleased;
    self.realtimeTurnReleased = YES;
    if (firstRelease && self.realtimeActive) {
        NSUInteger generation = self.realtimeGeneration;
        __weak REAIVoiceCompanionController *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            REAIVoiceCompanionController *strongSelf = weakSelf;
            if (strongSelf.realtimeActive && generation == strongSelf.realtimeGeneration &&
                !strongSelf.realtimeReplyDelivered) {
                [strongSelf failRealtimeForGeneration:generation reason:@"实时回复超时"];
            }
        });
    }
    if (!self.realtimeActive || !self.realtimeSessionReady) return;
    NSUInteger generation = self.realtimeGeneration;
    [self sendRealtimeEvent:@{
        @"type": @"input_audio_buffer.commit",
        @"event_id": NSUUID.UUID.UUIDString,
    } generation:generation];
    [self sendRealtimeEvent:@{
        @"type": @"input_audio_mute.commit",
        @"event_id": NSUUID.UUID.UUIDString,
    } generation:generation];
    self.logHandler(@"REALTIME", @"已提交本轮语音，等待端到端回复");
}

- (void)playRealtimePCMData:(NSData *)audioData generation:(NSUInteger)generation {
    if (audioData.length == 0 || generation != self.realtimeGeneration) return;
    if (self.realtimeOutputQueue == NULL) {
        AudioStreamBasicDescription format = {0};
        format.mSampleRate = 24000.0;
        format.mFormatID = kAudioFormatLinearPCM;
        format.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger |
                              kLinearPCMFormatFlagIsPacked;
        format.mBytesPerPacket = 2;
        format.mFramesPerPacket = 1;
        format.mBytesPerFrame = 2;
        format.mChannelsPerFrame = 1;
        format.mBitsPerChannel = 16;
        AudioQueueRef queue = NULL;
        OSStatus status = AudioQueueNewOutput(&format, reai_output_queue_callback,
                                               (__bridge void *)self, NULL, NULL, 0, &queue);
        if (status != noErr || queue == NULL) {
            self.logHandler(@"REALTIME", [NSString stringWithFormat:
                @"实时语音输出创建失败（OSStatus=%d）", (int)status]);
            return;
        }
        self.realtimeOutputQueue = queue;
        self.realtimeOutputStarted = NO;
        self.realtimeOutputBuffersInFlight = 0;
        self.realtimeOutputFinished = NO;
    }
    AudioQueueBufferRef buffer = NULL;
    OSStatus status = AudioQueueAllocateBuffer(self.realtimeOutputQueue,
                                                (UInt32)audioData.length, &buffer);
    if (status != noErr || buffer == NULL) return;
    memcpy(buffer->mAudioData, audioData.bytes, audioData.length);
    buffer->mAudioDataByteSize = (UInt32)audioData.length;
    self.realtimeOutputBuffersInFlight += 1;
    status = AudioQueueEnqueueBuffer(self.realtimeOutputQueue, buffer, 0, NULL);
    if (status != noErr) {
        self.realtimeOutputBuffersInFlight -= 1;
        AudioQueueFreeBuffer(self.realtimeOutputQueue, buffer);
        return;
    }
    if (!self.realtimeOutputStarted) {
        status = AudioQueueStart(self.realtimeOutputQueue, NULL);
        if (status == noErr) self.realtimeOutputStarted = YES;
    }
}

- (void)handleRealtimeOutputBufferFinishedForQueue:(AudioQueueRef)queue {
    if (queue != self.realtimeOutputQueue) return;
    if (self.realtimeOutputBuffersInFlight > 0) self.realtimeOutputBuffersInFlight -= 1;
    if (self.realtimeOutputFinished && self.realtimeOutputBuffersInFlight == 0) {
        [self hideTranscriptOverlayAfterDelay:1.0];
        if (self.realtimeTestTurn) {
            self.logHandler(@"REALTIME_TEST_OVERLAY", @"AI 回复字幕已随语音播放完成并准备淡出");
        }
    }
}

- (void)stopRealtimeAudioImmediately {
    AudioQueueRef queue = self.realtimeOutputQueue;
    self.realtimeOutputQueue = NULL;
    self.realtimeOutputStarted = NO;
    self.realtimeOutputBuffersInFlight = 0;
    self.realtimeOutputFinished = NO;
    if (queue != NULL) {
        AudioQueueStop(queue, true);
        AudioQueueDispose(queue, true);
    }
}

- (void)handleRealtimeEvent:(NSDictionary *)event generation:(NSUInteger)generation {
    NSString *type = [event[@"type"] isKindOfClass:NSString.class] ? event[@"type"] : @"";
    if ([type isEqualToString:@"session.created"]) {
        self.realtimeSessionReady = YES;
        NSArray<NSData *> *pending = [self.realtimePendingAudio copy];
        [self.realtimePendingAudio removeAllObjects];
        for (NSData *chunk in pending) {
            [self sendRealtimeEvent:@{
                @"type": @"input_audio_buffer.append",
                @"audio": [chunk base64EncodedStringWithOptions:0],
            } generation:generation];
        }
        if (self.realtimeTurnReleased) [self commitRealtimeInput];
        self.logHandler(@"REALTIME", [NSString stringWithFormat:
            @"端到端会话已建立·%@·Vivi", REAIRealtimeModel]);
        return;
    }
    if ([type isEqualToString:@"conversation.item.input_audio_transcription.delta"]) {
        NSString *delta = [event[@"delta"] isKindOfClass:NSString.class] ? event[@"delta"] : @"";
        if (delta.length > 0) {
            self.realtimeTranscriptStarted = YES;
            self.realtimeTranscript = reai_apply_realtime_transcript_snapshot(
                self.realtimeTranscript, delta);
            self.conversationView.transcriptLabel.stringValue = self.realtimeTranscript;
            [self showTranscriptOverlayWithText:self.realtimeTranscript];
            if (self.realtimeTestTurn) {
                self.logHandler(@"REALTIME_TEST_DELTA", self.realtimeTranscript);
            }
        }
        return;
    }
    if ([type isEqualToString:@"conversation.item.input_audio_transcription.completed"]) {
        NSString *text = [event[@"text"] isKindOfClass:NSString.class] ? event[@"text"] : nil;
        if (text.length == 0 && [event[@"transcript"] isKindOfClass:NSString.class]) {
            text = event[@"transcript"];
        }
        if (text.length > 0) {
            self.realtimeTranscriptStarted = YES;
            self.realtimeTranscript = text;
        }
        self.conversationView.transcriptLabel.stringValue = [NSString stringWithFormat:
            @"你：%@", self.realtimeTranscript.length > 0 ? self.realtimeTranscript : self.partialTranscript];
        NSString *finalTranscript = self.realtimeTranscript.length > 0
            ? self.realtimeTranscript : self.partialTranscript;
        [self showTranscriptOverlayWithText:finalTranscript];
        [self hideTranscriptOverlayAfterDelay:3.0];
        self.conversationView.statusLabel.stringValue = @"THINKING · 川仔正在回答";
        return;
    }
    if ([type isEqualToString:@"response.output_text.delta"]) {
        NSString *delta = [event[@"delta"] isKindOfClass:NSString.class] ? event[@"delta"] : @"";
        if (delta.length > 0) {
            self.realtimeReply = [self.realtimeReply stringByAppendingString:delta];
            [self showTranscriptOverlayWithText:[NSString stringWithFormat:
                @"川仔：%@", self.realtimeReply]];
            if (self.realtimeTestTurn) {
                self.logHandler(@"REALTIME_TEST_REPLY_DELTA", self.realtimeReply);
            }
        }
        return;
    }
    if ([type isEqualToString:@"response.output_text.done"]) {
        NSString *reply = [event[@"text"] isKindOfClass:NSString.class] ? event[@"text"] : self.realtimeReply;
        NSString *transcript = self.realtimeTranscript.length > 0
            ? self.realtimeTranscript : self.partialTranscript;
        transcript = [transcript stringByTrimmingCharactersInSet:
                      NSCharacterSet.whitespaceAndNewlineCharacterSet];
        reply = [reply stringByTrimmingCharactersInSet:
                 NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (reply.length > 0) {
            self.realtimeReply = reply;
            [self showTranscriptOverlayWithText:[NSString stringWithFormat:@"川仔：%@", reply]];
        }
        if (transcript.length > 0 && reply.length > 0 && !self.realtimeReplyDelivered) {
            self.realtimeReplyDelivered = YES;
            if (self.realtimeTestTurn) {
                self.conversationView.transcriptLabel.stringValue = [NSString stringWithFormat:
                    @"测试转录：%@\n川仔：%@", transcript, reply];
                self.logHandler(@"REALTIME_TEST", [NSString stringWithFormat:
                    @"转录=%@；回复=%@", transcript, reply]);
            } else {
                [self persistUtterance:transcript role:@"user"];
                [self deliverReply:reply transcript:transcript source:@"豆包端到端实时语音" speak:NO];
            }
            self.conversationView.statusLabel.stringValue = @"SPEAKING · Vivi 实时回复";
        }
        return;
    }
    if ([type isEqualToString:@"response.output_audio.delta"]) {
        NSString *delta = [event[@"delta"] isKindOfClass:NSString.class] ? event[@"delta"] : @"";
        NSData *audio = [[NSData alloc] initWithBase64EncodedString:delta
                                                           options:NSDataBase64DecodingIgnoreUnknownCharacters];
        [self playRealtimePCMData:audio generation:generation];
        return;
    }
    if ([type isEqualToString:@"response.output_audio.done"]) {
        self.realtimeOutputFinished = YES;
        if (self.realtimeOutputBuffersInFlight == 0) {
            [self hideTranscriptOverlayAfterDelay:1.0];
            if (self.realtimeTestTurn) {
                self.logHandler(@"REALTIME_TEST_OVERLAY", @"AI 回复无待播音频，准备淡出");
            }
        }
        if (self.realtimeReplyDelivered) {
            self.conversationView.statusLabel.stringValue = @"REMEMBERED · 已写入本地记忆";
            self.statusHandler(@"桌宠实时语音回复完成");
        }
        return;
    }
    if ([type isEqualToString:@"response.done"]) {
        if (!self.realtimeClosing) {
            self.realtimeClosing = YES;
            [self sendRealtimeEvent:@{
                @"type": @"session.close",
                @"event_id": NSUUID.UUID.UUIDString,
            } generation:generation];
        }
        return;
    }
    if ([type isEqualToString:@"session.closed"]) {
        self.realtimeActive = NO;
        self.realtimeSessionReady = NO;
        [self.realtimeSocket cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
        self.realtimeSocket = nil;
        [self.realtimeURLSession finishTasksAndInvalidate];
        self.realtimeURLSession = nil;
        self.logHandler(@"REALTIME", @"端到端会话已正常关闭");
        return;
    }
    if ([type isEqualToString:@"error"]) {
        NSDictionary *apiError = [event[@"error"] isKindOfClass:NSDictionary.class]
            ? event[@"error"] : event;
        NSString *message = [apiError[@"message"] isKindOfClass:NSString.class]
            ? apiError[@"message"] : @"服务端返回错误";
        [self failRealtimeForGeneration:generation reason:message];
    }
}

- (void)failRealtimeForGeneration:(NSUInteger)generation reason:(NSString *)reason {
    if (generation != self.realtimeGeneration || !self.realtimeActive) return;
    self.realtimeActive = NO;
    self.realtimeSessionReady = NO;
    [self.realtimeSocket cancelWithCloseCode:NSURLSessionWebSocketCloseCodeGoingAway reason:nil];
    self.realtimeSocket = nil;
    [self.realtimeURLSession invalidateAndCancel];
    self.realtimeURLSession = nil;
    self.logHandler(@"REALTIME", [NSString stringWithFormat:
        @"%@；本轮改用本地链路", reason.length > 0 ? reason : @"实时语音不可用"]);
    if (self.realtimeTurnReleased && !self.realtimeReplyDelivered && !self.awaitingFinalResult) {
        NSString *transcript = self.realtimeTranscript.length > 0
            ? self.realtimeTranscript : self.partialTranscript;
        transcript = [transcript stringByTrimmingCharactersInSet:
                      NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (transcript.length > 0) [self handleCompletedTranscript:transcript speak:YES];
    }
}

- (void)URLSession:(NSURLSession *)session
               task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    (void)session;
    if (task != self.realtimeSocket || error == nil || self.realtimeClosing) return;
    NSUInteger generation = self.realtimeGeneration;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self failRealtimeForGeneration:generation reason:error.localizedDescription];
    });
}

- (void)startRecording {
    if (!self.speechRecognizer.isAvailable || !self.speechRecognizer.supportsOnDeviceRecognition) {
        self.conversationView.statusLabel.stringValue = @"本机中文听写暂不可用";
        self.logHandler(@"VOICE", @"中文本地语音识别不可用");
        return;
    }

    self.ttsGeneration += 1;
    [self.ttsTask cancel];
    self.ttsTask = nil;
    [self.ttsPlayer stop];
    self.ttsPlayer = nil;
    [self.speechSynthesizer stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
    self.recognitionGeneration += 1;
    NSUInteger generation = self.recognitionGeneration;
    self.partialTranscript = @"";
    self.awaitingFinalResult = NO;
    self.recognitionRequest = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
    self.recognitionRequest.shouldReportPartialResults = YES;
    self.recognitionRequest.requiresOnDeviceRecognition = YES;
    self.recognitionRequest.taskHint = SFSpeechRecognitionTaskHintDictation;

    NSString *inputDeviceName = nil;
    BOOL avoidedBluetooth = NO;
    AudioDeviceID inputDevice = reai_preferred_input_device(&inputDeviceName, &avoidedBluetooth);
    NSString *inputDeviceUID = reai_audio_device_uid(inputDevice);
    if (inputDevice == kAudioObjectUnknown || inputDeviceUID.length == 0) {
        self.recognitionRequest = nil;
        self.conversationView.statusLabel.stringValue = @"没有可用的非蓝牙麦克风";
        self.logHandler(@"VOICE", @"为避免打断耳机音乐，未启用蓝牙麦克风；请使用 Mac 内建或 USB 麦克风");
        return;
    }

    AudioStreamBasicDescription streamFormat = {0};
    streamFormat.mSampleRate = 16000.0;
    streamFormat.mFormatID = kAudioFormatLinearPCM;
    streamFormat.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger |
                                kLinearPCMFormatFlagIsPacked;
    streamFormat.mBytesPerPacket = 2;
    streamFormat.mFramesPerPacket = 1;
    streamFormat.mBytesPerFrame = 2;
    streamFormat.mChannelsPerFrame = 1;
    streamFormat.mBitsPerChannel = 16;

    AudioQueueRef inputQueue = NULL;
    OSStatus queueStatus = AudioQueueNewInput(&streamFormat,
                                               reai_input_queue_callback,
                                               (__bridge void *)self,
                                               NULL,
                                               NULL,
                                               0,
                                               &inputQueue);
    if (queueStatus == noErr) {
        CFStringRef deviceUID = (__bridge CFStringRef)inputDeviceUID;
        queueStatus = AudioQueueSetProperty(inputQueue,
                                             kAudioQueueProperty_CurrentDevice,
                                             &deviceUID,
                                             sizeof(deviceUID));
    }
    if (queueStatus != noErr || inputQueue == NULL) {
        if (inputQueue != NULL) AudioQueueDispose(inputQueue, true);
        self.recognitionRequest = nil;
        self.conversationView.statusLabel.stringValue = @"麦克风启动失败";
        self.logHandler(@"VOICE", [NSString stringWithFormat:@"创建独立输入队列失败（OSStatus=%d）",
                                    (int)queueStatus]);
        return;
    }

    self.inputFormat = [[AVAudioFormat alloc] initWithStreamDescription:&streamFormat];
    const UInt32 bufferBytes = 640;
    for (NSUInteger index = 0; index < 3; index += 1) {
        AudioQueueBufferRef buffer = NULL;
        queueStatus = AudioQueueAllocateBuffer(inputQueue, bufferBytes, &buffer);
        if (queueStatus == noErr) queueStatus = AudioQueueEnqueueBuffer(inputQueue, buffer, 0, NULL);
        if (queueStatus != noErr) break;
    }
    if (queueStatus != noErr) {
        AudioQueueDispose(inputQueue, true);
        self.inputFormat = nil;
        self.recognitionRequest = nil;
        self.conversationView.statusLabel.stringValue = @"麦克风缓冲区初始化失败";
        self.logHandler(@"VOICE", [NSString stringWithFormat:@"初始化录音缓冲区失败（OSStatus=%d）",
                                    (int)queueStatus]);
        return;
    }

    __weak REAIVoiceCompanionController *weakSelf = self;
    self.recognitionTask = [self.speechRecognizer
        recognitionTaskWithRequest:self.recognitionRequest
                     resultHandler:^(SFSpeechRecognitionResult *result, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (weakSelf == nil || generation != weakSelf.recognitionGeneration) return;
            if (result != nil) {
                NSString *text = [result.bestTranscription.formattedString
                    stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                weakSelf.partialTranscript = text ?: @"";
                if (text.length > 0 &&
                    (!weakSelf.realtimeActive || !weakSelf.realtimeTranscriptStarted)) {
                    weakSelf.conversationView.transcriptLabel.stringValue = text;
                    [weakSelf showTranscriptOverlayWithText:text];
                }
                if (result.isFinal) [weakSelf finalizeRecognitionForGeneration:generation];
            }
            if (error != nil && weakSelf.awaitingFinalResult) {
                [weakSelf finalizeRecognitionForGeneration:generation];
            }
        });
    }];

    self.realtimeTestTurn = NO;
    [self startRealtimeTurn];
    self.inputQueue = inputQueue;
    self.recording = YES;
    queueStatus = AudioQueueStart(inputQueue, NULL);
    if (queueStatus != noErr) {
        self.recording = NO;
        self.inputQueue = NULL;
        AudioQueueDispose(inputQueue, true);
        [self.recognitionTask cancel];
        self.recognitionTask = nil;
        self.recognitionRequest = nil;
        self.inputFormat = nil;
        self.conversationView.statusLabel.stringValue = @"麦克风启动失败";
        self.logHandler(@"VOICE", [NSString stringWithFormat:@"启动独立输入队列失败（OSStatus=%d）",
                                    (int)queueStatus]);
        return;
    }

    NSString *reason = avoidedBluetooth ? @"，不触碰蓝牙播放链" : @"";
    self.logHandler(@"VOICE", [NSString stringWithFormat:@"独立录音输入：%@%@",
                                inputDeviceName ?: @"未知设备", reason]);
    [self.companionView setListening:YES];
    self.conversationView.statusLabel.stringValue = @"LISTENING · 松开语音键发送";
    self.conversationView.transcriptLabel.stringValue = @"正在听…";
    [self showTranscriptOverlayWithText:@"正在听…"];
    self.statusHandler(@"桌宠正在听");
    self.logHandler(@"VOICE", self.realtimeActive
        ? @"AI 语音键按下，开始端到端实时语音与本地转录"
        : @"AI 语音键按下，开始本地转录");
}

- (void)handleInputQueue:(AudioQueueRef)queue buffer:(AudioQueueBufferRef)buffer {
    AVAudioFormat *format = self.inputFormat;
    SFSpeechAudioBufferRecognitionRequest *request = self.recognitionRequest;
    if (self.recording && queue == self.inputQueue && format != nil && request != nil &&
        buffer->mAudioDataByteSize >= 2) {
        AVAudioFrameCount frames = buffer->mAudioDataByteSize / 2;
        AVAudioPCMBuffer *pcmBuffer = [[AVAudioPCMBuffer alloc]
            initWithPCMFormat:format frameCapacity:frames];
        pcmBuffer.frameLength = frames;
        AudioBuffer *destination = &pcmBuffer.mutableAudioBufferList->mBuffers[0];
        UInt32 bytes = MIN(destination->mDataByteSize, buffer->mAudioDataByteSize);
        memcpy(destination->mData, buffer->mAudioData, bytes);
        destination->mDataByteSize = bytes;
        [request appendAudioPCMBuffer:pcmBuffer];
        NSData *realtimeAudio = [NSData dataWithBytes:buffer->mAudioData length:bytes];
        [self enqueueRealtimeAudioData:realtimeAudio];
    }
    if (self.recording && queue == self.inputQueue) {
        AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
    }
}

- (void)voiceKeyReleased {
    self.voiceKeyDown = NO;
    if (!self.recording) return;
    self.recording = NO;
    self.awaitingFinalResult = YES;
    [self.companionView setListening:NO];
    self.conversationView.statusLabel.stringValue = @"THINKING · 正在整理这句话";
    AudioQueueRef inputQueue = self.inputQueue;
    self.inputQueue = NULL;
    if (inputQueue != NULL) {
        AudioQueueStop(inputQueue, true);
        AudioQueueDispose(inputQueue, true);
    }
    self.inputFormat = nil;
    [self.recognitionRequest endAudio];
    [self commitRealtimeInput];
    [self hideTranscriptOverlayAfterDelay:4.0];
    self.statusHandler(@"桌宠正在整理对话");
    self.logHandler(@"VOICE", @"AI 语音键释放，结束录音");

    NSUInteger generation = self.recognitionGeneration;
    __weak REAIVoiceCompanionController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (weakSelf.awaitingFinalResult && generation == weakSelf.recognitionGeneration) {
            [weakSelf finalizeRecognitionForGeneration:generation];
        }
    });
}

- (void)finalizeRecognitionForGeneration:(NSUInteger)generation {
    if (!self.awaitingFinalResult || generation != self.recognitionGeneration) return;
    self.awaitingFinalResult = NO;
    [self.recognitionTask finish];
    self.recognitionTask = nil;
    self.recognitionRequest = nil;
    NSString *transcript = [self.partialTranscript
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (transcript.length == 0) {
        self.conversationView.transcriptLabel.stringValue = @"这次没有听清，再按住语音键试一次。";
        self.conversationView.statusLabel.stringValue = @"READY · 等待下一句话";
        self.statusHandler(@"桌宠没有听清");
        self.logHandler(@"VOICE", @"本次转录为空");
        [self showTranscriptOverlayWithText:@"这次没有听清"];
        [self hideTranscriptOverlayAfterDelay:2.0];
        return;
    }
    if (self.realtimeActive || self.realtimeReplyDelivered) {
        self.logHandler(@"VOICE", @"本地转录已完成，由端到端语音链路回复");
        return;
    }
    [self handleCompletedTranscript:transcript speak:YES];
}

- (void)acceptRealtimePCMForTesting:(NSData *)audioData {
    if (audioData.length == 0 || self.recording) return;
    [self show];
    [self showTranscriptOverlayWithText:@"正在输入测试语音…"];
    [self startRealtimeTurn];
    self.realtimeTestTurn = YES;
    NSUInteger generation = self.realtimeGeneration;
    self.conversationView.statusLabel.stringValue = @"TESTING · 端到端实时语音";
    self.conversationView.transcriptLabel.stringValue = @"正在输入测试语音…";
    [self sendRealtimeTestAudio:audioData offset:0 generation:generation];
}

- (void)sendRealtimeTestAudio:(NSData *)audioData
                       offset:(NSUInteger)offset
                   generation:(NSUInteger)generation {
    if (!self.realtimeActive || generation != self.realtimeGeneration) return;
    if (offset >= audioData.length) {
        [self commitRealtimeInput];
        return;
    }
    NSUInteger length = MIN((NSUInteger)640, audioData.length - offset);
    NSData *chunk = [audioData subdataWithRange:NSMakeRange(offset, length)];
    [self enqueueRealtimeAudioData:chunk];
    __weak REAIVoiceCompanionController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.02 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf sendRealtimeTestAudio:audioData
                                 offset:offset + length
                             generation:generation];
    });
}

- (void)acceptTranscriptForTesting:(NSString *)transcript speak:(BOOL)speak {
    NSString *trimmed = [transcript stringByTrimmingCharactersInSet:
                         NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0) return;
    [self show];
    [self showConversation];
    [self handleCompletedTranscript:trimmed speak:speak];
}

- (void)handleCompletedTranscript:(NSString *)transcript speak:(BOOL)speak {
    NSArray<NSString *> *previousStatements = [self recentUserStatementsWithLimit:4];
    [self persistUtterance:transcript role:@"user"];
    [self reloadConversationHistory];
    self.conversationView.transcriptLabel.stringValue = [NSString stringWithFormat:@"你：%@", transcript];
    [self showTranscriptOverlayWithText:transcript];
    [self hideTranscriptOverlayAfterDelay:3.0];
    self.conversationView.statusLabel.stringValue = @"THINKING · 川仔正在想";
    self.statusHandler(@"桌宠正在思考");
    self.logHandler(@"TRANSCRIPT", transcript);
    NSString *systemFactReply = [self systemFactReplyForTranscript:transcript];
    if (systemFactReply != nil) {
        [self deliverReply:systemFactReply transcript:transcript source:@"macOS 系统时钟" speak:speak];
        return;
    }
    __weak REAIVoiceCompanionController *weakSelf = self;
    [self requestLocalAIReplyForTranscript:transcript
                        previousStatements:previousStatements
                                completion:^(NSString *reply, NSString *source) {
        REAIVoiceCompanionController *strongSelf = weakSelf;
        if (strongSelf == nil) return;
        NSString *finalReply = reply;
        if (finalReply.length == 0) {
            finalReply = [strongSelf replyToTranscript:transcript
                                     previousStatements:previousStatements];
            source = @"fallback";
        }
        finalReply = [strongSelf normalizePerspectiveInReply:finalReply transcript:transcript];
        [strongSelf deliverReply:finalReply transcript:transcript source:source speak:speak];
    }];
}

- (NSString *)systemFactReplyForTranscript:(NSString *)transcript {
    BOOL asksDate = [transcript containsString:@"今天几号"] ||
                    [transcript containsString:@"今天是多少号"] ||
                    [transcript containsString:@"今天的日期"] ||
                    [transcript containsString:@"今天日期"];
    BOOL asksTime = [transcript containsString:@"现在几点"] ||
                    [transcript containsString:@"现在的时间"] ||
                    [transcript containsString:@"现在时间"];
    if (!asksDate && !asksTime) return nil;
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    formatter.dateFormat = asksDate ? @"yyyy年M月d日，EEEE" : @"HH点mm分";
    NSString *value = [formatter stringFromDate:[NSDate date]];
    return asksDate ? [NSString stringWithFormat:@"今天是%@。", value]
                    : [NSString stringWithFormat:@"现在是%@。", value];
}

- (NSString *)normalizePerspectiveInReply:(NSString *)reply transcript:(NSString *)transcript {
    NSString *normalized = [reply stringByReplacingOccurrencesOfString:@"记住了，我"
                                                             withString:@"记住了，你"];
    BOOL asksOwnPreference = [transcript containsString:@"我喜欢"] ||
                             [transcript containsString:@"我的偏好"];
    if (asksOwnPreference && [normalized hasPrefix:@"我喜欢"]) {
        normalized = [@"你" stringByAppendingString:[normalized substringFromIndex:1]];
    } else if (asksOwnPreference && [normalized hasPrefix:@"我最喜欢"]) {
        normalized = [@"你" stringByAppendingString:[normalized substringFromIndex:1]];
    }
    BOOL asksOwnName = [transcript containsString:@"我叫什么"] ||
                       [transcript containsString:@"我的名字"];
    if (asksOwnName && [normalized hasPrefix:@"我叫"]) {
        normalized = [@"你" stringByAppendingString:[normalized substringFromIndex:1]];
    }
    return normalized;
}

- (void)deliverReply:(NSString *)reply
           transcript:(NSString *)transcript
               source:(NSString *)source
                speak:(BOOL)speak {
    [self persistUtterance:reply role:@"companion"];
    [self reloadConversationHistory];
    self.conversationView.transcriptLabel.stringValue = [NSString stringWithFormat:@"你：%@\n川仔：%@",
                                                       transcript, reply];
    self.conversationView.statusLabel.stringValue = @"REMEMBERED · 已写入本地记忆";
    self.statusHandler(@"桌宠已记住这句话");
    self.logHandler(@"COMPANION", [NSString stringWithFormat:@"%@ · %@", source, reply]);
    [self showTranscriptOverlayWithText:[NSString stringWithFormat:@"川仔：%@", reply]];
    if (speak) {
        [self speakReply:reply];
    } else if (![source isEqualToString:@"豆包端到端实时语音"]) {
        [self hideTranscriptOverlayAfterDelay:4.0];
    }
}

- (void)speakReply:(NSString *)reply {
    NSString *apiKey = reai_tts_api_key();
    if (apiKey.length == 0) {
        [self speakReplyWithSystemFallback:reply reason:@"未配置火山 Speech API Key"];
        return;
    }

    NSString *speaker = reai_trimmed_environment_value(@"REAI_TTS_SPEAKER");
    if (speaker.length == 0) speaker = REAITTSDefaultSpeaker;
    NSString *resourceID = reai_trimmed_environment_value(@"REAI_TTS_RESOURCE_ID");
    if (resourceID.length == 0) resourceID = REAITTSDefaultResourceID;
    NSDictionary *additions = @{
        @"post_process": @{@"pitch": @0},
        @"disable_markdown_filter": @YES,
        @"enable_latex_tn": @NO,
    };
    NSData *additionsData = [NSJSONSerialization dataWithJSONObject:additions options:0 error:nil];
    NSString *additionsJSON = [[NSString alloc] initWithData:additionsData
                                                    encoding:NSUTF8StringEncoding] ?: @"{}";
    NSDictionary *body = @{
        @"user": @{@"uid": @"reai-desktop-companion"},
        @"req_params": @{
            @"text": reply,
            @"speaker": speaker,
            @"sample_rate": @24000,
            @"audio_params": @{
                @"format": @"mp3",
                @"speech_rate": @0,
                @"loudness_rate": @0,
                @"bit_rate": @64000,
            },
            @"additions": additionsJSON,
        },
    };
    NSError *jsonError = nil;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonError];
    if (bodyData == nil) {
        [self speakReplyWithSystemFallback:reply reason:@"火山请求编码失败"];
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:
        @"https://openspeech.bytedance.com/api/v3/tts/unidirectional/sse"]
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:30.0];
    request.HTTPMethod = @"POST";
    request.HTTPBody = bodyData;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"text/event-stream" forHTTPHeaderField:@"Accept"];
    [request setValue:apiKey forHTTPHeaderField:@"X-Api-Key"];
    [request setValue:resourceID forHTTPHeaderField:@"X-Api-Resource-Id"];
    [request setValue:NSUUID.UUID.UUIDString forHTTPHeaderField:@"X-Api-Request-Id"];

    self.ttsGeneration += 1;
    NSUInteger generation = self.ttsGeneration;
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.timeoutIntervalForRequest = 30.0;
    configuration.timeoutIntervalForResource = 45.0;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
    __weak REAIVoiceCompanionController *weakSelf = self;
    self.ttsTask = [session dataTaskWithRequest:request
                              completionHandler:^(NSData *data,
                                                  NSURLResponse *response,
                                                  NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            REAIVoiceCompanionController *strongSelf = weakSelf;
            if (strongSelf == nil || generation != strongSelf.ttsGeneration) return;
            strongSelf.ttsTask = nil;
            NSHTTPURLResponse *httpResponse = [response isKindOfClass:NSHTTPURLResponse.class]
                ? (NSHTTPURLResponse *)response : nil;
            if (error != nil || httpResponse.statusCode < 200 || httpResponse.statusCode >= 300) {
                NSString *reason = error.localizedDescription ?: [NSString stringWithFormat:
                    @"火山 HTTP %ld", (long)httpResponse.statusCode];
                [strongSelf speakReplyWithSystemFallback:reply reason:reason];
                return;
            }
            NSString *apiError = nil;
            NSData *audio = reai_tts_audio_from_sse(data, &apiError);
            if (audio.length == 0) {
                [strongSelf speakReplyWithSystemFallback:reply
                                                   reason:apiError ?: @"火山未返回音频"];
                return;
            }
            NSError *playerError = nil;
            AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithData:audio error:&playerError];
            if (player == nil) {
                [strongSelf speakReplyWithSystemFallback:reply
                                                   reason:playerError.localizedDescription ?: @"音频解码失败"];
                return;
            }
            strongSelf.ttsPlayer = player;
            player.delegate = strongSelf;
            [player prepareToPlay];
            if ([player play]) {
                strongSelf.logHandler(@"TTS", [NSString stringWithFormat:
                    @"火山大模型 TTS 播放 · Vivi 2.0 · %lu bytes", (unsigned long)audio.length]);
            } else {
                [strongSelf speakReplyWithSystemFallback:reply reason:@"火山音频播放失败"];
            }
        });
    }];
    [self.ttsTask resume];
    self.logHandler(@"TTS", @"正在合成火山大模型音色 · Vivi 2.0");
}

- (void)speakReplyWithSystemFallback:(NSString *)reply reason:(NSString *)reason {
    self.logHandler(@"TTS", [NSString stringWithFormat:@"%@；改用 macOS 备用音色", reason]);
    AVSpeechUtterance *utterance = [AVSpeechUtterance speechUtteranceWithString:reply];
    utterance.voice = [AVSpeechSynthesisVoice voiceWithLanguage:@"zh-CN"];
    utterance.rate = 0.48f;
    utterance.pitchMultiplier = 1.08f;
    [self.speechSynthesizer speakUtterance:utterance];
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    if (player != self.ttsPlayer) return;
    self.ttsPlayer = nil;
    [self hideTranscriptOverlayAfterDelay:1.0];
    self.logHandler(@"TTS", flag ? @"AI 回复字幕随播报完成淡出" : @"TTS 播放中止，AI 回复字幕淡出");
}

- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer
 didFinishSpeechUtterance:(AVSpeechUtterance *)utterance {
    (void)synthesizer;
    (void)utterance;
    [self hideTranscriptOverlayAfterDelay:1.0];
}

- (void)requestLocalAIReplyForTranscript:(NSString *)transcript
                      previousStatements:(NSArray<NSString *> *)previousStatements
                              completion:(void (^)(NSString *reply, NSString *source))completion {
    NSString *memory = previousStatements.count > 0
        ? [[[previousStatements reverseObjectEnumerator] allObjects] componentsJoinedByString:@"；"]
        : @"暂无历史对话";
    NSString *systemPrompt = [NSString stringWithFormat:
        @"你是川仔，一只住在 macOS 桌面上的 3D 机械猫伙伴。"
         "你温和、机灵、有一点幽默，始终使用简体中文。"
         "回复限制为一到两句、80 个汉字以内，适合直接语音播报；不要使用 Markdown，"
         "不要展示思考过程。下面的过往记忆都是用户亲口说的话；复述用户的姓名、偏好"
         "和经历时必须使用‘你’，不能说成是你自己的。用户要求记住某件事时，简短确认"
         "‘记住了’。过往记忆：%@", memory];
    NSDictionary *body = @{
        @"model": @"qwen3:1.7b",
        @"stream": @NO,
        @"think": @NO,
        @"keep_alive": @"5m",
        @"messages": @[
            @{@"role": @"system", @"content": systemPrompt},
            @{@"role": @"user", @"content": transcript},
        ],
        @"options": @{@"temperature": @0.65, @"num_predict": @120},
    };
    NSError *jsonError = nil;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonError];
    if (bodyData == nil) {
        self.logHandler(@"MODEL", [NSString stringWithFormat:@"本地模型请求编码失败: %@",
                                    jsonError.localizedDescription ?: @"unknown"]);
        completion(nil, @"fallback");
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest
        requestWithURL:[NSURL URLWithString:@"http://127.0.0.1:11434/api/chat"]
           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
       timeoutInterval:45.0];
    request.HTTPMethod = @"POST";
    request.HTTPBody = bodyData;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
    __weak REAIVoiceCompanionController *weakSelf = self;
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
                                           completionHandler:^(NSData *data,
                                                               NSURLResponse *response,
                                                               NSError *error) {
        (void)response;
        NSString *reply = nil;
        if (data.length > 0 && error == nil) {
            NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            reply = payload[@"message"][@"content"];
            reply = [reply stringByTrimmingCharactersInSet:
                     NSCharacterSet.whitespaceAndNewlineCharacterSet];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (reply.length == 0) {
                NSString *reason = error.localizedDescription ?: @"模型未返回文字";
                weakSelf.logHandler(@"MODEL", [NSString stringWithFormat:@"qwen3:1.7b 不可用，使用回退回应: %@",
                                                reason]);
                completion(nil, @"fallback");
            } else {
                weakSelf.logHandler(@"MODEL", @"qwen3:1.7b 本地回复完成");
                completion(reply, @"qwen3:1.7b");
            }
        });
        [session finishTasksAndInvalidate];
    }];
    [task resume];
}

- (void)persistUtterance:(NSString *)utterance role:(NSString *)role {
    NSMutableArray<NSString *> *sentences = [NSMutableArray array];
    [utterance enumerateSubstringsInRange:NSMakeRange(0, utterance.length)
                                  options:NSStringEnumerationBySentences
                               usingBlock:^(NSString *substring, NSRange range,
                                            NSRange enclosingRange, BOOL *stop) {
        (void)range;
        (void)enclosingRange;
        (void)stop;
        NSString *sentence = [substring stringByTrimmingCharactersInSet:
                              NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (sentence.length > 0) [sentences addObject:sentence];
    }];
    if (sentences.count == 0) [sentences addObject:utterance];

    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    for (NSString *sentence in sentences) {
        NSDictionary *entry = @{
            @"timestamp": [formatter stringFromDate:[NSDate date]],
            @"role": role,
            @"text": sentence,
        };
        NSError *error = nil;
        NSData *json = [NSJSONSerialization dataWithJSONObject:entry options:0 error:&error];
        if (json == nil) {
            self.logHandler(@"ERROR", [NSString stringWithFormat:@"桌宠记忆编码失败: %@",
                                        error.localizedDescription ?: @"unknown"]);
            continue;
        }
        NSMutableData *line = [json mutableCopy];
        [line appendData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
        if (![[NSFileManager defaultManager] fileExistsAtPath:self.memoryPath]) {
            [NSData.data writeToFile:self.memoryPath atomically:YES];
        }
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:self.memoryPath];
        [handle seekToEndOfFile];
        [handle writeData:line];
        [handle closeFile];
    }
}

- (NSArray<NSString *> *)recentUserStatementsWithLimit:(NSUInteger)limit {
    NSData *data = [NSData dataWithContentsOfFile:self.memoryPath];
    if (data.length == 0) return @[];
    NSString *content = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSArray<NSString *> *lines = [content componentsSeparatedByCharactersInSet:
                                  NSCharacterSet.newlineCharacterSet];
    NSMutableArray<NSString *> *statements = [NSMutableArray array];
    for (NSString *line in lines.reverseObjectEnumerator) {
        if (line.length == 0) continue;
        NSData *lineData = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *entry = [NSJSONSerialization JSONObjectWithData:lineData options:0 error:nil];
        if ([entry[@"role"] isEqualToString:@"user"] && [entry[@"text"] length] > 0) {
            [statements addObject:entry[@"text"]];
            if (statements.count >= limit) break;
        }
    }
    return statements;
}

- (NSString *)replyToTranscript:(NSString *)transcript
             previousStatements:(NSArray<NSString *> *)previousStatements {
    if ([transcript containsString:@"你叫什么"] || [transcript containsString:@"你是谁"]) {
        return @"我叫川仔，是住在你桌面上的 REAI 伙伴。";
    }
    if ([transcript containsString:@"刚才说"] || [transcript containsString:@"记得什么"] ||
        [transcript containsString:@"说过什么"] || [transcript containsString:@"还记得"]) {
        if (previousStatements.count == 0) return @"这是我们记忆里的第一轮对话。";
        NSArray<NSString *> *ordered = [[previousStatements reverseObjectEnumerator] allObjects];
        NSCharacterSet *endingPunctuation = [NSCharacterSet characterSetWithCharactersInString:@"。！？!?；;，,"];
        NSMutableArray<NSString *> *cleaned = [NSMutableArray arrayWithCapacity:ordered.count];
        for (NSString *statement in ordered) {
            [cleaned addObject:[statement stringByTrimmingCharactersInSet:endingPunctuation]];
        }
        return [NSString stringWithFormat:@"我记得你说过：%@。",
                [cleaned componentsJoinedByString:@"；"]];
    }
    if ([transcript containsString:@"几点"] || [transcript containsString:@"时间"]) {
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
        formatter.dateFormat = @"HH 点 mm 分";
        return [NSString stringWithFormat:@"现在是 %@。", [formatter stringFromDate:[NSDate date]]];
    }
    if ([transcript containsString:@"你好"] || [transcript containsString:@"在吗"]) {
        return @"我在。按住语音键说话，我会一直听，也会一直记得。";
    }
    if ([transcript containsString:@"谢谢"]) return @"不用谢，我会把这段也好好记住。";
    if ([transcript hasSuffix:@"？"] || [transcript hasSuffix:@"?"]) {
        return [NSString stringWithFormat:@"我记住这个问题了：%@ 我们可以继续把它拆开聊。", transcript];
    }
    return [NSString stringWithFormat:@"记住了：%@ 你想接着聊哪一部分？", transcript];
}

@end
