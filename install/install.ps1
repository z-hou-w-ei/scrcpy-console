#Requires -Version 5.1
<#
  install.ps1 - 把 scrcpy-console 布置成一个可直接双击使用的运行目录

  用法：
    1) 先把 scrcpy 官方发行包解压到目标目录，并把其中的 scrcpy.exe 改名为 scrcpy-core.exe
       （发行包里的 adb.exe / scrcpy-server / SDL3.dll / av*.dll 等都留在同一目录）
    2) 运行：
         powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -TargetDir "D:\Tools\scrcpy"
       可选参数：
         -NoShortcuts   只布置文件，不创建快捷方式
         -NoAutostart   不创建开机启动项

  脚本做的事情：
    * 复制 src\*.ps1 到目标目录
    * 生成热点开关的 cmd
    * 用系统自带 csc.exe 把启动器编译成 目标目录\scrcpy.exe（带图标、无窗口）
    * 创建 桌面 / 开始菜单 / 开机启动 三处快捷方式
#>

param(
    [string]$TargetDir,
    [switch]$NoShortcuts,
    [switch]$NoAutostart
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot   # 仓库根目录
if (-not $TargetDir) { $TargetDir = $repoRoot }

if (-not (Test-Path $TargetDir)) { throw "目标目录不存在：$TargetDir" }
$TargetDir = (Resolve-Path $TargetDir).Path
Write-Host "运行目录：$TargetDir"

# ---------- 1. 前置检查 / 内置发行包展开 ----------
# 仓库自带 vendor\scrcpy（官方发行包原样文件）。目标目录还没有 scrcpy-core.exe 时，
# 自动把内置包复制过去，并把官方 scrcpy.exe 改名为 scrcpy-core.exe。
$core = Join-Path $TargetDir 'scrcpy-core.exe'
$vendor = Join-Path $repoRoot 'vendor\scrcpy'
if ((-not (Test-Path $core)) -and (Test-Path (Join-Path $vendor 'scrcpy.exe'))) {
    Write-Host '目标目录没有 scrcpy 本体，正在从 vendor\scrcpy 展开内置发行包…'
    Copy-Item (Join-Path $vendor '*') $TargetDir -Force
    $official = Join-Path $TargetDir 'scrcpy.exe'
    if (Test-Path $official) { Rename-Item $official 'scrcpy-core.exe' -Force }
    Write-Host '内置发行包已展开，scrcpy.exe 已改名为 scrcpy-core.exe。'
}

$core = Join-Path $TargetDir 'scrcpy-core.exe'
if (-not (Test-Path $core)) {
    Write-Warning "没有找到 scrcpy-core.exe，也没有可用的内置发行包。请自行解压 scrcpy 官方发行包，并把 scrcpy.exe 改名为 scrcpy-core.exe。"
}
foreach ($need in 'adb.exe', 'scrcpy-server', 'SDL3.dll') {
    if (-not (Test-Path (Join-Path $TargetDir $need))) { Write-Warning "缺少 $need（可用 vendor\scrcpy 或官方发行包补齐）" }
}

# ---------- 2. 复制脚本 ----------
foreach ($f in 'scrcpy-gui.ps1', 'ime-watch.ps1', 'hotspot.ps1', 'wifi-pair.ps1', 'brightness.ps1') {
    $src = Join-Path $repoRoot "src\$f"
    if (Test-Path $src) { Copy-Item $src (Join-Path $TargetDir $f) -Force; Write-Host "已复制 $f" }
}
Copy-Item (Join-Path $repoRoot 'assets\scrcpy.ico') (Join-Path $TargetDir 'scrcpy.ico') -Force

# ---------- 3. 热点开关的 cmd（指向运行目录内的 hotspot.ps1） ----------
$cmdBody = @'
@echo off
chcp 65001 >nul
set "HERE=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%hotspot.ps1" -Action __ACTION__
__PAUSE__
'@
$cmds = @{
    '开启热点.cmd' = @{ action = 'start'; pause = 'if errorlevel 1 pause' }
    '关闭热点.cmd' = @{ action = 'stop'; pause = 'if errorlevel 1 pause' }
    '热点开关.cmd' = @{ action = 'toggle'; pause = 'timeout /t 2 >nul' }
}
foreach ($n in $cmds.Keys) {
    $body = $cmdBody.Replace('__ACTION__', $cmds[$n].action).Replace('__PAUSE__', $cmds[$n].pause)
    [System.IO.File]::WriteAllText((Join-Path $TargetDir $n), $body, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "已生成 $n"
}

# ---------- 4. 编译启动器 ----------
$csc = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) { throw '找不到 csc.exe（需要 .NET Framework 4.x）' }

$launcherCs = Join-Path $repoRoot 'src\launcher\ScrcpyLauncher.cs'
$outExe = Join-Path $TargetDir 'scrcpy.exe'
if (Test-Path $outExe) { Rename-Item $outExe 'scrcpy.exe.bak' -Force -ErrorAction SilentlyContinue }

$cscArgs = @(
    '/nologo', '/target:winexe',
    "/win32icon:$(Join-Path $repoRoot 'assets\scrcpy.ico')",
    "/out:$outExe", $launcherCs
)
& $csc @cscArgs | Out-Null
if (-not (Test-Path $outExe)) { throw '启动器编译失败' }
Write-Host ("已生成 scrcpy.exe（" + (Get-Item $outExe).Length + " 字节）")

# ---------- 5. 快捷方式 ----------
if (-not $NoShortcuts) {
    $ws = New-Object -ComObject WScript.Shell
    $targets = @(
        @{ dir = [Environment]::GetFolderPath('Desktop'); name = '手机投屏.lnk' }
        @{ dir = [Environment]::GetFolderPath('Programs'); name = '手机投屏控制台.lnk' }
    )
    if (-not $NoAutostart) {
        $targets += @{ dir = [Environment]::GetFolderPath('Startup'); name = '手机投屏控制台.lnk' }
    }
    foreach ($t in $targets) {
        $lnk = $ws.CreateShortcut((Join-Path $t.dir $t.name))
        $lnk.TargetPath = $outExe
        $lnk.WorkingDirectory = $TargetDir
        $lnk.IconLocation = "$outExe,0"
        $lnk.Description = '手机投屏控制台'
        $lnk.Save()
        Write-Host ("已创建快捷方式：" + (Join-Path $t.dir $t.name))
    }
}

Write-Host ''
Write-Host '安装完成。双击 scrcpy.exe（或桌面「手机投屏」）即可启动控制台。'
