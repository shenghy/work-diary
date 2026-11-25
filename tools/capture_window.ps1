param(
    [string]$ProcessName = 'work_diary_app',
    [string]$Out = 'E:\Code\WorkDiary\shot.png'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$src = @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Text;

public static class WindowCapture {
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr SetForegroundWindow(IntPtr h);

    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }

    public static void Capture(IntPtr h, string path) {
        RECT r;
        GetWindowRect(h, out r);
        int w = r.Right - r.Left;
        int hh = r.Bottom - r.Top;
        using (var bmp = new Bitmap(w, hh)) {
            using (var g = Graphics.FromImage(bmp)) {
                IntPtr hdc = g.GetHdc();
                PrintWindow(h, hdc, 2); // PW_RENDERFULLCONTENT：Flutter 的合成表面要这个标志
                g.ReleaseHdc(hdc);
            }
            bmp.Save(path); // 扩展名决定格式：.png
        }
    }
}
'@

Add-Type -TypeDefinition $src -ReferencedAssemblies System.Drawing.dll

$proc = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowHandle -ne 0 } |
    Select-Object -First 1
if ($null -eq $proc) {
    Write-Host "WINDOW NOT FOUND for process: $ProcessName"
    exit 1
}
$hwnd = $proc.MainWindowHandle
[void][WindowCapture]::SetForegroundWindow($hwnd)
Start-Sleep -Milliseconds 500
[WindowCapture]::Capture($hwnd, $Out)
Write-Host "saved $Out"
