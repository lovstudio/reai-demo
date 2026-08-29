#import "reai-bluetooth-bridge.h"

#import <CoreBluetooth/CoreBluetooth.h>

static NSString *const REAIBLEDevicePrefix = @"REAI_VB_";
static NSString *const REAIBLEPeripheralIdentifierDefaultsKey = @"ble-peripheral-identifier";
static NSString *const REAIBLEPeripheralNameDefaultsKey = @"ble-peripheral-name";
static NSString *const REAIBLEAutoConnectDefaultsKey = @"ble-auto-connect-enabled";

static CBUUID *reai_service_uuid(void) {
    return [CBUUID UUIDWithString:@"00000000-0000-0000-0000-00000000FE60"];
}

static CBUUID *reai_command_uuid(void) {
    return [CBUUID UUIDWithString:@"00000000-0000-0000-0000-00000000FE61"];
}

static CBUUID *reai_event_uuid(void) {
    return [CBUUID UUIDWithString:@"00000000-0000-0000-0000-00000000FE62"];
}

static BOOL reai_decode_event(NSData *data,
                              uint8_t *command,
                              const uint8_t **payload,
                              NSUInteger *payloadLength) {
    if (data.length < 2) return NO;
    const uint8_t *bytes = data.bytes;
    NSUInteger length = bytes[1];
    if (data.length < length + 2) return NO;
    if (command != NULL) *command = bytes[0];
    if (payload != NULL) *payload = bytes + 2;
    if (payloadLength != NULL) *payloadLength = length;
    return YES;
}

@interface REAIBluetoothBridge () <CBCentralManagerDelegate, CBPeripheralDelegate>
@property(nonatomic, copy) REAIBluetoothConsumerHandler consumerHandler;
@property(nonatomic, copy) REAIBluetoothModeHandler modeHandler;
@property(nonatomic, copy) REAIBluetoothConnectionHandler connectionHandler;
@property(nonatomic, copy) REAIBluetoothLogHandler logHandler;
@property(nonatomic, strong) CBCentralManager *centralManager;
@property(nonatomic, strong) CBPeripheral *peripheral;
@property(nonatomic, strong) CBCharacteristic *commandCharacteristic;
@property(nonatomic, strong) CBCharacteristic *eventCharacteristic;
@property(nonatomic, assign) BOOL started;
@property(nonatomic, assign) BOOL stopping;
@property(nonatomic, assign) BOOL usbConnected;
@property(nonatomic, assign) BOOL scanning;
@property(nonatomic, assign) BOOL manualConnectRequested;
@property(nonatomic, assign) NSUInteger scanGeneration;
@end

@implementation REAIBluetoothBridge

- (instancetype)initWithConsumerHandler:(REAIBluetoothConsumerHandler)consumerHandler
                             modeHandler:(REAIBluetoothModeHandler)modeHandler
                       connectionHandler:(REAIBluetoothConnectionHandler)connectionHandler
                              logHandler:(REAIBluetoothLogHandler)logHandler {
    self = [super init];
    if (self != nil) {
        _consumerHandler = [consumerHandler copy];
        _modeHandler = [modeHandler copy];
        _connectionHandler = [connectionHandler copy];
        _logHandler = [logHandler copy];
    }
    return self;
}

- (void)runOnMainQueue:(dispatch_block_t)block {
    if (NSThread.isMainThread) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

- (void)start {
    [self runOnMainQueue:^{
        if (self.started) return;
        self.started = YES;
        self.stopping = NO;
        self.centralManager = [[CBCentralManager alloc]
            initWithDelegate:self
                       queue:dispatch_get_main_queue()
                     options:@{CBCentralManagerOptionShowPowerAlertKey: @NO}];
        self.logHandler(@"BLE", @"CoreBluetooth 已初始化，等待系统蓝牙状态");
    }];
}

- (void)stop {
    [self runOnMainQueue:^{
        self.stopping = YES;
        self.started = NO;
        self.scanGeneration += 1;
        [self stopScanning];
        if (self.peripheral != nil) {
            [self.centralManager cancelPeripheralConnection:self.peripheral];
        }
        [self clearConnection];
    }];
}

- (void)setUSBConnected:(BOOL)connected {
    [self runOnMainQueue:^{
        if (self.usbConnected == connected) return;
        self.usbConnected = connected;
        if (connected) {
            self.scanGeneration += 1;
            [self stopScanning];
            if (self.peripheral != nil) {
                self.logHandler(@"BLE", @"USB 已接入，断开 BLE 并切回 USB");
                [self.centralManager cancelPeripheralConnection:self.peripheral];
            }
            [self clearConnection];
            return;
        }
        if (self.autoConnectEnabled) {
            self.logHandler(@"BLE", @"USB 已断开，准备连接 REAI 蓝牙");
            [self beginScanningIfPossible];
        } else {
            self.connectionHandler(NO, @"蓝牙未连接 · 自动连接已关闭");
        }
    }];
}

- (BOOL)autoConnectEnabled {
    id stored = [NSUserDefaults.standardUserDefaults objectForKey:REAIBLEAutoConnectDefaultsKey];
    return stored == nil ? YES : [stored boolValue];
}

- (BOOL)connected {
    return self.peripheral.state == CBPeripheralStateConnected &&
           self.eventCharacteristic.isNotifying;
}

- (NSString *)rememberedDeviceName {
    return [NSUserDefaults.standardUserDefaults stringForKey:REAIBLEPeripheralNameDefaultsKey];
}

- (void)setAutoConnectEnabled:(BOOL)enabled {
    [self runOnMainQueue:^{
        [NSUserDefaults.standardUserDefaults setBool:enabled forKey:REAIBLEAutoConnectDefaultsKey];
        self.manualConnectRequested = NO;
        self.scanGeneration += 1;
        [self stopScanning];
        if (enabled) {
            if (!self.connected) {
                self.connectionHandler(NO, @"蓝牙自动连接已开启，正在连接");
                [self beginScanningIfPossible];
            }
        } else if (!self.connected && !self.usbConnected) {
            self.connectionHandler(NO, @"蓝牙未连接 · 自动连接已关闭");
        }
        self.logHandler(@"SETTINGS", enabled ? @"蓝牙自动连接已开启" : @"蓝牙自动连接已关闭");
    }];
}

- (void)reconnect {
    [self runOnMainQueue:^{
        self.manualConnectRequested = YES;
        self.scanGeneration += 1;
        [self stopScanning];
        if (self.usbConnected) {
            self.connectionHandler(NO, @"USB 正在使用 · 拔线后可连接蓝牙");
            return;
        }
        if (self.peripheral != nil) {
            self.connectionHandler(NO, @"正在重新连接 REAI 蓝牙");
            [self.centralManager cancelPeripheralConnection:self.peripheral];
        } else {
            [self beginScanningIfPossible];
        }
        self.logHandler(@"SETTINGS", @"手动重新扫描 / 连接蓝牙");
    }];
}

- (void)forgetDevice {
    [self runOnMainQueue:^{
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        [defaults removeObjectForKey:REAIBLEPeripheralIdentifierDefaultsKey];
        [defaults removeObjectForKey:REAIBLEPeripheralNameDefaultsKey];
        [defaults setBool:NO forKey:REAIBLEAutoConnectDefaultsKey];
        self.manualConnectRequested = NO;
        self.scanGeneration += 1;
        [self stopScanning];
        if (self.peripheral != nil) {
            [self.centralManager cancelPeripheralConnection:self.peripheral];
        }
        [self clearConnection];
        self.connectionHandler(NO, @"已忘记蓝牙设备 · 自动连接已关闭");
        self.logHandler(@"SETTINGS", @"已忘记 REAI 蓝牙设备");
    }];
}

- (void)clearConnection {
    self.commandCharacteristic = nil;
    self.eventCharacteristic = nil;
    self.peripheral.delegate = nil;
    self.peripheral = nil;
}

- (void)stopScanning {
    if (!self.scanning) return;
    [self.centralManager stopScan];
    self.scanning = NO;
}

- (void)beginScanningIfPossible {
    if ((!self.autoConnectEnabled && !self.manualConnectRequested) ||
        !self.started || self.stopping || self.usbConnected || self.scanning ||
        self.peripheral != nil || self.centralManager.state != CBManagerStatePoweredOn) {
        return;
    }

    NSString *storedIdentifier = [[NSUserDefaults standardUserDefaults]
        stringForKey:REAIBLEPeripheralIdentifierDefaultsKey];
    if (storedIdentifier.length > 0) {
        NSUUID *identifier = [[NSUUID alloc] initWithUUIDString:storedIdentifier];
        if (identifier != nil) {
            NSArray<CBPeripheral *> *known =
                [self.centralManager retrievePeripheralsWithIdentifiers:@[identifier]];
            if (known.count > 0) {
                CBPeripheral *peripheral = known.firstObject;
                self.peripheral = peripheral;
                peripheral.delegate = self;
                self.connectionHandler(NO, @"正在重连 REAI 蓝牙");
                self.logHandler(@"BLE", [NSString stringWithFormat:@"尝试重连已记住的设备 %@",
                                           peripheral.identifier.UUIDString]);
                [self.centralManager connectPeripheral:peripheral options:nil];
                return;
            }
        }
    }

    self.scanning = YES;
    self.scanGeneration += 1;
    NSUInteger generation = self.scanGeneration;
    self.connectionHandler(NO, @"正在扫描 REAI 蓝牙");
    self.logHandler(@"BLE", @"开始扫描 REAI_VB_ 设备");
    [self.centralManager scanForPeripheralsWithServices:nil
                                                options:@{CBCentralManagerScanOptionAllowDuplicatesKey: @NO}];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self.scanGeneration != generation || !self.scanning) return;
        [self stopScanning];
        self.connectionHandler(NO, @"未发现 REAI 蓝牙，继续等待");
        self.logHandler(@"BLE", @"12 秒内未发现 REAI_VB_，3 秒后重试");
        [self scheduleReconnectAfter:3.0];
    });
}

- (void)scheduleReconnectAfter:(NSTimeInterval)delay {
    if (self.stopping || self.usbConnected ||
        (!self.autoConnectEnabled && !self.manualConnectRequested)) return;
    NSUInteger generation = ++self.scanGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self.scanGeneration != generation || self.stopping || self.usbConnected ||
            (!self.autoConnectEnabled && !self.manualConnectRequested)) return;
        [self beginScanningIfPossible];
    });
}

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    NSString *state = @"未知";
    switch (central.state) {
        case CBManagerStatePoweredOn:
            state = @"已开启";
            break;
        case CBManagerStatePoweredOff:
            state = @"已关闭";
            break;
        case CBManagerStateUnauthorized:
            state = @"未授权";
            break;
        case CBManagerStateUnsupported:
            state = @"不支持";
            break;
        case CBManagerStateResetting:
            state = @"正在重置";
            break;
        case CBManagerStateUnknown:
            break;
    }
    self.logHandler(@"BLE", [NSString stringWithFormat:@"macOS 蓝牙状态：%@", state]);
    if (central.state == CBManagerStatePoweredOn) {
        if (self.autoConnectEnabled || self.manualConnectRequested) {
            [self beginScanningIfPossible];
        } else if (!self.usbConnected) {
            self.connectionHandler(NO, @"蓝牙未连接 · 自动连接已关闭");
        }
    } else if (!self.usbConnected) {
        self.connectionHandler(NO,
            central.state == CBManagerStateUnauthorized ? @"请允许 REAI 使用蓝牙" : @"请开启 macOS 蓝牙");
    }
}

- (void)centralManager:(CBCentralManager *)central
 didDiscoverPeripheral:(CBPeripheral *)peripheral
     advertisementData:(NSDictionary<NSString *, id> *)advertisementData
                  RSSI:(NSNumber *)RSSI {
    (void)central;
    if (self.usbConnected || self.stopping) return;
    NSString *name = advertisementData[CBAdvertisementDataLocalNameKey];
    if (name.length == 0) name = peripheral.name;
    if (![name hasPrefix:REAIBLEDevicePrefix]) return;

    NSString *storedIdentifier = [[NSUserDefaults standardUserDefaults]
        stringForKey:REAIBLEPeripheralIdentifierDefaultsKey];
    NSString *storedName = [[NSUserDefaults standardUserDefaults]
        stringForKey:REAIBLEPeripheralNameDefaultsKey];
    BOOL matchesStoredDevice = storedIdentifier.length == 0 ||
        [storedIdentifier isEqualToString:peripheral.identifier.UUIDString] ||
        (storedName.length > 0 && [storedName isEqualToString:name]);
    if (!matchesStoredDevice) return;

    [self stopScanning];
    self.peripheral = peripheral;
    peripheral.delegate = self;
    self.connectionHandler(NO, [NSString stringWithFormat:@"正在连接 %@", name]);
    self.logHandler(@"BLE", [NSString stringWithFormat:@"发现 %@（RSSI %@），开始连接", name, RSSI]);
    [self.centralManager connectPeripheral:peripheral options:nil];
}

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
    (void)central;
    if (self.usbConnected || self.stopping) {
        [self.centralManager cancelPeripheralConnection:peripheral];
        return;
    }
    self.logHandler(@"BLE", @"蓝牙链路已连接，开始发现 FE60 服务");
    [peripheral discoverServices:@[reai_service_uuid()]];
}

- (void)centralManager:(CBCentralManager *)central
 didFailToConnectPeripheral:(CBPeripheral *)peripheral
                  error:(NSError *)error {
    (void)central;
    self.logHandler(@"BLE", [NSString stringWithFormat:@"连接 %@ 失败：%@",
                               peripheral.name ?: peripheral.identifier.UUIDString,
                               error.localizedDescription ?: @"未知错误"]);
    [self clearConnection];
    [self scheduleReconnectAfter:2.0];
}

- (void)centralManager:(CBCentralManager *)central
 didDisconnectPeripheral:(CBPeripheral *)peripheral
        timestamp:(CFAbsoluteTime)timestamp
isReconnecting:(BOOL)isReconnecting
                  error:(NSError *)error API_AVAILABLE(macos(13.0)) {
    (void)central;
    (void)timestamp;
    (void)isReconnecting;
    [self handleDisconnectedPeripheral:peripheral error:error];
}

- (void)centralManager:(CBCentralManager *)central
 didDisconnectPeripheral:(CBPeripheral *)peripheral
                  error:(NSError *)error {
    (void)central;
    [self handleDisconnectedPeripheral:peripheral error:error];
}

- (void)handleDisconnectedPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    if (peripheral != self.peripheral) return;
    NSString *reason = error.localizedDescription ?: @"连接已结束";
    self.logHandler(@"BLE", [NSString stringWithFormat:@"蓝牙已断开：%@", reason]);
    [self clearConnection];
    if (!self.usbConnected && !self.stopping) {
        if (self.autoConnectEnabled || self.manualConnectRequested) {
            self.connectionHandler(NO, @"REAI 蓝牙已断开，正在重连");
            [self scheduleReconnectAfter:1.0];
        } else {
            self.connectionHandler(NO, @"蓝牙未连接 · 自动连接已关闭");
        }
    }
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    if (error != nil) {
        self.logHandler(@"BLE", [NSString stringWithFormat:@"服务发现失败：%@", error.localizedDescription]);
        [self.centralManager cancelPeripheralConnection:peripheral];
        return;
    }
    CBService *target = nil;
    for (CBService *service in peripheral.services) {
        if ([service.UUID isEqual:reai_service_uuid()]) {
            target = service;
            break;
        }
    }
    if (target == nil) {
        self.logHandler(@"BLE", @"设备没有 REAI FE60 服务");
        [self.centralManager cancelPeripheralConnection:peripheral];
        return;
    }
    [peripheral discoverCharacteristics:@[reai_command_uuid(), reai_event_uuid()]
                             forService:target];
}

- (void)peripheral:(CBPeripheral *)peripheral
didDiscoverCharacteristicsForService:(CBService *)service
             error:(NSError *)error {
    (void)service;
    if (error != nil) {
        self.logHandler(@"BLE", [NSString stringWithFormat:@"特征值发现失败：%@", error.localizedDescription]);
        [self.centralManager cancelPeripheralConnection:peripheral];
        return;
    }
    for (CBCharacteristic *characteristic in service.characteristics) {
        if ([characteristic.UUID isEqual:reai_command_uuid()]) {
            self.commandCharacteristic = characteristic;
        } else if ([characteristic.UUID isEqual:reai_event_uuid()]) {
            self.eventCharacteristic = characteristic;
        }
    }
    if (self.commandCharacteristic == nil || self.eventCharacteristic == nil) {
        self.logHandler(@"BLE", @"缺少 REAI FE61/FE62 特征值");
        [self.centralManager cancelPeripheralConnection:peripheral];
        return;
    }
    [peripheral setNotifyValue:YES forCharacteristic:self.eventCharacteristic];
}

- (void)peripheral:(CBPeripheral *)peripheral
didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic
             error:(NSError *)error {
    if (characteristic != self.eventCharacteristic) return;
    if (error != nil || !characteristic.isNotifying) {
        self.logHandler(@"BLE", [NSString stringWithFormat:@"FE62 通知订阅失败：%@",
                                   error.localizedDescription ?: @"未启用"]);
        [self.centralManager cancelPeripheralConnection:peripheral];
        return;
    }

    NSString *name = peripheral.name ?: @"REAI_VB";
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:peripheral.identifier.UUIDString
                 forKey:REAIBLEPeripheralIdentifierDefaultsKey];
    [defaults setObject:name forKey:REAIBLEPeripheralNameDefaultsKey];
    self.manualConnectRequested = NO;
    self.logHandler(@"CONNECTED", [NSString stringWithFormat:@"已通过蓝牙连接 %@", name]);
    self.connectionHandler(YES, [NSString stringWithFormat:@"蓝牙已连接 · %@", name]);
    [self queryWorkMode];
}

- (void)queryWorkMode {
    [self runOnMainQueue:^{
        if (self.usbConnected || self.peripheral.state != CBPeripheralStateConnected ||
            self.commandCharacteristic == nil) {
            return;
        }
        const uint8_t bytes[] = {0x12, 0x04, 0xC9, 0x00, 0x00, 0x00};
        NSData *command = [NSData dataWithBytes:bytes length:sizeof(bytes)];
        [self.peripheral writeValue:command
                  forCharacteristic:self.commandCharacteristic
                               type:CBCharacteristicWriteWithResponse];
    }];
}

- (void)peripheral:(CBPeripheral *)peripheral
didWriteValueForCharacteristic:(CBCharacteristic *)characteristic
             error:(NSError *)error {
    (void)peripheral;
    if (characteristic == self.commandCharacteristic && error != nil) {
        self.logHandler(@"BLE", [NSString stringWithFormat:@"FE61 写入失败：%@", error.localizedDescription]);
    }
}

- (void)peripheral:(CBPeripheral *)peripheral
didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic
             error:(NSError *)error {
    (void)peripheral;
    if (characteristic != self.eventCharacteristic) return;
    if (error != nil) {
        self.logHandler(@"BLE", [NSString stringWithFormat:@"FE62 通知读取失败：%@", error.localizedDescription]);
        return;
    }

    uint8_t command = 0;
    const uint8_t *payload = NULL;
    NSUInteger payloadLength = 0;
    if (!reai_decode_event(characteristic.value, &command, &payload, &payloadLength)) {
        self.logHandler(@"BLE", [NSString stringWithFormat:@"无法解析 FE62 通知（%lu 字节）",
                                   (unsigned long)characteristic.value.length]);
        return;
    }
    if (command == 0x0C && payloadLength >= 2) {
        uint16_t value = (uint16_t)payload[0] | ((uint16_t)payload[1] << 8);
        self.consumerHandler(value);
    } else if (command == 0x12 && payloadLength >= 2 && payload[0] == 0xC9 && payload[1] <= 2) {
        self.modeHandler(payload[1]);
    } else if (command == 0x60) {
        self.logHandler(@"BLE", @"设备通知即将主动断开");
    }
}

@end

BOOL REAIBluetoothRunProtocolSelfTest(void) {
    if (![[reai_service_uuid() UUIDString]
            isEqualToString:@"00000000-0000-0000-0000-00000000FE60"] ||
        ![[reai_command_uuid() UUIDString]
            isEqualToString:@"00000000-0000-0000-0000-00000000FE61"] ||
        ![[reai_event_uuid() UUIDString]
            isEqualToString:@"00000000-0000-0000-0000-00000000FE62"]) {
        return NO;
    }
    const uint8_t keyBytes[] = {0x0C, 0x02, 0x07, 0x0F};
    NSData *keyData = [NSData dataWithBytes:keyBytes length:sizeof(keyBytes)];
    uint8_t command = 0;
    const uint8_t *payload = NULL;
    NSUInteger length = 0;
    if (!reai_decode_event(keyData, &command, &payload, &length) ||
        command != 0x0C || length != 2 || payload[0] != 0x07 || payload[1] != 0x0F) {
        return NO;
    }

    const uint8_t modeBytes[] = {0x12, 0x04, 0xC9, 0x02, 0x00, 0x00};
    NSData *modeData = [NSData dataWithBytes:modeBytes length:sizeof(modeBytes)];
    if (!reai_decode_event(modeData, &command, &payload, &length) ||
        command != 0x12 || length != 4 || payload[0] != 0xC9 || payload[1] != 0x02) {
        return NO;
    }

    const uint8_t truncatedBytes[] = {0x0C, 0x02, 0x07};
    NSData *truncated = [NSData dataWithBytes:truncatedBytes length:sizeof(truncatedBytes)];
    return !reai_decode_event(truncated, NULL, NULL, NULL);
}
