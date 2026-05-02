$ErrorActionPreference = "Stop"

$stopBotScript = Join-Path $PSScriptRoot "stop-bot.ps1"
$stopWatchdogScript = Join-Path $PSScriptRoot "stop-proxy-watchdog.ps1"
$stopProxyScript = Join-Path $PSScriptRoot "stop-proxy.ps1"

if (Test-Path $stopBotScript) {
    & $stopBotScript
}

if (Test-Path $stopWatchdogScript) {
    & $stopWatchdogScript
}

if (Test-Path $stopProxyScript) {
    & $stopProxyScript
}
