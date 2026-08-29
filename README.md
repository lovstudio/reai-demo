# REAI Vibe Board macOS 模式控制器

LovStudio 为 REAI Vibe Board 编写的 macOS 原生演示程序。项目参考
[ReAI Board SDK](https://github.com/ReAI-com/reai-board-sdk) 的设备连接与协议资料，提供
音乐、游戏、蓝牙设置和 3D 语音桌宠等完整交互。

## 环境与构建

需要 macOS、Xcode Command Line Tools、Homebrew 和 `hidapi`：

```bash
brew install hidapi
./build.sh
```

构建生成的 `.app` 和命令行二进制不会进入 Git。安装到当前用户并启用登录启动：

```bash
./install.sh
```

支持 USB HID 与 BLE GATT 双通道。USB 插入时优先使用 USB；拔下 USB 后自动扫描并连接
`REAI_VB_…`，重新插线会自动断开 BLE 并切回 USB。第一次启用 BLE 时，macOS 会请求
“蓝牙”权限；允许后首次扫描可能需要约 40 秒。

键盘旋钮保留原生自定义 Consumer Control 事件，由后台 App 根据当前工作模式分流：

- KEY0 / 逆时针：`0x0F07`
- KEY1 / 顺时针：`0x0F08`
- KEY2 / 按下：`0x0F09`

音乐模式下分别映射为音量降低、音量升高和静音；游戏模式下分别映射为挡板左移、
挡板右移和发球/暂停。该分流需要后台 App 运行。

硬件原始配置备份是设备本地资料，不进入 Git；请把自己的 `.bin` 备份保存在仓库外。

恢复原来的旋钮配置：

```bash
./reai-key-config --restore-native /path/to/your-backup.bin
```

读取键盘当前配置：

```bash
./reai-key-config --show
```

`reai-volume-controller` 是不改硬件配置的前台调试工具；正常使用由后台 App 接管。

## 居中悬浮模式与按键

默认进入音乐模式。按 Tab 打开居中悬浮模式选择器，再按 Tab 按“音乐 → 游戏 → 设置”
循环，按 Enter（协议值 `0x0F06`，兼容 New `0x0F02`）确认进入。ESC 作为层级回退：
游戏或设置页回到 App 选择器，选择器再回到进入前的页面。

### 设置

设置是 Tab 循环中的最后一个 App。顶部会显示当前通道、蓝牙设备名与连接状态，下面提供：

- 蓝牙自动连接：控制拔下 USB 后是否自动连接上次设备；
- 重新扫描 / 连接：立即查找并连接已记住或附近的 `REAI_VB_…`；
- 忘记蓝牙设备：清除设备记录并关闭自动连接，需要二次确认；
- 桌宠 · 川仔：显示或隐藏桌面伙伴。

设置页的硬件操作：

- 旋钮左转 / 右转：选择上一项 / 下一项；
- Enter、旋钮按下或 Action：执行当前项目；
- Tab：返回 App 选择器；
- ESC：取消忘记设备确认，或回到 App 选择器。

蓝牙自动连接、上次设备与桌宠开关都通过 `NSUserDefaults` 持久化，应用重启和重新登录后
继续沿用上次状态。忘记设备后可选择“重新扫描 / 连接”再次配对。

## 全局 3D 桌宠

桌宠默认开启；也可以从设置 App 关闭。开启后会显示跨桌面置顶、透明且可拖动的小型 3D 桌宠“川仔”，常驻状态不再
显示文字气泡。点击川仔会在屏幕中央打开对话记忆窗，再次点击可收起；对话窗使用普通窗口层级，切换到其他 App 后会被覆盖。按住 AI 语音键
（`0x0F04`，兼容 `0x0F99`）说话时，屏幕底部会短暂显示无背景、实心字加描边的转录字幕，不会打开对话记录窗；
AI 开始回答后，同一字幕层会切换为“川仔：…”并逐字更新，保持到语音实际播放完成后淡出。松开按键后使用
豆包实时语音模型 3.0（Seeduplex `1.2.6.1`）直接完成语音理解、回复和 Vivi 真人音色流式播放。

当默认输入是蓝牙耳机麦克风时，应用会通过独立的 Core Audio 输入队列改用 Mac 内建麦克风
录音，不创建会触碰耳机输出的 `AVAudioEngine` 音频图，也不修改 macOS 的全局默认输入设置。

桌宠会持续漂浮、转身展示侧面与背面，并具有眼睛、耳朵、头部、手臂和尾巴的独立
动作；鼠标经过桌宠时，它会轻微朝指针方向偏转。

```text
~/Library/Application Support/REAI Music Controller/companion-memory.jsonl
```

麦克风音频不会保存；转录与桌宠回复会逐句追加到上述本地 JSONL 文件。该文件、运行日志和
Keychain 中的 Speech API Key 都不会进入仓库。

菜单栏可显示或隐藏桌宠、查看对话记录，也可以直接打开原始记忆文件。首次使用需要允许“麦克风”和
“语音识别”权限。对话优先由登录时常驻的本地 Ollama `qwen3:1.7b` 生成；模型服务
不可用时自动切换到内置的记忆回应，不影响转录和保存。

首次启用，在菜单栏 `REAI` 中选择“配置豆包实时语音…”，粘贴豆包语音新版控制台创建的
Speech API Key。密钥只写入 macOS Keychain，不保存到仓库、配置文件或日志。实时链路默认使用
`zh_female_vv_jupiter_bigtts`（Vivi）的 24 kHz PCM 输出；网络或服务异常时自动回退到本地转录、Ollama 回复与备用语音。

### 音乐模式

三段推杆切换：

- 高档：`YOLO` → Find Your Mood 的 `Relax` Radio Station
- 中档：`CHAT` → Find Your Mood 的 `Focus` Radio Station
- 低档：`PLAN` → Apple Music Classical 的 `Classical Sleep`

协议值分别为 `0x0F0A / 端点释放（兼容 0x0F0C）/ 0x0F0B`，模式值为
`1 / 0 / 2`。

Action：Apple Music 播放/暂停。

### 游戏模式

默认进入原生打砖块界面：

- 旋钮左转 / 右转：挡板向左 / 向右；
- 推杆高 / 中 / 低档：球速快速 / 标准 / 慢速；
- 旋钮按下：发球或暂停/继续；
- Action：发球或暂停/继续；
- Tab：返回工作模式选择器；
- ESC：暂停并回到 App 选择器。

键盘旋钮使用原始自定义事件，由后台程序按当前模式分流，因此游戏时不会同时改变
系统音量；回到音乐模式后，旋钮恢复调节系统音量/静音。游戏模式下，推杆只调节
游戏速度，不触发 Apple Music 歌单。

当前状态显示在菜单栏 `REAI·MODE`，同时写入：

```text
~/Library/Application Support/REAI Music Controller/current-mode
```

模式变化也会广播 `com.shougongchuan.reai.mode-change`，`userInfo.mode` 为
`YOLO`、`CHAT` 或 `PLAN`，供后续工作流接入。

安装并启用登录启动：

```bash
./install.sh
```

首次运行时，macOS 会请求三项权限：

1. “输入监控”：读取 REAI Vibe Board 旋钮、推杆与按键；
2. “蓝牙”：拔下 USB 后通过 BLE GATT 连接键盘；
3. “自动化 → Apple Music”：控制歌单和播放状态。

菜单栏会显示当前模式，例如 `REAI·CHAT`。连接状态应为“已连接，按键可用”；日志位于：

```text
~/Library/Logs/REAI Music Controller.log
```

旋钮在音乐模式下由此 App 控制系统音量，在游戏模式下控制挡板。
