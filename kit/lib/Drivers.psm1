#Requires -Version 5.1
<#
    DayZero - drivers: the optional Drivers\ folder (pnputil), the graphics card's official
    app, and the PC brand's official update tool (both from config\drivers.json).
#>

Set-StrictMode -Version 2.0

function Get-DzDriverFolder {
    <# Folders to install from: C:\DayZero\Drivers, plus the stick's copy if it differs. #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $list = New-Object System.Collections.Generic.List[string]
    $local = Join-Path $Context.KitRoot 'Drivers'
    if (Test-Path -LiteralPath $local) { $list.Add($local) }
    $buildId = if ($Context.Settings) { [string](Get-DzProperty $Context.Settings 'buildId' '') } else { '' }
    $usb = Find-DzUsbKit -BuildId $buildId
    if ($usb) {
        $usbDrivers = Join-Path $usb 'Drivers'
        if ((Test-Path -LiteralPath $usbDrivers) -and ($usbDrivers -ine $local)) {
            # Only use the stick's folder when it has drivers the local copy lacks.
            $localCount = @(Get-ChildItem -LiteralPath $local -Recurse -Filter '*.inf' -File -ErrorAction SilentlyContinue).Count
            $usbCount = @(Get-ChildItem -LiteralPath $usbDrivers -Recurse -Filter '*.inf' -File -ErrorAction SilentlyContinue).Count
            if ($usbCount -gt $localCount) { $list.Add($usbDrivers) }
        }
    }
    return $list.ToArray()
}

function Get-DzPnputilOutcome {
    <# pnputil exit codes: 0 ok, 3010 ok + restart, 259 nothing to do (already installed / no matching device). #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int]$ExitCode)
    switch ($ExitCode) {
        0 { return [pscustomobject]@{ Status = 'Done'; Text = 'Drivers installed.' } }
        3010 { return [pscustomobject]@{ Status = 'Warn'; Text = 'Drivers installed; a restart finishes the job.' } }
        259 { return [pscustomobject]@{ Status = 'Done'; Text = 'Nothing new: the drivers were already installed or no matching device is present.' } }
        default { return [pscustomobject]@{ Status = 'Failed'; Text = ('pnputil exit code {0}.' -f $ExitCode) } }
    }
}

function Install-DzDriverFolder {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $folders = @(Get-DzDriverFolder -Context $Context)
    $infs = @(foreach ($f in $folders) { Get-ChildItem -LiteralPath $f -Recurse -Filter '*.inf' -File -ErrorAction SilentlyContinue })
    if ($infs.Count -eq 0) { return (New-DzStepResult -Status Skipped -Message 'No drivers in the Drivers folder (that is fine; Windows Update handles drivers too).') }
    if (Test-DzDryRun) { return (New-DzStepResult -Status Done -Message ("[DRY-RUN] would install {0} driver package(s) with pnputil." -f $infs.Count)) }
    $worst = $null
    $notes = New-Object System.Collections.Generic.List[string]
    foreach ($f in $folders) {
        if ($Context.Progress) { & $Context.Progress "Installing drivers from $f ..." }
        $pattern = Join-Path $f '*.inf'
        $pnputil = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32\pnputil.exe' } else { 'pnputil.exe' }
        $r = Invoke-DzAction -Description ("pnputil /add-driver `"{0}`" /subdirs /install" -f $pattern) -Action {
            Invoke-DzProcess -FilePath $pnputil -Arguments @('/add-driver', $pattern, '/subdirs', '/install') -TimeoutSec 1800
        }
        foreach ($line in @($r.Output | Select-Object -Last 8)) { Write-DzLog -Message "  pnputil: $line" }
        $o = Get-DzPnputilOutcome -ExitCode $r.ExitCode
        $notes.Add($o.Text)
        if ($o.Status -eq 'Warn') { $Context.Flags['RestartRecommended'] = $true }
        if ($null -eq $worst -or $o.Status -eq 'Failed' -or ($o.Status -eq 'Warn' -and $worst -eq 'Done')) { $worst = $o.Status }
    }
    return (New-DzStepResult -Status $worst -Message ("{0} .inf file(s). {1}" -f $infs.Count, (($notes | Select-Object -Unique) -join ' ')))
}

function Add-DzFollowUp {
    <# A link for the summary screen (e.g. a vendor download page). Saved in state.json. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context, [Parameter(Mandatory = $true)][string]$Title, [Parameter(Mandatory = $true)][string]$Url)
    if ($null -eq $Context.State) { return }
    if (-not $Context.State.PSObject.Properties['followUps']) { $Context.State | Add-Member -NotePropertyName followUps -NotePropertyValue @() }
    if (@($Context.State.followUps | Where-Object { $_.url -eq $Url }).Count -gt 0) { return }
    $Context.State.followUps = @($Context.State.followUps) + @([pscustomobject]@{ title = $Title; url = $Url })
}

function Install-DzVendorApp {
    <# Installs a gpuApps / oemTools entry: winget id, Store id, or (no package) a link on the summary. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context, [Parameter(Mandatory = $true)][object]$Item)
    $name = [string]$Item.name
    $winget = [string](Get-DzProperty $Item 'winget' '')
    $store = [string](Get-DzProperty $Item 'msstore' '')
    $page = [string](Get-DzProperty $Item 'page' '')
    if ($winget) { return (Install-DzWingetPackage -Context $Context -Id $winget -Name $name -Source 'winget') }
    if ($store) { return (Install-DzWingetPackage -Context $Context -Id $store -Name $name -Source 'msstore') }
    if ($page) {
        Add-DzFollowUp -Context $Context -Title "Download the $name" -Url $page
        return (New-DzStepResult -Status Warn -Message ("{0} isn't published through winget, so it can't be installed silently. The summary has a button for the official download page ({1}). Windows Update already installed a working driver." -f $name, $page))
    }
    return (New-DzStepResult -Status Failed -Message "No package id or page for $name in config\drivers.json.")
}

Export-ModuleMember -Function @('Get-DzDriverFolder', 'Get-DzPnputilOutcome', 'Install-DzDriverFolder', 'Add-DzFollowUp', 'Install-DzVendorApp')
