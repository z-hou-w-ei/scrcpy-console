#Requires -Version 5.1
<#
  brightness.ps1 - 低亮投屏用的原生亮度控制（不叠任何覆盖窗口）

  背景（Meizu 20 Pro / Android 16 实测）：
    * screen_brightness = 0 时 SurfaceFlinger 图层表不新增任何 dim/scrim，
      截图内容照常（平均亮度 42/255），因此不会触发
      "Untrusted touch due to occlusion"，触控正常
    * 面板真实亮度 = 亮度曲线最低档约 2.5 尼特（设备 mNits 首档），API 无法再低

  被 scrcpy-gui.ps1 以 dot-source 方式加载，也可单独排查：
     powershell -File brightness.ps1 -Status
     powershell -File brightness.ps1 -Apply -Serial 192.168.137.176:5555
     powershell -File brightness.ps1 -Restore
#>

param(
    [switch]$Status,
    [switch]$Apply,
    [switch]$Restore,
    [string]$Serial,
    [string]$AdbExe,
    [string]$ConfigDir
)

$script:adb = if ($AdbExe) { $AdbExe } else { Join-Path $PSScriptRoot 'adb.exe' }
$script:configDir = if ($ConfigDir) { $ConfigDir } else { $PSScriptRoot }
$script:sessionFile = Join-Path $script:configDir 'brightness-session.json'

function Get-AnySerial {
    param([string]$Prefer)
    if ($Prefer) { return $Prefer }
    foreach ($line in (& $script:adb devices 2>$null)) {
        if ($line -match '^\s*([^\s]+)\s+device\b') { return $Matches[1] }
    }
    return ''
}

function Get-BrightnessValue {
    param([string]$Device)
    if (-not $Device) { return $null }
    $mode  = ((& $script:adb -s $Device shell 'settings get system screen_brightness_mode' 2>&1) -join '').Trim()
    $value = ((& $script:adb -s $Device shell 'settings get system screen_brightness' 2>&1) -join '').Trim()
    if ($mode -notmatch '^[01]$' -or $value -notmatch '^\d+$') { return $null }
    return [pscustomobject]@{ mode = [int]$mode; value = [int]$value }
}

function Save-BrightnessSession {
    param([string]$Device)
    $cur = Get-BrightnessValue -Device $Device
    if (-not $cur) { return $false }
    $obj = [ordered]@{
        serial = $Device
        mode   = $cur.mode
        value  = $cur.value
        saved  = (Get-Date -Format 's')
        note   = '断开投屏时按这里还原；若本文件残留说明上次异常退出，下次启动会自动还原'
    }
    try {
        [System.IO.File]::WriteAllText($script:sessionFile, ($obj | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
        return $true
    } catch { return $false }
}

function Apply-DimBrightness {
    param([string]$Device)
    if (-not $Device) { return }
    & $script:adb -s $Device shell 'settings put system screen_brightness_mode 0' 2>&1 | Out-Null
    & $script:adb -s $Device shell 'settings put system screen_brightness 0' 2>&1 | Out-Null
}

function Restore-Brightness {
    $serial = ''
    $mode = $null
    $value = $null
    if (Test-Path $script:sessionFile) {
        try {
            $o = Get-Content $script:sessionFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $serial = [string]$o.serial
            $mode = [int]$o.mode
            $value = [int]$o.value
        } catch { }
    }
    if (-not $serial) { $serial = Get-AnySerial }
    if (-not $serial -or $null -eq $mode) { return $false }
    & $script:adb -s $serial shell ("settings put system screen_brightness " + $value) 2>&1 | Out-Null
    & $script:adb -s $serial shell ("settings put system screen_brightness_mode " + $mode) 2>&1 | Out-Null
    Remove-Item $script:sessionFile -Force -ErrorAction SilentlyContinue
    return $true
}

# 兜底：没有记录但亮度被人为压到最低档时，恢复到能看清的程度
function Repair-BrightnessIfStuck {
    param([string]$Device)
    if (-not $Device) { $Device = Get-AnySerial }
    if (-not $Device) { return }
    $cur = Get-BrightnessValue -Device $Device
    if (-not $cur) { return }
    if ($cur.mode -eq 0 -and $cur.value -le 3) {
        & $script:adb -s $Device shell 'settings put system screen_brightness_mode 1' 2>&1 | Out-Null
        & $script:adb -s $Device shell 'settings put system screen_brightness 128' 2>&1 | Out-Null
    }
}

# ---------- standalone CLI ----------
if ($Status) {
    $d = Get-AnySerial -Prefer $Serial
    Write-Host ('device = ' + $d)
    $cur = Get-BrightnessValue -Device $d
    if ($cur) { Write-Host ('mode = ' + $cur.mode + '  value = ' + $cur.value) } else { Write-Host '读不到亮度' }
    Write-Host ('session file = ' + $script:sessionFile + ' exists=' + (Test-Path $script:sessionFile))
    if (Test-Path $script:sessionFile) { Get-Content $script:sessionFile | Out-String | Write-Host }
}
if ($Apply) {
    $d = Get-AnySerial -Prefer $Serial
    $ok = Save-BrightnessSession -Device $d
    Write-Host ('saved=' + $ok)
    if ($ok) { Apply-DimBrightness -Device $d; Write-Host 'applied brightness 0' }
}
if ($Restore) {
    $ok = Restore-Brightness
    Write-Host ('restored=' + $ok)
}
