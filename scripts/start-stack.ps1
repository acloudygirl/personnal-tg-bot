$ErrorActionPreference = "Stop"

$syncProxyConfigScript = Join-Path $PSScriptRoot "sync-bot-proxy-config.ps1"
$startProxyScript = Join-Path $PSScriptRoot "start-proxy-hidden.ps1"
$startWatchdogScript = Join-Path $PSScriptRoot "start-proxy-watchdog.ps1"
$startBotScript = Join-Path $PSScriptRoot "start-bot-hidden.ps1"

if (Test-Path $syncProxyConfigScript) {
    & $syncProxyConfigScript
}

if (Test-Path $startProxyScript) {
    & $startProxyScript
}

if (Test-Path $startWatchdogScript) {
    & $startWatchdogScript
}

if (-not (Test-Path $startBotScript)) {
    throw "Cannot find bot start script: $startBotScript"
}

& $startBotScript
