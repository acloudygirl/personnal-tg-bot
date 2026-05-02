param(
    [string]$TaskName = "CloudyLesbianBot_Autostart"
)

$ErrorActionPreference = "Stop"

$scriptPath = Join-Path $PSScriptRoot "start-stack.ps1"
if (-not (Test-Path $scriptPath)) {
    throw "Cannot find start script: $scriptPath"
}

$powershellExe = (Get-Command powershell.exe).Source
$args = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""

$action = New-ScheduledTaskAction -Execute $powershellExe -Argument $args
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Hours 0)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Description "Start cloudy_lesbian_bot (and dedicated proxy) at user logon" `
    -Force | Out-Null

Write-Output "Scheduled task installed: $TaskName"
Write-Output "Run now: Start-ScheduledTask -TaskName $TaskName"
