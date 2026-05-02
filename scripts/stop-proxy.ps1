$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$proxyPidPath = Join-Path (Join-Path $projectRoot "logs") "proxy.pid"

if (-not (Test-Path $proxyPidPath)) {
    Write-Output "Proxy pid file not found, proxy may already be stopped."
    exit 0
}

$pidRaw = Get-Content $proxyPidPath -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not ($pidRaw -match '^\d+$')) {
    Remove-Item $proxyPidPath -Force -ErrorAction SilentlyContinue
    Write-Output "Invalid proxy pid file removed."
    exit 0
}

$proc = Get-Process -Id ([int]$pidRaw) -ErrorAction SilentlyContinue
if (-not $proc) {
    Remove-Item $proxyPidPath -Force -ErrorAction SilentlyContinue
    Write-Output "Proxy process not found."
    exit 0
}

$proc | Stop-Process -Force
Remove-Item $proxyPidPath -Force -ErrorAction SilentlyContinue
Write-Output "Stopped proxy process PID=$pidRaw"
