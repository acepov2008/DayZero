#Requires -Version 5.1
<#
    DayZero - end-of-setup cleanup. Undoes the temporary things the answer file and the
    first sign-in set up so the wizard could run unattended:

      * the \DayZero\DayZero scheduled task that restarts the wizard at sign-in
      * automatic sign-in, including the plain-text password Windows keeps for it in
        HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon (DefaultPassword)
      * cached copies of the answer file in C:\Windows\Panther (they contain the
        base64-encoded password)
      * optionally marks the password as "must change at next sign-in"

    Every change goes through Invoke-DzAction, so dry-run mode only logs it.
#>

Set-StrictMode -Version 2.0

$script:WinlogonKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'

function Unregister-DzResumeTask {
    [CmdletBinding()]
    param()
    $task = Get-ScheduledTask -TaskName 'DayZero' -TaskPath '\DayZero\' -ErrorAction SilentlyContinue
    if ($null -eq $task) { Write-DzLog 'Auto-start task is already gone.'; return }
    Invoke-DzAction -Description 'Remove the DayZero auto-start task' -Action {
        Unregister-ScheduledTask -TaskName 'DayZero' -TaskPath '\DayZero\' -Confirm:$false
    } | Out-Null
}

function Disable-DzAutoLogon {
    [CmdletBinding()]
    param()
    Invoke-DzAction -Description 'Turn off automatic sign-in and delete the stored sign-in password' -Action {
        Set-ItemProperty -LiteralPath $script:WinlogonKey -Name 'AutoAdminLogon' -Value '0'
        foreach ($name in @('DefaultPassword', 'AutoLogonCount')) {
            if (Get-ItemProperty -LiteralPath $script:WinlogonKey -Name $name -ErrorAction SilentlyContinue) {
                Remove-ItemProperty -LiteralPath $script:WinlogonKey -Name $name -Force
            }
        }
    } | Out-Null
}

function Remove-DzCachedAnswerFile {
    [CmdletBinding()]
    param()
    $candidates = @(
        (Join-Path $env:SystemRoot 'Panther\unattend.xml'),
        (Join-Path $env:SystemRoot 'Panther\Unattend\unattend.xml'),
        (Join-Path $env:SystemRoot 'Panther\autounattend.xml'),
        (Join-Path $env:SystemRoot 'System32\Sysprep\unattend.xml')
    )
    foreach ($file in $candidates) {
        if (Test-Path -LiteralPath $file) {
            Invoke-DzAction -Description "Delete cached answer file $file (it holds the encoded password)" -Action {
                Remove-Item -LiteralPath $file -Force
            }.GetNewClosure() | Out-Null
        }
    }
}

function Set-DzPasswordChangeRequired {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$UserName)
    Invoke-DzAction -Description "Require a new password for '$UserName' at the next sign-in" -Action {
        $output = & net.exe user $UserName /logonpasswordchg:yes 2>&1
        if ($LASTEXITCODE -ne 0) { throw "net user failed: $output" }
    }.GetNewClosure() | Out-Null
}

function Invoke-DzRestart {
    <#
        Restarts the PC so a step can continue. If automatic sign-in is still active, makes
        sure it has at least 2 sign-ins left, so DayZero comes back on its own.
    #>
    [CmdletBinding()]
    param([string]$Reason = 'continue setup')
    Invoke-DzAction -Description "Restart the PC to $Reason" -Action {
        $auto = Get-ItemProperty -LiteralPath $script:WinlogonKey -ErrorAction SilentlyContinue
        if ($auto -and $auto.PSObject.Properties['AutoAdminLogon'] -and [string]$auto.AutoAdminLogon -eq '1' -and
            $auto.PSObject.Properties['DefaultPassword'] -and $auto.PSObject.Properties['AutoLogonCount'] -and [int]$auto.AutoLogonCount -lt 2) {
            Set-ItemProperty -LiteralPath $script:WinlogonKey -Name 'AutoLogonCount' -Value 2
        }
        Restart-Computer -Force
    } | Out-Null
}

function Complete-DzSetup {
    <# Runs all cleanup steps. Each one is attempted even if an earlier one fails. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Settings)
    $failures = 0
    $steps = @(
        @{ Name = 'auto-start task'; Run = { Unregister-DzResumeTask } },
        @{ Name = 'automatic sign-in'; Run = { Disable-DzAutoLogon } },
        @{ Name = 'cached answer files'; Run = { Remove-DzCachedAnswerFile } }
    )
    if ($Settings.temporaryPassword -and $Settings.userName) {
        $user = [string]$Settings.userName
        $steps += @{ Name = 'temporary password'; Run = { Set-DzPasswordChangeRequired -UserName $user }.GetNewClosure() }
    }
    foreach ($step in $steps) {
        try {
            & $step.Run
            Write-DzLog -Level Ok -Message ("Cleanup done: {0}" -f $step.Name)
        }
        catch {
            $failures++
            Write-DzLog -Level Error -Message ("Cleanup failed ({0}): {1}" -f $step.Name, $_.Exception.Message)
        }
    }
    return ($failures -eq 0)
}

Export-ModuleMember -Function @('Invoke-DzRestart', 'Unregister-DzResumeTask', 'Disable-DzAutoLogon', 'Remove-DzCachedAnswerFile', 'Set-DzPasswordChangeRequired', 'Complete-DzSetup')
