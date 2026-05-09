<#
  功能：一键停止整套运行栈。
  作用：依次停止 bot、守护、防休眠和代理相关进程。
#>

$ErrorActionPreference = "Continue"

$stopBotScript = Join-Path $PSScriptRoot "stop-bot.ps1"
$stopBotWatchdogScript = Join-Path $PSScriptRoot "stop-bot-watchdog.ps1"
$stopKeepAwakeScript = Join-Path $PSScriptRoot "stop-keep-awake.ps1"
$stopWatchdogScript = Join-Path $PSScriptRoot "stop-proxy-watchdog.ps1"
$stopProxyScript = Join-Path $PSScriptRoot "stop-proxy.ps1"
$projectRoot = Split-Path -Parent $PSScriptRoot
$logsDir = Join-Path $projectRoot "logs"

function Invoke-StopScript {
    param([string]$ScriptPath)

    if (-not (Test-Path $ScriptPath)) {
        return
    }

    try {
        & $ScriptPath
    } catch {
        Write-Warning "Stop script failed: $ScriptPath -> $($_.Exception.Message)"
    }
}

function Remove-PidFileSafe {
    param([string]$Path)

    try {
        Remove-Item -Path $Path -Force -ErrorAction Stop
    } catch {
        # Keep stop-stack resilient.
    }
}

Invoke-StopScript -ScriptPath $stopBotWatchdogScript
Invoke-StopScript -ScriptPath $stopWatchdogScript
Invoke-StopScript -ScriptPath $stopKeepAwakeScript
Invoke-StopScript -ScriptPath $stopBotScript
Invoke-StopScript -ScriptPath $stopProxyScript

if (Test-Path $logsDir) {
    @(
        "bot.pid",
        "bot_watchdog.pid",
        "proxy.pid",
        "proxy_watchdog.pid",
        "keep_awake.pid"
    ) | ForEach-Object {
        Remove-PidFileSafe -Path (Join-Path $logsDir $_)
    }
}
