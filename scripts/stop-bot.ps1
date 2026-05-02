$ErrorActionPreference = "Stop"

$processes = Get-Process -Name "cloudy_lesbian_bot" -ErrorAction SilentlyContinue
if (-not $processes) {
    Write-Output "Bot is not running."
    $projectRoot = Split-Path -Parent $PSScriptRoot
    $pidPath = Join-Path (Join-Path $projectRoot "logs") "bot.pid"
    Remove-Item $pidPath -Force -ErrorAction SilentlyContinue
    exit 0
}

$processes | Stop-Process -Force
Write-Output "Stopped bot process PID(s): $($processes.Id -join ', ')"

$projectRoot = Split-Path -Parent $PSScriptRoot
$pidPath = Join-Path (Join-Path $projectRoot "logs") "bot.pid"
Remove-Item $pidPath -Force -ErrorAction SilentlyContinue
