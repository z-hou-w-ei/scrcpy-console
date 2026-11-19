# Focus watcher for scrcpy.
# - scrcpy window focused  -> switch input language to US English
#   (raw letters reach the phone, so the phone IME can build pinyin)
# - focus leaves the scrcpy window   -> switch that window back to Chinese
# - scrcpy exits (including 控制台被强杀后 scrcpy 消失) -> force the foreground
#   window back to Chinese, so you never get stuck typing in the US layout
#
# 单独把当前焦点切回中文：powershell -File ime-watch.ps1 -Restore
#
# Logs to phone-ime.log next to this script. Exits when scrcpy exits.

param(
    [switch]$Restore,
    [string]$Title = 'PHONE'
)

$ErrorActionPreference = 'SilentlyContinue'
$title = $Title
$intervalMs = 200
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$log  = Join-Path $here 'phone-ime.log'

function Log([string]$msg) {
    $ts = (Get-Date).ToString('HH:mm:ss')
    Add-Content -LiteralPath $log -Value "$ts  $msg"
}

$sig = @'
using System;
using System.Text;
using System.Runtime.InteropServices;

public class ImeW {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern IntPtr GetKeyboardLayout(uint tid);
  [DllImport("user32.dll")] public static extern IntPtr LoadKeyboardLayout(string id, uint flags);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint tid, ref GUITHREADINFO info);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);

  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int L, T, R, B; }

  [StructLayout(LayoutKind.Sequential)]
  public struct GUITHREADINFO {
    public uint cbSize; public uint flags;
    public IntPtr hwndActive; public IntPtr hwndFocus;
    public IntPtr hwndCapture; public IntPtr hwndMenuOwner;
    public IntPtr hwndMoveSize; public IntPtr hwndCaret;
    public RECT rcCaret;
  }

  public const uint WM_INPUTLANGCHANGEREQUEST = 0x0050;
  public static string Target = "";
  public static uint ScrcpyPid = 0;

  public static string TitleOf(IntPtr h) {
    StringBuilder t = new StringBuilder(256);
    GetWindowText(h, t, 256);
    return t.ToString();
  }

  public static uint PidOf(IntPtr h) {
    uint pid = 0;
    GetWindowThreadProcessId(h, out pid);
    return pid;
  }

  public static bool IsTargetFocused() {
    return PidOf(GetForegroundWindow()) == ScrcpyPid;
  }

  public static ushort Cur() {
    IntPtr fg = GetForegroundWindow();
    uint pid;
    uint tid = GetWindowThreadProcessId(fg, out pid);
    return (ushort)(GetKeyboardLayout(tid).ToInt64() & 0xFFFF);
  }

  public static void Switch(IntPtr hkl) {
    IntPtr fg = GetForegroundWindow();
    PostMessage(fg, WM_INPUTLANGCHANGEREQUEST, IntPtr.Zero, hkl);
    uint pid;
    uint tid = GetWindowThreadProcessId(fg, out pid);
    GUITHREADINFO info = new GUITHREADINFO();
    info.cbSize = (uint)Marshal.SizeOf(typeof(GUITHREADINFO));
    if (GetGUIThreadInfo(tid, ref info) && info.hwndFocus != IntPtr.Zero && info.hwndFocus != fg && IsWindow(info.hwndFocus))
      PostMessage(info.hwndFocus, WM_INPUTLANGCHANGEREQUEST, IntPtr.Zero, hkl);
  }
}
'@

Add-Type -TypeDefinition $sig -ErrorAction SilentlyContinue
[ImeW]::Target = $title

$engHkl = [ImeW]::LoadKeyboardLayout('00000409', 0)
$zhHkl  = [ImeW]::LoadKeyboardLayout('00000804', 0)

# 把当前前台窗口切回中文，最多重试 $tries 次；成功返回 $true。
# 单次 WM_INPUTLANGCHANGEREQUEST 常被目标线程忽略（例如刚抢到焦点的浏览器），
# 所以这里反复投递并回读键盘布局确认，避免"切了但没切过去"。
function Restore-Chinese {
    param([int]$tries = 12)
    for ($i = 0; $i -lt $tries; $i++) {
        if ([ImeW]::Cur() -ne 0x0409) { return $true }
        [ImeW]::Switch($zhHkl)
        Start-Sleep -Milliseconds 120
    }
    return ([ImeW]::Cur() -ne 0x0409)
}

Log "watcher started (title=$title)"

if ($Restore) {
    # 由控制台在看门狗被杀之后调用：把用户当前正在用的窗口切回中文
    $ok = Restore-Chinese -tries 20
    Log ("standalone restore done, ok=$ok cur=0x$(([ImeW]::Cur()).ToString('X4'))")
    exit 0
}

$inScrcpy = $false
$leavePending = $false
$leaveTries = 0

while ($true) {
    $proc = Get-Process -Name 'scrcpy-core' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $proc) { $proc = Get-Process -Name 'scrcpy' -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if (-not $proc) { break }
    [ImeW]::ScrcpyPid = [uint32]$proc.Id
    $cur = [ImeW]::Cur()

    if ([ImeW]::IsTargetFocused()) {
        $leavePending = $false; $leaveTries = 0
        $inScrcpy = $true
        if ($cur -ne 0x0409) {
            [ImeW]::Switch($engHkl)
            Log "-> english (was 0x$($cur.ToString('X4')))"
            Start-Sleep -Milliseconds 150
        }
    }
    else {
        if ($inScrcpy) {
            $inScrcpy = $false
            $leavePending = $true
            $leaveTries = 0
            Log "focus left scrcpy -> $([ImeW]::TitleOf([ImeW]::GetForegroundWindow()))"
        }
        if ($leavePending) {
            if ($cur -eq 0x0409 -and $leaveTries -lt 12) {
                [ImeW]::Switch($zhHkl)
                $leaveTries++
                Log "-> chinese (try $leaveTries)"
                Start-Sleep -Milliseconds 150
            }
            elseif ($cur -ne 0x0409) {
                $leavePending = $false
                Log "restored chinese (0x$($cur.ToString('X4')))"
            }
        }
    }

    Start-Sleep -Milliseconds $intervalMs
}

# scrcpy 已经消失（正常断开、关窗口、或被强杀）：把用户当前窗口切回中文再说
$ok = Restore-Chinese -tries 20
Log ("scrcpy exited, watcher stop (restore ok=$ok cur=0x$(([ImeW]::Cur()).ToString('X4')))")
