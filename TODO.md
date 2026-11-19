# 待优化（TODO）

按优先级从高到低排列。每条都附上现状、预期与实现方向，方便哪天捡起来直接动手。

---

## 1. 托盘图标存在时，双击桌面快捷方式应唤出已运行的程序

**现状**：`src/scrcpy-gui.ps1` 用 `Global\ScrcpyConsoleGuiMutex` 做单实例保护：

```powershell
$script:instanceMutex = New-Object System.Threading.Mutex($false, 'Global\ScrcpyConsoleGuiMutex')
if (-not $script:instanceMutex.WaitOne(0)) { exit }
```

于是第二次启动（双击桌面「手机投屏」）会在拿不到互斥体时直接 `exit`，用户看到的现象就是"双击没反应"。

**预期**：已有实例在托盘里时，双击快捷方式 → 把已有实例的控制台面板 `Show` 出来并置前，而不是静默退出；如果这次带的是 `--auto` / `--wifi`，已有实例不应重复发起连接。

**实现方向**：

* 保留单实例互斥，但拿不到时先释放后通知：用命名事件（`System.Threading.EventWaitHandle`）或 `WM_COPYDATA`（向窗口类 `SDL_app` 以外的本程序隐藏窗口发消息）唤醒已有实例
* 已有实例侧用一个 `System.Windows.Forms.Timer` 或后台等待线程监听该事件，收到后调用现有的 `Show-Panel`
* 通知通道要带一个"是否请求连接"的标志，避免第二次启动的 `--wifi` 参数把已有会话重连一次

**验收**：托盘里有实例 → 双击桌面图标 → 面板弹到前台且状态栏文案不变；连续双击多次不产生额外进程。

---

（熄屏投屏相关方案仍在讨论中，确认后再补到这里。）
