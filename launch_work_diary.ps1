<#
    Work Diary launcher (server edition).

    Two jobs:

      1. Keep the build current.
         If any source file (lib / windows\runner / assets / pubspec.yaml) is
         newer than the Release artifacts, run `flutter build windows --release`
         first. If nothing changed, skip the build (about a second).

      2. Run from a deploy folder OUTSIDE the project tree.
         Some security software on this machine forces programs located under
         E:\Code\WorkDiary to start with a low-integrity token, which makes
         Hive fail with "access denied" on Documents and the app dies before
         it can show a window. The Release output is mirrored to
         %LOCALAPPDATA%\Programs\WorkDiaryDev and started from there, which
         runs with a normal token.

      3. Prove the deploy folder really matches the build.
         A mirrored folder that still holds an old file is worse than no
         deploy at all: an exe built as Release but shipped next to a Debug
         flutter_windows.dll dies during engine start-up ("could not resolve
         the kernel binary") and the only symptom is a double-click that does
         nothing. The mirror is therefore verified file by file afterwards.

    Parameters:
      -ApiUrl <url>   API base url written into api_url.txt (default: cloud server)
      -Force          rebuild even when the exe looks up to date
      -NoBuild        never build, just launch the existing build
      -NoDeploy       run directly from the Release folder (diagnostics only)

    Example:
      powershell -NoProfile -ExecutionPolicy Bypass -File launch_work_diary.ps1
#>
[CmdletBinding()]
param(
    [string]$ApiUrl = 'https://work.jspang.com',
    [switch]$Force,
    [switch]$NoBuild,
    [switch]$NoDeploy
)

$ErrorActionPreference = 'Stop'

# Errors exit with code 1; the .bat wrapper keeps the window open so the
# message can actually be read.
trap {
    Write-Host ''
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ''
    exit 1
}

# --------------------------------------------------------------------------
# Paths
# --------------------------------------------------------------------------
$AppDir     = 'E:\Code\WorkDiary\work_diary_app'
$ReleaseDir = Join-Path $AppDir 'build\windows\x64\runner\Release'
$DeployDir  = Join-Path $env:LOCALAPPDATA 'Programs\WorkDiaryDev'

# Source locations that require a rebuild when they are newer than the build.
$SourceDirs = @(
    (Join-Path $AppDir 'lib'),
    (Join-Path $AppDir 'windows\runner'),
    (Join-Path $AppDir 'assets')
)
$SourceFiles = @('pubspec.yaml', 'analysis_options.yaml')

# Touch after every successful build: "these artifacts are coherent as of this
# moment". Kept inside the Release folder so `flutter clean` drops it with the
# build it describes.
$StampName = '.build-stamp'
$StampPath = Join-Path $ReleaseDir $StampName
$ReleaseExe = Join-Path $ReleaseDir 'work_diary_app.exe'

# Files whose absence means the Release folder is not a runnable app.
$RequiredArtifacts = @(
    'work_diary_app.exe',
    'flutter_windows.dll',
    'data\app.so',
    'data\icudtl.dat'
)

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
function Write-Step {
    param([string]$Message)
    Write-Host "[*] $Message" -ForegroundColor Cyan
}

function Fail {
    param([string]$Message)
    Write-Host ''
    Write-Host "[ERROR] $Message" -ForegroundColor Red
    Write-Host ''
    exit 1
}

function Get-NewestSourceTime {
    $items = @()
    foreach ($dir in $SourceDirs) {
        if (Test-Path -LiteralPath $dir) {
            $items += @(Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue)
        }
    }
    foreach ($name in $SourceFiles) {
        $path = Join-Path $AppDir $name
        if (Test-Path -LiteralPath $path) {
            $items += @(Get-Item -LiteralPath $path -ErrorAction SilentlyContinue)
        }
    }
    if ($items.Count -eq 0) { return [datetime]::MinValue }
    return ($items | Measure-Object -Property LastWriteTime -Maximum).Maximum
}

# A Release folder is only runnable when all of these are present and were
# produced by the same build - an exe, an engine DLL and a Dart snapshot from
# different generations fail during engine start-up.
function Test-ReleaseComplete {
    foreach ($relative in $RequiredArtifacts) {
        if (-not (Test-Path -LiteralPath (Join-Path $ReleaseDir $relative))) { return $false }
    }
    return $true
}

# Wait until no work_diary_app process is left. Returns $false on timeout.
function Wait-AppExit {
    param([int]$TimeoutSeconds = 15)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process -Name 'work_diary_app' -ErrorAction SilentlyContinue)) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

# Deploy files that are still held open (loaded DLLs can not be overwritten,
# and robocopy has been observed leaving them in place without failing).
function Get-LockedDeployFile {
    foreach ($file in @(Get-ChildItem -LiteralPath $DeployDir -Filter '*.dll' -File -ErrorAction SilentlyContinue)) {
        $stream = $null
        try {
            $stream = [System.IO.File]::Open($file.FullName, 'Open', 'Write', 'None')
        }
        catch {
            return $file.Name
        }
        finally {
            if ($stream) { $stream.Dispose() }
        }
    }
    return $null
}

# relative path -> "size|write time", used to compare two trees.
# api_url.txt is written by this script after the mirror, so it is not part of
# the build and is ignored.
function Get-FileFingerprint {
    param([string]$Root)
    $map = @{}
    $prefix = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\') + '\'
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue)) {
        $relative = $file.FullName.Substring($prefix.Length)
        if ($relative -ieq 'api_url.txt') { continue }
        $map[$relative] = ('{0}|{1:yyyy-MM-dd HH:mm:ss}' -f $file.Length, $file.LastWriteTimeUtc)
    }
    return $map
}

function Assert-DeployMatchesBuild {
    $expected = Get-FileFingerprint -Root $ReleaseDir
    $actual = Get-FileFingerprint -Root $DeployDir

    $drift = @()
    foreach ($key in $expected.Keys) {
        if ($actual[$key] -ne $expected[$key]) { $drift += $key }
    }
    if ($drift.Count -gt 0) {
        $shown = @($drift | Select-Object -First 6)
        if ($drift.Count -gt $shown.Count) {
            $shown += ('...and {0} more' -f ($drift.Count - $shown.Count))
        }
        $list = $shown -join "`n        "
        Fail ("Deploy folder is out of date:`n        $list`n" +
              "        A previous instance usually still holds those files open.`n" +
              "        Close Work Diary from the tray icon and start this again.")
    }
}

function Resolve-Flutter {
    $candidates = @()

    if ($env:FLUTTER_ROOT) {
        $candidates += (Join-Path $env:FLUTTER_ROOT 'bin\flutter.bat')
    }

    $command = Get-Command 'flutter.bat' -ErrorAction SilentlyContinue
    if ($command) { $candidates += $command.Source }

    $candidates += @(
        'D:\FlutterSDK\flutter\bin\flutter.bat',
        'C:\flutter\bin\flutter.bat',
        'D:\flutter\bin\flutter.bat'
    )
    if ($env:LOCALAPPDATA) {
        $candidates += (Join-Path $env:LOCALAPPDATA 'flutter\bin\flutter.bat')
    }
    if ($env:USERPROFILE) {
        $candidates += (Join-Path $env:USERPROFILE 'flutter\bin\flutter.bat')
    }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    return $null
}

# --------------------------------------------------------------------------
# 0. Banner
# --------------------------------------------------------------------------
Write-Host ''
Write-Host '========================================' -ForegroundColor DarkGray
Write-Host '   Work Diary - server' -ForegroundColor White
Write-Host '========================================' -ForegroundColor DarkGray

if (-not (Test-Path -LiteralPath $AppDir)) {
    Fail "Project not found: $AppDir"
}

# --------------------------------------------------------------------------
# 1. Close the running instance so the exe and DLL file locks are released
# --------------------------------------------------------------------------
$running = @(Get-Process -Name 'work_diary_app' -ErrorAction SilentlyContinue)
if ($running.Count -gt 0) {
    Write-Step 'Closing the running instance...'
    $running | Stop-Process -Force -ErrorAction SilentlyContinue
    # Not a sleep: the DLLs stay mapped until the process table entry is gone,
    # and robocopy happily reports success while skipping a locked target.
    if (-not (Wait-AppExit)) {
        Fail 'A Work Diary process will not exit. End it in Task Manager and start this again.'
    }
    $locked = Get-LockedDeployFile
    if ($locked) {
        Fail ("$locked in the deploy folder is still held open.`n        Close Work Diary (tray icon -> Quit) and start this again.")
    }
}

# --------------------------------------------------------------------------
# 2. Decide whether a rebuild is needed
# --------------------------------------------------------------------------
$needBuild = $false

if ($NoBuild) {
    Write-Step 'Skipping build (-NoBuild).'
}
elseif ($Force) {
    $needBuild = $true
    Write-Step 'Rebuild forced (-Force).'
}
elseif (-not (Test-Path -LiteralPath $ReleaseExe)) {
    $needBuild = $true
    Write-Step 'No build found yet, building...'
}
elseif (-not (Test-ReleaseComplete)) {
    $needBuild = $true
    Write-Step 'Release folder is missing engine files, rebuilding...'
}
elseif (-not (Test-Path -LiteralPath $StampPath)) {
    $needBuild = $true
    Write-Step "No $($StampName) - the build was not made by this script, rebuilding..."
}
else {
    $sourceTime = Get-NewestSourceTime
    $buildTime = (Get-Item -LiteralPath $StampPath).LastWriteTime
    # 2 seconds of slack: build and filesystem timestamp granularity must not
    # cause a rebuild on every single launch.
    if ($sourceTime -gt $buildTime.AddSeconds(2)) {
        $needBuild = $true
        Write-Step ('Source changed ({0:yyyy-MM-dd HH:mm:ss}) after the build ({1:yyyy-MM-dd HH:mm:ss}), rebuilding...' -f $sourceTime, $buildTime)
    }
    else {
        Write-Step ('Build is up to date ({0:yyyy-MM-dd HH:mm:ss}).' -f $buildTime)
    }
}

# --------------------------------------------------------------------------
# 3. Build
# --------------------------------------------------------------------------
if ($needBuild) {
    $flutter = Resolve-Flutter
    if (-not $flutter) {
        Fail "flutter not found.`n        Set FLUTTER_ROOT, or put flutter.bat on PATH.`n        Expected: D:\FlutterSDK\flutter\bin\flutter.bat"
    }

    Write-Step "flutter : $flutter"
    Write-Step 'Running : flutter build windows --release'

    Push-Location $AppDir
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $flutter build windows --release
        $buildExit = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
        Pop-Location
    }

    if ($buildExit -ne 0) {
        Fail ("Build failed (exit code {0}).`n        Nothing was launched, so you can not accidentally run an old binary.`n        Use -NoBuild to start the previous build anyway." -f $buildExit)
    }
    if (-not (Test-ReleaseComplete)) {
        Fail "Build reported success but the Release folder is incomplete: $ReleaseDir"
    }
    # Only stamped once the build is known good: an older stamp keeps forcing a
    # rebuild after a failure.
    Set-Content -LiteralPath $StampPath -Value (Get-Date).ToString('o') -Encoding Ascii -NoNewline
    Write-Step 'Build finished.'
}

if (-not (Test-Path -LiteralPath $ReleaseExe)) {
    Fail "Executable not found: $ReleaseExe"
}

# --------------------------------------------------------------------------
# 4. Mirror the build to the deploy folder (outside the project tree)
# --------------------------------------------------------------------------
if ($NoDeploy) {
    Write-Step 'Running directly from the Release folder (-NoDeploy).'
    $runDir = $ReleaseDir
}
else {
    Write-Step "Deploying to: $DeployDir"
    New-Item -ItemType Directory -Force -Path $DeployDir | Out-Null
    # robocopy exit codes 0..7 are success (bit flags); >= 8 is a real error.
    # api_url.txt belongs to the deploy folder, not to the build.
    $robolog = & robocopy $ReleaseDir $DeployDir /MIR /NJH /NJS /NP /NFL /NDL /XF api_url.txt /R:5 /W:2
    $rc = $LASTEXITCODE
    if ($rc -ge 8) {
        Fail ("Deploy failed (robocopy exit {0}).`n{1}" -f $rc, ($robolog -join "`n"))
    }
    Assert-DeployMatchesBuild
    $runDir = $DeployDir
}

$exePath = Join-Path $runDir 'work_diary_app.exe'
if (-not (Test-Path -LiteralPath $exePath)) {
    Fail "Executable not found after deploy: $exePath"
}

# --------------------------------------------------------------------------
# 5. Point the app at the API and launch
# --------------------------------------------------------------------------
$apiFile = Join-Path $runDir 'api_url.txt'
try {
    Set-Content -LiteralPath $apiFile -Value $ApiUrl -Encoding Ascii -NoNewline
}
catch {
    Write-Host "[WARN] Could not write $apiFile : $($_.Exception.Message)" -ForegroundColor Yellow
}

$exeInfo = Get-Item -LiteralPath $exePath
$version = $exeInfo.VersionInfo.FileVersion
# The exe keeps its link date when only Dart code changed, so the stamp is the
# honest answer to "is this the build I just edited".
if (Test-Path -LiteralPath $StampPath) {
    $builtAt = (Get-Item -LiteralPath $StampPath).LastWriteTime
}
else {
    $builtAt = $exeInfo.LastWriteTime
}

Start-Process -FilePath $exePath -WorkingDirectory $runDir

Write-Host ''
Write-Host '========================================' -ForegroundColor DarkGray
Write-Host '   LAUNCHED' -ForegroundColor Green
Write-Host ('   Version : {0}' -f $version)
Write-Host ('   Built   : {0:yyyy-MM-dd HH:mm:ss}' -f $builtAt)
Write-Host ('   Exe     : {0}' -f $exePath)
Write-Host ('   API     : {0}' -f $ApiUrl)
Write-Host ('   Admin   : {0}/admin' -f $ApiUrl)
Write-Host '========================================' -ForegroundColor DarkGray
Write-Host ''

Start-Sleep -Seconds 3
exit 0
