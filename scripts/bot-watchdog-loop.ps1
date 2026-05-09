<#
  功能：机器人健康守护循环。
  作用：定时检测 Telegram 连通性；连续失败达到阈值后自动重启 bot。
#>

param(
    [int]$IntervalSeconds = 45,
    [int]$FailureThreshold = 8,
    [int]$RestartCooldownSeconds = 600
)

$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$startBotScript = Join-Path $PSScriptRoot "start-bot-hidden.ps1"
$stopBotScript = Join-Path $PSScriptRoot "stop-bot.ps1"
$envPath = Join-Path $projectRoot ".env"

function Load-DotEnv {
    param([string]$Path)

    if (-not (Test-Path $Path)) { return }

    Get-Content $Path | ForEach-Object {
        $line = $_.Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) { return }
        $parts = $line -split "=", 2
        if ($parts.Count -eq 2) {
            [Environment]::SetEnvironmentVariable($parts[0].Trim(), $parts[1].Trim(), "Process")
        }
    }
}

function Test-TcpEndpoint {
    param(
        [string]$HostName,
        [int]$Port,
        [int]$TimeoutMs = 2000
    )

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($HostName, $Port)
        return ($task.Wait($TimeoutMs) -and $client.Connected)
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

function Test-TelegramViaProxy {
    $token = [Environment]::GetEnvironmentVariable("TELOXIDE_TOKEN", "Process")
    $proxy = [Environment]::GetEnvironmentVariable("TELOXIDE_PROXY", "Process")
    if ([string]::IsNullOrWhiteSpace($token) -or [string]::IsNullOrWhiteSpace($proxy)) {
        return $false
    }

    try {
        $proxyUri = [Uri]$proxy
    } catch {
        return $false
    }

    if (-not (Test-TcpEndpoint -HostName $proxyUri.Host -Port $proxyUri.Port)) {
        return $false
    }

    $url = "https://api.telegram.org/bot$token/getMe"
    $args = @("--silent", "--show-error", "--max-time", "15", "--ssl-no-revoke")

    if ($proxyUri.Scheme -like "socks5*") {
        $args += @("--socks5-hostname", "$($proxyUri.Host):$($proxyUri.Port)")
    } else {
        $args += @("--proxy", $proxy)
    }
    $args += $url

    $output = & curl.exe @args 2>$null
    $ok = ($LASTEXITCODE -eq 0 -and $output -match '"ok"\s*:\s*true')
    return $ok
}

$failCount = 0
$lastRestartAt = [datetime]::MinValue

while ($true) {
    try {
        Load-DotEnv -Path $envPath

        $bot = Get-Process -Name "cloudy_lesbian_bot" -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $bot) {
            if (Test-Path $startBotScript) {
                & $startBotScript | Out-Null
                Write-Output "$(Get-Date -Format s) bot missing -> started"
            }
            $failCount = 0
            Start-Sleep -Seconds $IntervalSeconds
            continue
        }

        if (Test-TelegramViaProxy) {
            $failCount = 0
        } else {
            $failCount += 1
            Write-Output "$(Get-Date -Format s) health check failed ($failCount/$FailureThreshold)"
        }

        if ($failCount -ge $FailureThreshold) {
            $elapsed = ((Get-Date) - $lastRestartAt).TotalSeconds
            if ($elapsed -ge $RestartCooldownSeconds) {
                $botCheck = Get-Process -Name "cloudy_lesbian_bot" -ErrorAction SilentlyContinue | Select-Object -First 1
                if (-not $botCheck) {
                    if (Test-Path $startBotScript) { & $startBotScript | Out-Null }
                    $lastRestartAt = Get-Date
                    $failCount = 0
                    Write-Output "$(Get-Date -Format s) bot was missing and started by watchdog"
                } else {
                    # 网络波动时不强制重启，避免触发 TerminatedByOtherGetUpdates。
                    $failCount = [Math]::Min($FailureThreshold - 1, $failCount)
                }
            }
        }
    } catch {
        Write-Output "$(Get-Date -Format s) bot watchdog error: $($_.Exception.Message)"
    }

    Start-Sleep -Seconds $IntervalSeconds
}

