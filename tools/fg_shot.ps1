param([string]$Out = 'E:\Code\WorkDiary\shot_fg.png')

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$src = @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;

public static class FgCapture {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
    [DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Auto)]
    public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);

    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }

    public static void Shot(string path) {
        IntPtr h = GetForegroundWindow();
        RECT r;
        GetWindowRect(h, out r);
        int w = r.R - r.L;
        int hh = r.B - r.T;
        using (var bmp = new Bitmap(w, hh)) {
            using (var g = Graphics.FromImage(bmp)) {
                IntPtr dc = g.GetHdc();
                PrintWindow(h, dc, 2);
                g.ReleaseHdc(dc);
            }
            bmp.Save(path);
        }
        var name = new System.Text.StringBuilder(512);
        GetWindowText(h, name, name.Capacity);
        Console.WriteLine("hwnd=" + h + " title=" + name.ToString() +
                          " rect=" + r.L + "," + r.T + " size=" + w + "x" + hh);
    }
}
'@

Add-Type -TypeDefinition $src -ReferencedAssemblies System.Drawing.dll
[FgCapture]::Shot($Out)
