# 第三方组件与许可声明

本仓库**内置**了下列第三方二进制文件（位于 `vendor/scrcpy/`），均为官方发行包的原样拷贝，
未修改、未重新签名，仅为「克隆后即可直接运行」而一并提交。

**版权与归属**：这些文件的著作权属于各自的原始作者，本项目仅做分发，不主张任何权利。
**异议处理**：若原作者或任何权利人认为本仓库分发其二进制不妥，提出后维护者将立即删除 `vendor/scrcpy/`
目录，改为要求使用者自行从官方渠道下载。

## 1. scrcpy

* 项目：https://github.com/Genymobile/scrcpy
* 作者：Romain Vimont / Genymobile
* 许可：Apache License 2.0
* 用途：Android 屏幕镜像与输入注入内核。本项目以其发行包中的 `scrcpy.exe` 重命名为 `scrcpy-core.exe` 后调用。

Apache-2.0 全文见：http://www.apache.org/licenses/LICENSE-2.0

## 2. Android SDK Platform-Tools (adb)

* 项目：https://developer.android.com/studio/releases/platform-tools
* 作者：Google LLC
* 许可：Apache License 2.0
* 用途：设备连接、无线调试（`adb tcpip` / `adb connect`）。

## 3. SDL3

* 项目：https://github.com/libsdl-org/SDL
* 许可：zlib License
* 用途：scrcpy 的窗口与渲染层，随 scrcpy 发行包分发。

## 4. FFmpeg (libavcodec / libavformat / libavutil / swresample)

* 项目：https://ffmpeg.org
* 许可：LGPL-2.1（scrcpy 官方发行包使用 LGPL 构建）
* 用途：H.264 视频解码，随 scrcpy 发行包分发。

## 5. 本项目自有部分

* 文件：`src/*.ps1`、`src/launcher/ScrcpyLauncher.cs`、`tools/*.cmd`、`assets/scrcpy.ico`、`install/install.ps1`
* 作者：本仓库贡献者
* 许可：MIT（见 `LICENSE`）

## 商标说明

Android 是 Google LLC 的商标。本项目名称、文档中出现的第三方名称仅用于说明兼容性，不代表任何官方背书或隶属关系。
