<#
  功能：后台启动专用代理。
  作用：从 .env 读取代理程序路径与参数，启动后记录日志与 PID。
#>

$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $projectRoot

function Load-DotEnv {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return
    }

    Get-Content $Path | ForEach-Object {
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

Load-DotEnv -Path (Join-Path $projectRoot ".env")

$proxyExe = [Environment]::GetEnvironmentVariable("BOT_PROXY_EXE", "Process")
if ([string]::IsNullOrWhiteSpace($proxyExe)) {
    Write-Output "Skip proxy start: BOT_PROXY_EXE not configured in .env"
    exit 0
}

$proxyArgs = [Environment]::GetEnvironmentVariable("BOT_PROXY_ARGS", "Process")
$proxyWorkdir = [Environment]::GetEnvironmentVariable("BOT_PROXY_WORKDIR", "Process")
if ([string]::IsNullOrWhiteSpace($proxyWorkdir)) {
    $proxyWorkdir = Split-Path -Parent $proxyExe
}

if (-not (Test-Path $proxyExe)) {
    throw "BOT_PROXY_EXE does not exist: $proxyExe"
}

$proxyPidPath = Join-Path (Join-Path $projectRoot "logs") "proxy.pid"

function Get-ListeningProxyProcessIds {
    $pids = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalPort -in @(17890, 17891, 17899) } |
        Select-Object -ExpandProperty OwningProcess -Unique

    if ($null -eq $pids) {
        return @()
    }

    return @($pids)
}

function Is-ProxyProcess {
    param([int]$ProcessId)

    $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $proc) {
        return $false
    }

    if ($proc.ProcessName -eq "verge-mihomo") {
        return $true
    }

    try {
        $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction SilentlyContinue).CommandLine
        if (-not [string]::IsNullOrWhiteSpace($cmd) -and $cmd.ToLowerInvariant().Contains("verge-mihomo")) {
            return $true
        }
    } catch {
        # Ignore command line lookup failure.
    }

    return $false
}

if (Test-Path $proxyPidPath) {
    $existingPidRaw = Get-Content $proxyPidPath -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($existingPidRaw -match '^\d+$') {
        $existingProc = Get-Process -Id ([int]$existingPidRaw) -ErrorAction SilentlyContinue
        if ($existingProc) {
            $proxyPortOpen = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
                Where-Object { $_.OwningProcess -eq $existingProc.Id -and $_.LocalPort -in @(17890, 17891, 17899) } |
                Select-Object -First 1
            if ($proxyPortOpen) {
                Write-Output "Proxy already running with PID=$existingPidRaw"
                exit 0
            }
        }
    }
    Remove-Item $proxyPidPath -Force -ErrorAction SilentlyContinue
}

$listeningPids = Get-ListeningProxyProcessIds
foreach ($processId in $listeningPids) {
    if (Is-ProxyProcess -ProcessId ([int]$processId)) {
        Set-Content -Path $proxyPidPath -Value ([int]$processId) -Encoding ASCII
        Write-Output "Proxy already running with PID=$processId"
        exit 0
    }
}

$logDir = Join-Path $projectRoot "logs"
New-Item -Path $logDir -ItemType Directory -Force | Out-Null

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$stdoutLog = Join-Path $logDir "proxy_stdout_$timestamp.log"
$stderrLog = Join-Path $logDir "proxy_stderr_$timestamp.log"

$process = Start-Process `
    -FilePath $proxyExe `
    -ArgumentList $proxyArgs `
    -WorkingDirectory $proxyWorkdir `
    -WindowStyle Hidden `
    -RedirectStandardOutput $stdoutLog `
    -RedirectStandardError $stderrLog `
    -PassThru

Set-Content -Path $proxyPidPath -Value $process.Id -Encoding ASCII
Write-Output "Proxy started. PID=$($process.Id)"
Write-Output "Proxy STDOUT log: $stdoutLog"
Write-Output "Proxy STDERR log: $stderrLog"

