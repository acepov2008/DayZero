#Requires -Version 5.1
<#
    DayZero - turns a mode + the choices from the review screen into an ordered plan.

    Order (each line only appears when its step type exists and it applies to this PC):
       1. Check this PC                        6. Windows Update (incl. drivers)
       2. Drivers from the USB Drivers folder   7. GPU vendor app, PC-brand update tool
       3. Internet connection                   8. Remove bloat, optional removals, tweaks
       4. Activation check                      9. Apps, Microsoft 365
       5. Restore point, winget                10. Late tweaks (startup clean-up), final update check

    Drivers from the stick come before the internet step on purpose: a missing network
    driver can come from the stick.
#>

Set-StrictMode -Version 2.0

function Test-DzApplicable {
    <#
        Checks an item's optional "appliesTo" block against this PC. Returns $null when it
        applies, otherwise the reason it does not. Supported keys:
          windows [10,11]  minBuild  formFactor desktop|laptop|any  arch [amd64,arm64]
          editions [Core,Professional,...]  notVirtual true  gpuVendors [NVIDIA,AMD,Intel]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object]$Item, [AllowNull()][object]$System)
    $a = Get-DzProperty $Item 'appliesTo' $null
    if ($null -eq $a -or $null -eq $System) { return $null }
    $win = @(Get-DzProperty $a 'windows' @())
    if ($win.Count -gt 0 -and ($win -notcontains [int]$System.WindowsVersion)) { return "Only for Windows $($win -join '/')." }
    $minBuild = Get-DzProperty $a 'minBuild' $null
    if ($null -ne $minBuild -and [int]$System.Build -lt [int]$minBuild) { return "Needs Windows build $minBuild or newer." }
    $form = [string](Get-DzProperty $a 'formFactor' 'any')
    if ($form -eq 'desktop' -and $System.IsLaptop) { return 'Desktops only.' }
    if ($form -eq 'laptop' -and -not $System.IsLaptop) { return 'Laptops only.' }
    $arch = @(Get-DzProperty $a 'arch' @())
    if ($arch.Count -gt 0 -and ($arch -notcontains [string]$System.Architecture)) { return "Not available for $($System.Architecture)." }
    $editions = @(Get-DzProperty $a 'editions' @())
    if ($editions.Count -gt 0 -and ($editions -notcontains [string]$System.EditionId)) { return "Not for the $($System.EditionId) edition." }
    if ([bool](Get-DzProperty $a 'notVirtual' $false) -and $System.IsVirtualMachine) { return 'Not useful in a virtual machine.' }
    $gpus = @(Get-DzProperty $a 'gpuVendors' @())
    if ($gpus.Count -gt 0) {
        $match = @($System.GpuVendors | Where-Object { $gpus -contains $_ })
        if ($match.Count -eq 0) { return "Needs a $($gpus -join '/') graphics card." }
    }
    return $null
}

function Test-DzInMode {
    <# True when an item's "modes" list mentions any of the given mode ids (no list = all modes). #>
    param([AllowNull()][object]$Item, [string[]]$ModeIds)
    $modes = @(Get-DzProperty $Item 'modes' @())
    if ($modes.Count -eq 0) { return $true }
    foreach ($m in $modes) { if ($ModeIds -contains $m) { return $true } }
    return $false
}

function Get-DzReviewModel {
    <#
        What the review screen shows: the app list (mode apps ticked, optional extras not)
        and the optional switches (warning-carrying tweaks, PC-brand tool, removals).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Mode,
        [AllowNull()][object]$System,
        [Parameter(Mandatory = $true)][hashtable]$Config
    )
    $modeIds = @($Mode.modeIds)
    $isLaptop = ($null -ne $System -and [bool]$System.IsLaptop)
    $apps = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    if ($Config.apps) {
        foreach ($id in @($Mode.apps)) {
            $item = Get-DzCatalogItem -Catalog $Config.apps -Collection 'apps' -Id $id
            if ($null -eq $item -or $seen.ContainsKey($id)) { continue }
            if (Test-DzApplicable -Item $item -System $System) { continue }
            $seen[$id] = $true
            $apps.Add([pscustomobject]@{ Id = $id; Name = [string]$item.name; Group = [string](Get-DzProperty $item 'category' 'Apps'); Description = [string](Get-DzProperty $item 'description' ''); Checked = $true })
        }
        foreach ($item in @($Config.apps.apps)) {
            $id = [string]$item.id
            if ($seen.ContainsKey($id) -or -not [bool](Get-DzProperty $item 'optional' $false)) { continue }
            if (-not (Test-DzInMode -Item $item -ModeIds $modeIds)) { continue }
            if (Test-DzApplicable -Item $item -System $System) { continue }
            $seen[$id] = $true
            $apps.Add([pscustomobject]@{ Id = $id; Name = [string]$item.name; Group = [string](Get-DzProperty $item 'category' 'Apps'); Description = [string](Get-DzProperty $item 'description' ''); Checked = $false })
        }
    }

    $options = New-Object System.Collections.Generic.List[object]
    if ($Config.tweaks) {
        foreach ($t in @($Config.tweaks.tweaks)) {
            if (-not [bool](Get-DzProperty $t 'optional' $false)) { continue }
            # An optional tweak shows up only in modes that list it (or that its own "modes" names);
            # without this, Office mode would offer - and pre-tick - the gaming power plan.
            $explicitModes = @(Get-DzProperty $t 'modes' @()).Count -gt 0
            $inMode = (@($Mode.tweaks) -contains [string]$t.id) -or ($explicitModes -and (Test-DzInMode -Item $t -ModeIds $modeIds))
            if (-not $inMode) { continue }
            if (Test-DzApplicable -Item $t -System $System) { continue }
            $checked = [bool](Get-DzProperty $t 'default' $false)
            if ($isLaptop) { $checked = [bool](Get-DzProperty $t 'defaultLaptop' $checked) }
            $warning = [string](Get-DzProperty $t 'warning' '')
            $lw = [string](Get-DzProperty $t 'laptopWarning' '')
            if ($isLaptop -and $lw) { $warning = $lw }
            $options.Add([pscustomobject]@{ Id = [string]$t.id; Kind = 'tweak'; Title = [string]$t.title; Description = [string](Get-DzProperty $t 'what' ''); Warning = $warning; Checked = $checked })
        }
    }
    if ($Config.debloat) {
        foreach ($r in @(Get-DzProperty $Config.debloat 'optionalRemovals' @())) {
            if (-not (Test-DzInMode -Item $r -ModeIds $modeIds)) { continue }
            if (Test-DzApplicable -Item $r -System $System) { continue }
            $options.Add([pscustomobject]@{ Id = [string]$r.id; Kind = 'removal'; Title = [string]$r.title; Description = [string](Get-DzProperty $r 'what' ''); Warning = [string](Get-DzProperty $r 'warning' ''); Checked = [bool](Get-DzProperty $r 'default' $false) })
        }
    }
    if ($Config.drivers -and $null -ne $System -and -not $System.IsVirtualMachine) {
        $tool = @(Get-DzProperty $Config.drivers 'oemTools' @()) | Where-Object { $_.brand -eq $System.Brand } | Select-Object -First 1
        if ($tool) {
            $options.Add([pscustomobject]@{ Id = 'oemTool'; Kind = 'oemTool'; Title = "Install $($tool.name)"; Description = [string](Get-DzProperty $tool 'what' "$($System.Brand)'s official driver and firmware update app."); Warning = ''; Checked = $true })
        }
    }
    return [pscustomobject]@{ Apps = $apps.ToArray(); Options = $options.ToArray() }
}

function ConvertTo-DzPlanOption {
    <# Turns the ticked review items into the options hashtable stored in state.json. #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowEmptyCollection()][object[]]$Apps = @(), [AllowEmptyCollection()][object[]]$Options = @())
    return @{
        apps     = @($Apps | Where-Object { $_.Checked } | ForEach-Object { $_.Id })
        tweaks   = @($Options | Where-Object { $_.Checked -and $_.Kind -eq 'tweak' } | ForEach-Object { $_.Id })
        removals = @($Options | Where-Object { $_.Checked -and $_.Kind -eq 'removal' } | ForEach-Object { $_.Id })
        oemTool  = [bool](@($Options | Where-Object { $_.Checked -and $_.Kind -eq 'oemTool' }).Count -gt 0)
    }
}

function New-DzPlan {
    <# Returns the ordered list of step definitions (ordered dictionaries). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Mode,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Options,
        [AllowNull()][object]$System,
        [Parameter(Mandatory = $true)][hashtable]$Config
    )
    $steps = New-Object System.Collections.Generic.List[object]
    $add = {
        param([string]$Id, [string]$Title, [string]$Type, [string]$Group, [hashtable]$StepArgs = @{}, [string[]]$Requires = @())
        if (-not (Test-DzStepType -Type $Type)) { return }
        $steps.Add([ordered]@{ id = $Id; title = $Title; type = $Type; group = $Group; args = $StepArgs; requires = @($Requires) })
    }
    $opt = @{}
    foreach ($k in $Options.Keys) { $opt[$k] = $Options[$k] }
    $isVm = ($null -ne $System -and [bool]$System.IsVirtualMachine)

    & $add 'preflight' 'Check this PC' 'preflight' 'Start'
    & $add 'drivers-usb' 'Install drivers from the USB stick' 'driversFolder' 'Drivers'
    & $add 'network' 'Connect to the internet' 'network' 'Start'
    & $add 'activation' 'Check Windows activation' 'activation' 'Windows'
    & $add 'restore-point' 'Create a restore point' 'restorePoint' 'Safety'
    & $add 'winget' 'Get winget (Windows Package Manager) ready' 'winget' 'Apps' @{} @('internet')
    & $add 'windows-update' 'Windows Update (including drivers)' 'windowsUpdate' 'Windows' @{ final = $false } @('internet')

    if ($Config.drivers -and $null -ne $System -and -not $isVm) {
        foreach ($vendor in @($System.GpuVendors)) {
            $gpu = @(Get-DzProperty $Config.drivers 'gpuApps' @()) | Where-Object { $_.vendor -eq $vendor } | Select-Object -First 1
            if ($gpu) { & $add "gpu-$($vendor.ToLowerInvariant())" ("Install the {0}" -f $gpu.name) 'gpuApp' 'Drivers' @{ vendor = $vendor } @('internet') }
        }
        if ($opt.ContainsKey('oemTool') -and $opt.oemTool) {
            $tool = @(Get-DzProperty $Config.drivers 'oemTools' @()) | Where-Object { $_.brand -eq $System.Brand } | Select-Object -First 1
            if ($tool) { & $add 'oem-tool' ("Install {0}" -f $tool.name) 'oemTool' 'Drivers' @{ brand = $System.Brand } @('internet') }
        }
    }

    if ($Mode.debloat -and $Mode.debloat -ne 'none') {
        & $add 'debloat' ("Remove preinstalled bloat ({0})" -f $Mode.debloat) 'debloat' 'Tweaks' @{ profile = $Mode.debloat } @('restorePoint')
    }
    foreach ($rid in @($(if ($opt.ContainsKey('removals')) { $opt.removals } else { @() }))) {
        if (-not $rid) { continue }
        $r = @(Get-DzProperty $Config.debloat 'optionalRemovals' @()) | Where-Object { $_.id -eq $rid } | Select-Object -First 1
        if ($r) { & $add "remove:$rid" ([string]$r.title) 'removal' 'Tweaks' @{ id = $rid } @('restorePoint') }
    }

    $tweakIds = New-Object System.Collections.Generic.List[string]
    foreach ($t in @($Mode.tweaks)) {
        $item = Get-DzCatalogItem -Catalog $Config.tweaks -Collection 'tweaks' -Id $t
        if ($item -and -not [bool](Get-DzProperty $item 'optional' $false) -and -not $tweakIds.Contains($t)) { $tweakIds.Add($t) }
    }
    foreach ($t in @($(if ($opt.ContainsKey('tweaks')) { $opt.tweaks } else { @() }))) { if ($t -and -not $tweakIds.Contains($t)) { $tweakIds.Add($t) } }
    $late = New-Object System.Collections.Generic.List[object]
    foreach ($t in $tweakIds) {
        $item = Get-DzCatalogItem -Catalog $Config.tweaks -Collection 'tweaks' -Id $t
        if ($null -eq $item) { continue }
        if (Test-DzApplicable -Item $item -System $System) { continue }
        if ([string](Get-DzProperty $item 'phase' 'early') -eq 'late') { $late.Add($item); continue }
        & $add "tweak:$t" ([string]$item.title) 'tweak' 'Tweaks' @{ id = $t } @('restorePoint')
    }

    foreach ($a in @($(if ($opt.ContainsKey('apps')) { $opt.apps } else { @() }))) {
        $item = Get-DzCatalogItem -Catalog $Config.apps -Collection 'apps' -Id $a
        if ($null -eq $item) { continue }
        & $add "app:$a" ("Install {0}" -f $item.name) 'app' 'Apps' @{ id = $a } @('internet', 'winget')
    }
    if ($Mode.office) { & $add 'office' 'Install Microsoft 365 Apps' 'office' 'Apps' @{} @('internet') }

    foreach ($item in $late) { & $add "tweak:$($item.id)" ([string]$item.title) 'tweak' 'Tweaks' @{ id = [string]$item.id } @('restorePoint') }
    & $add 'windows-update-final' 'Final Windows Update check' 'windowsUpdate' 'Windows' @{ final = $true } @('internet')

    return , $steps.ToArray()
}

Export-ModuleMember -Function @('Test-DzApplicable', 'Test-DzInMode', 'Get-DzReviewModel', 'ConvertTo-DzPlanOption', 'New-DzPlan')
