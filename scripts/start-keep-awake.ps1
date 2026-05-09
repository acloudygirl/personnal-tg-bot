<#
  功能：后台启动防休眠进程。
  作用：拉起 keep-awake-loop 并写入 PID 文件。
#>

$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$logDir = Join-Path $projectRoot "logs"
New-Item -Path $logDir -ItemType Directory -Force | Out-Null

$loopScript = Join-Path $PSScriptRoot "keep-awake-loop.ps1"
if (-not (Test-Path $loopScript)) {
    throw "Cannot find keep-awake loop script: $loopScript"
}

function Normalize-PathLower {
    param([string]$PathValue)

    try {
        return [System.IO.Path]::GetFullPath($PathValue).ToLowerInvariant()
    } catch {
        return $PathValue.ToLowerInvariant()
    }
}

function Get-LoopProcessIds {
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

function Get-ValidPidFileProcessId {
    param(
        [string]$PidFilePath,
        [string]$ScriptPath
    )

    if (-not (Test-Path $PidFilePath)) {
        return $null
    }

    $pidRaw = Get-Content $PidFilePath -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not ($pidRaw -match "^\d+$")) {
        return $null
    }

    $processId = [int]$pidRaw
    $proc = Get-Process -Id $processId -ErrorAction SilentlyContinue
    if (-not $proc) {
        return $null
    }

    $procInfo = Get-CimInstance Win32_Process -Filter "ProcessId = $processId" -ErrorAction SilentlyContinue
    if (-not $procInfo -or [string]::IsNullOrWhiteSpace($procInfo.CommandLine)) {
        return $null
    }

    $target = Normalize-PathLower -PathValue $ScriptPath
    if ($procInfo.CommandLine.ToLowerInvariant().Contains($target)) {
        return $processId
    }

    return $null
}

$pidPath = Join-Path $logDir "keep_awake.pid"
$runningIds = Get-LoopProcessIds -ScriptPath $loopScript
$pidFileId = Get-ValidPidFileProcessId -PidFilePath $pidPath -ScriptPath $loopScript
if ($null -ne $pidFileId -and ($runningIds -notcontains $pidFileId)) {
    $runningIds = @($runningIds + $pidFileId)
}

if ($runningIds.Count -gt 0) {
    $runningIds = @($runningIds | Sort-Object -Unique)
    $primary = $runningIds[0]
    Set-Content -Path $pidPath -Value $primary -Encoding ASCII
    Write-Output "Keep-awake already running with PID(s): $($runningIds -join ', ')"
    exit 0
}

Remove-Item $pidPath -Force -ErrorAction SilentlyContinue

$powershellExe = (Get-Command powershell.exe).Source
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$stdoutLog = Join-Path $logDir "keep_awake_stdout_$timestamp.log"
$stderrLog = Join-Path $logDir "keep_awake_stderr_$timestamp.log"

$args = "-NoProfile -ExecutionPolicy Bypass -File `"$loopScript`""
$proc = Start-Process `
    -FilePath $powershellExe `
    -ArgumentList $args `
    -WorkingDirectory $projectRoot `
    -WindowStyle Hidden `
    -RedirectStandardOutput $stdoutLog `
    -RedirectStandardError $stderrLog `
    -PassThru

Set-Content -Path $pidPath -Value $proc.Id -Encoding ASCII
Write-Output "Keep-awake started. PID=$($proc.Id)"

