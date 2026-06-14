# iOS 键盘扩展可行性 PoC（录音 + Flutter 内存）

这两个 PoC 回答「现在这套 Android 语音输入法能不能照搬成 iOS 系统输入法（键盘扩展）」里**唯一两个会一票否决的技术问题**。其余障碍（审核、multicast 特批、Full Access）在「自用、不上架」前提下都已不成立或可绕过；剩下的就是下面这两道系统级硬墙——它们不因为你不上架而消失，所以必须先用最小代价验证。

> ⚠️ 编译/运行必须在 **macOS + Xcode + 真机 iPhone** 上。Windows 上只能写好代码（已完成）。键盘扩展录音**必须真机**——模拟器的麦克风行为不可信。

---

## PoC #1 — 键盘扩展里能不能真正录到音？　`poc/AudioProbeKeyboard/`

纯原生 Swift，无 Flutter。一个键盘面板，开 Full Access 后切到它、点「Record 3s」对着说话，面板直接给结论。

| 面板显示 | 含义 | 对项目的结论 |
|---|---|---|
| ✅ **SUCCESS**：frames 有、peak 是真实电平（说话时 0.01~1.0 波动） | 扩展能拿到真实麦克风流 | iOS 系统输入法**有戏**，可以继续 |
| ⚠️ **SILENT**：frames 在涨但 peak≈0 | iOS 给了你一路**静音流**（最阴险的失败，看着像成功） | 语音输入法形态**走不通**，得退回「普通 App 连桌面」 |
| ❌ **FAIL**：session 激活 / engine.start 抛错 | 录音被直接拒 | 同上，走不通 |

判读要点：**peak 才是真相**。很多 iOS 版本会让 `frameLength` 正常增长但所有采样都是 0——所以代码专门算了 peak/rms，别只看「有没有帧」。

前置（手册里有详细步骤）：先把 host app（Runner）装上真机打开一次、点「允许麦克风」——键盘扩展自己**不能**弹权限请求（和你 memory 里记的 Android「IME 不能 request 权限」同款坑，iOS 更严），权限是 App 级，必须主 App 先拿到。

---

## PoC #2 — 一个活的 FlutterEngine 塞进键盘扩展要吃多少内存？　`poc/FlutterMemKeyboard/`

加载真实 `FlutterViewController`（跑 `lib/main.dart` 里的 `pocFlutterMain`），顶部实时显示 `phys_footprint`（iOS jetsam 判杀用的就是这个指标，不是 resident_size）。「+10 MB」按钮不断灌入真实驻留内存，**直到键盘被系统杀掉消失**——消失那一刻的数值就是你的天花板。

要读出三个数：
1. **base**：引擎起来前的基线。
2. **after engine（Δ）**：FlutterEngine + FlutterViewController 起来后的增量 = Flutter 固定开销。
3. **kill 点**：点 +10MB 到键盘消失时的 footprint = jetsam 上限（历史上约 40~60MB，随设备/iOS 版本变动）。

决策：`kill点 − after引擎` = 留给**音频缓冲 + WebSocket + 火山流式 ASR** 的余量。
- 余量充裕（比如还有 30MB+）→ 系统输入法可行，可投入全量移植。
- 余量很小或 after-engine 本身就逼近上限 → 即使录音 PoC 过了，叠加 ASR 也会频繁 OOM，**不建议**做系统输入法。

> 注意：**Debug 版 Flutter framework 的内存数偏高**（JIT + 观测开销）。先用 Debug 跑通流程，真实数值要用 **Release** framework 再测一遍（手册有说明）。

---

## 两个 PoC 的总决策表

| PoC1 录音 | PoC2 内存 | 结论 |
|---|---|---|
| ✅ | 余量充裕 | **做 iOS 系统输入法**，全量移植（lib 下纯 Dart 几乎照搬，只重写原生层为 Swift Keyboard Extension） |
| ✅ | 余量很小 | 可做键盘但**别塞 Flutter**——用原生 Swift 画键盘 UI，只复用 Dart 的协议/网络层（改造量大） |
| ⚠️/❌ | 任意 | **放弃系统输入法**，退回「iOS 普通 App 录音 → WebSocket 发桌面」那条稳路（1~2 周可成，Dart 复用率最高） |

跑完把这两个数发我，我据此给下一步的具体方案。

---

## 文件清单

```
ios/poc/AudioProbeKeyboard/KeyboardViewController.swift   PoC1 录音键盘（principal class）
ios/poc/AudioProbeKeyboard/Info.plist                     PoC1 扩展 plist（RequestsOpenAccess=true）
ios/poc/FlutterMemKeyboard/KeyboardViewController.swift   PoC2 Flutter 嵌入键盘
ios/poc/FlutterMemKeyboard/MemoryProbe.swift              phys_footprint 读取
ios/poc/FlutterMemKeyboard/Info.plist                     PoC2 扩展 plist
lib/main.dart                          已加 pocFlutterMain 入口（PoC2 用）
ios/Runner/AppDelegate.swift           已加：启动时请求麦克风权限（给 PoC1 铺路）
ios/Runner/Info.plist                  已加：NSMicrophoneUsageDescription
```

组装步骤见 **`ASSEMBLY_macOS.md`**。
