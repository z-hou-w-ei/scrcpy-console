#Requires -Version 5.1
<#
  brightness.ps1 - 低亮投屏用的原生亮度控制（不叠任何覆盖窗口）

  为什么不用 settings put system screen_brightness：
    这台 Meizu 20 Pro（Android 16）上，直接写 Settings.System 的值**不会**改变实际输出亮度
    （实测写 0 后 dumpsys display 的 mScreenBrightness 仍是 1.0），
    只有走 DisplayManager 的 `cmd display set-brightness <0..1>` 才会真正压下去（1.0 -> 0.0）。
    所以主路径是 cmd display，settings 写入只作为老设备的兜底。

  为什么不会触发触控失灵：
    纯亮度调节不新增任何 dim/scrim 图层（SurfaceFlinger 图层表前后一致，截图内容照常），
    "Untrusted touch due to occlusion" 只针对覆盖窗口。面板下限约 2.5 尼特（硬件曲线首档）。

  被 scrcpy-gui.ps1 以 dot-source 方式加载，也可单独排查：
     powershell -File brightness.ps1 -Status
     powershell -File brightness.ps1 -Apply
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

# dumpsys display 里第一处 mScreenBrightness 才是主屏的实际输出亮度（0..1）
function Get-AppliedBrightness {
    param([string]$Device)
    if (-not $Device) { return $null }
    $text = ((& $script:adb -s $Device shell 'dumpsys display' 2>&1) -join "`n")
    $m = [regex]::Match($text, 'mScreenBrightness=([0-9.]+)')
    if (-not $m.Success) { return $null }
    return [double]$m.Groups[1].Value
}

function Get-BrightnessValue {
    param([string]$Device)
    if (-not $Device) { return $null }
    $mode  = ((& $script:adb -s $Device shell 'settings get system screen_brightness_mode' 2>&1) -join '').Trim()
    $value = ((& $script:adb -s $Device shell 'settings get system screen_brightness' 2>&1) -join '').Trim()
    if ($mode -notmatch '^[01]$' -or $value -notmatch '^\d+$') { return $null }
    return [pscustomobject]@{
        mode    = [int]$mode
        value   = [int]$value
        applied = (Get-AppliedBrightness -Device $Device)
    }
}

function Save-BrightnessSession {
    param([string]$Device)
    $cur = Get-BrightnessValue -Device $Device
    if (-not $cur) { return $false }
    # 读不到实际值就按满亮还原；已经处于极低亮度说明没有可信的还原点，跳过（避免还原成黑的）
    if ($null -eq $cur.applied) { $cur.applied = 1.0 }
    if ([double]$cur.applied -le 0.05) { return $false }
    $obj = [ordered]@{
        serial  = $Device
        mode    = $cur.mode
        value   = $cur.value
        applied = [string]([double]$cur.applied)          # 0..1，还原时用它
        saved   = (Get-Date -Format 's')
        note    = '断开投屏时按这里还原；若本文件残留说明上次异常退出，下次启动会自动还原'
    }
    try {
        [System.IO.File]::WriteAllText($script:sessionFile, ($obj | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
        return $true
    } catch { return $false }
}

function Set-DisplayBrightness {
    param([string]$Device, [double]$Ratio)
    if ($Ratio -lt 0) { $Ratio = 0 }
    if ($Ratio -gt 1) { $Ratio = 1 }
    $arg = $Ratio.ToString('0.0000', [System.Globalization.CultureInfo]::InvariantCulture)
    $out = (& $script:adb -s $Device shell "cmd display set-brightness $arg" 2>&1) -join ' '
    if ($out -match 'Error|Unknown|Exception|not found') { return $false }
    return $true
}

function Apply-DimBrightness {
    param([string]$Device)
    if (-not $Device) { return $false }
    # 主路径：DisplayManager（会真正改变输出亮度）
    [void](Set-DisplayBrightness -Device $Device -Ratio 0.0)
    Start-Sleep -Milliseconds 800
    for ($i = 0; $i -lt 3; $i++) {
        $applied = Get-AppliedBrightness -Device $Device
        if ($null -ne $applied -and $applied -le 0.05) { return $true }
        [void](Set-DisplayBrightness -Device $Device -Ratio 0.0)
        Start-Sleep -Milliseconds 700
    }
    # 兜底：没有 cmd display 的老设备，只能写 Settings.System
    & $script:adb -s $Device shell 'settings put system screen_brightness_mode 0' 2>&1 | Out-Null
    & $script:adb -s $Device shell 'settings put system screen_brightness 0' 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    $applied2 = Get-AppliedBrightness -Device $Device
    if ($null -ne $applied2 -and $applied2 -le 0.05) { return $true }
    return $false
}

function Restore-Brightness {
    $serial = ''
    $mode = $null
    $value = $null
    $applied = $null
    if (Test-Path $script:sessionFile) {
        try {
            $o = Get-Content $script:sessionFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $serial = [string]$o.serial
            $mode = [int]$o.mode
            $value = [int]$o.value
            $applied = [double]$o.applied
        } catch { }
    }
    if (-not $serial) { $serial = Get-AnySerial }
    if (-not $serial) { return $false }

    # 先按记录的实际输出亮度还原（这才是眼睛看到的那个）
    if ($null -ne $applied) { [void](Set-DisplayBrightness -Device $serial -Ratio $applied) }
    # 再把 Settings 里的模式/数值写回原样（有些 ROM 以 settings 为准）
    if ($null -ne $value) { & $script:adb -s $serial shell ("settings put system screen_brightness " + $value) 2>&1 | Out-Null }
    if ($null -ne $mode) { & $script:adb -s $serial shell ("settings put system screen_brightness_mode " + $mode) 2>&1 | Out-Null }
    Remove-Item $script:sessionFile -Force -ErrorAction SilentlyContinue
    return $true
}

# 兜底：没有记录但实际输出亮度被压到极低时，恢复到能看清
function Repair-BrightnessIfStuck {
    param([string]$Device)
    if (-not $Device) { $Device = Get-AnySerial }
    if (-not $Device) { return }
    $applied = Get-AppliedBrightness -Device $Device
    if ($null -ne $applied -and $applied -le 0.05) {
        [void](Set-DisplayBrightness -Device $Device -Ratio 0.25)
        & $script:adb -s $Device shell 'settings put system screen_brightness_mode 1' 2>&1 | Out-Null
        & $script:adb -s $Device shell 'settings put system screen_brightness 128' 2>&1 | Out-Null
        return
    }
    $cur = Get-BrightnessValue -Device $Device
    if ($cur -and $cur.mode -eq 0 -and $cur.value -le 3) {
        & $script:adb -s $Device shell 'settings put system screen_brightness_mode 1' 2>&1 | Out-Null
        & $script:adb -s $Device shell 'settings put system screen_brightness 128' 2>&1 | Out-Null
    }
}

# ---------- standalone CLI ----------
if ($Status) {
    $d = Get-AnySerial -Prefer $Serial
    Write-Host ('device  = ' + $d)
    $cur = Get-BrightnessValue -Device $d
    if ($cur) {
        Write-Host ('mode    = ' + $cur.mode + '   settings value = ' + $cur.value)
        Write-Host ('applied = ' + $cur.applied + '   (0 = 面板最低档，1 = 满亮)')
    } else { Write-Host '读不到亮度' }
    Write-Host ('session = ' + $script:sessionFile + '  exists=' + (Test-Path $script:sessionFile))
}
if ($Apply) {
    $d = Get-AnySerial -Prefer $Serial
    $saved = Save-BrightnessSession -Device $d
    Write-Host ('saved = ' + $saved)
    if ($saved) { Write-Host ('applied ok = ' + (Apply-DimBrightness -Device $d)) }
}
if ($Restore) {
    Write-Host ('restored = ' + (Restore-Brightness))
}
