# 待优化（TODO）

按优先级从高到低排列。每条都附上现状、预期与实现方向，方便哪天捡起来直接动手。

---

## 1. 托盘图标存在时，双击桌面快捷方式应唤出已运行的程序 —— **已实现**

**现状（实现前）**：`src/scrcpy-gui.ps1` 用 `Global\ScrcpyConsoleGuiMutex` 做单实例保护，第二次启动拿不到互斥体就直接 `exit`，看起来就是"双击没反应"。

**实现做法**：

* 先创建（或打开）命名事件 `Global\ScrcpyConsoleShowPanel`（AutoReset），再抢互斥体——这样第二次启动一定能找到通知通道
* 第二次启动：给事件 `Set()` 后自己退出（实测 0.6 秒退场）
* 已有实例用一个 800ms 轮询的 WinForms Timer 检查事件，收到就调用现成的 `Show-Panel`，把面板 `Show` + `ShowWindow(SW_RESTORE)` + `SetForegroundWindow`
* 只唤面板，不重放 `--auto`/`--wifi`，避免二次启动把已有会话重连一次
* 退出时 `Stop` + `Dispose` 该 Timer 与事件句柄

**验收**：托盘里有实例 → 双击桌面图标 → 面板弹到前台且状态栏文案不变；连续双击多次不产生额外进程（已隔离测试通过，trace 里可看到 `wake: show panel from second launch`）。

---

## 2. 低亮投屏已实现（记录实测口径，供后续维护）

**实现**：`src/brightness.ps1`（`Save-BrightnessSession` / `Apply-DimBrightness` / `Restore-Brightness` / `Repair-BrightnessIfStuck`），控制台面板「低亮投屏」勾选框，托盘「恢复屏幕亮度」，连接前记录 → 置 0，断开/退出/看门狗/启动自愈均还原。

**实测结论（Meizu 20 Pro，Android 16）**：

* **`settings put system screen_brightness` 在这台 ROM 上无效**：写 0 后 `dumpsys display` 的 `mScreenBrightness` 仍是 `1.0`（面板没变暗）。真正生效的是 `cmd display set-brightness 0.0`（1.0 → 0.0）。因此主路径改成 cmd display，settings 仅作老设备兜底。
* 纯亮度调节 **不会**新增 dim/scrim 图层，`screencap` 内容照常（平均亮度 42/255），所以不存在遮挡导致的触控失灵
* 面板下限约 2.5 尼特（`mBacklight 0.00342 → mNits 2.549`），`mEvenDimmerEnabled=false`，极暗通道不可用
* 会话记录同时保存 `applied`（0..1 实际输出）与 settings 的 `mode/value`；真机往返 `1.0/2047 → 0/1 → 1.0/2047`

**输入法补充**：强关投屏/强杀看门狗后可能停在美式键盘，已加 `ime-watch.ps1 -Restore` 与看门狗退出前自还原。

**仍待决策**：是否再验 scrcpy 的 `-S`（面板断电）。用户明确暂不实验，怕设备出问题。

---
