<#
  功能：停止 bot 主进程。
  作用：结束所有 cloudy_lesbian_bot 进程并清理 PID 文件。
#>

$ErrorActionPreference = "Continue"

function Stop-ProcessSafe {
    param([int]$ProcessId)

    $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $proc) {
        return $true
    }

    try {
        Stop-Process -Id $ProcessId -Force -ErrorAction Stop
        Write-Output "Stopped bot process PID=$ProcessId"
        return $true
    } catch {
        Write-Warning "Failed to stop bot process PID=$($ProcessId): $($_.Exception.Message)"
        return $false
    }
}

$processes = Get-Process -Name "cloudy_lesbian_bot" -ErrorAction SilentlyContinue
if (-not $processes) {
    Write-Output "Bot is not running."
    $projectRoot = Split-Path -Parent $PSScriptRoot
    $pidPath = Join-Path (Join-Path $projectRoot "logs") "bot.pid"
    Remove-Item $pidPath -Force -ErrorAction SilentlyContinue
    exit 0
} else {
    foreach ($proc in $processes) {
        [void](Stop-ProcessSafe -ProcessId $proc.Id)
    }
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$pidPath = Join-Path (Join-Path $projectRoot "logs") "bot.pid"
Remove-Item $pidPath -Force -ErrorAction SilentlyContinue

