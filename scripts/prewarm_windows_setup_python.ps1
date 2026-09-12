param(
    [string]$RunnerDir = "C:\actions-runners\workspace\worker-01",
    [ValidatePattern('^\d+\.\d+$')][string]$PythonMinor = "3.12"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Fail([string]$Message) {
    Write-Host "[ERR ] $Message" -ForegroundColor Red
    exit 1
}

function Info([string]$Message) {
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Ok([string]$Message) {
    Write-Host "[ OK ] $Message" -ForegroundColor Green
}

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($id)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fail "Open PowerShell as Administrator and run again."
}

if (-not (Test-Path -LiteralPath $RunnerDir)) {
    Fail "Runner directory not found: $RunnerDir"
}

$serviceFile = Join-Path $RunnerDir ".service"
if (-not (Test-Path -LiteralPath $serviceFile)) {
    Fail "Runner service metadata not found: $serviceFile"
}

$serviceName = (Get-Content -LiteralPath $serviceFile -Raw).Trim()
if ([string]::IsNullOrWhiteSpace($serviceName)) {
    Fail "Runner service name is empty."
}

$toolCache = Join-Path $RunnerDir "_work\_tool"
$tempRoot = Join-Path $env:TEMP ("workspace-python-prewarm-" + [guid]::NewGuid().ToString("N"))
$archive = Join-Path $tempRoot "python.zip"
$extractDir = Join-Path $tempRoot "extract"
$manifestUrl = "https://raw.githubusercontent.com/actions/python-versions/main/versions-manifest.json"

$service = Get-Service -Name $serviceName -ErrorAction Stop
$wasRunning = $service.Status -eq "Running"

try {
    if ($wasRunning) {
        Info "Stopping runner service during tool-cache provisioning: $serviceName"
        Stop-Service -Name $serviceName -Force
    }

    New-Item -ItemType Directory -Force -Path $tempRoot, $extractDir, $toolCache | Out-Null

    Info "Resolving latest stable Python $PythonMinor release that has a win32-x64 artifact..."
    $manifest = Invoke-RestMethod -Uri $manifestUrl -UseBasicParsing
    $candidates = @(
        $manifest |
            Where-Object { $_.stable -eq $true -and [string]$_.version -like "$PythonMinor.*" } |
            Sort-Object { [version]$_.version } -Descending
    )

    if ($candidates.Count -eq 0) {
        Fail "No stable Python $PythonMinor release found in actions/python-versions manifest."
    }

    $release = $null
    $file = $null

    foreach ($candidate in $candidates) {
        $candidateFile = $candidate.files |
            Where-Object {
                [string]$_.platform -eq "win32" -and
                [string]$_.arch -eq "x64" -and
                -not [string]::IsNullOrWhiteSpace([string]$_.download_url)
            } |
            Select-Object -First 1

        if ($null -ne $candidateFile) {
            $release = $candidate
            $file = $candidateFile
            break
        }

        Info "Skipping Python $($candidate.version): no win32-x64 artifact in manifest."
    }

    if ($null -eq $release -or $null -eq $file) {
        Fail "No stable Python $PythonMinor release with a win32-x64 artifact was found."
    }

    $version = [string]$release.version
    Info "Selected Python $version"
    Info "Downloading official actions/python-versions artifact..."
    Invoke-WebRequest -Uri ([string]$file.download_url) -OutFile $archive -UseBasicParsing

    Info "Extracting artifact..."
    Expand-Archive -LiteralPath $archive -DestinationPath $extractDir -Force

    $setup = Join-Path $extractDir "setup.ps1"
    if (-not (Test-Path -LiteralPath $setup)) {
        Fail "setup.ps1 was not found in the downloaded Python artifact."
    }

    $versionDir = Join-Path (Join-Path $toolCache "Python") $version
    if (Test-Path -LiteralPath $versionDir) {
        Info "Removing incomplete existing cache entry: $versionDir"
        Remove-Item -LiteralPath $versionDir -Recurse -Force
    }

    $env:RUNNER_TOOL_CACHE = $toolCache
    $env:AGENT_TOOLSDIRECTORY = $toolCache

    Info "Provisioning Python $version into runner tool cache with Administrator authority..."
    Push-Location $extractDir
    try {
        & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $setup
        if ($LASTEXITCODE -ne 0) {
            Fail "Python tool-cache setup failed with exit code $LASTEXITCODE."
        }
    }
    finally {
        Pop-Location
    }

    $pythonExe = Join-Path $versionDir "x64\python.exe"
    $completeMarker = Join-Path $versionDir "x64.complete"

    if (-not (Test-Path -LiteralPath $pythonExe)) {
        Fail "Python executable missing after setup: $pythonExe"
    }
    if (-not (Test-Path -LiteralPath $completeMarker)) {
        Fail "Tool-cache completion marker missing: $completeMarker"
    }

    & icacls.exe $toolCache /grant:r "NT AUTHORITY\NETWORK SERVICE:(OI)(CI)RX" /T /C | Out-Null

    $reportedVersion = (& $pythonExe --version 2>&1 | Out-String).Trim()
    Ok "Tool cache ready: $reportedVersion"
    Write-Host "TOOL_CACHE=$toolCache"
    Write-Host "PYTHON_EXE=$pythonExe"
    Write-Host "COMPLETE_MARKER=$completeMarker"
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue

    if ($wasRunning) {
        Info "Restarting runner service: $serviceName"
        Start-Service -Name $serviceName
        Start-Sleep -Seconds 2
        $state = (Get-Service -Name $serviceName).Status
        if ($state -ne "Running") {
            Fail "Runner service did not return to Running state: $state"
        }
        Ok "Runner service is Running."
    }
}

Write-Host "WINDOWS_PYTHON_TOOLCACHE_PREWARM_OK" -ForegroundColor Green
