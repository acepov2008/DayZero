#Requires -Version 5.1
<#
    DayZero - Windows steps: restore point, activation, debloat, optional removals and the
    individual tweaks. Also the 'restorePoint' requirement: tweaks and removals only run
    after a restore point exists (config\tweaks.json "requireRestorePoint").
#>

Set-StrictMode -Version 2.0

$script:RestorePointName = 'DayZero: before tweaks'

function Invoke-DzStepRestorePoint {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $drive = $env:SystemDrive + '\'
    if ($Context.Progress) { & $Context.Progress "Creating a restore point for $drive ..." }
    if (Test-DzDryRun) {
        Write-DzLog -Message "[DRY-RUN] would: turn on System Protection for $drive and create the restore point '$script:RestorePointName'"
        return (New-DzStepResult -Status Done -Message '[DRY-RUN] would create a restore point.')
    }
    Invoke-DzAction -Description "Turn on System Protection (System Restore) for $drive" -Action { Enable-ComputerRestore -Drive $drive -ErrorAction Stop } | Out-Null

    # Windows allows one restore point per 24 h by default; lift that for this one call only.
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $name = 'SystemRestorePointCreationFrequency'
    $before = Get-DzRegistryValue -Path $key -Name $name
    Set-DzRegistryValue -Path $key -Name $name -Value 0 -Kind 'DWord'
    try {
        Invoke-DzAction -Description "Create restore point '$script:RestorePointName'" -Action {
            Checkpoint-Computer -Description $script:RestorePointName -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        } | Out-Null
    }
    finally {
        if ($before.Exists) { Set-DzRegistryValue -Path $key -Name $name -Value $before.Value -Kind $before.Kind }
        else { Remove-DzRegistryValue -Path $key -Name $name }
    }
    $made = @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue | Where-Object { $_.Description -eq $script:RestorePointName })
    if ($made.Count -eq 0) { return (New-DzStepResult -Status Failed -Message 'Windows reported no error, but the restore point is not in the list.') }
    return (New-DzStepResult -Status Done -Message 'Created. To roll back: Start > "Create a restore point" > System Restore.')
}

function ConvertFrom-DzFirmwareKeyDescription {
    <# "[4.0] Professional OEM:DM" -> "Professional". Returns $null when it can't tell. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][AllowEmptyString()][string]$Description)
    $m = [regex]::Match([string]$Description, '\]\s*(\S+)\s+OEM')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Invoke-DzStepActivation {
    <#
        Legitimate activation only: if Windows is not activated yet and the PC's firmware
        holds a key for the installed edition, install that key and activate online.
        Otherwise trigger one online activation attempt (digital licence). Never anything else.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $s = Get-DzActivationStatus
    if ($s.Error) { return (New-DzStepResult -Status Warn -Message "Could not read the activation status: $($s.Error)") }
    if ($s.Activated) { return (New-DzStepResult -Status Done -Message ("Activated ({0})." -f $(if ($s.Channel) { $s.Channel } else { 'licensed' }))) }

    $installed = if ($Context.System) { [string]$Context.System.EditionId } else { '' }
    if ($s.FirmwareKeyPresent) {
        $fwEdition = ConvertFrom-DzFirmwareKeyDescription -Description $s.FirmwareEdition
        if ($fwEdition -and $installed -and $fwEdition -ne $installed) {
            return (New-DzStepResult -Status Warn -Message ("This PC's built-in key is for '{0}', but '{1}' is installed, so it can't activate this edition. Reinstall with edition 'Auto', or buy an upgrade in Settings > System > Activation." -f $fwEdition, $installed))
        }
        Invoke-DzAction -Description "Install this PC's own firmware (OEM) product key and activate online" -Action {
            $svc = Get-CimInstance -ClassName SoftwareLicensingService -ErrorAction Stop
            $key = [string]$svc.OA3xOriginalProductKey
            [void](Invoke-CimMethod -InputObject $svc -MethodName InstallProductKey -Arguments @{ ProductKey = $key } -ErrorAction Stop)
            [void](Invoke-CimMethod -InputObject $svc -MethodName RefreshLicenseStatus -ErrorAction SilentlyContinue)
        } | Out-Null
    }
    if (Test-DzDryRun) { return (New-DzStepResult -Status Done -Message '[DRY-RUN] would try online activation.') }

    try {
        $windowsAppId = '55c92734-d682-4d71-983e-d6ec3f16059f'
        $product = Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "ApplicationID = '$windowsAppId' AND PartialProductKey IS NOT NULL" -ErrorAction Stop | Select-Object -First 1
        if ($product) {
            Write-DzLog -Message 'Asking Microsoft to activate Windows (online).'
            [void](Invoke-CimMethod -InputObject $product -MethodName Activate -ErrorAction Stop)
        }
    }
    catch { Write-DzLog -Level Warn -Message ('Online activation attempt: ' + $_.Exception.Message) }

    $after = Get-DzActivationStatus
    if ($after.Activated) { return (New-DzStepResult -Status Done -Message 'Activated.') }
    return (New-DzStepResult -Status Warn -Message 'Not activated yet. A digital licence often activates within an hour; otherwise enter your key in Settings > System > Activation.')
}

function Invoke-DzStepDebloat {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    # 'profile' is the argument name of DayZero 0.7 and earlier (light / full), kept for resumed runs.
    $level = [string](Get-DzStepArg -Context $Context -Name 'level' -Default (Get-DzStepArg -Context $Context -Name 'profile' -Default 'minimal'))
    $keep = @(Get-DzStepArg -Context $Context -Name 'keepApps' -Default @()) | Where-Object { $_ } | ForEach-Object { [string]$_ }
    return (Remove-DzBloatware -Context $Context -Level $level -KeepApps @($keep))
}

function Invoke-DzStepRemoval {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    return (Remove-DzOptionalItem -Context $Context -Id ([string](Get-DzStepArg -Context $Context -Name 'id')))
}

function Invoke-DzStepTweak {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $id = [string](Get-DzStepArg -Context $Context -Name 'id')
    $tweak = Get-DzCatalogItem -Catalog $Context.Config.tweaks -Collection 'tweaks' -Id $id
    if ($null -eq $tweak) { return (New-DzStepResult -Status Failed -Message "Tweak '$id' is not in config\tweaks.json.") }
    $reason = Test-DzApplicable -Item $tweak -System $Context.System
    if ($reason) { return (New-DzStepResult -Status Skipped -Message $reason) }
    return (Invoke-DzTweak -Tweak $tweak -Context $Context)
}

Register-DzStepType -Type 'restorePoint' -Command 'Invoke-DzStepRestorePoint'
Register-DzStepType -Type 'activation' -Command 'Invoke-DzStepActivation'
Register-DzStepType -Type 'debloat' -Command 'Invoke-DzStepDebloat'
Register-DzStepType -Type 'removal' -Command 'Invoke-DzStepRemoval'
Register-DzStepType -Type 'tweak' -Command 'Invoke-DzStepTweak'

Register-DzRequirement -Name 'restorePoint' -Check {
    param($Context)
    $require = [bool](Get-DzProperty $Context.Config.tweaks 'requireRestorePoint' $true)
    if (-not $require -or $Context.DryRun -or $null -eq $Context.State) { return $null }
    $rp = @($Context.State.steps | Where-Object { $_.id -eq 'restore-point' }) | Select-Object -First 1
    if ($null -eq $rp -or $rp.status -in @('done', 'warn')) { return $null }
    return 'No restore point yet (see "Create a restore point"), so DayZero did not change this. Fix that step, then press Retry failed steps.'
}

Export-ModuleMember -Function @('Invoke-DzStepRestorePoint', 'ConvertFrom-DzFirmwareKeyDescription', 'Invoke-DzStepActivation', 'Invoke-DzStepDebloat', 'Invoke-DzStepRemoval', 'Invoke-DzStepTweak')
