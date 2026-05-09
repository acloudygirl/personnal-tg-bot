<#
  功能：后台启动机器人主程序。
  作用：加载 .env、检查代理端点、必要时构建并隐藏启动，写入日志与 PID。
#>

$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $projectRoot

# Avoid duplicate bot instances.
$running = Get-Process -Name "cloudy_lesbian_bot" -ErrorAction SilentlyContinue
if ($running) {
    Write-Output "Bot already running with PID(s): $($running.Id -join ', ')"
    exit 0
}

# Load .env into current process environment.
$envPath = Join-Path $projectRoot ".env"
if (Test-Path $envPath) {
    Get-Content $envPath | ForEach-Object {
        $line = $_.Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) {
            return
        }

        $parts = $line -split "=", 2
        if ($parts.Count -eq 2) {
            $key = $parts[0].Trim()
            $value = $parts[1].Trim()
            if ($key) {
                [Environment]::SetEnvironmentVariable($key, $value, "Process")
            }
        }
    }
}

function Wait-TcpEndpoint {
    param(
        [string]$HostName,
        [int]$Port,
        [int]$TimeoutSeconds = 20
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $task = $client.ConnectAsync($HostName, $Port)
            if ($task.Wait(1000) -and $client.Connected) {
                return $true
            }
        } catch {
            # Ignore and retry until timeout.
        } finally {
            $client.Dispose()
        }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

$proxyRaw = [Environment]::GetEnvironmentVariable("TELOXIDE_PROXY", "Process")
if (-not [string]::IsNullOrWhiteSpace($proxyRaw)) {
    $proxyUri = $null
    try {
        $proxyUri = [System.Uri]$proxyRaw
    } catch {
        Write-Output "Warning: TELOXIDE_PROXY is not a valid URI: $proxyRaw"
    }

    if ($proxyUri -and $proxyUri.Host -and $proxyUri.Port -gt 0) {
        Write-Output "Waiting for proxy endpoint $($proxyUri.Host):$($proxyUri.Port) ..."
        if (-not (Wait-TcpEndpoint -HostName $proxyUri.Host -Port $proxyUri.Port -TimeoutSeconds 25)) {
            Write-Output "Warning: proxy endpoint not reachable yet, bot may retry network calls."
        }
    }
}

$exePath = Join-Path $projectRoot "target\\debug\\cloudy_lesbian_bot.exe"
$manifestPath = Join-Path $projectRoot "Cargo.toml"
$sourcePaths = @(
    (Join-Path $projectRoot "src\\main.rs"),
    $manifestPath
)

$needsBuild = (-not (Test-Path $exePath))
if (-not $needsBuild) {
    $exeTime = (Get-Item $exePath).LastWriteTimeUtc
    foreach ($src in $sourcePaths) {
        if (Test-Path $src) {
            if ((Get-Item $src).LastWriteTimeUtc -gt $exeTime) {
                $needsBuild = $true
                break
            }
        }
    }
}

if ($needsBuild) {
    Write-Output "Bot executable missing/outdated, building..."
    cargo build | Out-Null
}

$logDir = Join-Path $projectRoot "logs"
New-Item -Path $logDir -ItemType Directory -Force | Out-Null

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$stdoutLog = Join-Path $logDir "bot_stdout_$timestamp.log"
$stderrLog = Join-Path $logDir "bot_stderr_$timestamp.log"
$pidPath = Join-Path $logDir "bot.pid"

$process = Start-Process `
    -FilePath $exePath `
    -WorkingDirectory $projectRoot `
    -WindowStyle Hidden `
    -RedirectStandardOutput $stdoutLog `
    -RedirectStandardError $stderrLog `
    -PassThru

Set-Content -Path $pidPath -Value $process.Id -Encoding ASCII
Write-Output "Bot started. PID=$($process.Id)"
Write-Output "STDOUT log: $stdoutLog"
Write-Output "STDERR log: $stderrLog"

