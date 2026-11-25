param([Parameter(Mandatory = $true)][string]$ConfigPath)

$ErrorActionPreference = 'Stop'
$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$appDir = [IO.Path]::GetFullPath($config.app_dir).TrimEnd('\')
$parentDir = Split-Path -LiteralPath $appDir
$appName = Split-Path -Leaf $appDir
$exeName = [string]$config.exe_name
$transaction = [string]$config.transaction
if ($transaction -notmatch '^[a-f0-9-]+$' -or $exeName -ne [IO.Path]::GetFileName($exeName) -or
    $appDir -eq [IO.Path]::GetPathRoot($appDir).TrimEnd('\')) {
    throw 'Invalid upgrade destination.'
}
$exePath = Join-Path $appDir $exeName
$workspace = Join-Path $parentDir ".$appName.upgrade-$transaction"
$newDir = Join-Path $workspace 'new'
$backupDir = Join-Path $workspace 'old'
$failedDir = Join-Path $workspace 'failed'
$marker = Join-Path $appDir 'upgrade_pending.txt'
$ready = [string]$config.ready_path
$proceed = [string]$config.proceed_path
$resultPath = [string]$config.result_path
$logPath = [string]$config.log_path
$backedUp = $false
$promoted = $false
$confirmed = $false
$newProcess = $null
$workspaceOwned = $false

function Log([string]$message) {
    Add-Content -LiteralPath $logPath -Encoding UTF8 -Value "[$(Get-Date -Format o)] [$transaction] $message"
}

# Destructive cleanup is limited to this transaction's verified sibling folder.
function Remove-WorkspaceItem([string]$path) {
    $resolved = [IO.Path]::GetFullPath($path).TrimEnd('\')
    if ($resolved -ne $workspace -and -not $resolved.StartsWith($workspace + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe cleanup path: $resolved"
    }
    if (Test-Path -LiteralPath $resolved) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}

function App-Processes {
    @(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($exeName)) -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and [IO.Path]::GetFullPath($_.Path) -eq $exePath })
}

function Save-Result([string]$status, [string]$message) {
    @{status = $status; message = $message; version = $config.version;
        transaction = $transaction; backup_dir = $backupDir; time = (Get-Date -Format o)} |
        ConvertTo-Json | Set-Content -LiteralPath $resultPath -Encoding UTF8
}

function Start-App([string[]]$launchArgs = @()) {
    # ProcessStartInfo preserves literal paths containing brackets or apostrophes.
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $exePath
    $start.WorkingDirectory = $appDir
    $start.UseShellExecute = $false
    $start.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $start.Arguments = $launchArgs -join ' '
    [Diagnostics.Process]::Start($start)
}

try {
    # Never keep the installation folder as the updater's working directory.
    Set-Location -LiteralPath ([IO.Path]::GetTempPath())
    Log "prepare: app=$appDir; staging=$newDir; backup=$backupDir; zip=$($config.zip_path)"
    if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) { throw 'Installed executable not found.' }
    if (Test-Path -LiteralPath $workspace) { throw 'Upgrade workspace already exists; preserving it.' }
    if ((Get-Item -LiteralPath $appDir).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'Installation path is a junction or symbolic link.'
    }
    [IO.Directory]::CreateDirectory($newDir) | Out-Null
    $workspaceOwned = $true

    # Verify the ZIP layout before shutting down the running app or touching it.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($config.zip_path)
    try {
        $names = @($archive.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
        foreach ($entry in $archive.Entries) {
            $entryName = $entry.FullName.Replace('/', '\')
            $target = [IO.Path]::GetFullPath((Join-Path $newDir $entryName))
            if ($entryName.Contains(':') -or -not $target.StartsWith($newDir + '\', [StringComparison]::OrdinalIgnoreCase)) {
                throw "Unsafe ZIP entry: $entryName"
            }
        }
        foreach ($required in @($exeName, 'flutter_windows.dll', 'data/app.so', 'data/icudtl.dat',
            'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
            if ($names -notcontains $required) { throw "Incomplete upgrade package: $required" }
        }
    } finally { $archive.Dispose() }
    # Preserve installation metadata, local API config and other existing files.
    # Refuse reparse points rather than following them into unrelated directories.
    $oldItems = @(Get-ChildItem -LiteralPath $appDir -Recurse -Force)
    if ($oldItems | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }) {
        throw 'Installation contains a junction or symbolic link; use the installer to update.'
    }
    Get-ChildItem -LiteralPath $appDir -Force | Copy-Item -Destination $newDir -Recurse -Force
    # Expand-Archive in Windows PowerShell mishandles brackets in destination
    # paths. Extract validated entries using literal .NET filesystem paths.
    $archive = [IO.Compression.ZipFile]::OpenRead($config.zip_path)
    try {
        foreach ($entry in $archive.Entries) {
            $target = [IO.Path]::GetFullPath((Join-Path $newDir $entry.FullName.Replace('/', '\')))
            if ($entry.FullName.EndsWith('/')) {
                [IO.Directory]::CreateDirectory($target) | Out-Null
            } else {
                [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
            }
        }
    } finally { $archive.Dispose() }
    $packVersion = (Get-Item -LiteralPath (Join-Path $newDir $exeName)).VersionInfo.ProductVersion
    if (-not $packVersion -or $packVersion.Split('+')[0] -ne ([string]$config.version).Split('+')[0]) {
        throw "Package executable version does not match published version: $packVersion"
    }
    $localApi = Join-Path $appDir 'api_url.txt'
    if (Test-Path -LiteralPath $localApi) { Copy-Item -LiteralPath $localApi -Destination $newDir -Force }
    $staleMarker = Join-Path $newDir 'upgrade_pending.txt'
    if (Test-Path -LiteralPath $staleMarker) { Remove-Item -LiteralPath $staleMarker -Force }
    Log 'prepared; waiting for app to authorize shutdown'
    Set-Content -LiteralPath $ready -Value $transaction -Encoding ASCII

    $deadline = (Get-Date).AddSeconds(60)
    while (-not (Test-Path -LiteralPath $proceed)) {
        if ((Get-Date) -gt $deadline) { throw 'App did not authorize shutdown; installation left unchanged.' }
        Start-Sleep -Milliseconds 200
    }

    # Match full executable paths, not process names: other installations stay alive.
    $deadline = (Get-Date).AddSeconds(15)
    while (@(App-Processes).Count -gt 0 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250 }
    foreach ($remaining in @(App-Processes)) {
        Log "stopping stale instance at the same path: PID=$($remaining.Id)"
        Stop-Process -Id $remaining.Id -Force
    }
    $deadline = (Get-Date).AddSeconds(5)
    while (@(App-Processes).Count -gt 0 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250 }
    if (@(App-Processes).Count -gt 0) { throw 'Old application is still running; update cancelled.' }
    Log 'all processes at the installation path have exited'

    # Keep the original folder name (WorkDiary, Release, or a custom name).
    # Retry brief antivirus/file-lock delays; do not overwrite an existing backup.
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        try {
            Move-Item -LiteralPath $appDir -Destination $backupDir
            $backedUp = $true
            break
        } catch {
            if ($attempt -eq 9) { throw }
            Start-Sleep -Milliseconds 500
        }
    }
    Move-Item -LiteralPath $newDir -Destination $appDir
    $promoted = $true
    Log "promoted to original path: $appDir; marker=$marker"
    @{transaction = $transaction; version = $config.version} | ConvertTo-Json |
        Set-Content -LiteralPath $marker -Encoding UTF8
    $newProcess = Start-App @('--upgrade', "--upgrade-id=$transaction")
    $waitSeconds = 60
    if ($config.confirm_timeout_seconds) { $waitSeconds = [int]$config.confirm_timeout_seconds }
    $deadline = (Get-Date).AddSeconds($waitSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 250
        $newProcess.Refresh()
        if ($newProcess.HasExited) { throw "New application exited: $($newProcess.ExitCode)" }
        if (-not (Test-Path -LiteralPath $marker)) {
            $confirmed = $true
            break
        }
    }
    if (-not $confirmed) { throw 'New application did not confirm startup before timeout.' }
    Log 'SUCCESS: new version confirmed initialization and first frame'
    Save-Result 'success' 'Upgrade completed.'
    # A cleanup failure must never roll back a confirmed upgrade.
    try {
        Remove-WorkspaceItem $workspace
        Remove-Item -LiteralPath $config.zip_path -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $config.pending_path -Force -ErrorAction SilentlyContinue
    } catch { Log "cleanup deferred: $_" }
    exit 0
} catch {
    $failure = $_.Exception.Message
    Log "FAILED: $failure"
    if ($confirmed) { exit 0 }
    try {
        if ($promoted) {
            foreach ($running in @(App-Processes)) {
                Stop-Process -Id $running.Id -Force
                $running.WaitForExit(5000) | Out-Null
            }
            Move-Item -LiteralPath $appDir -Destination $failedDir
        }
        if ($backedUp) {
            Move-Item -LiteralPath $backupDir -Destination $appDir
            Log "rollback restored original path: $appDir"
        }
        Save-Result 'failed' $failure
        # Keep the ZIP and pending JSON for retry, including after rollback.
        if ((Test-Path -LiteralPath $proceed) -and @(App-Processes).Count -eq 0) {
            Start-App | Out-Null
        }
        if ($workspaceOwned -and (Test-Path -LiteralPath $workspace)) { Remove-WorkspaceItem $workspace }
    } catch {
        Log "ROLLBACK/RECOVERY FAILED: $_; backup preserved at $backupDir"
        Save-Result 'recovery_failed' "$failure; recovery: $($_.Exception.Message)"
    }
    exit 1
}
