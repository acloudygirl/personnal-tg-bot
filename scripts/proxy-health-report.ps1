<#
  功能：代理健康报告。
  作用：读取 mihomo 控制面数据并输出节点可用率、延迟与切换统计。
#>

param(
    [int]$Hours = 1,
    [int]$Top = 8
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$projectRoot = Split-Path -Parent $PSScriptRoot
$envPath = Join-Path $projectRoot ".env"
$logDir = Join-Path $projectRoot "logs"

if (Test-Path $envPath) {
    Get-Content $envPath | ForEach-Object {
        $line = $_.Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) {
            return
        }
        $parts = $line -split "=", 2
        if ($parts.Count -eq 2) {
            [Environment]::SetEnvironmentVariable($parts[0].Trim(), $parts[1].Trim(), "Process")
        }
    }
}

$controller = [Environment]::GetEnvironmentVariable("BOT_PROXY_CONTROLLER", "Process")
if ([string]::IsNullOrWhiteSpace($controller)) {
    $controller = "http://127.0.0.1:19097"
}
$secret = [Environment]::GetEnvironmentVariable("BOT_PROXY_SECRET", "Process")
if ([string]::IsNullOrWhiteSpace($secret)) {
    $secret = "set-your-secret"
}

$headers = @{ Authorization = "Bearer $secret" }

function Get-ProxyItem {
    param(
        [object]$ProxyMap,
        [string]$Name
    )
    return $ProxyMap.PSObject.Properties[$Name].Value
}

function Get-LatestDelay {
    param([object]$Proxy)

    if (-not $Proxy) { return $null }
    if (-not $Proxy.history) { return $null }
    $history = @($Proxy.history)
    if ($history.Count -eq 0) { return $null }
    $last = $history[-1]
    if ($null -eq $last.delay) { return $null }
    if ($last.delay -le 0) { return $null }
    return [int]$last.delay
}

function Pick-PrimarySelectorName {
    param([object]$ProxyMap)

    $preferred = [Environment]::GetEnvironmentVariable("BOT_PROXY_PRIMARY_GROUP", "Process")
    if (-not [string]::IsNullOrWhiteSpace($preferred)) {
        $item = Get-ProxyItem -ProxyMap $ProxyMap -Name $preferred
        if ($item -and $item.type -eq "Selector") {
            return $preferred
        }
    }

    $selectorNames = $ProxyMap.PSObject.Properties |
        Where-Object { $_.Value.type -eq "Selector" } |
        ForEach-Object { $_.Name }

    foreach ($name in $selectorNames) {
        if ($name -notin @("GLOBAL", "DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE")) {
            return $name
        }
    }

    return $null
}

$configs = Invoke-RestMethod -Method Get -Uri "$controller/configs" -Headers $headers
$proxyMap = (Invoke-RestMethod -Method Get -Uri "$controller/proxies" -Headers $headers).proxies

$global = Get-ProxyItem -ProxyMap $proxyMap -Name "GLOBAL"
$primaryName = Pick-PrimarySelectorName -ProxyMap $proxyMap
$primary = $null
if (-not [string]::IsNullOrWhiteSpace($primaryName)) {
    $primary = Get-ProxyItem -ProxyMap $proxyMap -Name $primaryName
}

$nodeRows = @()
if ($primary -and $primary.all) {
    foreach ($name in @($primary.all)) {
        if ($name -in @("DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE")) { continue }
        $item = Get-ProxyItem -ProxyMap $proxyMap -Name $name
        if (-not $item) { continue }
        if ($item.type -in @("Selector", "URLTest", "Fallback")) { continue }
        $nodeRows += [pscustomobject]@{
            Name = $name
            Alive = [bool]$item.alive
            Delay = Get-LatestDelay -Proxy $item
        }
    }
}

$aliveCount = ($nodeRows | Where-Object { $_.Alive }).Count
$topRows = $nodeRows |
    Where-Object { $_.Alive -and $null -ne $_.Delay } |
    Sort-Object Delay, Name |
    Select-Object -First $Top

$windowStart = (Get-Date).AddHours(-1 * [Math]::Abs($Hours))
$switchEvents = @()
if (Test-Path $logDir) {
    $watchdogLogs = Get-ChildItem -Path $logDir -Filter "proxy_watchdog_stdout_*.log" -ErrorAction SilentlyContinue
    foreach ($file in $watchdogLogs) {
        $switchEvents += Select-String -Path $file.FullName -Pattern "switch '" -ErrorAction SilentlyContinue |
            Where-Object { $_.Line -match '^\d{4}-\d{2}-\d{2}T' } |
            ForEach-Object {
                $tsRaw = $_.Line.Substring(0, 19)
                $ts = [datetime]::ParseExact($tsRaw, "yyyy-MM-ddTHH:mm:ss", $null)
                [pscustomobject]@{ Time = $ts; Line = $_.Line }
            }
    }
}
$switchRecent = $switchEvents | Where-Object { $_.Time -ge $windowStart }

Write-Output "Proxy Health Report"
Write-Output "Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Output "Controller: $controller"
Write-Output "Mode: $($configs.mode)"
Write-Output "GLOBAL now: $($global.now)"
if ($primaryName) {
    Write-Output "Primary selector: $primaryName (now: $($primary.now))"
}
Write-Output "Alive nodes in primary selector: $aliveCount / $($nodeRows.Count)"
Write-Output "Switch events in last $Hours hour(s): $($switchRecent.Count)"

if ($topRows.Count -gt 0) {
    Write-Output ""
    Write-Output "Top healthy nodes (lower delay is better):"
    foreach ($row in $topRows) {
        Write-Output ("- {0} | {1}ms" -f $row.Name, $row.Delay)
    }
} else {
    Write-Output ""
    Write-Output "No healthy node delay data yet."
}

