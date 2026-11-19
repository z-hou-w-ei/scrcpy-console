# scrcpy-console

[English](README.en.md) | 中文

## 为什么做这个（作者自述）

我不想在工作电脑上登录自己的微信，可摸鱼的时候又得频繁掏手机，于是想起了 scrcpy 这个项目。

之前在教室多媒体上给学生放视频资料时用过它，感觉很好使。别问我为什么不登上自己的账号放资料——理由前面已经说过了；U 盘也很容易忘，还麻烦。

总之，这一次为了摸鱼更方便，我在 scrcpy 基础上套了几个脚本。目的仅仅是想让它更符合我个人的使用习惯，没打算做成通用产品。

感谢 scrcpy，人人为我，我为人人。

---

Windows 下的 Android 投屏控制台：把 [scrcpy](https://github.com/Genymobile/scrcpy) 包装成「双击即用」的图形界面，补齐了原生命令行版本缺的几件事——有线/无线一键切换、系统托盘、自动输入法切换、自动开关移动热点、鼠标自由穿出窗口。

投屏内核不是本项目写的：scrcpy v5.0.1 官方发行包已原样内置在 `vendor/scrcpy/`，克隆即可使用，来源与许可见下方「内置二进制说明」。

---

## 功能

| 功能 | 说明 |
|---|---|
| 图形控制台 | 双击入口直接弹面板，无黑窗；连接后自动最小化到系统托盘 |
| 有线 / 无线 | 面板里单选；无线模式下自动确保移动热点已开 |
| 热点自动管理 | 连无线前若热点是关的就开启，断开后还原为原来的状态（原本开着就保持开着） |
| 自动输入法 | 焦点进入投屏窗口切英文键盘（字母直达手机），离开则还原中文 |
| 鼠标模式 | `--mouse=sdk` 让鼠标可自由穿出投屏窗口边界 |
| 保持唤醒 | 投屏期间手机不锁屏（`--stay-awake`） |
| 画质档位 | 流畅 / 标准 / 高清，对应不同 `--max-fps` 与码率 |
| 托盘通知 | 连接成功弹气泡，显示连接方式与已启用的选项 |

## 目录结构

```
scrcpy-console/
├── src/
│   ├── launcher/ScrcpyLauncher.cs   编译成 scrcpy.exe 的静默启动器
│   ├── scrcpy-gui.ps1               控制台主程序（WinForms + 托盘）
│   ├── wifi-pair.ps1                无线调试配对/连接（adb pair + mDNS 发现）
│   ├── brightness.ps1               低亮投屏：原生亮度存取与还原（可单独运行排查）
│   ├── ime-watch.ps1                焦点轮询，自动切换输入法
│   └── hotspot.ps1                  移动热点开关（WinRT 网络共享接口）
├── tools/
│   ├── 开启热点.cmd
│   ├── 关闭热点.cmd
│   └── 热点开关.cmd
├── assets/
│   └── scrcpy.ico                   多尺寸图标（256/64/48/32/16）
├── vendor/
│   └── scrcpy/                      scrcpy 官方发行包（原样内置，含 LICENSE.txt）
├── install/
│   ├── install.ps1                  一键布置：展开内置发行包、编译启动器、建快捷方式
│   └── publish-gitee.ps1            用 API 发布到 Gitee（不依赖 git）
├── LICENSE                          MIT（本项目自有脚本）
└── NOTICE.md                        第三方组件与许可声明
```

## 内置二进制说明（重要）

`vendor/scrcpy/` 里的文件**不是本项目开发的作品**，而是 [scrcpy](https://github.com/Genymobile/scrcpy) 官方发行包（v5.0.1）的**原样拷贝**，为方便直接克隆即用而一并提交：

* 版权归原作者 Romain Vimont 与 Genymobile，遵循 **Apache License 2.0**，许可全文见 `vendor/scrcpy/LICENSE.txt`
* 未做任何修改、未改动签名，仅文件名在安装时由 `install.ps1` 把 `scrcpy.exe` 改为 `scrcpy-core.exe`（纯粹因为本项目自己的启动器占用了 `scrcpy.exe` 这个名字）
* `adb.exe` 等 Platform-Tools 文件归 Google LLC，Apache-2.0；`SDL3.dll` 为 zlib 许可；FFmpeg 相关 dll 为 LGPL-2.1
* 若原作者或任何权利人对本仓库内含其二进制有异议，**提交 issue 或联系仓库维护者后会立即移除**，改用「自行下载官方发行包」的方式
* 本项目与 Genymobile / Google 无任何隶属或背书关系，仓库名与文档中出现的第三方名称仅用于说明来源与兼容性

## 依赖

* Windows 10 / 11
* Windows PowerShell 5.1（控制台与热点脚本均运行在 5.1 下）
* .NET Framework 4.x（系统自带，用于编译启动器）
* scrcpy 官方发行包（仓库已内置于 `vendor/scrcpy`，也可自行下载替换）

## 安装

1. 克隆本仓库到本地任意目录（例如 `D:\Tools\scrcpy`）。
2. 运行：
   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File install\install.ps1 -TargetDir "D:\Tools\scrcpy"
   ```
   它会：
   * 把 `vendor\scrcpy` 里的官方发行包展开到目标目录，并把官方 `scrcpy.exe` 改名为 `scrcpy-core.exe`
   * 复制 `src\*.ps1`、生成热点开关的 cmd
   * 用系统自带 `csc.exe` 把 `src\launcher\ScrcpyLauncher.cs` 编译成带图标的 **`scrcpy.exe`**（双击即拉起控制台，无黑窗）
   * 创建桌面 / 开始菜单 / 开机启动三处快捷方式
3. 手机开启「USB 调试」并在电脑上确认授权。

> 运行目录里 `scrcpy.exe` 是启动器、`scrcpy-core.exe` 是上游本体，两者不要搞反。
> 想把仓库直接当运行目录用也可以：`install.ps1 -TargetDir <仓库根目录>`，此时生成的 `scrcpy.exe` 已在 `.gitignore` 里排除。

## 使用

* **有线**：插数据线 → 面板选「USB 有线」→ 连接。
* **无线**：手机与电脑连同一个局域网（或连电脑开的移动热点）→ 面板选「无线 WiFi」。
  * **免数据线的首次配对（Android 11+）**：手机上打开 `设置 → 系统 → 开发者选项 → 无线调试`，点「使用配对码配对设备」，让弹窗保持打开；电脑面板点「无线配对…」→「自动发现」→ 填手机弹窗上的 6 位配对码 →「配对并连接」。全程不需要插线，也不用 `adb tcpip 5555`。
  * 控制台会把配对成功后的 `IP:端口` 记在 `wifi.json`（与脚本同目录，已在 `.gitignore` 中），下次启动自动回连。
  * **手机重启后端口会变**：`wifi.json` 里的旧地址连不上是正常的，再走一次上面的配对流程即可（多数机型已配对过只需重新取一次页面顶部的 IP:端口）。
  * 老办法仍然保留：先用 USB 连一次，控制台会自动 `adb tcpip 5555` 并读取手机 IP 建立无线连接。
  * 无线模式会在连接前自动开启移动热点，断开后按原状态还原（原本开着就保持开着，原本关着就关回去）。
  * mDNS 自动发现会优先挑**本机网段内**的设备，避免连到同一局域网里别人的手机；发现不到时可在面板「无线地址」里手填 `IP:端口`。
* **低亮投屏（手机面板几乎不发光）**：勾选「低亮投屏」后，控制台在连接前把手机的实际输出亮度压到最低档（走 DisplayManager 的 `cmd display set-brightness`，不再依赖 `settings put`——后者在部分 ROM 上根本不改变输出亮度），断开时按原值还原。
  * 施加后会回读 `dumpsys display` 的 `mScreenBrightness` 校验，没压下去就如实提示，不会假装成功。
  * 不叠加任何覆盖窗口，所以不会触发 Android 的 “Untrusted touch due to occlusion”，触控、键盘、鼠标都正常。
  * 面板真实亮度约为 **2.5 尼特**（这台机器的亮度曲线下限），亮灯环境基本看不见，全黑房间仍有很淡的微光——这是硬件下限，API 无法再低。
  * 原亮度记录写在同目录 `brightness-session.json`（已 `.gitignore`）。若控制台被强杀、断电导致没来得及还原，**下次启动会自动按记录还原**；托盘右键也有「恢复屏幕亮度」可手动兜底。
* **热点手动控制**：`tools/` 下三个 cmd，双击即可开启 / 关闭 / 切换。

投屏窗口内的快捷键（scrcpy 自带）：

| 快捷键 | 作用 |
|---|---|
| `Ctrl+H` | 主页 |
| `Ctrl+B` | 返回 |
| `Ctrl+S` | 最近任务 |
| `Ctrl+M` | 菜单 |
| `Ctrl+P` | 电源键 |
| `Ctrl+O` / `Ctrl+Shift+O` | 关屏 / 开屏 |
| `Ctrl+V` | 把电脑剪贴板粘贴到手机 |

## 已知限制

* 无线投屏需要电脑能提供热点或手机与电脑同网段；跨网段（例如不在同一局域网）无法 `adb connect`。
* 2.4 GHz 热点下有效带宽约 15–17 Mbps，标准档（16 Mbps / 60 fps）基本够用，若出现卡顿请切「流畅」档。
* 移动热点通过 Windows WinRT 接口控制，等同系统设置里的开关，不写入任何凭据，SSID 与密码沿用系统里已配置的那份。
* 开始菜单「固定到开始屏幕」在 Windows 11 不支持脚本操作，需在开始菜单里对快捷方式右键固定一次。

待优化项统一记在 [`TODO.md`](TODO.md)，含现状、预期与实现方向。

## 隐私与安全

* 仓库内**不含**任何设备序列号、IP 地址、`adbkey` 私钥、日志文件；`.gitignore` 已排除这些内容。
* 运行时不采集、不上传任何数据，所有配置都在本机。
* 手机端 adb 授权由用户自己确认，脚本不会绕过。

## 源项目与致谢

* 投屏内核：**scrcpy** — https://github.com/Genymobile/scrcpy （作者 Romain Vimont / Genymobile，Apache-2.0）
* 调试桥：Android SDK Platform-Tools（`adb`），Google，Apache-2.0

本项目与上述项目无隶属关系，仅为本地化封装。

## 许可

本项目自有的 PowerShell / C# / 批处理脚本与图标以 **MIT** 协议发布，见 `LICENSE`。
随包使用的第三方组件（scrcpy、adb、SDL3、FFmpeg 等）各自遵循其原许可，见 `NOTICE.md`。
