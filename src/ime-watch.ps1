# Focus watcher for scrcpy.
# - scrcpy window focused  -> switch input language to US English
#   (raw letters reach the phone, so the phone IME can build pinyin)
# - focus leaves the scrcpy window   -> switch that window back to Chinese
#
# Logs to phone-ime.log next to this script. Exits when scrcpy exits.

$ErrorActionPreference = 'SilentlyContinue'
$title = 'PHONE'
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

Log "watcher started (title=$title)"

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
            if ($cur -eq 0x0409 -and $leaveTries -lt 6) {
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

Log "scrcpy exited, watcher stop"
