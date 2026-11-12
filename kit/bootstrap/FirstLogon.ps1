#Requires -Version 5.1
<#
    DayZero - first sign-in (called by FirstLogon.cmd).

    Registers the scheduled task \DayZero\DayZero, which starts the wizard elevated at
    every sign-in of this account until the wizard finishes (the wizard removes the task
    at the end), then starts the wizard right away.

    FirstLogonCommands run elevated for administrator accounts, so no UAC prompt appears,
    and the task's "run with highest privileges" setting keeps it that way after reboots.
#>
[CmdletBinding()]
param([string]$BuildId = '')

$ErrorActionPreference = 'Stop'
$kit = Join-Path $env:SystemDrive 'DayZero'
$logDir = Join-Path $kit 'Logs'
if (-not (Test-Path -LiteralPath $logDir)) { [void](New-Item -ItemType Directory -Path $logDir -Force) }
$logFile = Join-Path $logDir 'firstlogon.log'

function Write-FirstLogonLog {
    param([Parameter(Mandatory = $true)][string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
}

try {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principalCheck = New-Object System.Security.Principal.WindowsPrincipal($identity)
    $isAdmin = $principalCheck.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    Write-FirstLogonLog ("First sign-in of {0}. Build {1}. Elevated: {2}" -f $identity.Name, $BuildId, $isAdmin)
    if (-not $isAdmin) { throw 'Not running elevated, so the DayZero task cannot be registered.' }

    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $wizard = Join-Path $kit 'DayZero.ps1'
    $taskArgs = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}" -Resume' -f $wizard

    $action = New-ScheduledTaskAction -Execute $powershell -Argument $taskArgs -WorkingDirectory $kit
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity.Name
    $principal = New-ScheduledTaskPrincipal -UserId $identity.Name -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    $description = 'Starts the DayZero setup wizard at sign-in until setup has finished. The wizard deletes this task when it is done.'
    [void](Register-ScheduledTask -TaskName 'DayZero' -TaskPath '\DayZero\' -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings -Description $description -Force)
    Write-FirstLogonLog 'Registered scheduled task \DayZero\DayZero.'

    Start-ScheduledTask -TaskName 'DayZero' -TaskPath '\DayZero\'
    Write-FirstLogonLog 'Started the DayZero wizard.'
    exit 0
}
catch {
    Write-FirstLogonLog ('ERROR: ' + $_.Exception.Message)
    # Do not leave the user with nothing: try to start the wizard directly.
    try {
        Start-Process -FilePath (Join-Path $kit 'DayZero.cmd') -ArgumentList '-Resume'
        Write-FirstLogonLog 'Started DayZero.cmd directly instead.'
    }
    catch {
        Write-FirstLogonLog ('Could not start the wizard either: ' + $_.Exception.Message)
    }
    exit 1
}
