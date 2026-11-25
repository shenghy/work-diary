using System;
using System.IO;
using System.Threading;
using System.Reflection;

[assembly: AssemblyFileVersion("1.0.7.0")]
[assembly: AssemblyInformationalVersion("1.0.7")]

// Small executable for exercising actual Windows directory replacement and
// process lifecycle without opening the user's Flutter app or its database.
class UpgradeApp {
    static int Main(string[] args) {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string behavior = File.ReadAllText(Path.Combine(dir, "behavior.txt")).Trim();
        File.AppendAllText(Path.Combine(dir, "launches.txt"), String.Join(" ", args) + "\n");
        if (behavior == "exit") return 23;
        if (behavior == "confirm" && Array.IndexOf(args, "--upgrade") >= 0) {
            Thread.Sleep(300);
            File.Delete(Path.Combine(dir, "upgrade_pending.txt"));
        }
        Thread.Sleep(120000);
        return 0;
    }
}
