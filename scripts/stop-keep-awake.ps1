<#
  功能：停止防休眠进程。
  作用：按 PID 结束 keep-awake-loop 并清理 PID 文件。
#>

$ErrorActionPreference = "Continue"

$projectRoot = Split-Path -Parent $PSScriptRoot
$logDir = Join-Path $projectRoot "logs"
$pidPath = Join-Path $logDir "keep_awake.pid"
$loopScript = Join-Path $PSScriptRoot "keep-awake-loop.ps1"

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
        Write-Output "Stopped keep-awake PID=$ProcessId"
        return $true
    } catch {
        Write-Warning "Failed to stop keep-awake PID=$($ProcessId): $($_.Exception.Message)"
        return $false
    }
}

$pids = New-Object System.Collections.Generic.List[int]
$pidFromFile = Get-PidFromFile -PidFilePath $pidPath
if ($null -ne $pidFromFile) {
    $pids.Add($pidFromFile)
}
foreach ($processId in (Get-LoopProcessIds -ScriptPath $loopScript)) {
    $pids.Add([int]$processId)
}

$all = @($pids | Sort-Object -Unique)
if ($all.Count -eq 0) {
    Write-Output "Keep-awake is not running."
} else {
    foreach ($processId in $all) {
        [void](Stop-ProcessSafe -ProcessId $processId)
    }
}

Remove-Item $pidPath -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $logDir -Filter "keep_awake*.pid" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

