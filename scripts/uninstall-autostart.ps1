<#
  功能：卸载开机（登录）自启动任务。
  作用：删除已注册的计划任务，取消自动拉起。
#>

param(
    [string]$TaskName = "CloudyLesbianBot_Autostart"
)

$ErrorActionPreference = "Stop"

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $task) {
    Write-Output "Task not found: $TaskName"
    exit 0
}

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
Write-Output "Scheduled task removed: $TaskName"

