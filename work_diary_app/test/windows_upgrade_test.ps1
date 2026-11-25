$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$script = Join-Path $project 'assets\upgrade\windows_upgrade.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('workdiary-upgrade-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$exeName = 'workdiary_upgrade_fixture.exe'
$fixture = Join-Path $root $exeName
& 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe' /nologo /target:winexe "/out:$fixture" (Join-Path $PSScriptRoot 'fixtures\upgrade_app.cs')
if ($LASTEXITCODE -ne 0) { throw 'Fixture compile failed.' }

function Assert($condition, [string]$message) {
    if (-not $condition) { throw $message }
}
function Write-Text([string]$path, [string]$text) {
    [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false)))
}
function Stop-Fixtures([string]$under) {
    Get-Process -Name 'workdiary_upgrade_fixture' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith($under + '\', [StringComparison]::OrdinalIgnoreCase) } |
        ForEach-Object { Stop-Process -Id $_.Id -Force; $_.WaitForExit(5000) | Out-Null }
}
function Run-Case([string]$name, [string]$behavior, [bool]$expectedSuccess, [bool]$invalidZip = $false, [bool]$duplicates = $false, [bool]$locked = $false, [bool]$wrongVersion = $false) {
    $caseRoot = Join-Path $root ([guid]::NewGuid().ToString('N'))
    $app = Join-Path $caseRoot $name
    $payload = Join-Path $caseRoot 'payload'
    New-Item -ItemType Directory -Path $app, (Join-Path $payload 'data') | Out-Null
    Copy-Item -LiteralPath $fixture -Destination (Join-Path $app $exeName)
    Write-Text (Join-Path $app 'behavior.txt') 'old'
    Write-Text (Join-Path $app 'version.txt') 'old'
    Write-Text (Join-Path $app 'unins000.dat') 'installer metadata'
    Write-Text (Join-Path $app 'api_url.txt') 'http://local-override.invalid'
    Copy-Item -LiteralPath $fixture -Destination (Join-Path $payload $exeName)
    Write-Text (Join-Path $payload 'behavior.txt') $behavior
    Write-Text (Join-Path $payload 'version.txt') 'new'
    foreach ($file in @('flutter_windows.dll', 'data\app.so', 'data\icudtl.dat', 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
        Write-Text (Join-Path $payload $file) 'fixture'
    }
    if ($invalidZip) { Remove-Item -LiteralPath (Join-Path $payload 'flutter_windows.dll') }
    $zip = Join-Path $caseRoot 'update.zip'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($payload, $zip)
    $configPath = Join-Path $caseRoot 'config.json'
    $config = @{
        app_dir = $app; exe_name = $exeName; transaction = [guid]::NewGuid().ToString(); version = '1.0.7';
        zip_path = $zip; pending_path = (Join-Path $caseRoot 'upgrade_pending.json');
        result_path = (Join-Path $caseRoot 'result.json'); log_path = (Join-Path $caseRoot 'upgrade.log');
        ready_path = (Join-Path $caseRoot 'ready'); proceed_path = (Join-Path $caseRoot 'proceed');
        confirm_timeout_seconds = 2
    }
    if ($wrongVersion) { $config.version = '1.0.8' }
    Write-Text $config.pending_path '{"version":"1.0.7"}'
    Write-Text $configPath ($config | ConvertTo-Json)
    $outside = Join-Path $caseRoot 'another-install'
    New-Item -ItemType Directory -Path $outside | Out-Null
    Copy-Item -LiteralPath $fixture -Destination (Join-Path $outside $exeName)
    Write-Text (Join-Path $outside 'behavior.txt') 'old'
    $unrelated = Start-Process -FilePath (Join-Path $outside $exeName) -WorkingDirectory $outside -WindowStyle Hidden -PassThru
    if ($duplicates) {
        Start-Process -FilePath (Join-Path $app $exeName) -WorkingDirectory $env:TEMP -WindowStyle Hidden | Out-Null
        Start-Process -FilePath (Join-Path $app $exeName) -WorkingDirectory $env:TEMP -WindowStyle Hidden | Out-Null
    }
    $lockStream = $null
    if ($locked) {
        $lockStream = [IO.File]::Open((Join-Path $app 'unins000.dat'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    }
    $helper = Start-Process powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$script`"", '-ConfigPath', "`"$configPath`"") -WorkingDirectory $env:TEMP -WindowStyle Hidden -PassThru
    try {
        $deadline = (Get-Date).AddSeconds(15)
        while (-not (Test-Path -LiteralPath $config.ready_path) -and -not $helper.HasExited -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 100
            $helper.Refresh()
        }
        if (-not $invalidZip -and -not $wrongVersion) {
            Assert (Test-Path -LiteralPath $config.ready_path) "Updater did not prepare: $(Get-Content $config.log_path -Raw -ErrorAction SilentlyContinue)"
            Write-Text $config.proceed_path 'proceed'
        }
        Assert ($helper.WaitForExit(35000)) 'Updater timed out.'
        Assert (Test-Path -LiteralPath $config.result_path) 'Updater did not write a result.'
        $result = Get-Content -LiteralPath $config.result_path -Raw | ConvertFrom-Json
        if ($expectedSuccess) {
            Assert ($result.status -eq 'success') "Expected success: $($result.message)"
            Assert ((Get-Content -LiteralPath (Join-Path $app 'version.txt') -Raw) -eq 'new') 'New app is not at the original path.'
            Assert ((Get-Content -LiteralPath (Join-Path $app 'launches.txt') -Raw).Contains("--upgrade-id=$($config.transaction)")) 'Upgrade transaction argument was not forwarded.'
            Assert (-not (Test-Path -LiteralPath $config.pending_path)) 'Success left stale pending state.'
            Assert (-not (Test-Path -LiteralPath $zip)) 'Success left the downloaded ZIP.'
        } else {
            Assert ($result.status -eq 'failed') "Expected a recoverable failure: $($result.status)"
            Assert ((Get-Content -LiteralPath (Join-Path $app 'version.txt') -Raw) -eq 'old') 'Rollback did not restore the original path.'
            Assert (Test-Path -LiteralPath $config.pending_path) 'Failure lost pending state.'
            Assert (Test-Path -LiteralPath $zip) 'Failure lost the ZIP needed for retry.'
        }
        Assert ((Get-Content -LiteralPath (Join-Path $app 'unins000.dat') -Raw) -eq 'installer metadata') 'Installer metadata was lost.'
        Assert ((Get-Content -LiteralPath (Join-Path $app 'api_url.txt') -Raw) -eq 'http://local-override.invalid') 'Local API setting was lost.'
        $unrelated.Refresh()
        Assert (-not $unrelated.HasExited) 'Updater stopped an unrelated installation.'
        Write-Output "PASS: $name / $behavior / invalid=$invalidZip / duplicates=$duplicates / locked=$locked / wrongVersion=$wrongVersion"
    } finally {
        if ($lockStream) { $lockStream.Dispose() }
        if (-not $helper.HasExited) { Stop-Process -Id $helper.Id -Force }
        Stop-Fixtures $caseRoot
    }
}

try {
    Run-Case 'WorkDiary' 'confirm' $true
    Run-Case 'Release' 'confirm' $true
    Run-Case "极简 工作日记 [test] O'Brien `$app" 'confirm' $true
    Run-Case 'CustomInstall' 'exit' $false
    Run-Case 'TimeoutInstall' 'wait' $false
    Run-Case 'BadPackage' 'confirm' $false $true
    Run-Case 'StaleInstances' 'confirm' $true $false $true
    Run-Case 'LockedInstallation' 'confirm' $false $false $false $true
    Run-Case 'MismatchedVersion' 'confirm' $false $false $false $false $true
    Write-Output "All Windows upgrade integration checks passed. Evidence: $root"
} finally {
    Stop-Fixtures $root
    # Keep tiny fixtures and logs as evidence; no user installation was touched.
}
