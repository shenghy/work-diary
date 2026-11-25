import 'dart:io';

/// Keep the PowerShell process observable until it reports that staging is ready.
/// On Windows, detached PowerShell may return a PID without running the script.
Future<Process> launchWindowsUpgradeHelper({
  required String scriptPath,
  required String configPath,
  required String workingDirectory,
}) {
  return Process.start(
    'powershell.exe',
    [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-WindowStyle',
      'Hidden',
      '-File',
      scriptPath,
      '-ConfigPath',
      configPath,
    ],
    workingDirectory: workingDirectory,
    mode: ProcessStartMode.normal,
  );
}
