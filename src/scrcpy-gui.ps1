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

# single instance: the first one keeps this mutex for its lifetime.
# 第二次启动（双击桌面「手机投屏」）不再静默退出：通过命名事件通知已有实例
# 把控制台面板唤到前台，然后把消息投递完就退出。
$script:showEventName = 'Global\ScrcpyConsoleShowPanel'
# 先建（或打开）事件，再抢互斥体：这样第二次启动一定能找到通知通道，不会撞上初始化窗口
$script:showEvent = New-Object System.Threading.EventWaitHandle(
    $false, [System.Threading.EventResetMode]::AutoReset, $script:showEventName)
$script:instanceMutex = New-Object System.Threading.Mutex($false, 'Global\ScrcpyConsoleGuiMutex')
if (-not $script:instanceMutex.WaitOne(0)) {
    # 已有实例在托盘里：让它把面板唤出来，自己退场
    try { [void]$script:showEvent.Set() } catch { }
    $script:showEvent.Dispose()
    exit
}

$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$launcher = Join-Path $here 'scrcpy.exe'        # 双击入口（本控制台的启动器）
$scrcpy   = Join-Path $here 'scrcpy-core.exe'   # 真正的 scrcpy 本体
$adb    = Join-Path $here 'adb.exe'
$watch  = Join-Path $here 'ime-watch.ps1'
$wifiPair = Join-Path $here 'wifi-pair.ps1'
$brightnessHelper = Join-Path $here 'brightness.ps1'
$title  = 'PHONE'   # 投屏窗口标题，可自行修改

# 无线调试配对助手（Android 11+）：提供 Get-MdnsServices / Invoke-AdbPair / Save-Target 等函数
$script:pairHelper = $false
if (Test-Path $wifiPair) {
    . $wifiPair -AdbExe $adb
    $script:pairHelper = $true
}
T ('wifi-pair helper: ' + $script:pairHelper)

# 低亮投屏：原生亮度存取与还原（brightness.ps1）
$script:brightnessHelperOK = $false
if (Test-Path $brightnessHelper) {
    . $brightnessHelper -AdbExe $adb -ConfigDir $here
    $script:brightnessHelperOK = $true
}
T ('brightness helper: ' + $script:brightnessHelperOK)

function Stop-DimBrightness {
    if ($script:brightnessHelperOK) { Restore-Brightness | Out-Null }
    if ($script:dimActive) { T 'dim: cleared' }
    $script:dimActive = $false
}

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
    # 0) 已经在 adb devices 里的网络设备
    foreach ($d in (Get-DeviceList)) {
        if ($d -match ':') { return $d }
    }

    # 1) 上次成功用过的地址（wifi.json），重启后端口可能变，失败就继续往下试
    if ($script:pairHelper) {
        $saved = Get-SavedTarget
        if ($saved) {
            T ('wifi: trying saved target ' + $saved)
            $hit = Connect-AdbTarget -Target $saved -WaitMs 5000
            if ($hit) { return $hit }
        }
    }

    # 2) 面板上手工填写的地址
    if ($manualIp) {
        T ('wifi: trying manual target ' + $manualIp)
        if ($script:pairHelper) {
            $hit = Connect-AdbTarget -Target $manualIp -WaitMs 5000
            if ($hit) { return $hit }
        }
        else {
            $target = if ($manualIp -match ':') { $manualIp } else { "$manualIp`:5555" }
            & $adb connect $target 2>$null | Out-Null
            Start-Sleep -Milliseconds 1500
            foreach ($d in (Get-DeviceList)) { if ($d -eq $target) { return $d } }
        }
    }

    # 3) 无线调试广播出来的连接端口（mDNS 自动发现）
    if ($script:pairHelper) {
        $disc = Get-ConnectionTarget
        if ($disc) {
            T ('wifi: trying mdns target ' + $disc)
            $hit = Connect-AdbTarget -Target $disc -WaitMs 5000
            if ($hit) { return $hit }
        }
    }

    # 4) 兜底：USB 首次引导（开启 tcpip 5555 并读取手机 IP）
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
    $victims = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like '*ime-watch*' -and $_.CommandLine -notlike '*-Restore*' }
    $had = $false
    foreach ($v in $victims) {
        $had = $true
        Stop-Process -Id $v.ProcessId -Force -ErrorAction SilentlyContinue
    }
    # 看门狗被强杀后没机会自己还原，这里补一刀：把当前前台窗口切回中文，
    # 否则强关投屏后会停在美式键盘上，打字全变字母
    if ($had -and (Test-Path $watch)) {
        try {
            $p = Start-Process -FilePath 'powershell.exe' `
                -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$watch`"", '-Restore') `
                -WindowStyle Hidden -PassThru
            [void]$p.Handle
            $p.WaitForExit(3000)
            T 'ime: restore dispatched after watcher kill'
        } catch { T ('ime: restore failed - ' + $_.Exception.Message) }
    }
}

function Stop-Mirror {
    Get-Process -Name 'scrcpy-core', 'scrcpy' -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Stop-Watcher
}

# ---------- 低亮投屏：走系统原生亮度，不叠任何覆盖窗口 ----------------
# 实测（Meizu 20 Pro / Android 16）：screen_brightness 设到 0 时
#   * SurfaceFlinger 图层表不新增任何 dim/scrim，截图内容照常（平均亮度 42/255）
#   * 面板真实亮度 = 设备亮度曲线最低档约 2.5 尼特，API 无法再低
# 因此不会触发 "Untrusted touch due to occlusion"（那条保护只针对覆盖窗口）。
# 具体实现在 brightness.ps1（可单独运行排查），这里只保留状态标记。
$script:dimActive = $false

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

$btnPair = New-Object System.Windows.Forms.Button
$btnPair.Text = '无线配对…'
$btnPair.Location = New-Object System.Drawing.Point(294, 80)
$btnPair.Size = New-Object System.Drawing.Size(120, 26)
$btnPair.Enabled = $false
$form.Controls.Add($btnPair)

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
$chkFull.Size = New-Object System.Drawing.Size(86, 24)
$chkFull.Checked = $false
$form.Controls.Add($chkFull)

$chkDim = New-Object System.Windows.Forms.CheckBox
$chkDim.Text = '低亮投屏（面板≈2.5 尼特，触控正常）'
$chkDim.Location = New-Object System.Drawing.Point(110, 206)
$chkDim.Size = New-Object System.Drawing.Size(310, 24)
$chkDim.Checked = $false
$form.Controls.Add($chkDim)

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
$miBright = $trayMenu.Items.Add('恢复屏幕亮度')
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
    Stop-DimBrightness
    Set-Status '已断开' 'idle'
    $btnConnect.Enabled = $true
    $btnStop.Enabled = $false
    Show-Panel
})
$miBright.Add_Click({
    Stop-DimBrightness
    Set-Status '已把手机亮度还原为投屏前的设置' 'ok'
    Show-Panel
})
$miExit.Add_Click({ $form.Close() })
$tray.Add_DoubleClick({ Show-Panel })

# ---------- 无线配对对话框（Android 11+「无线调试」） ----------
# 流程：手机打开 无线调试 → 使用配对码配对设备 → 电脑点「自动发现」→ 填 6 位码 → 配对并连接
# 配对端口只在手机弹窗打开期间有效；连上后地址写进 wifi.json 供下次直接用。
function Show-PairDialog {
    if (-not $script:pairHelper) { return '' }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = '无线配对（Android 11+ 无线调试）'
    $dlg.ClientSize = New-Object System.Drawing.Size(476, 344)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = "手机上：设置 → 系统 → 开发者选项 → 无线调试`n点「使用配对码配对设备」，让那个弹窗保持打开；`n电脑上点「自动发现」，把 6 位配对码填进来。`n全程不需要数据线。"
    $hint.Location = New-Object System.Drawing.Point(12, 10)
    $hint.Size = New-Object System.Drawing.Size(452, 76)
    $hint.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($hint)

    $lblPair = New-Object System.Windows.Forms.Label
    $lblPair.Text = '配对地址'
    $lblPair.Location = New-Object System.Drawing.Point(12, 96)
    $lblPair.Size = New-Object System.Drawing.Size(70, 22)
    $dlg.Controls.Add($lblPair)

    $txtPair = New-Object System.Windows.Forms.TextBox
    $txtPair.Location = New-Object System.Drawing.Point(86, 93)
    $txtPair.Size = New-Object System.Drawing.Size(250, 24)
    $dlg.Controls.Add($txtPair)

    $lblCode = New-Object System.Windows.Forms.Label
    $lblCode.Text = '配对码'
    $lblCode.Location = New-Object System.Drawing.Point(12, 128)
    $lblCode.Size = New-Object System.Drawing.Size(70, 22)
    $dlg.Controls.Add($lblCode)

    $txtCode = New-Object System.Windows.Forms.TextBox
    $txtCode.Location = New-Object System.Drawing.Point(86, 125)
    $txtCode.Size = New-Object System.Drawing.Size(120, 24)
    $txtCode.MaxLength = 6
    $dlg.Controls.Add($txtCode)

    $lblConn = New-Object System.Windows.Forms.Label
    $lblConn.Text = '连接地址'
    $lblConn.Location = New-Object System.Drawing.Point(12, 160)
    $lblConn.Size = New-Object System.Drawing.Size(70, 22)
    $dlg.Controls.Add($lblConn)

    $txtConn = New-Object System.Windows.Forms.TextBox
    $txtConn.Location = New-Object System.Drawing.Point(86, 157)
    $txtConn.Size = New-Object System.Drawing.Size(250, 24)
    $dlg.Controls.Add($txtConn)

    $lblConnHint = New-Object System.Windows.Forms.Label
    $lblConnHint.Text = '页面顶部那行'
    $lblConnHint.Location = New-Object System.Drawing.Point(340, 160)
    $lblConnHint.Size = New-Object System.Drawing.Size(120, 22)
    $lblConnHint.ForeColor = [System.Drawing.Color]::Gray
    $dlg.Controls.Add($lblConnHint)

    $btnDiscover = New-Object System.Windows.Forms.Button
    $btnDiscover.Text = '自动发现'
    $btnDiscover.Location = New-Object System.Drawing.Point(12, 194)
    $btnDiscover.Size = New-Object System.Drawing.Size(104, 30)
    $dlg.Controls.Add($btnDiscover)

    $btnPairGo = New-Object System.Windows.Forms.Button
    $btnPairGo.Text = '配对并连接'
    $btnPairGo.Location = New-Object System.Drawing.Point(124, 194)
    $btnPairGo.Size = New-Object System.Drawing.Size(136, 30)
    $dlg.Controls.Add($btnPairGo)

    $btnConnOnly = New-Object System.Windows.Forms.Button
    $btnConnOnly.Text = '仅连接'
    $btnConnOnly.Location = New-Object System.Drawing.Point(268, 194)
    $btnConnOnly.Size = New-Object System.Drawing.Size(96, 30)
    $dlg.Controls.Add($btnConnOnly)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = '取消'
    $btnCancel.Location = New-Object System.Drawing.Point(364, 194)
    $btnCancel.Size = New-Object System.Drawing.Size(100, 30)
    $dlg.Controls.Add($btnCancel)

    $lblMsg = New-Object System.Windows.Forms.Label
    $lblMsg.Text = '等待发现设备…'
    $lblMsg.Location = New-Object System.Drawing.Point(12, 236)
    $lblMsg.Size = New-Object System.Drawing.Size(452, 100)
    $lblMsg.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lblMsg)

    $found = @{ pair = ''; conn = '' }
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 2000
    $timer.Add_Tick({
        try {
            $p = Get-PairingTarget
            $c = Get-ConnectionTarget
            if ($p) {
                $found.pair = $p
                if (-not $txtPair.Text.Trim()) { $txtPair.Text = $p }
            }
            if ($c) {
                $found.conn = $c
                if (-not $txtConn.Text.Trim()) { $txtConn.Text = $c }
            }
            if ($p -or $c) {
                $lblMsg.ForeColor = [System.Drawing.Color]::ForestGreen
                $pText = if ($p) { $p } else { '未广播' }
                $cText = if ($c) { $c } else { '未广播' }
                $lblMsg.Text = ("已发现  配对: " + $pText + "`n已发现  连接: " + $cText)
            }
        } catch { }
    })
    $timer.Start()

    $doPair = {
        $pair = $txtPair.Text.Trim()
        if (-not $pair) {
            $lblMsg.ForeColor = [System.Drawing.Color]::Firebrick
            $lblMsg.Text = '还没有配对地址：先点「自动发现」，或照手机页面手动填 IP:端口。'
            return
        }
        if ($txtCode.Text.Trim() -notmatch '^\d{6}$') {
            $lblMsg.ForeColor = [System.Drawing.Color]::Firebrick
            $lblMsg.Text = '配对码是手机弹窗上的 6 位数字。'
            return
        }
        $lblMsg.ForeColor = [System.Drawing.Color]::DimGray
        $lblMsg.Text = '正在配对…'
        $dlg.Refresh()
        $r = Invoke-AdbPair -Target $pair -Code $txtCode.Text.Trim()
        if (-not $r.ok) {
            $lblMsg.ForeColor = [System.Drawing.Color]::Firebrick
            $lblMsg.Text = ('配对失败：' + $r.msg + "`n（配对弹窗关闭后端口即失效，请重新打开再点「自动发现」）")
            return
        }
        $lblMsg.Text = '配对成功，正在连接…'
        $dlg.Refresh()
        $target = $txtConn.Text.Trim()
        if (-not $target) { $target = $found.conn }
        if (-not $target) {
            $lblMsg.ForeColor = [System.Drawing.Color]::DarkGoldenrod
            $lblMsg.Text = '配对成功。请把手机「无线调试」页顶部那行 IP 地址和端口 填到「连接地址」，再点「仅连接」。'
            return
        }
        $dev = Connect-AdbTarget -Target $target -WaitMs 8000
        if (-not $dev) {
            $lblMsg.ForeColor = [System.Drawing.Color]::Firebrick
            $lblMsg.Text = '配对成功，但连接没成功。核对「连接地址」是不是页面顶部那行 IP:端口（不是配对弹窗里的端口）。'
            return
        }
        Save-Target $dev
        $dlg.Tag = $dev
        $timer.Stop()
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dlg.Close()
    }

    $btnDiscover.Add_Click({
        $lblMsg.ForeColor = [System.Drawing.Color]::DimGray
        $lblMsg.Text = '正在重新发现…'
        $dlg.Refresh()
        $p = Get-PairingTarget
        $c = Get-ConnectionTarget
        if ($p) { $found.pair = $p; $txtPair.Text = $p }
        if ($c) { $found.conn = $c; $txtConn.Text = $c }
        if ($p -or $c) {
            $lblMsg.ForeColor = [System.Drawing.Color]::ForestGreen
            $lblMsg.Text = ('已发现  配对: ' + $(if ($p) { $p } else { '无' }) + '   连接: ' + $(if ($c) { $c } else { '无' }))
        }
        else {
            $lblMsg.ForeColor = [System.Drawing.Color]::DarkGoldenrod
            $lblMsg.Text = '没发现广播：确认手机「无线调试」已打开且配对弹窗还在，或手动填地址。'
        }
    })

    $btnPairGo.Add_Click($doPair)

    $btnConnOnly.Add_Click({
        $target = $txtConn.Text.Trim()
        if (-not $target) { $target = $found.conn }
        if (-not $target) {
            $lblMsg.ForeColor = [System.Drawing.Color]::Firebrick
            $lblMsg.Text = '请先填「连接地址」（手机无线调试页顶部那行 IP:端口）。'
            return
        }
        $lblMsg.Text = '正在连接…'
        $dlg.Refresh()
        $dev = Connect-AdbTarget -Target $target -WaitMs 8000
        if (-not $dev) {
            $lblMsg.ForeColor = [System.Drawing.Color]::Firebrick
            $lblMsg.Text = '连接失败：端口可能已变（重启手机后必变），或手机不在同一网络。'
            return
        }
        Save-Target $dev
        $dlg.Tag = $dev
        $timer.Stop()
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dlg.Close()
    })

    $btnCancel.Add_Click({ $timer.Stop(); $dlg.Close() })
    $dlg.Add_FormClosed({ $timer.Stop(); $timer.Dispose() })

    [void]$dlg.ShowDialog($form)
    if ($dlg.Tag) { return [string]$dlg.Tag }
    return ''
}

# ---------- connect ----------
function Connect-Mirror {
    T 'connect: start'
    Set-Status '正在查找设备…' 'idle'

    if ($rbWifi.Checked) {
        Confirm-WifiHotspot
        Set-Status '正在查找无线设备…' 'idle'
        $serial = Get-WifiSerial($txtIp.Text.Trim())
        if (-not $serial -and $script:pairHelper) {
            Set-Status '未发现已连接的无线设备，打开配对窗口…' 'idle'
            $serial = Show-PairDialog
            if ($serial) { $txtIp.Text = $serial }
        }
        if (-not $serial) {
            Set-Status '无线未连接：可用「无线配对…」（Android 11+ 无线调试，免数据线），或先插一次 USB 引导。' 'err'
            Restore-Hotspot
            return
        }
        if ($script:pairHelper) { Save-Target $serial }
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

    # 低亮投屏：先记原值再用系统原生亮度压到最低档（不叠任何覆盖窗口）
    if ($chkDim.Checked) {
        if ($script:brightnessHelperOK -and (Save-BrightnessSession -Device $serial)) {
            if (Apply-DimBrightness -Device $serial) {
                $script:dimActive = $true
                T 'dim: applied and verified (display brightness 0.0)'
                Set-Status '已切到低亮（手机面板≈2.5 尼特），正在启动投屏…' 'idle'
            } else {
                T 'dim: command accepted but display brightness unchanged'
                Set-Status '这台手机不接受亮度写入，已按正常亮度连接' 'idle'
            }
        } else {
            T 'dim: skipped (helper missing, unreadable, or already at minimum)'
            Set-Status '读不到可信的原亮度，改按正常亮度连接' 'idle'
        }
    }

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
        Stop-DimBrightness
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
    $dim   = if ($chkDim.Checked -and $script:dimActive) { '低亮' } else { '正常亮度' }
    Set-Status "已连接[$link]  $serial" 'ok'

    $btnConnect.Enabled = $false
    $btnStop.Enabled = $true
    $script:linkLabel = "$link / $awake / $dim / $mode / $ime"

    # hide into the tray so the mirror window is unobstructed
    $tray.Text = "手机投屏 - 已连接[$link]"
    $tray.BalloonTipTitle = '手机投屏已连接'
    $tray.BalloonTipText = "$link  $serial`n$awake | $dim | $mode | $ime"
    $tray.ShowBalloonTip(3000)
    $form.Hide()
}

# ---------- events ----------
$btnConnect.Add_Click({ Connect-Mirror })

$btnStop.Add_Click({
    $script:sessionActive = $false
    Stop-Mirror
    Stop-DimBrightness
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
    Stop-DimBrightness
    Restore-Hotspot
    $wakePoll.Stop()
    if ($script:showEvent) { $script:showEvent.Dispose() }
    $tray.Visible = $false
    $tray.Dispose()
})

$rbWifi.Add_CheckedChanged({
    $txtIp.Enabled = $rbWifi.Checked
    $lblIp.Enabled = $rbWifi.Checked
    $btnPair.Enabled = ($rbWifi.Checked -and $script:pairHelper)
})
$txtIp.Enabled = $false
$lblIp.Enabled = $false

$btnPair.Add_Click({
    $got = Show-PairDialog
    if ($got) {
        $txtIp.Text = $got
        Set-Status ('已配对并连接: ' + $got) 'ok'
    }
})

# watchdog: clean up in the tray when the mirror window is closed
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1500
$timer.Add_Tick({
    if ($script:sessionActive -and -not (Get-Process -Name 'scrcpy-core', 'scrcpy' -ErrorAction SilentlyContinue)) {
        $script:sessionActive = $false
        Stop-Watcher
        Stop-DimBrightness
        Restore-Hotspot
        $tray.Text = '手机投屏控制台'
        $btnConnect.Enabled = $true
        $btnStop.Enabled = $false
        Set-Status '投屏已结束（可在托盘图标右键重新连接）' 'idle'
    }
})
$timer.Start()

# 第二次启动投递过来的「显示控制台」请求：800ms 轮询一次，几乎无开销
$wakePoll = New-Object System.Windows.Forms.Timer
$wakePoll.Interval = 800
$wakePoll.Add_Tick({
    if ($script:showEvent -and $script:showEvent.WaitOne(0)) {
        T 'wake: show panel from second launch'
        Show-Panel
    }
})
$wakePoll.Start()

$script:autoConnect = ($args -contains '--auto')
$script:autoWifi = ($args -contains '--wifi')
[void]$form.Add_Shown({
    # 上次异常退出（控制台被强杀/断电）留下的低亮状态，先按记录还原
    Stop-DimBrightness
    Repair-BrightnessIfStuck
    # 上次成功用过的无线地址，填好省得每次找
    if ($script:pairHelper) {
        $saved = Get-SavedTarget
        if ($saved -and -not $txtIp.Text) { $txtIp.Text = $saved }
    }
    if ($script:autoWifi) { $rbWifi.Checked = $true }
    if ($script:autoConnect -or $script:autoWifi) { Connect-Mirror }
})

T 'entering message loop'
[System.Windows.Forms.Application]::Run($form)
T 'message loop returned'

$tray.Visible = $false
$tray.Dispose()
