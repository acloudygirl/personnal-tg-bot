<#
  功能：代理守护循环。
  作用：确保 rule 模式、自动挑选健康节点，并修正 GLOBAL 指向。
#>

param(
    [int]$IntervalSeconds = 90
)

$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$envPath = Join-Path $projectRoot ".env"

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

function Invoke-ControllerApi {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Method,
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        [string]$ContentType,
        [object]$Body
    )

    $baseParams = @{
        Method = $Method
        Uri = $Uri
    }
    if ($ContentType) { $baseParams.ContentType = $ContentType }
    if ($null -ne $Body) { $baseParams.Body = $Body }

    try {
        return Invoke-RestMethod @baseParams -Headers $headers
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match "\b(400|401|403)\b") {
            return Invoke-RestMethod @baseParams
        }
        throw
    }
}

function Encode-Segment {
    param([string]$Value)
    return [Uri]::EscapeDataString($Value)
}

function Get-ProxyMap {
    $resp = Invoke-ControllerApi -Method Get -Uri "$controller/proxies"
    return $resp.proxies
}

function Get-ProxyItem {
    param(
        [object]$ProxyMap,
        [string]$Name
    )
    return $ProxyMap.PSObject.Properties[$Name].Value
}

function Set-SelectorChoice {
    param(
        [string]$SelectorName,
        [string]$ChoiceName
    )
    $encoded = Encode-Segment $SelectorName
    $body = @{ name = $ChoiceName } | ConvertTo-Json -Compress
    Invoke-ControllerApi `
        -Method Put `
        -Uri "$controller/proxies/$encoded" `
        -ContentType "application/json; charset=utf-8" `
        -Body $body | Out-Null
}

function Trigger-DelayTest {
    param(
        [string]$GroupName
    )
    $encoded = Encode-Segment $GroupName
    $url = "$controller/group/$encoded/delay?url=https%3A%2F%2Fapi.telegram.org&timeout=8000"
    try {
        Invoke-ControllerApi -Method Get -Uri $url | Out-Null
    } catch {
        # Keep loop resilient if one test call fails.
    }
}

function Ensure-RuleMode {
    try {
        $cfg = Invoke-ControllerApi -Method Get -Uri "$controller/configs"
        if ($cfg.mode -ne "rule") {
            $body = @{ mode = "rule" } | ConvertTo-Json -Compress
            Invoke-ControllerApi `
                -Method Patch `
                -Uri "$controller/configs" `
                -ContentType "application/json; charset=utf-8" `
                -Body $body | Out-Null
            Write-Output "$(Get-Date -Format s) switch mode -> rule"
        }
    } catch {
        Write-Output "$(Get-Date -Format s) failed to ensure mode=rule: $($_.Exception.Message)"
    }
}

function Pick-PrimarySelector {
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

function Choose-HealthyTarget {
    param(
        [object]$ProxyMap,
        [object]$Selector
    )

    $options = @($Selector.all)
    if ($options.Count -eq 0) { return $null }

    $auto = $options | Where-Object { $_ -match "自动选择|auto|url[- ]?test" } | Select-Object -First 1
    $fallback = $options | Where-Object { $_ -match "故障转移|fallback" } | Select-Object -First 1

    foreach ($candidate in @($auto, $fallback, $Selector.now)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $item = Get-ProxyItem -ProxyMap $ProxyMap -Name $candidate
        if ($item -and $item.alive) {
            return $candidate
        }
    }

    foreach ($candidate in $options) {
        if ($candidate -in @("DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE")) {
            continue
        }
        $item = Get-ProxyItem -ProxyMap $ProxyMap -Name $candidate
        if ($item -and $item.alive) {
            return $candidate
        }
    }

    return $auto
}

while ($true) {
    try {
        Ensure-RuleMode
        $proxyMap = Get-ProxyMap
        $primarySelectorName = Pick-PrimarySelector -ProxyMap $proxyMap

        if (-not [string]::IsNullOrWhiteSpace($primarySelectorName)) {
            $primarySelector = Get-ProxyItem -ProxyMap $proxyMap -Name $primarySelectorName
            $bestTarget = Choose-HealthyTarget -ProxyMap $proxyMap -Selector $primarySelector

            if (-not [string]::IsNullOrWhiteSpace($bestTarget) -and $primarySelector.now -ne $bestTarget) {
                Set-SelectorChoice -SelectorName $primarySelectorName -ChoiceName $bestTarget
                Write-Output "$(Get-Date -Format s) switch '$primarySelectorName' -> '$bestTarget'"
                $proxyMap = Get-ProxyMap
                $primarySelector = Get-ProxyItem -ProxyMap $proxyMap -Name $primarySelectorName
            }

            $globalSelector = Get-ProxyItem -ProxyMap $proxyMap -Name "GLOBAL"
            if ($globalSelector -and $globalSelector.type -eq "Selector") {
                if ($globalSelector.now -in @("DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE")) {
                    Set-SelectorChoice -SelectorName "GLOBAL" -ChoiceName $primarySelectorName
                    Write-Output "$(Get-Date -Format s) switch 'GLOBAL' -> '$primarySelectorName'"
                }
            }

            foreach ($opt in @($primarySelector.all)) {
                if ($opt -match "自动选择|故障转移|auto|fallback") {
                    Trigger-DelayTest -GroupName $opt
                }
            }
        }
    } catch {
        Write-Output "$(Get-Date -Format s) watchdog error: $($_.Exception.Message)"
    }

    Start-Sleep -Seconds $IntervalSeconds
}

