# 在 Mac 上组装并运行两个 PoC（精确步骤）

这些 PoC 的源码已在仓库里写好。唯一必须在 Xcode GUI 里手动做的事是「**新建 Keyboard Extension target**」——`project.pbxproj` 不适合手写，所以这步靠 Xcode 点几下生成，然后把我提供的文件填进去。

## 0. 前置

- macOS + Xcode（建议最新版）。
- 一部 **真机 iPhone**（键盘扩展录音必须真机；模拟器麦克风行为不可信）。
- 用你的 Apple ID 登录 Xcode（`Xcode ▸ Settings ▸ Accounts ▸ +`）。免费个人账号即可，签名 7 天有效，自用足够，**无需付费开发者账号**。
- 把仓库拷到 Mac，终端进入 `mobile/`，先拉依赖：
  ```bash
  flutter pub get
  ```

## 1. 打开工程，先把主 App 跑起来一次（拿麦克风权限）

```bash
open ios/Runner.xcworkspace
```

1. 顶部 scheme 选 **Runner**，设备选你的 iPhone。
2. 第一次会要签名：选 **Runner** target ▸ *Signing & Capabilities* ▸ 勾 **Automatically manage signing** ▸ Team 选你的个人 Apple ID。
3. ▶︎ Run。App 启动后会弹**麦克风权限**——点**允许**。（这一步给 PoC1 铺路：键盘扩展自己不能弹权限，权限是 App 级的，必须主 App 先拿到。）
4. 真机首次会提示「不受信任的开发者」：iPhone *设置 ▸ 通用 ▸ VPN与设备管理* ▸ 信任你的开发者证书。

---

## 2. PoC #1 — 录音键盘（AudioProbe）

### 2.1 新建扩展 target
- Xcode 菜单 **File ▸ New ▸ Target…** ▸ iOS ▸ **Custom Keyboard Extension** ▸ Next。
- Product Name：`AudioProbe`　Language：Swift ▸ Finish。
- 弹「Activate "AudioProbe" scheme?」→ **Activate**。
- Xcode 自动生成 `AudioProbe/` 组，含 `KeyboardViewController.swift` 和 `Info.plist`。

### 2.2 填入我们的代码
- 用 `ios/poc/AudioProbeKeyboard/KeyboardViewController.swift` 的**全部内容**覆盖 Xcode 刚生成的 `AudioProbe/KeyboardViewController.swift`。
- 打开 `AudioProbe/Info.plist`，把 `NSExtension ▸ NSExtensionAttributes ▸ RequestsOpenAccess` 改成 **YES**（Xcode 默认生成 NO）。其余键保持 Xcode 生成的即可——它和 `ios/poc/AudioProbeKeyboard/Info.plist` 等价，照后者核对一遍最稳。

### 2.3 签名
- 选 **AudioProbe** target ▸ *Signing & Capabilities* ▸ 同一个 Team。bundle id 应为 `dev.voiceinput.mobile.AudioProbe`（必须是主 App id 的子前缀）。

### 2.4 运行 + 启用
- scheme 选 **AudioProbe**，▶︎ Run；Xcode 问用哪个 App 承载，选 **Mobile/Runner**（或随便选个有输入框的 App 如 Safari）。
- iPhone *设置 ▸ 通用 ▸ 键盘 ▸ 键盘 ▸ 添加新键盘* ▸ **AudioProbe**。
- 再进 *键盘 ▸ AudioProbe* ▸ 打开 **允许完全访问（Allow Full Access）**。
- 打开备忘录/Safari，点输入框，长按 🌐 切到 **AudioProbe**，点 **● Record 3s**，对着麦克风说话。

### 2.5 读结果
看面板（判读表见 `POC_README.md`）：
- ✅ SUCCESS（peak 有真实电平）→ 录音这关过了。
- ⚠️ SILENT（frames 涨但 peak≈0）/ ❌ FAIL → 录音被静音/拒绝，系统输入法形态走不通。

---

## 3. PoC #2 — Flutter 嵌入内存（FlutterMem）

### 3.1 先产出 Flutter framework
add-to-app 把 Flutter 嵌进非 Runner 的 target，最可靠的方式是手动嵌 xcframework。终端在 `mobile/`：

```bash
# Debug：先跑通流程（注意 Debug 内存偏高，不是真实值）
flutter build ios-framework --debug --no-profile --no-release --output=build/ios-framework
```

产出在 `build/ios-framework/Debug/`，关键是 `Flutter.xcframework` 和 `App.xcframework`。

### 3.2 新建扩展 target
- **File ▸ New ▸ Target ▸ Custom Keyboard Extension** ▸ Product Name：`FlutterMem` ▸ Finish ▸ Activate。

### 3.3 填入我们的代码
- 用 `ios/poc/FlutterMemKeyboard/KeyboardViewController.swift` 覆盖生成的同名文件。
- 把 `ios/poc/FlutterMemKeyboard/MemoryProbe.swift` 拖进 Xcode 的 `FlutterMem` 组；拖入时**勾选 Target membership = FlutterMem**。
- `FlutterMem/Info.plist` 的 `RequestsOpenAccess` 设 **YES**。

### 3.4 把 Flutter 链进扩展（PoC2 最容易卡的一步）
- 选 **FlutterMem** target ▸ *General* ▸ **Frameworks and Libraries** ▸ `+` ▸ **Add Other… ▸ Add Files…**。
- 选 `build/ios-framework/Debug/Flutter.xcframework`，再加一次选 `App.xcframework`。
- 两者的 Embed 都设为 **Embed & Sign**。
- 同样在主 **Runner** target 里也确保有 Flutter（Runner 本身就是 Flutter app，通常已具备）。

> 如果这一步死活链不进去 / 运行即崩、报找不到 Flutter 符号——**这本身就是 PoC2 的一个负面信号**：把 Flutter 塞进键盘扩展的工程代价很高。记录下来告诉我。

### 3.5 签名 + 运行
- **FlutterMem** target ▸ Signing ▸ 同一 Team（bundle id `dev.voiceinput.mobile.FlutterMem`）。
- scheme 选 **FlutterMem** ▶︎ Run，host 选 Mobile/Runner。
- 设置里添加 **FlutterMem** 键盘（内存测试可不开 Full Access）。
- 切到该键盘：应看到底部 Flutter 在跑（"Flutter alive · tick" 在跳），顶部绿字显示 footprint。

### 3.6 读结果
- 记下 **base**、**after engine（Δ）** 两个数。
- 反复点 **+10 MB**，直到键盘**突然消失**（被 jetsam 杀）——记下消失前最后的 footprint = **kill 点**。
- 余量 = kill点 − after引擎。判读与决策见 `POC_README.md` 的总决策表。

### 3.7（重要）用 Release 复测真实内存
Debug framework 内存偏高。流程跑通后，换 Release 重测才是真实值：
```bash
flutter build ios-framework --release --no-debug --no-profile --output=build/ios-framework-release
```
把 3.4 里链接的 framework 换成 `build/ios-framework-release/Release/` 下的版本，重跑 3.5/3.6。`pocFlutterMain` 已用 `@pragma('vm:entry-point')` 标注且与 `main` 同库，Release AOT 下不会被 tree-shake。

---

## 常见卡点速查

| 现象 | 原因 / 处理 |
|---|---|
| 键盘列表里看不到 AudioProbe/FlutterMem | extension 没装上：确认 Run 时 host app 选对、真机已信任开发者证书 |
| 切过去键盘是空白/高度为 0 | 已用 heightAnchor 固定高度；若仍空白，检查 principal class 名是否 `$(PRODUCT_MODULE_NAME).KeyboardViewController` |
| Record 提示 Full Access OFF | 设置里没开「允许完全访问」 |
| Record 直接 FAIL 或 SILENT | 这是真实结论，不是 bug——见判读表 |
| FlutterMem 一切就崩 / 链接报错 | Flutter 没正确链进扩展，见 3.4 的提示 |
| 7 天后键盘失效 | 免费签名有效期 7 天，重连真机 Run 一次即可 |
