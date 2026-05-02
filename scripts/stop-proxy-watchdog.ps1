$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$pidPath = Join-Path (Join-Path $projectRoot "logs") "proxy_watchdog.pid"

if (-not (Test-Path $pidPath)) {
    Write-Output "Proxy watchdog is not running."
    exit 0
}

$pidRaw = Get-Content $pidPath -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not ($pidRaw -match '^\d+$')) {
    Remove-Item $pidPath -Force -ErrorAction SilentlyContinue
    Write-Output "Invalid watchdog pid file removed."
    exit 0
}

$proc = Get-Process -Id ([int]$pidRaw) -ErrorAction SilentlyContinue
if ($proc) {
    $proc | Stop-Process -Force
    Write-Output "Stopped proxy watchdog PID=$pidRaw"
} else {
    Write-Output "Proxy watchdog process not found."
}

Remove-Item $pidPath -Force -ErrorAction SilentlyContinue
