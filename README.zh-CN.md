# VoiceInput

[English](./README.md) · **简体中文**

装在手机里的电脑语音键盘。

对着手机说话，识别出的文字就出现在桌面当前的光标处——任何 app、走家里的
Wi-Fi 即可。手机本身还兼作一套完整的安卓输入法（IME），所以同一条
录音 → 识别 → 润色 → 插入 的流水线，在微信、浏览器或手机上任何 app 里都能直接用。

> 用手机当电脑的语音键盘。手机说一句，桌面焦点处自动出字；同一套录音→识别→润色→插入的流水线也可以装成系统输入法，在任何安卓 app 里直接用。

---

## 亮点

- **局域网直连、零云端转发** —— 手机和桌面在同一 Wi-Fi 下通过 mDNS 或 UDP
  广播互相发现，然后用 WebSocket 通信。一次 6 位 PIN 配对 + 持久化 token，
  保证同网段的陌生人没法往你电脑里打字。
- **三套 ASR 引擎，运行时可切换**
  - 系统（通过 `speech_to_text` 调用厂商语音识别，多数现代手机可离线）
  - **Whisper 兼容** 批量识别（OpenAI、Groq、本地 `whisper.cpp` 服务，
    任何暴露 `/v1/audio/transcriptions` 的端点）
  - **火山引擎大模型流式**（`api/v3/sauc/bigmodel`，完整自实现的二进制帧协议；
    支持中间结果 + 最终结果、热词）
- **发送前 LLM 润色** —— 可选 原文 / 轻度 / 结构化 / 正式 四档，手机会调用
  任意 OpenAI 兼容的 Chat Completions 端点（DeepSeek、火山方舟/豆包、Moonshot、
  OpenAI 本家……）或 Anthropic Messages API 来改写原始识别结果。系统提示词
  被设计成**只改写**——绝不回答问题、也不加开场白。
- **用户热词词典**，会自动注入到两个地方：火山 ASR 的 `hotwords` 配置，
  以及润色提示词里"以下术语原样保留"的提示，让专业词、专有名词在一整轮
  往返后仍然不走样。
- **常用语库**，桌面侧按分类管理、手机侧以胶囊呈现。每个分类的前缀 / 后缀 /
  发送键都可配置；还能用一条正则匹配桌面前台进程名来**自动切换**当前分类
  （比如 VSCode → 编程类、Premiere → 视频类）。
- **跨平台桌面端**，Apple 风格 UI、毛玻璃弹窗、浅色 / 深色 / 跟随系统主题、
  原生下拉控件经 CSS 重新配色、中英双语界面。
- **安卓输入法模式**：键盘启用后，会在手机上每个 app 里都暴露同一套
  麦克风 + 缓冲区面板。点一下 `→ PC`，发送目标就从本地输入框切到桌面，
  润色后的文字直接进电脑。
- **稳健的文本注入**（Windows）：短文本走 `SendInput` 的 Unicode 按键事件
  （不污染剪贴板）；长文本走 剪贴板 + `Ctrl+V`，事后还原原有剪贴板内容。
  支持组合后缀键：`Ctrl+Enter`、`Alt+Enter` 等。

---

## 架构

```
  手机 (Flutter / Android)                 桌面 (Wails / Go + React)
  +---------------------------+           +------------------------------+
  | Mic        speech_to_text |           |  HTTP /healthz               |
  |  |         Whisper        |           |  WebSocket /ws  ----------------+
  |  v         Volcengine WS  |           |     ^                         | |
  | ASR provider (one of 3)   |           |     |                         | |
  |  |  partial / final       |           |     | mDNS publish            | |
  |  v                        |           |     | UDP beacon              | |
  | Buffer  <----- user edits |           |     v                         | |
  |  |                        |           |  Pairing (PIN + Token)        | |
  |  v  (optional)            |           |     |                         | |
  | Polish provider:          |           |     v                         | |
  |   OpenAI-compatible       |           |  Snippet store (SQLite)       | |
  |   Anthropic               |           |  Dictionary store             | |
  |  |  +hotwords from dict   |           |  Focus detector (Win API)     | |
  |  v                        |           |     |                         | |
  | Send -------- WS msg --------------- > Inject (SendInput / Ctrl+V)    | |
  +---------------------------+           +------------------------------+ |
                                                                          |
  手机端的发现 + 重连:                                                      |
    mDNS -> UDP -> 手动 IP, 带重试                                          |
                                                                          |
  同一台手机也可以当系统输入法 —— 同一份代码、同一个缓冲区、                  |
  同一步润色 —— 只是把文字提交给本地的 InputConnection。                     |
```

两个 Dart 入口共用同一份 Flutter 代码：

- `main()` —— 普通手机 app（设备选择、常用语、设置）。
- `imeMain()` —— 标注 `@pragma('vm:entry-point')`，运行在原生
  `InputMethodService` 里，让一个被缓存的 `FlutterEngine` 把 IME 面板
  托在约 200 dp 高度，上方仍能看到当前系统 app。

桌面侧是单个 Wails 二进制；启动时它会拉起 WebSocket 服务、发布 mDNS、
启动 UDP 信标、打开 SQLite 常用语/词典存储，并开始轮询前台窗口。

---

## 技术栈

| 层 | 选型 |
|---|---|
| 桌面外壳 | [Wails v2](https://wails.io)（Go + WebView2） |
| 桌面 UI | React 18 + TypeScript + Vite + 手写 CSS |
| 桌面存储 | SQLite，经 [`modernc.org/sqlite`](https://gitlab.com/cznic/sqlite)（纯 Go，无 CGO） |
| 桌面发现 | [`grandcat/zeroconf`](https://github.com/grandcat/zeroconf) 做 mDNS + 原生 UDP 做信标 |
| 移动外壳 | Flutter 3.x |
| 移动 ASR | `speech_to_text`（系统）/ 直连 HTTP + `record`（Whisper）/ 原生 WebSocket + 二进制帧（火山） |
| 移动传输 | `web_socket_channel` + 自定义信封 |
| 移动持久化 | `shared_preferences`（token、设置） |
| 鉴权 | 6 位 PIN 握手，随后每个对端在 `peers.json` 里存一枚 32 字节十六进制 token |

---

## 构建

### 前置依赖

- Go 1.24+
- Node 18+ 和 npm
- [Wails CLI](https://wails.io/docs/gettingstarted/installation) v2.12+
- Flutter 3.44+（含 Android SDK）
- 一台开启 USB / 无线 ADB 调试的安卓设备

### 桌面端

```bash
cd desktop
wails dev          # 热重载开发循环
wails build        # 在 desktop/build/bin/ 产出发布二进制
```

在 Windows 上产物是 `desktop\build\bin\desktop.exe`，自带运行时——无需安装器，
双击即用。macOS / Linux 也能构建，但文本注入在这些平台上目前是桩实现（见路线图）。

### 移动端

```bash
cd mobile
flutter pub get
flutter build apk --debug
```

较新版本的 `record` 与其 Linux 联邦实现存在一个已知不兼容，会导致即便只构建
Android 也跑不通 Dart kernel 编译。本项目在 `mobile/pubspec.yaml` 里用
`dependency_overrides: record_platform_interface: 1.2.0` 固定住了这个问题。

安装到手机：

```bash
adb install -r mobile/build/app/outputs/flutter-apk/app-debug.apk
```

### 启用输入法（Android）

```bash
adb shell ime enable dev.voiceinput.mobile/.VoiceInputIme
adb shell ime set    dev.voiceinput.mobile/.VoiceInputIme
```

或手动操作：设置 → 语言和输入法 → 键盘 → 启用 VoiceInput，再把它选为当前键盘。

---

## 配置

所有 API key 都留在手机本地（或 Wails 侧配置留在桌面）。它们被写入
`SharedPreferences`（移动端）或 `%AppData%\VoiceInput\`（桌面端），从不同步上云。

### 润色服务商

1. 打开手机 app → 设置齿轮 → **润色服务商**。
2. 点一个预设（DeepSeek / OpenAI / 方舟 / Moonshot / Anthropic）自动填好
   base URL + 模型。
3. 粘贴你的 API key。
4. 选一个默认润色档位（原文 / 轻度 / 结构化 / 正式）。
5. **冒烟测试**：用一句示例点*运行测试*，保存前先确认可达。

### ASR 引擎

同一设置页 → **语音引擎（ASR）**：

- **系统** —— 无需额外配置。在小米/MIUI 上，你可能需要先唤醒一次内置语音助手，
  好让 `mibrain.speech` 服务拿到麦克风归属。
- **Whisper** —— 填 base URL（`https://api.openai.com/v1` 或你的 Whisper
  兼容端点）、模型、API key、语言。
- **火山引擎** —— 填 App Key + Access Key（火山控制台获取），选资源
  （`volc.bigasr.sauc.duration` 为更小更快的模型，`.bigmodel` 为大模型），
  端点默认 `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel`。

### 词典

桌面 → **词典** 标签页 → 输入一个术语后回车。列表自动保存并立即推送给已连接的手机。
词典里的术语会在识别时出现在两处：

1. 作为火山 ASR 配置里的 `hotwords` 字段。
2. 作为润色提示词里"以下术语原样保留"的提示。

---

## 网络说明

移动端按以下顺序使用三条发现路径，前一条失败就回退：

1. **mDNS** 查找 `_voiceinput._tcp.local.` —— 家用 Wi-Fi 下最快。
2. **UDP 广播** 端口 53117 —— 能扛住屏蔽组播的 AP。
3. **手动主机 + 端口** —— 永远可用的兜底。WebSocket 端口是 53118。

桌面侧，mDNS 和 UDP 信标被显式绑定到仅限 RFC1918 的 LAN 网卡
（`192.168/16`、`10/8`、`172.16/12`）。WSL、VirtualBox、Hyper-V、VPN 虚拟网卡
都会被跳过——这通常正是"手机这次开机能看到桌面、下次又看不到"的根因。

如果 AP 开了客户端隔离（连同一 SSID 下两台设备间的 TCP 都被挡），那 app
再怎么折腾也没用——去路由器后台关掉"AP 隔离"/"无线隔离"，或者改用手机热点。

---

## 路线图

已完成：

- 手机 ↔ 桌面核心闭环、输入法模式、润色服务商、多 ASR（系统 / Whisper /
  火山流式）、词典、前台自动切换、Apple 风格 UI（浅/深色、中/英）。

尚未完成：

- macOS 与 Linux 的文本注入器（接口已留桩）。
- 翻译快捷键（录一次音，转写 + 翻译成目标语言后插入）。
- iOS 支持 —— iOS 自定义键盘对网络/麦克风限制严格，需要和安卓 IME 不同的形态。
  早期的键盘扩展 PoC（麦克风采集 + 一个常驻 FlutterEngine 的内存占用）现已放在
  `mobile/ios/`，等有 Mac + 真机再测数据。
- 输入法模式下的润色按钮 —— IME 面板目前只有 麦克风 + 缓冲区 + 发送，
  *润色*动作还只在主 app 里。
- 少数低频英文文案（常用语编辑弹窗、冒烟测试面板）的 i18n 覆盖待补。

---

## 灵感来源

面向用户的模型——两段式缓冲区、润色档位、热词词典、随焦点切换的分类——
其想法受到 [Open-Less/openless](https://github.com/Open-Less/openless) 的启发。
这里的实现是独立完成的，并针对 Wails + Flutter 的拆分做了定制。

## 许可证

[Apache 2.0](./LICENSE)。
