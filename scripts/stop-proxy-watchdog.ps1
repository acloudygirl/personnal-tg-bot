<#
  功能：停止代理守护进程。
  作用：按 PID 结束 proxy-watchdog-loop 并清理 PID 文件。
#>

$ErrorActionPreference = "Continue"

$projectRoot = Split-Path -Parent $PSScriptRoot
$logDir = Join-Path $projectRoot "logs"
$pidPath = Join-Path (Join-Path $projectRoot "logs") "proxy_watchdog.pid"
$loopScript = Join-Path $PSScriptRoot "proxy-watchdog-loop.ps1"

function Normalize-PathLower {
    param([string]$PathValue)

    try {
        return [System.IO.Path]::GetFullPath($PathValue).ToLowerInvariant()
    } catch {
        return $PathValue.ToLowerInvariant()
    }
}

function Get-WatchdogProcessIds {
    param([string]$ScriptPath)

    $target = Normalize-PathLower -PathValue $ScriptPath
    if ([string]::IsNullOrWhiteSpace($target)) {
        return @()
    }

    $matched = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match "^(powershell|pwsh)(\.exe)?$" -and
        -not [string]::IsNullOrWhiteSpace($_.CommandLine) -and
        $_.CommandLine.ToLowerInvariant().Contains($target)
    } | Select-Object -ExpandProperty ProcessId

    if ($null -eq $matched) {
        return @()
    }

    return @($matched)
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

function Stop-ProcessSafe {
    param([int]$ProcessId)

    $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $proc) {
        return $true
    }

    try {
        Stop-Process -Id $ProcessId -Force -ErrorAction Stop
        Write-Output "Stopped proxy watchdog PID=$ProcessId"
        return $true
    } catch {
        Write-Warning "Failed to stop proxy watchdog PID=$($ProcessId): $($_.Exception.Message)"
        return $false
    }
}

$pids = New-Object System.Collections.Generic.List[int]
$pidFromFile = Get-PidFromFile -PidFilePath $pidPath
if ($null -ne $pidFromFile) {
    $pids.Add($pidFromFile)
}
foreach ($processId in (Get-WatchdogProcessIds -ScriptPath $loopScript)) {
    $pids.Add([int]$processId)
}

$all = @($pids | Sort-Object -Unique)
if ($all.Count -eq 0) {
    Write-Output "Proxy watchdog is not running."
} else {
    foreach ($processId in $all) {
        [void](Stop-ProcessSafe -ProcessId $processId)
    }
}

Remove-Item $pidPath -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $logDir -Filter "proxy_watchdog*.pid" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

