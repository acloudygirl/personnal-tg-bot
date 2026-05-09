<#
  功能：防休眠保活循环。
  作用：持续调用系统 API 防止系统休眠导致 bot 中断。
#>

$ErrorActionPreference = "Stop"

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class PowerKeepAwake {
    [DllImport("kernel32.dll")]
    public static extern uint SetThreadExecutionState(uint esFlags);
}
"@

$ES_SYSTEM_REQUIRED = [uint32]1
$ES_AWAYMODE_REQUIRED = [uint32]64
$ES_CONTINUOUS = [uint32]2147483648

$flags = $ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED -bor $ES_AWAYMODE_REQUIRED

try {
    while ($true) {
        [PowerKeepAwake]::SetThreadExecutionState($flags) | Out-Null
        Start-Sleep -Seconds 20
    }
} finally {
    [PowerKeepAwake]::SetThreadExecutionState($ES_CONTINUOUS) | Out-Null
}

