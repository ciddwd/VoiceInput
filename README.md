# VoiceInput

**English** · [简体中文](./README.zh-CN.md)

A voice keyboard for your computer that lives on your phone.

Speak into the phone, the recognised text appears at the desktop's text cursor
— in any app, over your home Wi-Fi. The phone also doubles as a full Android
input method (IME), so the same voice + polish pipeline works inside WeChat,
your browser, or any other app on the phone itself.

> 用手机当电脑的语音键盘。手机说一句，桌面焦点处自动出字；同一套录音→识别→润色→插入的流水线也可以装成系统输入法，在任何安卓 app 里直接用。

---

## Highlights

- **Local-network, zero-cloud transport** — mobile and desktop discover each
  other over mDNS or UDP broadcast on the same Wi-Fi, then talk over a
  WebSocket. A 6-digit PIN pair + persistent token means a stranger on the
  same network can't dictate into your computer.
- **Three ASR engines, switchable at runtime**
  - System (OEM speech recognizer via `speech_to_text`, offline-capable on
    most modern phones)
  - **Whisper-compatible** batch (OpenAI, Groq, local `whisper.cpp` server,
    anything that exposes `/v1/audio/transcriptions`)
  - **Volcengine bigmodel streaming** (`api/v3/sauc/bigmodel`, full custom
    binary frame implementation; partial + final, hotwords supported)
- **LLM polish before send** — choose Raw / Light / Structured / Formal,
  and the phone calls any OpenAI-compatible Chat Completions endpoint
  (DeepSeek, Ark/Doubao, Moonshot, OpenAI itself…) or the Anthropic
  Messages API to rewrite the raw ASR. System prompts are designed to
  *only* rewrite — never answer questions or add a preface.
- **Dictionary of user hotwords** that are auto-injected into both the
  Volcengine ASR `hotwords` config and the polish prompt's "preserve these
  terms verbatim" hint, so domain words and proper nouns survive the round
  trip intact.
- **Snippets library** with categories on the desktop, chips on the phone.
  Category prefix / suffix / send-key are configurable; a regex against the
  desktop's foreground process name auto-switches the active category
  (e.g. VSCode → 编程类, Premiere → 视频类).
- **Cross-platform desktop**, Apple-style UI with frosted-glass modals,
  light / dark / auto theme, native-element selects retheme'd through CSS,
  bilingual UI (中文 / English).
- **Android IME mode** so the phone keyboard, once enabled, exposes the same
  mic-and-buffer panel inside every app on the phone. Tapping `→ PC`
  rewires Send so the polished text goes to the desktop instead of the
  local input field.
- **Robust text injection** on Windows: short text via `SendInput` with
  Unicode key events (no clipboard pollution); long text via
  clipboard + `Ctrl+V` with original clipboard contents restored after.
  Chorded suffixes supported: `Ctrl+Enter`, `Alt+Enter`, etc.

---

## Architecture

```
  Phone (Flutter / Android)               Desktop (Wails / Go + React)
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
  Discovery + reconnect on phone:                                          |
    mDNS -> UDP -> manual IP, with retries                                 |
                                                                          |
  Same phone can also be the system IME — same code, same buffer,          |
  same Polish step — just commits text to the local InputConnection.       |
```

Two Dart entry points share the same Flutter code:

- `main()` — the regular phone app (device picker, snippets, settings).
- `imeMain()` — `@pragma('vm:entry-point')`, runs inside the native
  `InputMethodService` so a cached `FlutterEngine` can host the IME panel
  at ~200 dp with the system app showing through above it.

The desktop side ships a single Wails binary; on launch it brings up the
WebSocket server, publishes mDNS, starts the UDP beacon, opens the SQLite
snippet/dictionary store, and begins polling the foreground window.

---

## Tech stack

| Layer | Pick |
|---|---|
| Desktop shell | [Wails v2](https://wails.io) (Go + WebView2) |
| Desktop UI | React 18 + TypeScript + Vite + hand-written CSS |
| Desktop storage | SQLite via [`modernc.org/sqlite`](https://gitlab.com/cznic/sqlite) (pure Go, no CGO) |
| Desktop discovery | [`grandcat/zeroconf`](https://github.com/grandcat/zeroconf) for mDNS + raw UDP for the beacon |
| Mobile shell | Flutter 3.x |
| Mobile ASR | `speech_to_text` (system) / direct HTTP + `record` (Whisper) / raw WebSocket + binary frames (Volcengine) |
| Mobile transport | `web_socket_channel` + custom envelope |
| Mobile persistence | `shared_preferences` (tokens, settings) |
| Auth | 6-digit PIN handshake then a 32-byte hex token stored per peer in `peers.json` |

---

## Build

### Prerequisites

- Go 1.24+
- Node 18+ and npm
- [Wails CLI](https://wails.io/docs/gettingstarted/installation) v2.12+
- Flutter 3.44+ (with Android SDK)
- Android device with USB / wireless ADB debugging

### Desktop

```bash
cd desktop
wails dev          # hot-reload dev loop
wails build        # produce a release binary in desktop/build/bin/
```

On Windows the output is `desktop\build\bin\desktop.exe`. The binary is
self-contained — no installer, just double-click. macOS / Linux builds work
too but text injection is a stub on those platforms (see Roadmap).

### Mobile

```bash
cd mobile
flutter pub get
flutter build apk --debug
```

There is a known incompatibility between recent `record` releases and the
Linux federated implementation that breaks the Dart kernel compile even for
Android-only builds. The project pins this via `dependency_overrides:
record_platform_interface: 1.2.0` in `mobile/pubspec.yaml`.

Install on the phone:

```bash
adb install -r mobile/build/app/outputs/flutter-apk/app-debug.apk
```

### Enable the IME (Android)

```bash
adb shell ime enable dev.voiceinput.mobile/.VoiceInputIme
adb shell ime set    dev.voiceinput.mobile/.VoiceInputIme
```

Or do it manually: Settings → Languages & input → Keyboards → enable
VoiceInput, then pick it as the current keyboard.

---

## Configuration

All API keys stay on the phone (or on the desktop for the Wails-side
config). They are written to `SharedPreferences` (mobile) or
`%AppData%\VoiceInput\` (desktop) and never sync.

### Polish provider

1. Open the phone app → settings cog → **Polish Provider**.
2. Tap a preset (DeepSeek / OpenAI / Ark / Moonshot / Anthropic) to fill
   base URL + model.
3. Paste your API key.
4. Pick a default polish mode (Raw / Light / Structured / Formal).
5. **Smoke test**: tap *Run test* with a sample sentence to verify
   reachability before saving.

### ASR engine

Same settings page → **Speech engine (ASR)**:

- **System** — no extra config. On Xiaomi/MIUI you may need to wake the
  built-in voice assistant once to grant the `mibrain.speech` service the
  microphone attribution.
- **Whisper** — fill base URL (`https://api.openai.com/v1` or your
  Whisper-compatible endpoint), model, API key, language.
- **Volcengine** — fill App Key + Access Key (from the Volcengine
  console), pick resource (`volc.bigasr.sauc.duration` for the smaller /
  faster model or `.bigmodel` for the large one), endpoint defaults to
  `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel`.

### Dictionary

Desktop → **Dictionary** tab → type a term + Enter. The list is auto-saved
and pushed to the connected phone immediately. Dictionary terms appear in
two places at recognition time:

1. As the `hotwords` field in the Volcengine ASR config.
2. As a "preserve these terms verbatim" hint in the polish prompt.

---

## Network notes

The mobile uses three discovery paths in this order, falling back when one
fails:

1. **mDNS** for `_voiceinput._tcp.local.` — quickest on home Wi-Fi.
2. **UDP broadcast** on port 53117 — survives APs that block multicast.
3. **Manual host + port** — the always-works fallback. The WebSocket port
   is 53118.

On the desktop side, mDNS and the UDP beacon are explicitly bound to
RFC1918 LAN interfaces only (`192.168/16`, `10/8`, `172.16/12`). WSL,
VirtualBox, Hyper-V, and VPN virtual NICs are skipped, which is the usual
reason a phone "sees" the desktop on one boot but not the next.

If the AP isolates clients (so even TCP between two devices on the same
SSID is blocked), nothing the app can do helps — switch off "AP
isolation" / "Wireless isolation" in the router's admin page, or use a
phone hotspot.

---

## Roadmap

Done:

- Mobile ↔ desktop core loop, IME mode, Polish provider, multi-ASR
  (System / Whisper / Volcengine streaming), Dictionary, focus auto-switch,
  Apple-style UI with light/dark and zh/en.

Not yet:

- macOS and Linux text injectors (interfaces exist as stubs).
- Translation hotkey (record once, transcribe + translate to target
  language, insert).
- iOS support — iOS custom keyboards have strict network/mic limits, so
  this would need a different shape than the Android IME. Early
  keyboard-extension PoCs (mic capture + a live FlutterEngine's memory
  footprint) now live in `mobile/ios/`, pending a Mac + device to measure.
- IME-mode polish button — the IME panel currently only shows mic + buffer
  + send; the *Polish* action is on the main app only.
- A few less-trafficked English strings (snippet editor modal, smoke-test
  panel) are pending i18n coverage.

---

## Inspiration

The user-facing model — two-stage buffer, polish modes, hotword
dictionary, focus-aware categories — is shaped by ideas from
[Open-Less/openless](https://github.com/Open-Less/openless). The
implementation here is independent and tailored to a Wails + Flutter
split.

## License

[Apache 2.0](./LICENSE).
