#import <Cocoa/Cocoa.h>

typedef void (^REAIVoiceLogHandler)(NSString *level, NSString *message);
typedef void (^REAIVoiceStatusHandler)(NSString *status);

BOOL REAIVoiceCompanionRunTTSSelfTest(void);
BOOL REAIVoiceCompanionRunRealtimeTranscriptSelfTest(void);

@interface REAIVoiceCompanionController : NSObject
@property(nonatomic, readonly, getter=isRecording) BOOL recording;
@property(nonatomic, readonly, getter=isVisible) BOOL visible;
@property(nonatomic, readonly, copy) NSString *memoryPath;
- (instancetype)initWithLogHandler:(REAIVoiceLogHandler)logHandler
                     statusHandler:(REAIVoiceStatusHandler)statusHandler;
- (void)show;
- (void)hide;
- (void)toggleVisible;
- (void)showConversation;
- (void)configureVolcengineTTS;
- (void)voiceKeyPressed;
- (void)voiceKeyReleased;
- (void)cancelVoiceInteraction;
- (void)acceptTranscriptForTesting:(NSString *)transcript speak:(BOOL)speak;
- (void)acceptRealtimePCMForTesting:(NSData *)audioData;
@end
