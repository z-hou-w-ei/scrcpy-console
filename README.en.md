# scrcpy-console

## Why this exists (author's note)

I don't want to sign in to my personal WeChat on a work computer, yet when I want to slack off I have to keep reaching for my phone. That's when [scrcpy](https://github.com/Genymobile/scrcpy) came to mind.

I had used it before on the classroom projector to play video material for my students, and it worked great. Don't ask why I didn't just log into my own account for that — I've already explained the reason. USB sticks get forgotten easily and are a hassle anyway.

So this time, to make slacking off a bit smoother, I wrapped a few scripts around scrcpy. The goal is simple: make it fit my own habits. It was never meant to be a general-purpose product.

Thanks to scrcpy — one for all, all for one.

---

A Windows front-end for scrcpy: turns the command-line screen mirroring tool into a double-click GUI with the pieces the CLI version lacks — USB/Wi-Fi switching, a system tray icon, automatic keyboard-layout switching, automatic mobile-hotspot handling, and a mouse that can leave the mirror window.

> This repository is a **wrapper**. The actual mirroring engine is scrcpy by Genymobile; its official release files are bundled unmodified under `vendor/scrcpy/` (see [Bundled binaries](#bundled-binaries)).

---

## Features

| Feature | Details |
|---|---|
| GUI console | Double-click entry, no console window; hides into the tray after connecting |
| USB / Wi-Fi | Radio switch in the panel; Wi-Fi mode makes sure the hotspot is up first |
| Hotspot lifecycle | Turns the Windows mobile hotspot on before a Wi-Fi session and restores the previous state afterwards (stays on if it was already on) |
| Auto keyboard layout | Switches to US English while the mirror window has focus, restores the previous layout when focus leaves |
| Free mouse | `--mouse=sdk`, so the cursor can cross the mirror window border |
| Keep awake | `--stay-awake` keeps the phone unlocked while mirroring |
| Quality presets | Smooth / Standard / Sharp, mapped to `--max-fps` and video bit-rate |
| Tray balloon | Confirms the link type and the enabled options on connect |
| Single-instance wake | While the console sits in the tray, double-clicking the desktop icon brings the panel back instead of doing nothing |

## Layout

```
scrcpy-console/
├── src/
│   ├── launcher/ScrcpyLauncher.cs   silent launcher compiled into scrcpy.exe
│   ├── scrcpy-gui.ps1               the console (WinForms + tray icon)
│   ├── wifi-pair.ps1                wireless-debugging pairing (adb pair + mDNS discovery)
│   ├── ime-watch.ps1                focus polling, switches keyboard layout
│   └── hotspot.ps1                  mobile hotspot on/off (WinRT tethering API)
├── tools/                           hotspot on / off / toggle .cmd
├── vendor/scrcpy/                   official scrcpy v5.0.1 release, unmodified
├── install/
│   ├── install.ps1                  expand vendor, build launcher, create shortcuts
│   └── publish-gitee.ps1            publish to Gitee via API (no git needed)
├── assets/scrcpy.ico                multi-size icon (256/64/48/32/16)
├── LICENSE                          MIT (this project's own scripts)
└── NOTICE.md                        third-party components and licenses
```

## Bundled binaries

Files under `vendor/scrcpy/` are **not** this project's work — they are an unmodified copy of the official [scrcpy](https://github.com/Genymobile/scrcpy) v5.0.1 release, bundled so that `git clone` gives a working setup:

* Copyright belongs to Romain Vimont and Genymobile, licensed under **Apache License 2.0**; the full text ships as `vendor/scrcpy/LICENSE.txt`
* Nothing was modified or re-signed. At install time `install.ps1` only renames `scrcpy.exe` to `scrcpy-core.exe`, purely because this project's own launcher occupies the name `scrcpy.exe`
* `adb.exe` and friends belong to Google LLC (Apache-2.0); `SDL3.dll` is zlib; the FFmpeg DLLs are LGPL-2.1
* If the original author or any rights holder objects to this repository redistributing their binaries, **open an issue and it will be removed immediately**, replaced by "download the official release yourself"
* This project is not affiliated with, endorsed by, or sponsored by Genymobile or Google

## Requirements

* Windows 10 / 11
* Windows PowerShell 5.1 (the console and the hotspot script run under 5.1)
* .NET Framework 4.x (bundled with Windows, used to build the launcher)
* scrcpy official release (bundled in `vendor/scrcpy`, or bring your own)

## Install

1. Clone the repository anywhere, e.g. `D:\Tools\scrcpy`.
2. Run:
   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File install\install.ps1 -TargetDir "D:\Tools\scrcpy"
   ```
   It will:
   * expand `vendor\scrcpy` into the target directory and rename `scrcpy.exe` → `scrcpy-core.exe`
   * copy `src\*.ps1` and generate the hotspot `.cmd` wrappers
   * compile `src\launcher\ScrcpyLauncher.cs` into a **`scrcpy.exe`** with icon (double-click opens the console, no console window)
   * create Desktop / Start Menu / Startup shortcuts
3. Enable **USB debugging** on the phone and confirm the authorization prompt.

> In the runtime directory `scrcpy.exe` is the launcher and `scrcpy-core.exe` is the upstream engine — don't mix them up.
> You can also use the repository itself as the runtime directory: `install.ps1 -TargetDir <repo root>`; the generated `scrcpy.exe` is already ignored by git.

## Usage

* **USB**: plug the cable, choose “USB 有线”, connect.
* **Wi-Fi**: phone and PC on the same network (or connected to the PC's mobile hotspot), choose “无线 WiFi”.
  * **Cable-free first pairing (Android 11+)**: on the phone open `Settings → System → Developer options → Wireless debugging`, tap “Pair device with pairing code” and leave that dialog open; on the PC open “无线配对…”, press “自动发现”, type the 6-digit code shown on the phone, then “配对并连接”. No cable, and no `adb tcpip 5555` needed.
  * The console remembers the working `IP:port` in `wifi.json` next to the scripts (git-ignored) and reconnects automatically on the next launch.
  * **Ports change after a reboot**: the saved address going stale is normal — run the pairing flow again (usually you only need the fresh `IP:port` from the top of the wireless-debugging page).
  * The legacy route still works: connect over USB once, and the console runs `adb tcpip 5555`, reads the phone IP and connects wirelessly.
  * Wi-Fi mode turns the hotspot on before connecting and restores the previous state on disconnect.
  * mDNS discovery prefers devices **inside the local subnet**, so it will not grab somebody else's phone on the same LAN; if nothing is found, type `IP:port` into the “无线地址” box.
* **Low-brightness mode (the phone panel barely glows)**: tick “低亮投屏” and the console pushes the phone's actual output brightness to the lowest step before connecting (through DisplayManager's `cmd display set-brightness`, because writing `settings put screen_brightness` alone changes nothing on some ROMs), then restores the original value on disconnect.
  * After applying, it reads back `mScreenBrightness` from `dumpsys display` to verify; if the panel did not actually go down the console says so instead of pretending.
  * It stacks no overlay window at all, so Android's “Untrusted touch due to occlusion” protection never triggers — touch, keyboard and mouse keep working.
  * The panel lands at roughly **2.5 nits** (the bottom of this device's brightness curve): effectively invisible in a lit room, a very faint glow in a pitch-black room. That is the hardware floor; the API cannot go lower.
  * The original value is saved to `brightness-session.json` next to the scripts (git-ignored). If the console is killed or the power drops before it can restore, the **next launch restores automatically**; the tray menu also has “恢复屏幕亮度” as a manual fallback.
* **Manual hotspot**: the three `.cmd` files under `tools/`.

scrcpy's built-in shortcuts inside the mirror window:

| Shortcut | Action |
|---|---|
| `Ctrl+H` | Home |
| `Ctrl+B` | Back |
| `Ctrl+S` | App switch |
| `Ctrl+M` | Menu |
| `Ctrl+P` | Power |
| `Ctrl+O` / `Ctrl+Shift+O` | Screen off / on |
| `Ctrl+V` | Paste host clipboard |

## Known limitations

* Wi-Fi mirroring needs a shared network (PC hotspot or same LAN); `adb connect` cannot cross subnets.
* On a 2.4 GHz hotspot the usable throughput is roughly 15–17 Mbps; the Standard preset (16 Mbps / 60 fps) fits, switch to Smooth if it stutters.
* The hotspot is toggled through the Windows WinRT tethering API — the same switch as in Settings. No credentials are written; the SSID/password are whatever is already configured in Windows.
* Pinning to the Windows 11 Start screen cannot be scripted; right-click the Start Menu shortcut once.

Planned improvements live in [`TODO.md`](TODO.md), each with current behaviour, expected behaviour and an implementation direction.

## Privacy

* No device serial numbers, IP addresses, `adbkey` files, or logs are committed; `.gitignore` covers them.
* The tool collects nothing and phones home to nothing; all state stays local.
* adb authorization is always confirmed by the user on the device.

## Credits

* Mirroring engine: **scrcpy** — https://github.com/Genymobile/scrcpy (Apache-2.0)
* Debug bridge: Android SDK Platform-Tools (`adb`), Google, Apache-2.0

## License

This project's own PowerShell / C# / batch scripts and icon are released under the **MIT** license (`LICENSE`).
Bundled third-party components keep their upstream licenses (`NOTICE.md`).

---

[中文说明](README.md)
