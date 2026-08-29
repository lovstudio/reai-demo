#import "reai-mode-ui.h"

static NSFont *reai_font(NSString *name, CGFloat size, NSFontWeight fallbackWeight) {
    return [NSFont fontWithName:name size:size] ?: [NSFont systemFontOfSize:size weight:fallbackWeight];
}

static NSColor *reai_color(CGFloat red, CGFloat green, CGFloat blue, CGFloat alpha) {
    return [NSColor colorWithSRGBRed:red green:green blue:blue alpha:alpha];
}

@interface REAIModeSelectorView : NSView
@property(nonatomic, assign) REAIExperienceMode selectedMode;
@end

@implementation REAIModeSelectorView

- (BOOL)isOpaque {
    return NO;
}

- (void)drawModeCard:(NSRect)rect
                mode:(REAIExperienceMode)mode
               title:(NSString *)title
            subtitle:(NSString *)subtitle {
    BOOL selected = self.selectedMode == mode;
    NSColor *accent = mode == REAIExperienceModeMusic
        ? reai_color(0.24, 0.72, 0.98, 1.0)
        : (mode == REAIExperienceModeGame
            ? reai_color(1.00, 0.48, 0.22, 1.0)
            : reai_color(0.28, 0.84, 0.62, 1.0));
    NSBezierPath *card = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:24 yRadius:24];
    [reai_color(0.075, 0.085, 0.11, selected ? 0.98 : 0.78) setFill];
    [card fill];
    [selected ? accent : reai_color(0.28, 0.30, 0.35, 0.75) setStroke];
    card.lineWidth = selected ? 2.5 : 1.0;
    [card stroke];

    NSRect iconRect = NSMakeRect(NSMinX(rect) + 24, NSMaxY(rect) - 78, 52, 52);
    NSBezierPath *iconPlate = [NSBezierPath bezierPathWithRoundedRect:iconRect xRadius:16 yRadius:16];
    [[accent colorWithAlphaComponent:selected ? 0.22 : 0.10] setFill];
    [iconPlate fill];

    [accent setStroke];
    if (mode == REAIExperienceModeMusic) {
        CGFloat centerY = NSMidY(iconRect);
        for (NSInteger index = 0; index < 5; index++) {
            CGFloat x = NSMinX(iconRect) + 11 + index * 7.5;
            CGFloat height = index % 2 == 0 ? 14 : 26;
            NSBezierPath *bar = [NSBezierPath bezierPath];
            [bar moveToPoint:NSMakePoint(x, centerY - height / 2.0)];
            [bar lineToPoint:NSMakePoint(x, centerY + height / 2.0)];
            bar.lineWidth = 3.0;
            bar.lineCapStyle = NSLineCapStyleRound;
            [bar stroke];
        }
    } else if (mode == REAIExperienceModeGame) {
        NSRect brick = NSMakeRect(NSMinX(iconRect) + 10, NSMaxY(iconRect) - 19, 13, 7);
        for (NSInteger row = 0; row < 2; row++) {
            for (NSInteger column = 0; column < 2; column++) {
                NSRect cell = NSOffsetRect(brick, column * 16, -row * 10);
                [[NSBezierPath bezierPathWithRoundedRect:cell xRadius:2 yRadius:2] stroke];
            }
        }
        NSBezierPath *paddle = [NSBezierPath bezierPath];
        [paddle moveToPoint:NSMakePoint(NSMinX(iconRect) + 13, NSMinY(iconRect) + 10)];
        [paddle lineToPoint:NSMakePoint(NSMaxX(iconRect) - 13, NSMinY(iconRect) + 10)];
        paddle.lineWidth = 4.0;
        paddle.lineCapStyle = NSLineCapStyleRound;
        [paddle stroke];
    } else {
        NSRect outer = NSInsetRect(iconRect, 12, 12);
        NSRect inner = NSInsetRect(iconRect, 20, 20);
        NSBezierPath *gear = [NSBezierPath bezierPathWithOvalInRect:outer];
        gear.lineWidth = 3.0;
        [gear stroke];
        [[NSBezierPath bezierPathWithOvalInRect:inner] stroke];
        NSBezierPath *axis = [NSBezierPath bezierPath];
        [axis moveToPoint:NSMakePoint(NSMidX(iconRect), NSMinY(iconRect) + 6)];
        [axis lineToPoint:NSMakePoint(NSMidX(iconRect), NSMinY(iconRect) + 15)];
        [axis moveToPoint:NSMakePoint(NSMidX(iconRect), NSMaxY(iconRect) - 15)];
        [axis lineToPoint:NSMakePoint(NSMidX(iconRect), NSMaxY(iconRect) - 6)];
        [axis moveToPoint:NSMakePoint(NSMinX(iconRect) + 6, NSMidY(iconRect))];
        [axis lineToPoint:NSMakePoint(NSMinX(iconRect) + 15, NSMidY(iconRect))];
        [axis moveToPoint:NSMakePoint(NSMaxX(iconRect) - 15, NSMidY(iconRect))];
        [axis lineToPoint:NSMakePoint(NSMaxX(iconRect) - 6, NSMidY(iconRect))];
        axis.lineWidth = 3.0;
        axis.lineCapStyle = NSLineCapStyleRound;
        [axis stroke];
    }

    NSDictionary *titleAttributes = @{
        NSFontAttributeName: reai_font(@"AvenirNext-DemiBold", 24, NSFontWeightSemibold),
        NSForegroundColorAttributeName: NSColor.whiteColor
    };
    NSDictionary *subtitleAttributes = @{
        NSFontAttributeName: reai_font(@"AvenirNext-Medium", 13, NSFontWeightMedium),
        NSForegroundColorAttributeName: reai_color(0.64, 0.67, 0.73, 1.0)
    };
    [title drawAtPoint:NSMakePoint(NSMinX(rect) + 24, NSMinY(rect) + 58)
        withAttributes:titleAttributes];
    [subtitle drawAtPoint:NSMakePoint(NSMinX(rect) + 24, NSMinY(rect) + 32)
           withAttributes:subtitleAttributes];

    if (selected) {
        NSString *ready = @"READY";
        NSDictionary *readyAttributes = @{
            NSFontAttributeName: reai_font(@"Menlo-Bold", 10, NSFontWeightBold),
            NSForegroundColorAttributeName: accent
        };
        NSSize readySize = [ready sizeWithAttributes:readyAttributes];
        [ready drawAtPoint:NSMakePoint(NSMaxX(rect) - readySize.width - 22,
                                       NSMaxY(rect) - readySize.height - 22)
          withAttributes:readyAttributes];
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSRect bounds = self.bounds;
    NSBezierPath *background = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bounds, 1, 1)
                                                               xRadius:30
                                                               yRadius:30];
    NSGradient *gradient = [[NSGradient alloc]
        initWithStartingColor:reai_color(0.055, 0.060, 0.078, 0.99)
                  endingColor:reai_color(0.025, 0.028, 0.040, 0.99)];
    [gradient drawInBezierPath:background angle:-90];
    [reai_color(0.30, 0.33, 0.40, 0.55) setStroke];
    background.lineWidth = 1.0;
    [background stroke];

    NSDictionary *eyebrowAttributes = @{
        NSFontAttributeName: reai_font(@"Menlo-Bold", 10, NSFontWeightBold),
        NSForegroundColorAttributeName: reai_color(0.47, 0.75, 0.91, 1.0),
        NSKernAttributeName: @2.0
    };
    [@"REAI MODE SWITCHER" drawAtPoint:NSMakePoint(34, NSMaxY(bounds) - 50)
                         withAttributes:eyebrowAttributes];
    NSDictionary *headingAttributes = @{
        NSFontAttributeName: reai_font(@"AvenirNext-DemiBold", 31, NSFontWeightSemibold),
        NSForegroundColorAttributeName: NSColor.whiteColor
    };
    [@"选择模式" drawAtPoint:NSMakePoint(32, NSMaxY(bounds) - 94)
                    withAttributes:headingAttributes];

    CGFloat gap = 14;
    CGFloat cardWidth = (NSWidth(bounds) - 64 - gap * 2.0) / 3.0;
    NSRect musicRect = NSMakeRect(32, 68, cardWidth, 176);
    NSRect gameRect = NSOffsetRect(musicRect, cardWidth + gap, 0);
    NSRect settingsRect = NSOffsetRect(gameRect, cardWidth + gap, 0);
    [self drawModeCard:musicRect
                  mode:REAIExperienceModeMusic
                 title:@"音乐"
              subtitle:@"推杆选台 · Action 播放"];
    [self drawModeCard:gameRect
                  mode:REAIExperienceModeGame
                 title:@"游戏"
              subtitle:@"旋钮挡板 · 推杆速度"];
    [self drawModeCard:settingsRect
                  mode:REAIExperienceModeSettings
                 title:@"设置"
              subtitle:@"蓝牙与桌宠"];

    NSDictionary *hintAttributes = @{
        NSFontAttributeName: reai_font(@"Menlo", 11, NSFontWeightRegular),
        NSForegroundColorAttributeName: reai_color(0.54, 0.57, 0.63, 1.0)
    };
    NSString *hint = @"TAB  切换       ENTER  进入       ESC  返回";
    NSSize hintSize = [hint sizeWithAttributes:hintAttributes];
    [hint drawAtPoint:NSMakePoint(NSMidX(bounds) - hintSize.width / 2.0, 29)
       withAttributes:hintAttributes];

    NSDictionary *creditAttributes = @{
        NSFontAttributeName: reai_font(@"AvenirNext-Medium", 9, NSFontWeightMedium),
        NSForegroundColorAttributeName: reai_color(0.42, 0.45, 0.51, 1.0)
    };
    NSString *credit = @"Powered by LovStudio.ai（手工川工作室）";
    NSSize creditSize = [credit sizeWithAttributes:creditAttributes];
    CGFloat creditY = 13;
    CGFloat logoSize = 13;
    CGFloat logoGap = 6;
    CGFloat logoX = NSMaxX(bounds) - logoSize - 30;
    CGFloat creditX = logoX - logoGap - creditSize.width;
    CGFloat logoY = creditY + (creditSize.height - logoSize) / 2.0 + 1.0;
    NSString *logoPath = [[NSBundle mainBundle] pathForResource:@"lovstudio-logo" ofType:@"svg"];
    NSImage *logo = logoPath == nil ? nil : [[NSImage alloc] initWithContentsOfFile:logoPath];
    if (logo != nil) {
        [logo drawInRect:NSMakeRect(logoX, logoY, logoSize, logoSize)
                fromRect:NSZeroRect
               operation:NSCompositingOperationSourceOver
                fraction:0.90
          respectFlipped:NO
                   hints:nil];
    }
    [credit drawAtPoint:NSMakePoint(creditX, creditY)
         withAttributes:creditAttributes];
}

@end

@interface REAISettingsView : NSView
@property(nonatomic, assign) BOOL desktopPetEnabled;
@property(nonatomic, assign) BOOL voiceConversationEnabled;
@property(nonatomic, assign) BOOL bluetoothAutoConnectEnabled;
@property(nonatomic, assign) REAISettingsRow selectedRow;
@property(nonatomic, assign) BOOL forgetConfirmation;
@property(nonatomic, copy) NSString *connectionStatus;
@property(nonatomic, copy) NSString *deviceName;
@end

@implementation REAISettingsView

- (BOOL)isOpaque { return NO; }

- (void)drawToggleInRect:(NSRect)rect enabled:(BOOL)enabled accent:(NSColor *)accent {
    NSBezierPath *toggle = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:18 yRadius:18];
    [enabled ? accent : reai_color(0.20, 0.23, 0.28, 1.0) setFill];
    [toggle fill];
    CGFloat knobX = enabled ? NSMaxX(rect) - 18 : NSMinX(rect) + 18;
    [NSColor.whiteColor setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(knobX - 13, NSMidY(rect) - 13, 26, 26)] fill];
}

- (void)drawActionRow:(NSRect)rect
                   row:(REAISettingsRow)row
                 title:(NSString *)title
                  body:(NSString *)body
             accessory:(NSString *)accessory
                danger:(BOOL)danger {
    BOOL selected = self.selectedRow == row;
    NSColor *accent = danger
        ? reai_color(1.00, 0.43, 0.38, 1.0)
        : reai_color(0.28, 0.84, 0.62, 1.0);
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:18 yRadius:18];
    [reai_color(0.075, 0.088, 0.105, selected ? 0.98 : 0.82) setFill];
    [path fill];
    [selected ? accent : reai_color(0.24, 0.28, 0.32, 0.82) setStroke];
    path.lineWidth = selected ? 2.0 : 1.0;
    [path stroke];

    NSDictionary *titleAttributes = @{
        NSFontAttributeName: reai_font(@"AvenirNext-DemiBold", 17, NSFontWeightSemibold),
        NSForegroundColorAttributeName: danger && self.forgetConfirmation ? accent : NSColor.whiteColor
    };
    NSDictionary *bodyAttributes = @{
        NSFontAttributeName: reai_font(@"AvenirNext-Medium", 12, NSFontWeightMedium),
        NSForegroundColorAttributeName: reai_color(0.60, 0.64, 0.70, 1.0)
    };
    [title drawAtPoint:NSMakePoint(NSMinX(rect) + 22, NSMaxY(rect) - 31)
        withAttributes:titleAttributes];
    [body drawAtPoint:NSMakePoint(NSMinX(rect) + 22, NSMinY(rect) + 13)
       withAttributes:bodyAttributes];

    NSDictionary *accessoryAttributes = @{
        NSFontAttributeName: reai_font(@"Menlo-Bold", 11, NSFontWeightBold),
        NSForegroundColorAttributeName: selected ? accent : reai_color(0.50, 0.54, 0.61, 1.0)
    };
    NSSize accessorySize = [accessory sizeWithAttributes:accessoryAttributes];
    [accessory drawAtPoint:NSMakePoint(NSMaxX(rect) - accessorySize.width - 22,
                                       NSMidY(rect) - accessorySize.height / 2.0)
          withAttributes:accessoryAttributes];
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSRect bounds = self.bounds;
    NSBezierPath *background = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bounds, 1, 1)
                                                               xRadius:30
                                                               yRadius:30];
    NSGradient *gradient = [[NSGradient alloc]
        initWithStartingColor:reai_color(0.050, 0.064, 0.072, 0.99)
                  endingColor:reai_color(0.025, 0.030, 0.040, 0.99)];
    [gradient drawInBezierPath:background angle:-90];
    [reai_color(0.28, 0.84, 0.62, 0.45) setStroke];
    [background stroke];

    NSDictionary *eyebrow = @{
        NSFontAttributeName: reai_font(@"Menlo-Bold", 10, NSFontWeightBold),
        NSForegroundColorAttributeName: reai_color(0.28, 0.84, 0.62, 1.0),
        NSKernAttributeName: @2.0
    };
    [@"REAI SETTINGS" drawAtPoint:NSMakePoint(34, NSMaxY(bounds) - 50)
                    withAttributes:eyebrow];
    NSDictionary *heading = @{
        NSFontAttributeName: reai_font(@"AvenirNext-DemiBold", 31, NSFontWeightSemibold),
        NSForegroundColorAttributeName: NSColor.whiteColor
    };
    [@"设置" drawAtPoint:NSMakePoint(32, NSMaxY(bounds) - 94) withAttributes:heading];

    NSColor *accent = reai_color(0.28, 0.84, 0.62, 1.0);
    NSRect deviceCard = NSMakeRect(32, 461, NSWidth(bounds) - 64, 82);
    NSBezierPath *devicePath = [NSBezierPath bezierPathWithRoundedRect:deviceCard xRadius:20 yRadius:20];
    [[accent colorWithAlphaComponent:0.10] setFill];
    [devicePath fill];
    [[accent colorWithAlphaComponent:0.42] setStroke];
    [devicePath stroke];
    NSDictionary *deviceLabel = @{
        NSFontAttributeName: reai_font(@"Menlo-Bold", 10, NSFontWeightBold),
        NSForegroundColorAttributeName: accent,
        NSKernAttributeName: @1.2
    };
    [@"BLUETOOTH DEVICE" drawAtPoint:NSMakePoint(54, 514) withAttributes:deviceLabel];
    NSDictionary *deviceNameAttributes = @{
        NSFontAttributeName: reai_font(@"AvenirNext-DemiBold", 19, NSFontWeightSemibold),
        NSForegroundColorAttributeName: NSColor.whiteColor
    };
    NSString *deviceName = self.deviceName.length > 0 ? self.deviceName : @"尚未配对设备";
    [deviceName drawAtPoint:NSMakePoint(54, 481) withAttributes:deviceNameAttributes];
    NSDictionary *statusAttributes = @{
        NSFontAttributeName: reai_font(@"AvenirNext-Medium", 12, NSFontWeightMedium),
        NSForegroundColorAttributeName: reai_color(0.66, 0.71, 0.76, 1.0)
    };
    NSString *status = self.connectionStatus.length > 0 ? self.connectionStatus : @"蓝牙状态未知";
    NSSize statusSize = [status sizeWithAttributes:statusAttributes];
    [status drawAtPoint:NSMakePoint(NSMaxX(deviceCard) - statusSize.width - 22, 490)
         withAttributes:statusAttributes];

    CGFloat rowX = 32;
    CGFloat rowWidth = NSWidth(bounds) - 64;
    NSRect autoRow = NSMakeRect(rowX, 380, rowWidth, 66);
    [self drawActionRow:autoRow
                    row:REAISettingsRowBluetoothAutoConnect
                  title:@"蓝牙自动连接"
                   body:@"拔下 USB 后自动连接上次使用的 REAI Vibe Board"
              accessory:@""
                 danger:NO];
    [self drawToggleInRect:NSMakeRect(NSMaxX(autoRow) - 82, NSMidY(autoRow) - 17, 62, 34)
                    enabled:self.bluetoothAutoConnectEnabled
                     accent:accent];
    [self drawActionRow:NSMakeRect(rowX, 304, rowWidth, 66)
                    row:REAISettingsRowBluetoothReconnect
                  title:@"重新扫描 / 连接"
                   body:@"立即查找并连接已记住或附近的 REAI 设备"
              accessory:@"ENTER"
                 danger:NO];
    NSString *forgetTitle = self.forgetConfirmation ? @"再次按下以确认忘记" : @"忘记蓝牙设备";
    NSString *forgetBody = self.forgetConfirmation
        ? @"将清除设备记录并关闭自动连接"
        : @"清除当前设备记录；之后可重新扫描连接";
    [self drawActionRow:NSMakeRect(rowX, 228, rowWidth, 66)
                    row:REAISettingsRowBluetoothForget
                  title:forgetTitle
                   body:forgetBody
              accessory:self.forgetConfirmation ? @"CONFIRM" : @"ENTER"
                 danger:YES];
    NSRect petRow = NSMakeRect(rowX, 152, rowWidth, 66);
    [self drawActionRow:petRow
                    row:REAISettingsRowDesktopPet
                  title:@"桌宠桌面显示"
                   body:@"只控制川仔是否常驻桌面，不影响语音对话"
              accessory:@""
                 danger:NO];
    [self drawToggleInRect:NSMakeRect(NSMaxX(petRow) - 82, NSMidY(petRow) - 17, 62, 34)
                    enabled:self.desktopPetEnabled
                     accent:accent];
    NSRect voiceRow = NSMakeRect(rowX, 76, rowWidth, 66);
    [self drawActionRow:voiceRow
                    row:REAISettingsRowVoiceConversation
                  title:@"语音对话"
                   body:@"只控制语音键录音、转录与 AI 回复"
              accessory:@""
                 danger:NO];
    [self drawToggleInRect:NSMakeRect(NSMaxX(voiceRow) - 82, NSMidY(voiceRow) - 17, 62, 34)
                    enabled:self.voiceConversationEnabled
                     accent:accent];

    NSDictionary *hint = @{
        NSFontAttributeName: reai_font(@"Menlo", 11, NSFontWeightRegular),
        NSForegroundColorAttributeName: reai_color(0.54, 0.57, 0.63, 1.0)
    };
    NSString *hintText = @"旋钮  选择    ENTER / ACTION  应用    TAB  App    ESC  返回";
    NSSize hintSize = [hintText sizeWithAttributes:hint];
    [hintText drawAtPoint:NSMakePoint(NSMidX(bounds) - hintSize.width / 2.0, 34)
           withAttributes:hint];
}

@end

@interface REAIBrickBreakerView : NSView
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, strong) NSMutableArray<NSValue *> *bricks;
@property(nonatomic, assign) NSPoint ballPosition;
@property(nonatomic, assign) NSPoint ballVelocity;
@property(nonatomic, assign) CGFloat paddleX;
@property(nonatomic, assign) NSInteger score;
@property(nonatomic, assign) NSInteger lives;
@property(nonatomic, assign) BOOL ballLaunched;
@property(nonatomic, assign) BOOL paused;
@property(nonatomic, assign) CGFloat speedMultiplier;
@property(nonatomic, copy) NSString *speedLabel;
@end

@implementation REAIBrickBreakerView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self != nil) {
        self.wantsLayer = YES;
        self.lives = 3;
        self.paused = YES;
        self.speedMultiplier = 1.0;
        self.speedLabel = @"NORMAL";
        self.bricks = [NSMutableArray array];
        [self resetLevel];
        self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 60.0
                                                      target:self
                                                    selector:@selector(step:)
                                                    userInfo:nil
                                                     repeats:YES];
    }
    return self;
}

- (void)dealloc {
    [self.timer invalidate];
}

- (BOOL)isOpaque {
    return YES;
}

- (void)resetLevel {
    [self.bricks removeAllObjects];
    CGFloat width = NSWidth(self.bounds) > 0 ? NSWidth(self.bounds) : 780;
    CGFloat brickWidth = (width - 92) / 10.0;
    for (NSInteger row = 0; row < 5; row++) {
        for (NSInteger column = 0; column < 10; column++) {
            CGFloat x = 36 + column * (brickWidth + 2);
            CGFloat y = 300 + row * 29;
            [self.bricks addObject:[NSValue valueWithRect:NSMakeRect(x, y, brickWidth, 21)]];
        }
    }
    self.paddleX = width / 2.0;
    self.ballLaunched = NO;
    self.ballPosition = NSMakePoint(self.paddleX, 72);
    self.ballVelocity = NSMakePoint(4.3 * self.speedMultiplier,
                                    5.1 * self.speedMultiplier);
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    if (self.bricks.count == 0) [self resetLevel];
}

- (void)movePaddleBy:(CGFloat)delta {
    CGFloat halfPaddle = 58;
    self.paddleX = MAX(halfPaddle + 24,
                       MIN(NSWidth(self.bounds) - halfPaddle - 24, self.paddleX + delta));
    if (!self.ballLaunched) self.ballPosition = NSMakePoint(self.paddleX, 72);
    [self setNeedsDisplay:YES];
}

- (void)setSpeedMultiplier:(CGFloat)multiplier label:(NSString *)label {
    CGFloat oldMultiplier = self.speedMultiplier > 0 ? self.speedMultiplier : 1.0;
    CGFloat newMultiplier = MAX(0.5, MIN(1.8, multiplier));
    CGFloat ratio = newMultiplier / oldMultiplier;
    self.ballVelocity = NSMakePoint(self.ballVelocity.x * ratio,
                                    self.ballVelocity.y * ratio);
    self.speedMultiplier = newMultiplier;
    self.speedLabel = [label copy];
    [self setNeedsDisplay:YES];
}

- (void)toggleAction {
    if (!self.ballLaunched) {
        self.ballLaunched = YES;
        self.paused = NO;
    } else {
        self.paused = !self.paused;
    }
    [self setNeedsDisplay:YES];
}

- (void)pause {
    self.paused = YES;
    [self setNeedsDisplay:YES];
}

- (void)step:(NSTimer *)timer {
    (void)timer;
    CGFloat halfPaddle = 58;
    if (!self.ballLaunched) {
        self.ballPosition = NSMakePoint(self.paddleX, 72);
    }
    if (self.paused || !self.ballLaunched) {
        [self setNeedsDisplay:YES];
        return;
    }

    self.ballPosition = NSMakePoint(self.ballPosition.x + self.ballVelocity.x,
                                    self.ballPosition.y + self.ballVelocity.y);
    if (self.ballPosition.x <= 13 || self.ballPosition.x >= NSWidth(self.bounds) - 13) {
        self.ballVelocity = NSMakePoint(-self.ballVelocity.x, self.ballVelocity.y);
        self.ballPosition = NSMakePoint(MAX(13, MIN(NSWidth(self.bounds) - 13, self.ballPosition.x)),
                                        self.ballPosition.y);
    }
    if (self.ballPosition.y >= NSHeight(self.bounds) - 13) {
        self.ballVelocity = NSMakePoint(self.ballVelocity.x, -fabs(self.ballVelocity.y));
    }

    NSRect ballRect = NSMakeRect(self.ballPosition.x - 7, self.ballPosition.y - 7, 14, 14);
    NSRect paddleRect = NSMakeRect(self.paddleX - halfPaddle, 48, halfPaddle * 2, 14);
    if (self.ballVelocity.y < 0 && NSIntersectsRect(ballRect, paddleRect)) {
        CGFloat offset = (self.ballPosition.x - self.paddleX) / halfPaddle;
        self.ballVelocity = NSMakePoint(offset * 6.2 * self.speedMultiplier,
                                        fabs(self.ballVelocity.y));
        self.ballPosition = NSMakePoint(self.ballPosition.x, NSMaxY(paddleRect) + 8);
    }

    for (NSInteger index = self.bricks.count - 1; index >= 0; index--) {
        NSRect brick = self.bricks[index].rectValue;
        if (NSIntersectsRect(ballRect, brick)) {
            [self.bricks removeObjectAtIndex:index];
            self.ballVelocity = NSMakePoint(self.ballVelocity.x, -self.ballVelocity.y);
            self.score += 100;
            break;
        }
    }

    if (self.ballPosition.y < -10) {
        self.lives -= 1;
        if (self.lives <= 0) {
            self.lives = 3;
            self.score = 0;
            [self resetLevel];
        } else {
            self.ballLaunched = NO;
            self.paused = YES;
            self.ballPosition = NSMakePoint(self.paddleX, 72);
        }
    } else if (self.bricks.count == 0) {
        [self resetLevel];
        self.score += 500;
    }
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    [reai_color(0.025, 0.030, 0.045, 1.0) setFill];
    NSRectFill(self.bounds);

    [reai_color(0.15, 0.18, 0.23, 0.28) setStroke];
    for (CGFloat x = 20; x < NSWidth(self.bounds); x += 40) {
        NSBezierPath *line = [NSBezierPath bezierPath];
        [line moveToPoint:NSMakePoint(x, 0)];
        [line lineToPoint:NSMakePoint(x, NSHeight(self.bounds))];
        [line stroke];
    }
    for (CGFloat y = 20; y < NSHeight(self.bounds); y += 40) {
        NSBezierPath *line = [NSBezierPath bezierPath];
        [line moveToPoint:NSMakePoint(0, y)];
        [line lineToPoint:NSMakePoint(NSWidth(self.bounds), y)];
        [line stroke];
    }

    NSDictionary *eyebrow = @{
        NSFontAttributeName: reai_font(@"Menlo-Bold", 10, NSFontWeightBold),
        NSForegroundColorAttributeName: reai_color(1.0, 0.50, 0.22, 1.0),
        NSKernAttributeName: @2.0
    };
    [@"REAI ARCADE / BRICK 01" drawAtPoint:NSMakePoint(26, NSHeight(self.bounds) - 38)
                             withAttributes:eyebrow];
    NSDictionary *hud = @{
        NSFontAttributeName: reai_font(@"Menlo-Bold", 12, NSFontWeightBold),
        NSForegroundColorAttributeName: reai_color(0.75, 0.79, 0.86, 1.0)
    };
    NSString *scoreText = [NSString stringWithFormat:@"SCORE %05ld      LIVES %ld      SPEED %@",
                           (long)self.score, (long)self.lives, self.speedLabel];
    NSSize scoreSize = [scoreText sizeWithAttributes:hud];
    [scoreText drawAtPoint:NSMakePoint(NSWidth(self.bounds) - scoreSize.width - 26,
                                       NSHeight(self.bounds) - 39)
          withAttributes:hud];

    NSArray<NSColor *> *rowColors = @[
        reai_color(0.25, 0.72, 0.98, 1.0),
        reai_color(0.22, 0.82, 0.70, 1.0),
        reai_color(0.96, 0.76, 0.27, 1.0),
        reai_color(1.0, 0.49, 0.23, 1.0),
        reai_color(0.76, 0.39, 0.94, 1.0)
    ];
    for (NSValue *value in self.bricks) {
        NSRect brick = value.rectValue;
        NSInteger row = MAX(0, MIN(4, (NSInteger)((brick.origin.y - 300) / 29)));
        NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:brick xRadius:5 yRadius:5];
        [rowColors[row] setFill];
        [shape fill];
        [[[rowColors[row] blendedColorWithFraction:0.35 ofColor:NSColor.whiteColor]
            colorWithAlphaComponent:0.65] setStroke];
        [shape stroke];
    }

    NSRect paddleRect = NSMakeRect(self.paddleX - 58, 48, 116, 14);
    NSBezierPath *paddle = [NSBezierPath bezierPathWithRoundedRect:paddleRect xRadius:7 yRadius:7];
    [reai_color(0.88, 0.93, 1.0, 1.0) setFill];
    [paddle fill];
    NSRect ballRect = NSMakeRect(self.ballPosition.x - 7, self.ballPosition.y - 7, 14, 14);
    [reai_color(1.0, 0.83, 0.32, 1.0) setFill];
    [[NSBezierPath bezierPathWithOvalInRect:ballRect] fill];

    NSDictionary *hint = @{
        NSFontAttributeName: reai_font(@"Menlo", 11, NSFontWeightRegular),
        NSForegroundColorAttributeName: reai_color(0.53, 0.57, 0.64, 1.0)
    };
    NSString *hintText = @"旋钮 LEFT / RIGHT    推杆 SLOW / NORMAL / FAST    ACTION 发球 / 暂停    ESC 返回";
    NSSize hintSize = [hintText sizeWithAttributes:hint];
    [hintText drawAtPoint:NSMakePoint(NSMidX(self.bounds) - hintSize.width / 2.0, 18)
           withAttributes:hint];

    if (self.paused) {
        NSRect badgeRect = NSMakeRect(NSMidX(self.bounds) - 110, 202, 220, 58);
        NSBezierPath *badge = [NSBezierPath bezierPathWithRoundedRect:badgeRect xRadius:18 yRadius:18];
        [reai_color(0.035, 0.042, 0.060, 0.92) setFill];
        [badge fill];
        [reai_color(0.38, 0.43, 0.52, 0.85) setStroke];
        [badge stroke];
        NSString *state = self.ballLaunched ? @"PAUSED · ACTION 继续" : @"READY · ACTION 发球";
        NSDictionary *stateAttributes = @{
            NSFontAttributeName: reai_font(@"AvenirNext-DemiBold", 15, NSFontWeightSemibold),
            NSForegroundColorAttributeName: NSColor.whiteColor
        };
        NSSize stateSize = [state sizeWithAttributes:stateAttributes];
        [state drawAtPoint:NSMakePoint(NSMidX(self.bounds) - stateSize.width / 2.0,
                                       NSMidY(badgeRect) - stateSize.height / 2.0)
          withAttributes:stateAttributes];
    }
}

@end

@interface REAIModeOverlayController ()
@property(nonatomic, strong) NSPanel *panel;
@property(nonatomic, strong) REAIModeSelectorView *selectorView;
@property(nonatomic, strong) REAIBrickBreakerView *gameView;
@property(nonatomic, strong) REAISettingsView *settingsView;
@property(nonatomic, readwrite) BOOL showingSelector;
@property(nonatomic, readwrite) BOOL showingGame;
@property(nonatomic, readwrite) BOOL showingSettings;
@end

@implementation REAIModeOverlayController

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        self.panel = [[NSPanel alloc]
            initWithContentRect:NSMakeRect(0, 0, 780, 360)
                      styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                        backing:NSBackingStoreBuffered
                          defer:NO];
        self.panel.backgroundColor = NSColor.clearColor;
        self.panel.opaque = NO;
        self.panel.hasShadow = YES;
        self.panel.level = NSFloatingWindowLevel;
        self.panel.hidesOnDeactivate = NO;
        self.panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                        NSWindowCollectionBehaviorFullScreenAuxiliary;
        self.selectorView = [[REAIModeSelectorView alloc] initWithFrame:NSMakeRect(0, 0, 780, 360)];
        self.gameView = [[REAIBrickBreakerView alloc] initWithFrame:NSMakeRect(0, 0, 780, 500)];
        self.settingsView = [[REAISettingsView alloc] initWithFrame:NSMakeRect(0, 0, 720, 646)];
        self.settingsView.selectedRow = REAISettingsRowBluetoothAutoConnect;
    }
    return self;
}

- (void)showSelectorWithMode:(REAIExperienceMode)mode {
    [NSApp unhideWithoutActivation];
    [self.gameView pause];
    self.selectorView.selectedMode = mode;
    [self.selectorView setNeedsDisplay:YES];
    [self.panel setContentSize:NSMakeSize(780, 360)];
    self.panel.contentView = self.selectorView;
    [self.panel center];
    [self.panel orderFrontRegardless];
    self.showingSelector = YES;
    self.showingGame = NO;
    self.showingSettings = NO;
}

- (void)showGame {
    [NSApp unhideWithoutActivation];
    [self.panel setContentSize:NSMakeSize(780, 500)];
    self.panel.contentView = self.gameView;
    [self.panel center];
    [self.panel orderFrontRegardless];
    self.showingSelector = NO;
    self.showingGame = YES;
    self.showingSettings = NO;
    [self.gameView setNeedsDisplay:YES];
}

- (void)showSettingsWithDesktopPetEnabled:(BOOL)desktopPetEnabled
                 voiceConversationEnabled:(BOOL)voiceConversationEnabled
                bluetoothAutoConnectEnabled:(BOOL)bluetoothAutoConnectEnabled
                           connectionStatus:(NSString *)connectionStatus
                                 deviceName:(NSString *)deviceName {
    [NSApp unhideWithoutActivation];
    [self.gameView pause];
    [self updateSettingsWithDesktopPetEnabled:desktopPetEnabled
                  voiceConversationEnabled:voiceConversationEnabled
                  bluetoothAutoConnectEnabled:bluetoothAutoConnectEnabled
                             connectionStatus:connectionStatus
                                   deviceName:deviceName];
    [self.settingsView setNeedsDisplay:YES];
    [self.panel setContentSize:NSMakeSize(720, 646)];
    self.panel.contentView = self.settingsView;
    [self.panel center];
    [self.panel orderFrontRegardless];
    self.showingSelector = NO;
    self.showingGame = NO;
    self.showingSettings = YES;
}

- (void)updateSettingsWithDesktopPetEnabled:(BOOL)desktopPetEnabled
                   voiceConversationEnabled:(BOOL)voiceConversationEnabled
                  bluetoothAutoConnectEnabled:(BOOL)bluetoothAutoConnectEnabled
                             connectionStatus:(NSString *)connectionStatus
                                   deviceName:(NSString *)deviceName {
    self.settingsView.desktopPetEnabled = desktopPetEnabled;
    self.settingsView.voiceConversationEnabled = voiceConversationEnabled;
    self.settingsView.bluetoothAutoConnectEnabled = bluetoothAutoConnectEnabled;
    self.settingsView.connectionStatus = connectionStatus ?: @"蓝牙状态未知";
    self.settingsView.deviceName = deviceName ?: @"";
    [self.settingsView setNeedsDisplay:YES];
}

- (void)setDesktopPetEnabled:(BOOL)enabled {
    self.settingsView.desktopPetEnabled = enabled;
    [self.settingsView setNeedsDisplay:YES];
}

- (void)setVoiceConversationEnabled:(BOOL)enabled {
    self.settingsView.voiceConversationEnabled = enabled;
    [self.settingsView setNeedsDisplay:YES];
}

- (void)moveSettingsSelectionBy:(NSInteger)delta {
    NSInteger count = REAISettingsRowVoiceConversation + 1;
    NSInteger selected = (self.settingsView.selectedRow + delta) % count;
    if (selected < 0) selected += count;
    self.settingsView.selectedRow = (REAISettingsRow)selected;
    self.settingsView.forgetConfirmation = NO;
    [self.settingsView setNeedsDisplay:YES];
}

- (REAISettingsRow)selectedSettingsRow {
    return self.settingsView.selectedRow;
}

- (void)setSettingsForgetConfirmation:(BOOL)confirmation {
    self.settingsView.forgetConfirmation = confirmation;
    [self.settingsView setNeedsDisplay:YES];
}

- (void)hide {
    [self.gameView pause];
    [self.panel orderOut:nil];
    self.showingSelector = NO;
    self.showingGame = NO;
    self.showingSettings = NO;
}

- (void)moveGamePaddleBy:(CGFloat)delta {
    [self.gameView movePaddleBy:delta];
}

- (void)setGameSpeedMultiplier:(CGFloat)multiplier label:(NSString *)label {
    [self.gameView setSpeedMultiplier:multiplier label:label];
}

- (void)toggleGameAction {
    [self.gameView toggleAction];
}

@end

BOOL REAIRenderSettingsPreview(NSString *path) {
    NSRect frame = NSMakeRect(0, 0, 720, 646);
    REAISettingsView *view = [[REAISettingsView alloc] initWithFrame:frame];
    view.desktopPetEnabled = YES;
    view.voiceConversationEnabled = NO;
    view.bluetoothAutoConnectEnabled = YES;
    view.selectedRow = REAISettingsRowBluetoothReconnect;
    view.connectionStatus = @"蓝牙已连接";
    view.deviceName = @"REAI_VB_1C26E52A";
    NSBitmapImageRep *bitmap = [view bitmapImageRepForCachingDisplayInRect:frame];
    if (bitmap == nil) return NO;
    [view cacheDisplayInRect:frame toBitmapImageRep:bitmap];
    NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    return png != nil && [png writeToFile:path atomically:YES];
}
