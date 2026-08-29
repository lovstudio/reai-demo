#include <AudioToolbox/AudioHardwareService.h>
#include <CoreAudio/CoreAudio.h>
#include <hidapi.h>
#include <hidapi_darwin.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

enum {
    REAI_VENDOR_ID = 0x363C,
    REAI_PRODUCT_ID = 0xED20,
    REAI_CONSUMER_USAGE_PAGE = 0x000C,
    REAI_CONSUMER_REPORT_ID = 0x0C,
    REAI_KNOB_COUNTERCLOCKWISE = 0x0F07,
    REAI_KNOB_CLOCKWISE = 0x0F08,
    REAI_KNOB_PRESS = 0x0F09,
};

static volatile sig_atomic_t g_stop;
static bool g_debug;

static void log_message(const char *level, const char *message) {
    time_t now = time(NULL);
    struct tm local;
    localtime_r(&now, &local);
    char stamp[24];
    strftime(stamp, sizeof(stamp), "%Y-%m-%d %H:%M:%S", &local);
    fprintf(stdout, "%s [%s] %s\n", stamp, level, message);
    fflush(stdout);
}

static bool get_default_output_device(AudioDeviceID *device) {
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    UInt32 size = sizeof(*device);
    OSStatus status = AudioObjectGetPropertyData(
        kAudioObjectSystemObject, &address, 0, NULL, &size, device
    );
    return status == noErr && *device != kAudioObjectUnknown;
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
    if (AudioObjectIsPropertySettable(device, &address, &settable) != noErr || !settable) {
        return false;
    }
    if (volume < 0.0f) volume = 0.0f;
    if (volume > 1.0f) volume = 1.0f;
    return AudioObjectSetPropertyData(
        device, &address, 0, NULL, sizeof(volume), &volume
    ) == noErr;
}

static bool change_output_volume(Float32 delta) {
    Float32 before;
    if (!get_output_volume(&before)) {
        log_message("ERROR", "无法读取默认输出设备音量");
        return false;
    }
    Float32 after = before + delta;
    if (after < 0.0f) after = 0.0f;
    if (after > 1.0f) after = 1.0f;
    if (!set_output_volume(after)) {
        log_message("ERROR", "默认输出设备不允许设置主音量");
        return false;
    }
    char message[96];
    snprintf(message, sizeof(message), "音量 %.0f%% -> %.0f%%", before * 100.0f, after * 100.0f);
    log_message("VOLUME", message);
    return true;
}

static bool toggle_output_mute(void) {
    AudioDeviceID device;
    if (!get_default_output_device(&device)) {
        log_message("ERROR", "无法找到默认输出设备");
        return false;
    }
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyMute,
        kAudioDevicePropertyScopeOutput,
        kAudioObjectPropertyElementMain,
    };
    UInt32 muted = 0;
    UInt32 size = sizeof(muted);
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &muted) != noErr) {
        log_message("ERROR", "默认输出设备不支持读取静音状态");
        return false;
    }
    muted = muted ? 0 : 1;
    if (AudioObjectSetPropertyData(device, &address, 0, NULL, sizeof(muted), &muted) != noErr) {
        log_message("ERROR", "默认输出设备不支持设置静音状态");
        return false;
    }
    log_message("MUTE", muted ? "已静音" : "已取消静音");
    return true;
}

static void handle_consumer_value(uint16_t value) {
    switch (value) {
        case REAI_KNOB_COUNTERCLOCKWISE:
            change_output_volume(-0.04f);
            break;
        case REAI_KNOB_CLOCKWISE:
            change_output_volume(0.04f);
            break;
        case REAI_KNOB_PRESS:
            toggle_output_mute();
            break;
        default:
            if (g_debug && value != 0) {
                char message[64];
                snprintf(message, sizeof(message), "忽略 Consumer value=0x%04X", value);
                log_message("DEBUG", message);
            }
            break;
    }
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

static hid_device *open_consumer_interface(void) {
    struct hid_device_info *devices = hid_enumerate(REAI_VENDOR_ID, REAI_PRODUCT_ID);
    struct hid_device_info *current = devices;
    hid_device *device = NULL;

    while (current != NULL) {
        if (g_debug) {
            fprintf(
                stdout,
                "HID path=%s usage_page=0x%04X usage=0x%04X interface=%d\n",
                current->path,
                current->usage_page,
                current->usage,
                current->interface_number
            );
        }
        if (current->usage_page == REAI_CONSUMER_USAGE_PAGE) {
            device = hid_open_path(current->path);
            if (device != NULL) break;
        }
        current = current->next;
    }
    hid_free_enumeration(devices);
    return device;
}

static void listen_until_disconnect(hid_device *device) {
    unsigned char report[64];
    while (!g_stop) {
        int length = hid_read_timeout(device, report, sizeof(report), 250);
        if (length < 0) {
            const wchar_t *error = hid_error(device);
            char message[256];
            snprintf(message, sizeof(message), "HID 读取失败: %ls", error != NULL ? error : L"未知错误");
            log_message("ERROR", message);
            break;
        }
        if (length == 0) continue;

        if (g_debug) {
            fprintf(stdout, "REPORT len=%d data=", length);
            int shown = length < 16 ? length : 16;
            for (int i = 0; i < shown; i++) {
                fprintf(stdout, "%02X%s", report[i], i + 1 == shown ? "" : " ");
            }
            fputc('\n', stdout);
            fflush(stdout);
        }

        uint16_t value = decode_consumer_value(report, length);
        if (value != 0) handle_consumer_value(value);
    }
}

static void stop_signal_handler(int signal_number) {
    (void)signal_number;
    g_stop = 1;
}

static int run_self_test(void) {
    Float32 before;
    if (!get_output_volume(&before)) {
        fprintf(stderr, "self-test: 无法读取默认输出音量\n");
        return 1;
    }
    Float32 changed = before <= 0.98f ? before + 0.01f : before - 0.01f;
    if (!set_output_volume(changed)) {
        fprintf(stderr, "self-test: 无法设置默认输出音量\n");
        return 1;
    }
    Float32 read_back = before;
    bool changed_ok = get_output_volume(&read_back) && read_back != before;
    bool restored_ok = set_output_volume(before);
    printf(
        "self-test: before=%.4f changed=%.4f read_back=%.4f restored=%s\n",
        before,
        changed,
        read_back,
        restored_ok ? "yes" : "no"
    );
    return changed_ok && restored_ok ? 0 : 1;
}

static int run_protocol_test(void) {
    const unsigned char counterclockwise[] = {0x0C, 0x07, 0x0F};
    const unsigned char clockwise[] = {0x0C, 0x08, 0x0F};
    const unsigned char press[] = {0x0C, 0x09, 0x0F};
    const unsigned char release[] = {0x0C, 0x00, 0x00};
    bool passed =
        decode_consumer_value(counterclockwise, sizeof(counterclockwise)) == REAI_KNOB_COUNTERCLOCKWISE &&
        decode_consumer_value(clockwise, sizeof(clockwise)) == REAI_KNOB_CLOCKWISE &&
        decode_consumer_value(press, sizeof(press)) == REAI_KNOB_PRESS &&
        decode_consumer_value(release, sizeof(release)) == 0;
    printf("protocol-test: %s\n", passed ? "passed" : "failed");
    return passed ? 0 : 1;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (argc > 1 && strcmp(argv[1], "--self-test") == 0) {
        return run_self_test();
    }
    if (argc > 1 && strcmp(argv[1], "--protocol-test") == 0) {
        return run_protocol_test();
    }
    g_debug = argc > 1 && strcmp(argv[1], "--debug") == 0;
    signal(SIGINT, stop_signal_handler);
    signal(SIGTERM, stop_signal_handler);

    if (hid_init() != 0) {
        log_message("ERROR", "hidapi 初始化失败");
        return 1;
    }
    hid_darwin_set_open_exclusive(0);
    log_message("READY", "控制器已启动；逆时针减音量，顺时针加音量，按下切换静音");

    while (!g_stop) {
        hid_device *device = open_consumer_interface();
        if (device == NULL) {
            log_message("WAITING", "未找到 REAI Vibe Board Consumer 接口，1 秒后重试");
            sleep(1);
            continue;
        }
        log_message("CONNECTED", "已连接 REAI Vibe Board Consumer 接口");
        listen_until_disconnect(device);
        hid_close(device);
        if (!g_stop) {
            log_message("DISCONNECTED", "设备已断开，1 秒后重连");
            sleep(1);
        }
    }

    hid_exit();
    log_message("STOPPED", "控制器已退出");
    return 0;
}
