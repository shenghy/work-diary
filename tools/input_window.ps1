param(
    [ValidateSet('click', 'type', 'key')]
    [Parameter(Mandatory = $true)][string]$Action,
    [int]$X = 0,
    [int]$Y = 0,
    [string]$Text = '',
    [string]$Keys = '',
    [string]$ProcessName = 'work_diary_app'
)

# 给真实窗口喂鼠标/键盘。Flutter 窗口没有 UIA 树，只能按坐标点，
# 而坐标是 capture_window.ps1 截图上的相对位置，所以这里要加窗口左上角偏移。

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$src = @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Threading;

public static class WinInput {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern IntPtr SetForegroundWindow(IntPtr h);

    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }

    const uint LEFTDOWN = 0x0002, LEFTUP = 0x0004;

    public static void Focus(IntPtr h) {
        SetForegroundWindow(h);
        Thread.Sleep(350);
    }

    public static Rectangle Rect(IntPtr h) {
        RECT r;
        GetWindowRect(h, out r);
        return new Rectangle(r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top);
    }

    public static void Click(int x, int y) {
        SetCursorPos(x, y);
        Thread.Sleep(150);
        mouse_event(LEFTDOWN, 0, 0, 0, UIntPtr.Zero);
        Thread.Sleep(70);
        mouse_event(LEFTUP, 0, 0, 0, UIntPtr.Zero);
    }
}
'@
Add-Type -TypeDefinition $src -ReferencedAssemblies System.Drawing.dll

$proc = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowHandle -ne 0 } |
    Select-Object -First 1
if ($null -eq $proc) { Write-Host "NO PROCESS $ProcessName"; exit 1 }

$hwnd = $proc.MainWindowHandle
$rect = [WinInput]::Rect($hwnd)
[WinInput]::Focus($hwnd)

switch ($Action) {
    'click' {
        [WinInput]::Click($rect.Left + $X, $rect.Top + $Y)
        Write-Host "clicked window-relative $X,$Y (screen $($rect.Left + $X),$($rect.Top + $Y))"
    }
    'type' {
        [System.Windows.Forms.Clipboard]::SetText($Text)
        Start-Sleep -Milliseconds 150
        # 中文直接 SendKeys 会被输入法吃掉，走剪贴板粘贴
        [System.Windows.Forms.SendKeys]::SendWait('^v')
        Write-Host "pasted $($Text.Length) chars"
    }
    'key' {
        [System.Windows.Forms.SendKeys]::SendWait($Keys)
        Write-Host "sent $Keys"
    }
}
