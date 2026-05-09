<#
  功能：生成 bot 专用代理配置。
  作用：从 Clash Verge 配置复制并改写端口/控制器/mode/dns 等关键项。
#>

param(
    [int]$MixedPort = 17899,
    [int]$SocksPort = 17891,
    [int]$HttpPort = 17890,
    [int]$ControllerPort = 19097
)

$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$sourceConfig = Join-Path $env:APPDATA "io.github.clash-verge-rev.clash-verge-rev\clash-verge.yaml"
$targetDir = Join-Path $projectRoot "proxy"
$targetConfig = Join-Path $targetDir "bot-proxy.yaml"

if (-not (Test-Path $sourceConfig)) {
    throw "Clash Verge config not found: $sourceConfig"
}

New-Item -Path $targetDir -ItemType Directory -Force | Out-Null
$lines = Get-Content $sourceConfig -Encoding UTF8

$hasMixed = $false
$hasSocks = $false
$hasHttp = $false
$hasController = $false
$hasPipe = $false
$hasAllowLan = $false
$hasMode = $false
$dnsInBlock = $false
$dnsEnableSet = $false

for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]

    if ($line -match '^mixed-port:') {
        $lines[$i] = "mixed-port: $MixedPort"
        $hasMixed = $true
        continue
    }
    if ($line -match '^socks-port:') {
        $lines[$i] = "socks-port: $SocksPort"
        $hasSocks = $true
        continue
    }
    if ($line -match '^port:') {
        $lines[$i] = "port: $HttpPort"
        $hasHttp = $true
        continue
    }
    if ($line -match '^external-controller:') {
        $lines[$i] = "external-controller: 127.0.0.1:$ControllerPort"
        $hasController = $true
        continue
    }
    if ($line -match '^external-controller-pipe:') {
        $lines[$i] = 'external-controller-pipe: \\.\pipe\cloudy-bot-mihomo'
        $hasPipe = $true
        continue
    }
    if ($line -match '^allow-lan:') {
        $lines[$i] = 'allow-lan: false'
        $hasAllowLan = $true
        continue
    }
    if ($line -match '^mode:') {
        $lines[$i] = 'mode: rule'
        $hasMode = $true
        continue
    }

    if ($line -match '^dns:\s*$') {
        $dnsInBlock = $true
        continue
    }

    if ($dnsInBlock -and $line -match '^[A-Za-z0-9_-]+:') {
        $dnsInBlock = $false
    }

    if ($dnsInBlock -and $line -match '^\s{2}enable:') {
        $lines[$i] = '  enable: false'
        $dnsEnableSet = $true
    }
}

$prefix = @()
if (-not $hasHttp) { $prefix += "port: $HttpPort" }
if (-not $hasSocks) { $prefix += "socks-port: $SocksPort" }
if (-not $hasMixed) { $prefix += "mixed-port: $MixedPort" }
if (-not $hasAllowLan) { $prefix += "allow-lan: false" }
if (-not $hasController) { $prefix += "external-controller: 127.0.0.1:$ControllerPort" }
if (-not $hasPipe) { $prefix += 'external-controller-pipe: \\.\pipe\cloudy-bot-mihomo' }
if (-not $hasMode) { $prefix += "mode: rule" }

if (-not $dnsEnableSet) {
    $prefix += "dns:"
    $prefix += "  enable: false"
}

if ($prefix.Count -gt 0) {
    $lines = @($prefix + "" + $lines)
}

Set-Content -Path $targetConfig -Value $lines -Encoding UTF8
Write-Output "Bot proxy config synced to: $targetConfig"

