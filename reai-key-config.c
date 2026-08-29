#include <hidapi.h>
#include <hidapi_darwin.h>
#include <fcntl.h>
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
    USAGE_PAGE_CONFIG = 0xFFA0,
    USAGE_CONFIG = 0x0002,
    REPORT_ID_INPUT = 0x0A,
    REPORT_ID_OUTPUT = 0x0B,
    CMD_GET_KEY_SETTING = 0x15,
    CMD_SET_KEY_SETTING = 0x16,
    KEY_CLASS_MEDIA = 0x0A,
    KEY_DATA_LENGTH = 60,
    PACKET_SIZE = 64,
};

static hid_device *open_config_interface(void) {
    struct hid_device_info *devices = hid_enumerate(REAI_VENDOR_ID, REAI_PRODUCT_ID);
    struct hid_device_info *current = devices;
    hid_device *device = NULL;
    while (current != NULL) {
        if (current->usage_page == USAGE_PAGE_CONFIG && current->usage == USAGE_CONFIG) {
            device = hid_open_path(current->path);
            break;
        }
        current = current->next;
    }
    hid_free_enumeration(devices);
    return device;
}

static int read_matching_response(
    hid_device *device,
    uint8_t expected_command,
    uint8_t response[PACKET_SIZE]
) {
    struct timespec start;
    clock_gettime(CLOCK_MONOTONIC, &start);
    for (;;) {
        int length = hid_read_timeout(device, response, PACKET_SIZE, 100);
        if (length < 0) return -1;
        if (length >= 2 && response[0] == REPORT_ID_INPUT && response[1] == expected_command) {
            return length;
        }
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        long elapsed_ms = (now.tv_sec - start.tv_sec) * 1000L +
            (now.tv_nsec - start.tv_nsec) / 1000000L;
        if (elapsed_ms >= 3000) return 0;
    }
}

static bool read_key_config(hid_device *device, uint8_t config[KEY_DATA_LENGTH]) {
    uint8_t command[PACKET_SIZE] = {0};
    command[0] = REPORT_ID_OUTPUT;
    command[1] = CMD_GET_KEY_SETTING;
    if (hid_write(device, command, sizeof(command)) < 0) {
        fprintf(stderr, "读取配置命令发送失败: %ls\n", hid_error(device));
        return false;
    }
    uint8_t response[PACKET_SIZE] = {0};
    int length = read_matching_response(device, CMD_GET_KEY_SETTING, response);
    if (length < PACKET_SIZE) {
        fprintf(stderr, "读取配置响应不足: len=%d\n", length);
        return false;
    }
    if (response[3] != 0) {
        fprintf(stderr, "读取配置失败: result=0x%02X\n", response[3]);
        return false;
    }
    memcpy(config, &response[4], KEY_DATA_LENGTH);
    return true;
}

static bool write_key_config(hid_device *device, const uint8_t config[KEY_DATA_LENGTH]) {
    uint8_t command[PACKET_SIZE] = {0};
    command[0] = REPORT_ID_OUTPUT;
    command[1] = CMD_SET_KEY_SETTING;
    command[2] = KEY_DATA_LENGTH;
    memcpy(&command[3], config, KEY_DATA_LENGTH);
    if (hid_write(device, command, sizeof(command)) < 0) {
        fprintf(stderr, "写入配置命令发送失败: %ls\n", hid_error(device));
        return false;
    }
    uint8_t response[PACKET_SIZE] = {0};
    int length = read_matching_response(device, CMD_SET_KEY_SETTING, response);
    if (length < 4) {
        fprintf(stderr, "写入配置响应不足: len=%d\n", length);
        return false;
    }
    if (response[3] != 0) {
        fprintf(stderr, "写入配置失败: result=0x%02X\n", response[3]);
        return false;
    }
    return true;
}

static bool save_backup_exclusive(const char *path, const uint8_t config[KEY_DATA_LENGTH]) {
    int descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (descriptor < 0) {
        perror("无法创建备份；为避免覆盖已有备份已停止");
        return false;
    }
    ssize_t written = write(descriptor, config, KEY_DATA_LENGTH);
    bool ok = written == KEY_DATA_LENGTH && fsync(descriptor) == 0;
    close(descriptor);
    if (!ok) {
        fprintf(stderr, "备份写入不完整\n");
        return false;
    }
    return true;
}

static bool load_backup(const char *path, uint8_t config[KEY_DATA_LENGTH]) {
    int descriptor = open(path, O_RDONLY);
    if (descriptor < 0) {
        perror("无法打开备份");
        return false;
    }
    ssize_t length = read(descriptor, config, KEY_DATA_LENGTH);
    uint8_t extra;
    ssize_t extra_length = read(descriptor, &extra, 1);
    close(descriptor);
    if (length != KEY_DATA_LENGTH || extra_length != 0) {
        fprintf(stderr, "备份长度错误: %zd，预期 %d\n", length, KEY_DATA_LENGTH);
        return false;
    }
    return true;
}

static void print_knob_config(const char *label, const uint8_t config[KEY_DATA_LENGTH]) {
    printf(
        "%s KEY0=%02X:%02X%02X KEY1=%02X:%02X%02X KEY2=%02X:%02X%02X\n",
        label,
        config[0], config[2], config[1],
        config[3], config[5], config[4],
        config[6], config[8], config[7]
    );
}

static int configure_native(hid_device *device, const char *backup_path) {
    uint8_t original[KEY_DATA_LENGTH];
    if (!read_key_config(device, original)) return 1;
    print_knob_config("写入前", original);
    if (!save_backup_exclusive(backup_path, original)) return 1;
    printf("备份完成: %s\n", backup_path);

    uint8_t changed[KEY_DATA_LENGTH];
    memcpy(changed, original, sizeof(changed));
    changed[0] = KEY_CLASS_MEDIA;
    changed[1] = 0xEA;
    changed[2] = 0x00;
    changed[3] = KEY_CLASS_MEDIA;
    changed[4] = 0xE9;
    changed[5] = 0x00;
    changed[6] = KEY_CLASS_MEDIA;
    changed[7] = 0xE2;
    changed[8] = 0x00;

    if (!write_key_config(device, changed)) {
        fprintf(stderr, "新配置写入失败，尝试恢复原配置\n");
        write_key_config(device, original);
        return 1;
    }
    uint8_t read_back[KEY_DATA_LENGTH];
    if (!read_key_config(device, read_back) || memcmp(changed, read_back, sizeof(changed)) != 0) {
        fprintf(stderr, "写后回读不一致，尝试恢复原配置\n");
        write_key_config(device, original);
        return 1;
    }
    print_knob_config("写入后", read_back);
    puts("配置成功并回读一致");
    return 0;
}

static int restore_native(hid_device *device, const char *backup_path) {
    uint8_t backup[KEY_DATA_LENGTH];
    if (!load_backup(backup_path, backup)) return 1;
    if (!write_key_config(device, backup)) return 1;
    uint8_t read_back[KEY_DATA_LENGTH];
    if (!read_key_config(device, read_back) || memcmp(backup, read_back, sizeof(backup)) != 0) {
        fprintf(stderr, "恢复后回读不一致\n");
        return 1;
    }
    print_knob_config("已恢复", read_back);
    puts("原配置恢复成功并回读一致");
    return 0;
}

int main(int argc, char **argv) {
    bool show = argc == 2 && strcmp(argv[1], "--show") == 0;
    bool configure = argc == 3 && strcmp(argv[1], "--configure-native") == 0;
    bool restore = argc == 3 && strcmp(argv[1], "--restore-native") == 0;
    if (!show && !configure && !restore) {
        fprintf(stderr, "用法: %s --show | --configure-native BACKUP.bin | --restore-native BACKUP.bin\n", argv[0]);
        return 2;
    }
    if (hid_init() != 0) {
        fprintf(stderr, "hidapi 初始化失败\n");
        return 1;
    }
    hid_darwin_set_open_exclusive(0);
    hid_device *device = open_config_interface();
    if (device == NULL) {
        fprintf(stderr, "无法打开 REAI Vibe Board Config 接口\n");
        hid_exit();
        return 1;
    }

    int result;
    if (show) {
        uint8_t config[KEY_DATA_LENGTH];
        result = read_key_config(device, config) ? 0 : 1;
        if (result == 0) print_knob_config("当前配置", config);
    } else if (configure) {
        result = configure_native(device, argv[2]);
    } else {
        result = restore_native(device, argv[2]);
    }
    hid_close(device);
    hid_exit();
    return result;
}
