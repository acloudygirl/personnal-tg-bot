<#
  功能：停止专用代理进程。
  作用：按 PID 停止代理，并尝试清理残留 verge-mihomo 进程。
#>

$ErrorActionPreference = "Continue"

$projectRoot = Split-Path -Parent $PSScriptRoot
$logDir = Join-Path $projectRoot "logs"
$proxyPidPath = Join-Path (Join-Path $projectRoot "logs") "proxy.pid"

function Stop-ProcessSafe {
    param(
        [int]$ProcessId,
        [string]$Label
    )

    $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $proc) {
        return $true
    }

    try {
        Stop-Process -Id $ProcessId -Force -ErrorAction Stop
        Write-Output "Stopped $Label PID=$ProcessId"
        return $true
    } catch {
        Write-Warning "Failed to stop $Label PID=$($ProcessId): $($_.Exception.Message)"
        return $false
    }
}

function Get-PidFromFile {
    param([string]$PidFilePath)

    if (-not (Test-Path $PidFilePath)) {
        return $null
    }

    $raw = Get-Content $PidFilePath -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($raw -match "^\d+$") {
        return [int]$raw
    }
    return $null
}

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

$pids = New-Object System.Collections.Generic.List[int]
$pidFromFile = Get-PidFromFile -PidFilePath $proxyPidPath
if ($null -ne $pidFromFile) {
    $pids.Add($pidFromFile)
}

foreach ($processId in (Get-ListeningProxyProcessIds)) {
    if (Is-ProxyProcess -ProcessId ([int]$processId)) {
        $pids.Add([int]$processId)
    }
}

$all = @($pids | Sort-Object -Unique)
if ($all.Count -eq 0) {
    Write-Output "Proxy process not found."
} else {
    foreach ($processId in $all) {
        [void](Stop-ProcessSafe -ProcessId $processId -Label "proxy process")
    }
}

Remove-Item $proxyPidPath -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $logDir -Filter "proxy*.pid" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

$leftover = Get-Process -Name "verge-mihomo" -ErrorAction SilentlyContinue
if ($leftover) {
    foreach ($proc in $leftover) {
        [void](Stop-ProcessSafe -ProcessId $proc.Id -Label "leftover verge-mihomo")
    }
}

