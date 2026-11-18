# scrcpy GUI launcher (portable wrapper around scrcpy-core.exe).
# Options before connecting: USB or WiFi link, keep-awake, mouse mode,
# auto input-method switching, fullscreen, video quality.
# After connecting the panel hides into the system tray.
# Runs without any console window (started through scrcpy-gui.vbs).

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = 'SilentlyContinue'

function T([string]$m) {
    $line = (Get-Date -Format 'HH:mm:ss') + ' ' + $m
    Add-Content -Path (Join-Path $here 'gui-trace.log') -Value $line
}
T 'script start'

# single instance: the first one keeps this mutex for its lifetime
$script:instanceMutex = New-Object System.Threading.Mutex($false, 'Global\ScrcpyConsoleGuiMutex')
if (-not $script:instanceMutex.WaitOne(0)) { exit }

$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$launcher = Join-Path $here 'scrcpy.exe'        # 双击入口（本控制台的启动器）
$scrcpy   = Join-Path $here 'scrcpy-core.exe'   # 真正的 scrcpy 本体
$adb    = Join-Path $here 'adb.exe'
$watch  = Join-Path $here 'ime-watch.ps1'
$title  = 'PHONE'   # 投屏窗口标题，可自行修改

# ---------- hotspot helpers (WiFi mirroring needs the mobile hotspot) ----------
# 无线模式：连接前自动开热点；断开后只在"本次是我们开的"情况下关掉，
# 原本就开着的热点保持不动。
$hotspotScript = Join-Path $here 'hotspot.ps1'
$script:hotspotStartedByUs = $false

function Invoke-Hotspot([string]$act) {
    if (-not (Test-Path $hotspotScript)) { return }
    & 'powershell.exe' -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden `
        -File "`"$hotspotScript`"" -Action $act 2>$null | Out-Null
}

function Get-HotspotState {
    if (-not (Test-Path $hotspotScript)) { return '' }
    $out = & 'powershell.exe' -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden `
        -File "`"$hotspotScript`"" -Action status -Quiet 2>$null
    return (($out | Out-String).Trim())
}

function Confirm-WifiHotspot {
    $state = Get-HotspotState
    if (-not $state) { return }
    if ($state -eq 'On') {
        T 'hotspot: already on, keep it as is'
        return
    }
    T ('hotspot: state=' + $state + ' -> starting')
    Set-Status '正在开启移动热点…' 'idle'
    Invoke-Hotspot 'start'
    for ($i = 0; $i -lt 12; $i++) {
        Start-Sleep -Milliseconds 800
        if ((Get-HotspotState) -eq 'On') { break }
    }
    $script:hotspotStartedByUs = $true
    Set-Status '移动热点已开启，等待手机接入…' 'idle'
}

function Restore-Hotspot {
    if (-not $script:hotspotStartedByUs) { return }
    T 'hotspot: turning off (it was off before this session)'
    Invoke-Hotspot 'stop'
    $script:hotspotStartedByUs = $false
}

if (-not (Test-Path $scrcpy)) {
    [System.Windows.Forms.MessageBox]::Show("scrcpy.exe 不存在: $scrcpy", '手机投屏')
    exit 1
}

# ---------- native helpers ----------
$sig = @'
using System;
using System.Text;
using System.Runtime.InteropServices;

public class ScrcpyGui {
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc f, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern IntPtr LoadKeyboardLayout(string id, uint flags);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  public delegate bool EnumWindowsProc(IntPtr h, IntPtr l);

  // scrcpy draws its mirror into an SDL window (class "SDL_app"), while its
  // stderr/stdout console is a separate "ConsoleWindowClass" window we hide.
  public static IntPtr FindSdl() {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, l) => {
      StringBuilder c = new StringBuilder(128);
      GetClassName(h, c, 128);
      if (c.ToString() == "SDL_app") { found = h; return false; }
      return true;
    }, IntPtr.Zero);
    return found;
  }

  public static void HideConsole(uint pid) {
    EnumWindows((h, l) => {
      uint wpid = 0;
      GetWindowThreadProcessId(h, out wpid);
      if (wpid == pid) {
        StringBuilder c = new StringBuilder(128);
        GetClassName(h, c, 128);
        if (c.ToString() == "ConsoleWindowClass") { ShowWindow(h, 0); }
      }
      return true;
    }, IntPtr.Zero);
  }

  public static IntPtr Find(string title) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, l) => {
      StringBuilder t = new StringBuilder(256);
      GetWindowText(h, t, 256);
      if (t.ToString().IndexOf(title, StringComparison.OrdinalIgnoreCase) >= 0) { found = h; return false; }
      return true;
    }, IntPtr.Zero);
    return found;
  }

  public static void ToEnglish(IntPtr h) {
    IntPtr hkl = LoadKeyboardLayout("00000409", 1);
    PostMessage(h, 0x0050, IntPtr.Zero, hkl);
  }
}
'@
Add-Type -TypeDefinition $sig -ErrorAction SilentlyContinue

# ---------- adb / scrcpy helpers ----------
$script:serial = ''
$script:sessionActive = $false
$script:linkLabel = ''

function Invoke-AdbShell([string]$cmd) {
    if (-not $script:serial) { return '' }
    $out = ''
    for ($i = 0; $i -lt 4; $i++) {
        $out = (& $adb -s $script:serial shell $cmd 2>&1) -join "`n"
        if ($out -notmatch 'not found' -and $out -notmatch 'offline' -and $out -notmatch 'error:') {
            return $out.Trim()
        }
        Start-Sleep -Milliseconds 900
    }
    return $out.Trim()
}

function Get-DeviceList {
    $list = @()
    foreach ($l in (& $adb devices 2>$null)) {
        if ($l -match '^\s*([^\s]+)\s+device') { $list += $Matches[1] }
    }
    return $list
}

function Get-UsbSerial {
    for ($try = 0; $try -lt 4; $try++) {
        $raw = (& $adb devices 2>$null)
        T ("adb devices try " + $try + ": " + (($raw | Out-String).Trim() -replace "`r`n", " / "))
        foreach ($d in (Get-DeviceList)) {
            if ($d -notmatch ':') { return $d }
        }
        # a wedged adb server is the usual reason for an empty list: restart it
        & $adb kill-server 2>$null | Out-Null
        Start-Sleep -Milliseconds 600
        & $adb start-server 2>$null | Out-Null
        Start-Sleep -Milliseconds 1500
    }
    return ''
}

function Get-WifiSerial([string]$manualIp) {
    # 1) an already-advertised network device
    foreach ($d in (Get-DeviceList)) {
        if ($d -match ':') { return $d }
    }

    # 2) a manually typed address
    if ($manualIp) {
        $target = if ($manualIp -match ':') { $manualIp } else { "$manualIp`:5555" }
        & $adb connect $target 2>$null | Out-Null
        Start-Sleep -Milliseconds 1500
        foreach ($d in (Get-DeviceList)) { if ($d -eq $target) { return $d } }
    }

    # 3) bootstrap over USB: enable tcpip, read the WiFi address, then connect
    $usb = Get-UsbSerial
    if (-not $usb) { return '' }

    $ip = ''
    $raw = (& $adb -s $usb shell 'ip -f inet addr show wlan0' 2>&1) -join "`n"
    foreach ($m in [regex]::Matches($raw, 'inet\s+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/')) {
        $cand = $m.Groups[1].Value
        if ($cand -notlike '127.*') { $ip = $cand }
    }
    if (-not $ip) {
        $raw2 = (& $adb -s $usb shell 'ip -f inet addr' 2>&1) -join "`n"
        foreach ($m in [regex]::Matches($raw2, 'inet\s+([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/')) {
            $cand = $m.Groups[1].Value
            if ($cand -notlike '127.*') { $ip = $cand }
        }
    }
    if (-not $ip) { return '' }

    & $adb -s $usb tcpip 5555 2>$null | Out-Null
    Start-Sleep -Seconds 2
    $target = "$ip`:5555"
    & $adb connect $target 2>$null | Out-Null
    Start-Sleep -Milliseconds 1500
    foreach ($d in (Get-DeviceList)) { if ($d -eq $target) { return $d } }
    return ''
}

function Stop-Watcher {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like '*ime-watch*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Stop-Mirror {
    Get-Process -Name 'scrcpy-core', 'scrcpy' -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Stop-Watcher
}

# ---- safety: never leave the panel stuck on a near-black brightness -------------
# (a very low brightness makes Android stack a full-screen dim layer that swallows
# every touch as "untrusted occlusion", which looks exactly like dead touch input)
function Repair-BrightnessIfStuck {
    $serial = ''
    foreach ($l in (& $adb devices 2>$null)) {
        if ($l -match '^\s*([^\s]+)\s+device') { $serial = $Matches[1]; break }
    }
    if (-not $serial) { return }
    $ok = $false
    foreach ($cmd in @('settings get system screen_brightness_mode', 'settings get system screen_brightness')) {
        $val = (& $adb -s $serial shell $cmd 2>&1) -join ''
        if ($cmd -like '*mode') { if ($val.Trim() -eq '0') { $ok = $true } }
        elseif ($ok -and $val.Trim() -match '^\d+' -and [int]$val.Trim() -le 3) { $ok = 'stuck' }
        elseif ($ok) { $ok = $false }
    }
    if ($ok -eq 'stuck') {
        & $adb -s $serial shell 'settings put system screen_brightness_mode 1' 2>&1 | Out-Null
        & $adb -s $serial shell 'settings put system screen_brightness 128' 2>&1 | Out-Null
    }
}

# ---------- UI ----------
$form = New-Object System.Windows.Forms.Form
$form.Text = '手机投屏控制'
$form.ClientSize = New-Object System.Drawing.Size(440, 356)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($scrcpy)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = '手机投屏控制台'
$lblTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 15, [System.Drawing.FontStyle]::Bold)
$lblTitle.Location = New-Object System.Drawing.Point(16, 10)
$lblTitle.Size = New-Object System.Drawing.Size(400, 34)
$form.Controls.Add($lblTitle)

$lblLink = New-Object System.Windows.Forms.Label
$lblLink.Text = '连接方式'
$lblLink.Location = New-Object System.Drawing.Point(18, 52)
$lblLink.Size = New-Object System.Drawing.Size(64, 22)
$form.Controls.Add($lblLink)

$rbUsb = New-Object System.Windows.Forms.RadioButton
$rbUsb.Text = 'USB 有线'
$rbUsb.Location = New-Object System.Drawing.Point(88, 50)
$rbUsb.Size = New-Object System.Drawing.Size(100, 24)
$rbUsb.Checked = $true
$form.Controls.Add($rbUsb)

$rbWifi = New-Object System.Windows.Forms.RadioButton
$rbWifi.Text = '无线 WiFi'
$rbWifi.Location = New-Object System.Drawing.Point(196, 50)
$rbWifi.Size = New-Object System.Drawing.Size(100, 24)
$form.Controls.Add($rbWifi)

$lblIp = New-Object System.Windows.Forms.Label
$lblIp.Text = '无线地址'
$lblIp.Location = New-Object System.Drawing.Point(18, 84)
$lblIp.Size = New-Object System.Drawing.Size(64, 22)
$form.Controls.Add($lblIp)

$txtIp = New-Object System.Windows.Forms.TextBox
$txtIp.Location = New-Object System.Drawing.Point(88, 81)
$txtIp.Size = New-Object System.Drawing.Size(200, 24)
$form.Controls.Add($txtIp)

$lblIpHint = New-Object System.Windows.Forms.Label
$lblIpHint.Text = '留空自动探测'
$lblIpHint.Location = New-Object System.Drawing.Point(294, 84)
$lblIpHint.Size = New-Object System.Drawing.Size(120, 22)
$lblIpHint.ForeColor = [System.Drawing.Color]::Gray
$form.Controls.Add($lblIpHint)

$chkAwake = New-Object System.Windows.Forms.CheckBox
$chkAwake.Text = '保持唤醒（投屏期间手机不自动锁屏）'
$chkAwake.Location = New-Object System.Drawing.Point(18, 116)
$chkAwake.Size = New-Object System.Drawing.Size(400, 24)
$chkAwake.Checked = $true
$form.Controls.Add($chkAwake)

$chkMouse = New-Object System.Windows.Forms.CheckBox
$chkMouse.Text = '鼠标自由移动（指针可离开投屏窗口）'
$chkMouse.Location = New-Object System.Drawing.Point(18, 146)
$chkMouse.Size = New-Object System.Drawing.Size(400, 24)
$chkMouse.Checked = $true
$form.Controls.Add($chkMouse)

$chkIme = New-Object System.Windows.Forms.CheckBox
$chkIme.Text = '自动切换输入法（投屏时英文、离开恢复中文）'
$chkIme.Location = New-Object System.Drawing.Point(18, 176)
$chkIme.Size = New-Object System.Drawing.Size(400, 24)
$chkIme.Checked = $true
$form.Controls.Add($chkIme)

$chkFull = New-Object System.Windows.Forms.CheckBox
$chkFull.Text = '全屏启动'
$chkFull.Location = New-Object System.Drawing.Point(18, 206)
$chkFull.Size = New-Object System.Drawing.Size(180, 24)
$chkFull.Checked = $false
$form.Controls.Add($chkFull)

$lblQuality = New-Object System.Windows.Forms.Label
$lblQuality.Text = '画质'
$lblQuality.Location = New-Object System.Drawing.Point(18, 242)
$lblQuality.Size = New-Object System.Drawing.Size(64, 22)
$form.Controls.Add($lblQuality)

$cmbQuality = New-Object System.Windows.Forms.ComboBox
$cmbQuality.DropDownStyle = 'DropDownList'
$cmbQuality.Location = New-Object System.Drawing.Point(88, 239)
$cmbQuality.Size = New-Object System.Drawing.Size(210, 24)
[void]$cmbQuality.Items.Add('流畅（8M / 30fps）')
[void]$cmbQuality.Items.Add('标准（16M / 60fps）')
[void]$cmbQuality.Items.Add('高清（32M / 60fps）')
$cmbQuality.SelectedIndex = 1
$form.Controls.Add($cmbQuality)

$btnConnect = New-Object System.Windows.Forms.Button
$btnConnect.Text = '连接'
$btnConnect.Location = New-Object System.Drawing.Point(18, 280)
$btnConnect.Size = New-Object System.Drawing.Size(130, 38)
$form.Controls.Add($btnConnect)

$btnStop = New-Object System.Windows.Forms.Button
$btnStop.Text = '断开'
$btnStop.Location = New-Object System.Drawing.Point(155, 280)
$btnStop.Size = New-Object System.Drawing.Size(130, 38)
$btnStop.Enabled = $false
$form.Controls.Add($btnStop)

$btnQuit = New-Object System.Windows.Forms.Button
$btnQuit.Text = '退出'
$btnQuit.Location = New-Object System.Drawing.Point(292, 280)
$btnQuit.Size = New-Object System.Drawing.Size(130, 38)
$form.Controls.Add($btnQuit)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = '未连接'
$lblStatus.Location = New-Object System.Drawing.Point(18, 322)
$lblStatus.Size = New-Object System.Drawing.Size(404, 28)
$lblStatus.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($lblStatus)

function Set-Status([string]$text, [string]$color) {
    $lblStatus.Text = $text
    switch ($color) {
        'ok'   { $lblStatus.ForeColor = [System.Drawing.Color]::ForestGreen }
        'err'  { $lblStatus.ForeColor = [System.Drawing.Color]::Firebrick }
        default { $lblStatus.ForeColor = [System.Drawing.Color]::DimGray }
    }
    $form.Refresh()
}

# ---------- tray ----------
$tray = New-Object System.Windows.Forms.NotifyIcon
$trayIcon = [System.Drawing.Icon]::ExtractAssociatedIcon($scrcpy)
if (-not $trayIcon) { $trayIcon = [System.Drawing.SystemIcons]::Application }
$tray.Icon = $trayIcon
$tray.Text = '手机投屏控制台'
$tray.Visible = $true

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$miShow = $trayMenu.Items.Add('显示控制台')
$miStop = $trayMenu.Items.Add('断开投屏')
$miExit = $trayMenu.Items.Add('退出')
$tray.ContextMenuStrip = $trayMenu

function Show-Panel {
    $form.Show()
    $form.WindowState = 'Normal'
    [ScrcpyGui]::ShowWindow($form.Handle, 9) | Out-Null
    [ScrcpyGui]::SetForegroundWindow($form.Handle) | Out-Null
}

$miShow.Add_Click({ Show-Panel })
$miStop.Add_Click({
    $script:sessionActive = $false
    Stop-Mirror
    Set-Status '已断开' 'idle'
    $btnConnect.Enabled = $true
    $btnStop.Enabled = $false
    Show-Panel
})
$miExit.Add_Click({ $form.Close() })
$tray.Add_DoubleClick({ Show-Panel })

# ---------- connect ----------
function Connect-Mirror {
    T 'connect: start'
    Set-Status '正在查找设备…' 'idle'

    if ($rbWifi.Checked) {
        Confirm-WifiHotspot
        Set-Status '正在查找无线设备…' 'idle'
        $serial = Get-WifiSerial($txtIp.Text.Trim())
        if (-not $serial) {
            Set-Status "没有可用的无线连接。首次请先用 USB 连一次（会自动开启 5555 并读取手机 IP）。" 'err'
            Restore-Hotspot
            return
        }
        $link = '无线'
    }
    else {
        $serial = Get-UsbSerial
        if (-not $serial) {
            Set-Status '没有检测到 USB 连接的手机，请连接数据线并授权 USB 调试。' 'err'
            return
        }
        $link = '有线'
    }

    $script:serial = $serial
    T ("connect: serial=" + $serial)
    Stop-Mirror
    Start-Sleep -Milliseconds 800

    $argList = @('-s', $serial, '--keyboard=uhid')
    if ($chkAwake.Checked) { $argList += '--stay-awake' }
    if ($chkMouse.Checked) { $argList += '--mouse=sdk' } else { $argList += '--mouse=uhid' }

    switch ($cmbQuality.SelectedIndex) {
        0 { $argList += @('--max-fps=30', '--video-bit-rate=8M') }
        2 { $argList += @('--max-fps=60', '--video-bit-rate=32M') }
        default { $argList += @('--max-fps=60', '--video-bit-rate=16M') }
    }
    if ($chkFull.Checked) { $argList += '--fullscreen' }
    $argList += "--window-title=$title"

    $script:sessionActive = $true
    # CreateNoWindow keeps the console of scrcpy from ever appearing (it is a
    # console-subsystem exe); the SDL mirror window still opens normally.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $scrcpy
    $psi.Arguments = ($argList -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $here
    $proc = [System.Diagnostics.Process]::Start($psi)

    $h = [IntPtr]::Zero
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 500
        $h = [ScrcpyGui]::FindSdl()
        if ($h -ne [IntPtr]::Zero) { break }
    }

    if ($h -eq [IntPtr]::Zero) {
        $script:sessionActive = $false
        Set-Status '投屏窗口没有出现，检查手机是否授权调试（adb devices）。' 'err'
        Restore-Hotspot
        return
    }

    Start-Sleep -Milliseconds 900
    if ($proc) { [ScrcpyGui]::HideConsole([uint32]$proc.Id) }
    [ScrcpyGui]::ShowWindow($h, 9) | Out-Null
    [ScrcpyGui]::SetForegroundWindow($h) | Out-Null
    Start-Sleep -Milliseconds 400
    [ScrcpyGui]::ShowWindow($h, 9) | Out-Null
    [ScrcpyGui]::ToEnglish($h)

    if ($chkIme.Checked -and (Test-Path $watch)) {
        Start-Process -FilePath 'powershell.exe' `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$watch`"") `
            -WindowStyle Hidden
    }

    $mode  = if ($chkMouse.Checked)  { '鼠标自由' } else { '鼠标锁定(Alt解锁)' }
    $ime   = if ($chkIme.Checked)    { '自动输入法' } else { '不切输入法' }
    $awake = if ($chkAwake.Checked)  { '保持唤醒' } else { '允许锁屏' }
    Set-Status "已连接[$link]  $serial" 'ok'

    $btnConnect.Enabled = $false
    $btnStop.Enabled = $true
    $script:linkLabel = "$link / $awake / $mode / $ime"

    # hide into the tray so the mirror window is unobstructed
    $tray.Text = "手机投屏 - 已连接[$link]"
    $tray.BalloonTipTitle = '手机投屏已连接'
    $tray.BalloonTipText = "$link  $serial`n$awake | $mode | $ime"
    $tray.ShowBalloonTip(3000)
    $form.Hide()
}

# ---------- events ----------
$btnConnect.Add_Click({ Connect-Mirror })

$btnStop.Add_Click({
    $script:sessionActive = $false
    Stop-Mirror
    Restore-Hotspot
    Set-Status '已断开' 'idle'
    $tray.Text = '手机投屏控制台'
    $btnConnect.Enabled = $true
    $btnStop.Enabled = $false
})

$btnQuit.Add_Click({ $form.Close() })
$form.Add_FormClosing({
    T 'FormClosing fired'
    Stop-Mirror
    Restore-Hotspot
    $tray.Visible = $false
    $tray.Dispose()
})

$rbWifi.Add_CheckedChanged({
    $txtIp.Enabled = $rbWifi.Checked
    $lblIp.Enabled = $rbWifi.Checked
})
$txtIp.Enabled = $false
$lblIp.Enabled = $false

# watchdog: clean up in the tray when the mirror window is closed
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1500
$timer.Add_Tick({
    if ($script:sessionActive -and -not (Get-Process -Name 'scrcpy-core', 'scrcpy' -ErrorAction SilentlyContinue)) {
        $script:sessionActive = $false
        Stop-Watcher
        Restore-Hotspot
        $tray.Text = '手机投屏控制台'
        $btnConnect.Enabled = $true
        $btnStop.Enabled = $false
        Set-Status '投屏已结束（可在托盘图标右键重新连接）' 'idle'
    }
})
$timer.Start()

$script:autoConnect = ($args -contains '--auto')
$script:autoWifi = ($args -contains '--wifi')
[void]$form.Add_Shown({
    Repair-BrightnessIfStuck
    if ($script:autoWifi) { $rbWifi.Checked = $true }
    if ($script:autoConnect -or $script:autoWifi) { Connect-Mirror }
})

T 'entering message loop'
[System.Windows.Forms.Application]::Run($form)
T 'message loop returned'

$tray.Visible = $false
$tray.Dispose()
