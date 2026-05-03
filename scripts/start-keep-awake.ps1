$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$logDir = Join-Path $projectRoot "logs"
New-Item -Path $logDir -ItemType Directory -Force | Out-Null

$pidPath = Join-Path $logDir "keep_awake.pid"
if (Test-Path $pidPath) {
    $existingPidRaw = Get-Content $pidPath -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($existingPidRaw -match '^\d+$') {
        $existing = Get-Process -Id ([int]$existingPidRaw) -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Output "Keep-awake already running with PID=$existingPidRaw"
            exit 0
        }
    }
}

$loopScript = Join-Path $PSScriptRoot "keep-awake-loop.ps1"
if (-not (Test-Path $loopScript)) {
    throw "Cannot find keep-awake loop script: $loopScript"
}

$powershellExe = (Get-Command powershell.exe).Source
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$stdoutLog = Join-Path $logDir "keep_awake_stdout_$timestamp.log"
$stderrLog = Join-Path $logDir "keep_awake_stderr_$timestamp.log"

$args = "-NoProfile -ExecutionPolicy Bypass -File `"$loopScript`""
$proc = Start-Process `
    -FilePath $powershellExe `
    -ArgumentList $args `
    -WorkingDirectory $projectRoot `
    -WindowStyle Hidden `
    -RedirectStandardOutput $stdoutLog `
    -RedirectStandardError $stderrLog `
    -PassThru

Set-Content -Path $pidPath -Value $proc.Id -Encoding ASCII
Write-Output "Keep-awake started. PID=$($proc.Id)"
