<#
  功能：一键启动整套运行栈。
  作用：依次同步代理配置、启动防休眠、代理、守护与 bot。
#>

$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$logsDir = Join-Path $projectRoot "logs"
$markerPath = Join-Path $logsDir "stack_start_in_progress.lock"

New-Item -Path $logsDir -ItemType Directory -Force | Out-Null
if (Test-Path $markerPath) {
    Write-Output "Start stack already in progress. Skip duplicate invocation."
    exit 0
}
Set-Content -Path $markerPath -Value "$PID" -Encoding ASCII

try {
$syncProxyConfigScript = Join-Path $PSScriptRoot "sync-bot-proxy-config.ps1"
$startKeepAwakeScript = Join-Path $PSScriptRoot "start-keep-awake.ps1"
$startProxyScript = Join-Path $PSScriptRoot "start-proxy-hidden.ps1"
$startWatchdogScript = Join-Path $PSScriptRoot "start-proxy-watchdog.ps1"
$startBotWatchdogScript = Join-Path $PSScriptRoot "start-bot-watchdog.ps1"
$startBotScript = Join-Path $PSScriptRoot "start-bot-hidden.ps1"

if (Test-Path $syncProxyConfigScript) {
    & $syncProxyConfigScript
}

if (Test-Path $startKeepAwakeScript) {
    & $startKeepAwakeScript
}

if (Test-Path $startProxyScript) {
    & $startProxyScript
}

if (Test-Path $startWatchdogScript) {
    & $startWatchdogScript
}

if (Test-Path $startBotWatchdogScript) {
    & $startBotWatchdogScript
}

if (-not (Test-Path $startBotScript)) {
    throw "Cannot find bot start script: $startBotScript"
}

# 给 watchdog 一点时间确认 bot 状态，避免并发触发二次启动。
Start-Sleep -Seconds 2
& $startBotScript
}
finally {
    Remove-Item -Path $markerPath -Force -ErrorAction SilentlyContinue
}

