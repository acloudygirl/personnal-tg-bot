$ErrorActionPreference = "Stop"

$stopBotScript = Join-Path $PSScriptRoot "stop-bot.ps1"
$stopBotWatchdogScript = Join-Path $PSScriptRoot "stop-bot-watchdog.ps1"
$stopKeepAwakeScript = Join-Path $PSScriptRoot "stop-keep-awake.ps1"
$stopWatchdogScript = Join-Path $PSScriptRoot "stop-proxy-watchdog.ps1"
$stopProxyScript = Join-Path $PSScriptRoot "stop-proxy.ps1"

if (Test-Path $stopBotScript) {
    & $stopBotScript
}

if (Test-Path $stopBotWatchdogScript) {
    & $stopBotWatchdogScript
}

if (Test-Path $stopKeepAwakeScript) {
    & $stopKeepAwakeScript
}

if (Test-Path $stopWatchdogScript) {
    & $stopWatchdogScript
}

if (Test-Path $stopProxyScript) {
    & $stopProxyScript
}
