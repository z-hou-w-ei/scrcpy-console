// ScrcpyLauncher: the double-click entry of this console.
//
// The original scrcpy.exe is renamed to scrcpy-core.exe; this launcher sits in
// its place and starts scrcpy-gui.ps1 without showing any console window.
// It resolves its own directory, so the whole folder can be moved anywhere.
//
// Build (Windows built-in compiler, no SDK required):
//   csc /nologo /target:winexe /win32icon:<repo>\assets\scrcpy.ico ^
//       /out:<runtime-dir>\scrcpy.exe <repo>\src\launcher\ScrcpyLauncher.cs

using System;
using System.Diagnostics;
using System.IO;

public class ScrcpyConsoleLauncher
{
    [STAThread]
    public static void Main()
    {
        try
        {
            string baseDir = AppDomain.CurrentDomain.BaseDirectory;
            string script = Path.Combine(baseDir, "scrcpy-gui.ps1");
            if (!File.Exists(script))
            {
                // 脚本被放在 src/ 下的仓库结构里：向上找一层
                string alt = Path.Combine(baseDir, "src", "scrcpy-gui.ps1");
                if (File.Exists(alt)) script = alt;
                else return;
            }

            string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
            if (!File.Exists(ps)) ps = "powershell.exe";

            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = ps;
            psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\"";
            psi.WorkingDirectory = Path.GetDirectoryName(script);
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            Process.Start(psi);
        }
        catch
        {
            // 启动失败不弹窗，避免反复打扰
        }
    }
}
