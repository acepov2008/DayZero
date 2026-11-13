#Requires -Version 5.1
<#
    DayZero - turns a mode + the choices from the review screen into an ordered plan.

    Order (each line only appears when its step type exists and it applies to this PC):
       1. Check this PC                        6. Windows Update (incl. drivers)
       2. Drivers from the USB Drivers folder   7. GPU vendor app, PC-brand update tool
       3. Internet connection                   8. Remove apps (clean-up level), removals, tweaks
       4. Activation check                      9. Apps, Microsoft 365
       5. Restore point, winget                10. Your own scripts, late tweaks, final update check

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

function Get-DzSelectionValue {
    <# Reads a field of the builder's customSelection (hashtable or JSON object). #>
    param([AllowNull()][object]$Selection, [string]$Name, [AllowNull()][object]$Default)
    if ($null -eq $Selection) { return $Default }
    return (Get-DzProperty $Selection $Name $Default)
}

function Get-DzReviewModel {
    <#
        What the review screen (and the builder's picker) shows.

        Apps: the WHOLE catalog, grouped by category in apps.json order. A normal mode ticks
        its own apps; Custom mode ticks nothing except what -Preselect (the builder's
        customSelection) lists. Categories with pickOne get radio buttons plus "None".
        Microsoft 365 is an item in "Office & documents" (Kind 'office').

        Options:
          * the clean-up level (radio: Clear / Minimal / Standard / Advanced, from debloat.json),
            -DebloatLevel (the builder's pick) > Custom picks from older builders > the mode's
            suggestion > debloat.json defaultLevel;
          * 'Privacy and clean-up': every tweak and removal some level uses (LevelOwned). The
            chosen level's are ticked; Set-DzReviewLevel re-ticks them when the level changes;
          * 'Tweaks': the rest (a mode's own tweaks ticked; optional ones follow their
            default / defaultLaptop; Custom: the builder's picks);
          * the PC-brand tool.

        Every item: Id, Kind, Name/Title, Description, Warning, Group, GroupId, Exclusive,
        Checked, LevelOwned. Level items also carry Tweaks and Removals (cumulative).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Mode,
        [AllowNull()][object]$System,
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [AllowNull()][object]$Preselect = $null,
        [AllowNull()][AllowEmptyString()][string]$DebloatLevel = $null,
        [AllowEmptyCollection()][string[]]$UserScripts = @()
    )
    $isCustom = [bool](Get-DzProperty $Mode 'custom' $false)
    $isLaptop = ($null -ne $System -and [bool]$System.IsLaptop)
    $modeApps = @($Mode.apps)
    $pickApps = @(Get-DzSelectionValue $Preselect 'apps' @())
    $pickTweaks = @(Get-DzSelectionValue $Preselect 'tweaks' @())

    $apps = New-Object System.Collections.Generic.List[object]
    if ($Config.apps) {
        $categories = New-Object System.Collections.Generic.List[object]
        foreach ($c in @(Get-DzProperty $Config.apps 'categories' @())) { $categories.Add($c) }
        $known = @($categories | ForEach-Object { [string]$_.id })
        $extra = @($Config.apps.apps | ForEach-Object { [string](Get-DzProperty $_ 'category' 'other') } | Where-Object { $known -notcontains $_ } | Select-Object -Unique)
        foreach ($e in $extra) { $categories.Add([pscustomobject]@{ id = $e; title = $e }) }

        foreach ($cat in $categories) {
            $catId = [string]$cat.id
            $title = [string](Get-DzProperty $cat 'title' $catId)
            $exclusive = [bool](Get-DzProperty $cat 'pickOne' $false)
            $items = New-Object System.Collections.Generic.List[object]
            foreach ($a in @($Config.apps.apps | Where-Object { [string](Get-DzProperty $_ 'category' 'other') -eq $catId })) {
                if (Test-DzApplicable -Item $a -System $System) { continue }
                $id = [string]$a.id
                $kind = if ([string](Get-DzProperty $a 'kind' '') -eq 'office') { 'office' } else { 'app' }
                if ($isCustom) {
                    $checked = ($pickApps -contains $id) -or ($kind -eq 'office' -and [bool](Get-DzSelectionValue $Preselect 'office' $false))
                }
                else {
                    $checked = ($modeApps -contains $id) -or ($kind -eq 'office' -and [bool]$Mode.office)
                }
                $items.Add([pscustomobject]@{
                        Id = $id; Kind = $kind; Name = [string]$a.name; Title = [string]$a.name
                        Description = [string](Get-DzProperty $a 'description' ''); Warning = ''
                        Group = $title; GroupId = $catId; Exclusive = $exclusive; Checked = [bool]$checked
                    })
            }
            if ($items.Count -eq 0) { continue }
            if ($exclusive) {
                $seen = $false
                foreach ($i in $items) { if ($i.Checked) { if ($seen) { $i.Checked = $false } else { $seen = $true } } }
                $items.Add([pscustomobject]@{
                        Id = "none:$catId"; Kind = 'none'; Name = 'None'; Title = 'None'; Description = ''; Warning = ''
                        Group = $title; GroupId = $catId; Exclusive = $true; Checked = (-not $seen)
                    })
            }
            foreach ($i in $items) { $apps.Add($i) }
        }
    }

    $options = New-Object System.Collections.Generic.List[object]
    $levels = @(Get-DzDebloatLevelList -Config $Config)
    $levelId = Resolve-DzDebloatLevelId -Config $Config -Id $DebloatLevel
    if (-not $levelId -and $isCustom) { $levelId = Resolve-DzDebloatLevelId -Config $Config -Id ([string](Get-DzSelectionValue $Preselect 'debloat' '')) }
    if (-not $levelId) { $levelId = Resolve-DzDebloatLevelId -Config $Config -Id ([string](Get-DzProperty $Mode 'debloat' '')) }
    if (-not $levelId) { $levelId = Get-DzDefaultDebloatLevel -Config $Config }
    $level = @($levels | Where-Object { $_.id -eq $levelId }) | Select-Object -First 1
    $levelTweaks = if ($level) { @($level.tweaks) } else { @() }
    $levelRemovals = if ($level) { @($level.removals) } else { @() }
    $ownedTweaks = @($levels | ForEach-Object { $_.tweaks } | Select-Object -Unique)
    $ownedRemovals = @($levels | ForEach-Object { $_.removals } | Select-Object -Unique)
    $cleanGroup = 'Privacy and clean-up'

    foreach ($l in $levels) {
        $title = if ($l.tagline) { '{0} - {1}' -f $l.title, $l.tagline } else { $l.title }
        $options.Add([pscustomobject]@{
                Id = $l.id; Kind = 'debloat'; Title = $title; Name = [string]$l.title; Description = $l.description; Warning = ''
                Group = 'Clean-up level'; GroupId = 'debloat'; Exclusive = $true; Checked = ($l.id -eq $levelId); LevelOwned = $false
                Tweaks = @($l.tweaks); Removals = @($l.removals)
            })
    }
    $tweakItems = New-Object System.Collections.Generic.List[object]
    if ($Config.tweaks) {
        foreach ($t in @($Config.tweaks.tweaks)) {
            if (Test-DzApplicable -Item $t -System $System) { continue }
            $id = [string]$t.id
            $owned = $ownedTweaks -contains $id
            $optional = [bool](Get-DzProperty $t 'optional' $false)
            if ($isCustom) { $checked = ($pickTweaks -contains $id) }
            elseif (@($Mode.tweaks) -contains $id) {
                $checked = $true
                if ($optional) {
                    $checked = [bool](Get-DzProperty $t 'default' $false)
                    if ($isLaptop) { $checked = [bool](Get-DzProperty $t 'defaultLaptop' $checked) }
                }
            }
            else { $checked = $false }
            if ($levelTweaks -contains $id) { $checked = $true }
            $warning = [string](Get-DzProperty $t 'warning' '')
            $lw = [string](Get-DzProperty $t 'laptopWarning' '')
            if ($isLaptop -and $lw) { $warning = $lw }
            $tweakItems.Add([pscustomobject]@{
                    Id = $id; Kind = 'tweak'; Title = [string]$t.title; Name = [string]$t.title
                    Description = [string](Get-DzProperty $t 'what' ''); Warning = $warning
                    Group = $(if ($owned) { $cleanGroup } else { 'Tweaks' }); GroupId = $(if ($owned) { 'cleanup' } else { 'tweaks' })
                    Exclusive = $false; Checked = [bool]$checked; LevelOwned = $owned
                })
        }
    }
    foreach ($i in @($tweakItems | Where-Object { $_.LevelOwned })) { $options.Add($i) }
    if ($Config.debloat) {
        foreach ($r in @(Get-DzProperty $Config.debloat 'optionalRemovals' @())) {
            if (Test-DzApplicable -Item $r -System $System) { continue }
            $id = [string]$r.id
            $checked = if ($isCustom) { @(Get-DzSelectionValue $Preselect 'removals' @()) -contains $id } else { [bool](Get-DzProperty $r 'default' $false) }
            if ($levelRemovals -contains $id) { $checked = $true }
            $options.Add([pscustomobject]@{
                    Id = $id; Kind = 'removal'; Title = [string]$r.title; Name = [string]$r.title
                    Description = [string](Get-DzProperty $r 'what' ''); Warning = [string](Get-DzProperty $r 'warning' '')
                    Group = $cleanGroup; GroupId = 'cleanup'; Exclusive = $false; Checked = [bool]$checked; LevelOwned = ($ownedRemovals -contains $id)
                })
        }
    }
    foreach ($i in @($tweakItems | Where-Object { -not $_.LevelOwned })) { $options.Add($i) }
    if ($Config.drivers -and $null -ne $System -and -not $System.IsVirtualMachine) {
        $tool = @(Get-DzProperty $Config.drivers 'oemTools' @()) | Where-Object { $_.brand -eq $System.Brand } | Select-Object -First 1
        if ($tool) {
            $options.Add([pscustomobject]@{
                    Id = 'oemTool'; Kind = 'oemTool'; Title = "Install $($tool.name)"; Name = "Install $($tool.name)"
                    Description = [string](Get-DzProperty $tool 'what' "$($System.Brand)'s official driver and firmware update app."); Warning = ''
                    Group = 'Drivers'; GroupId = 'drivers'; Exclusive = $false; Checked = $true; LevelOwned = $false
                })
        }
    }
    if (@($UserScripts).Count -gt 0) {
        $options.Add([pscustomobject]@{
                Id = 'userScripts'; Kind = 'userScripts'; Title = 'Run your own scripts after the apps'; Name = 'Run your own scripts'
                Description = ('From the Scripts folder, in this order: ' + (@($UserScripts) -join ', ')); Warning = ''
                Group = 'Your scripts'; GroupId = 'userScripts'; Exclusive = $false; Checked = $true; LevelOwned = $false
            })
    }
    return [pscustomobject]@{ Apps = $apps.ToArray(); Options = $options.ToArray() }
}

function Set-DzReviewLevel {
    <#
        Picking a clean-up level works like WinUtil's preset buttons: it ticks exactly that
        level's tweaks and removals among the level-owned switches (the others stay as they are).
        Changes the items' Checked in place; the UI then copies them to the switches.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Options = @(), [Parameter(Mandatory = $true)][string]$LevelId)
    $level = @($Options | Where-Object { $_.Kind -eq 'debloat' -and $_.Id -eq $LevelId }) | Select-Object -First 1
    if ($null -eq $level) { return }
    foreach ($o in $Options) {
        if ($o.Kind -eq 'debloat') { $o.Checked = ($o.Id -eq $LevelId); continue }
        if (-not ($o.PSObject.Properties['LevelOwned'] -and $o.LevelOwned)) { continue }
        if ($o.Kind -eq 'tweak') { $o.Checked = (@($level.Tweaks) -contains $o.Id) }
        elseif ($o.Kind -eq 'removal') { $o.Checked = (@($level.Removals) -contains $o.Id) }
    }
}

function ConvertTo-DzPlanOption {
    <#
        Turns the ticked review items into the options stored in state.json. Because the review
        screen lists every tweak, the tweak list is complete ('explicitTweaks'): exactly the
        ticked ones run. Clean-up level and Microsoft 365 come from their own items.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowEmptyCollection()][object[]]$Apps = @(), [AllowEmptyCollection()][object[]]$Options = @())
    $kindOf = { param($x) if ($x.PSObject.Properties['Kind']) { [string]$x.Kind } else { 'app' } }
    $result = @{
        apps     = @($Apps | Where-Object { $_.Checked -and (& $kindOf $_) -eq 'app' } | ForEach-Object { $_.Id })
        tweaks   = @($Options | Where-Object { $_.Checked -and $_.Kind -eq 'tweak' } | ForEach-Object { $_.Id })
        removals = @($Options | Where-Object { $_.Checked -and $_.Kind -eq 'removal' } | ForEach-Object { $_.Id })
        oemTool  = [bool](@($Options | Where-Object { $_.Checked -and $_.Kind -eq 'oemTool' }).Count -gt 0)
    }
    if (@($Options | Where-Object { $_.Kind -eq 'userScripts' }).Count -gt 0) {
        $result.userScripts = [bool](@($Options | Where-Object { $_.Checked -and $_.Kind -eq 'userScripts' }).Count -gt 0)
    }
    if (@($Apps | Where-Object { (& $kindOf $_) -eq 'office' }).Count -gt 0) {
        $result.office = [bool](@($Apps | Where-Object { $_.Checked -and (& $kindOf $_) -eq 'office' }).Count -gt 0)
    }
    $levels = @($Options | Where-Object { $_.Kind -eq 'debloat' })
    if ($levels.Count -gt 0) {
        $picked = @($levels | Where-Object { $_.Checked }) | Select-Object -First 1
        $result.debloat = if ($picked) { [string]$picked.Id } else { 'clear' }
    }
    if (@($Options | Where-Object { $_.Kind -eq 'tweak' }).Count -gt 0) { $result.explicitTweaks = $true }
    return $result
}

function Get-DzModeSummary {
    <#
        Plain-text "what this mode includes" for the builder: ticked apps per category,
        Microsoft 365, the mode's own tweaks (and which ones stay off unless ticked). The
        clean-up level is picked and described separately (Get-DzDebloatLevelSummary).
        Built from the same review model the wizard uses, so it can't drift from it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][object]$Mode,
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [AllowNull()][object]$Preselect = $null
    )
    $nl = [Environment]::NewLine
    $bullet = [string][char]0x2022
    # Clear level: only the mode's own tweaks show; the clean-up level is described separately.
    $clear = @(Get-DzDebloatLevelList -Config $Config) | Select-Object -First 1
    $r = Get-DzReviewModel -Mode $Mode -System $null -Config $Config -Preselect $Preselect -DebloatLevel $(if ($clear) { $clear.id } else { $null })
    $lines = New-Object System.Collections.Generic.List[string]
    $pickedApps = @($r.Apps | Where-Object { $_.Checked -and $_.Kind -ne 'none' })
    if ($Mode.custom -and $pickedApps.Count -eq 0 -and @($r.Options | Where-Object { $_.Checked -and $_.Kind -eq 'tweak' }).Count -eq 0) {
        $lines.Add("Nothing is ticked yet. Press 'Choose apps and options' to pick now, or pick everything on the new PC.")
    }
    else {
        $groups = New-Object System.Collections.Generic.List[string]
        foreach ($a in $pickedApps) { if (-not $groups.Contains([string]$a.Group)) { $groups.Add([string]$a.Group) } }
        foreach ($g in $groups) {
            $names = @($pickedApps | Where-Object { $_.Group -eq $g } | ForEach-Object { $_.Name })
            $lines.Add(("{0} {1}: {2}" -f $bullet, ($g -replace '\s*\(pick one\)', ''), ($names -join ', ')))
        }
        if ($pickedApps.Count -eq 0) { $lines.Add("$bullet No apps") }
    }
    $on = @($r.Options | Where-Object { $_.Kind -eq 'tweak' -and $_.Checked })
    if ($on.Count -gt 0) {
        $names = foreach ($t in $on) {
            $item = Get-DzCatalogItem -Catalog $Config.tweaks -Collection 'tweaks' -Id $t.Id
            $suffix = if ($item -and (Get-DzProperty $item 'defaultLaptop' $null) -eq $false) { ' (off on laptops)' } else { '' }
            $t.Title + $suffix
        }
        $lines.Add(("{0} Tweaks: {1}" -f $bullet, ($names -join '; ')))
    }
    if (-not $Mode.custom) {
        $offered = @($r.Options | Where-Object { $_.Kind -eq 'tweak' -and -not $_.Checked -and @($Mode.tweaks) -contains $_.Id })
        if ($offered.Count -gt 0) { $lines.Add(("{0} Offered but off unless you tick them: {1}" -f $bullet, (($offered | ForEach-Object { $_.Title }) -join '; '))) }
    }
    $lines.Add(("{0} Clean-up and privacy: the level you pick below." -f $bullet))
    $lines.Add(("{0} Always: Windows Update with drivers, restore point first, activation check, graphics-card app, PC-brand tool (you're asked), Windows 10 ESU reminder." -f $bullet))
    $lines.Add('Everything can still be ticked or unticked on the new PC before DayZero starts.')
    return ($lines -join $nl)
}

function Get-DzDebloatLevelSummary {
    <# Plain-text "what this clean-up level does" for the builder. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][hashtable]$Config, [Parameter(Mandatory = $true)][string]$LevelId)
    $nl = [Environment]::NewLine
    $bullet = [string][char]0x2022
    $level = Get-DzDebloatLevel -Config $Config -Id $LevelId
    if ($null -eq $level) { return "Unknown clean-up level '$LevelId'." }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add($level.description)
    if ($level.rank -eq 0) {
        $lines.Add('You can still tick single privacy tweaks on the new PC.')
        return ($lines -join $nl)
    }
    $titles = foreach ($id in $level.tweaks) {
        $t = Get-DzCatalogItem -Catalog $Config.tweaks -Collection 'tweaks' -Id $id
        if ($t) { [string]$t.title }
    }
    if (@($titles).Count -gt 0) { $lines.Add(("{0} Changes: {1}" -f $bullet, (@($titles) -join '; '))) }
    $apps = @(Get-DzProperty $Config.debloat 'packages' @() | Where-Object {
            $l = Get-DzDebloatLevel -Config $Config -Id ([string](Get-DzProperty $_ 'level' ''))
            $l -and $l.rank -le $level.rank
        } | ForEach-Object { ([string]$_.title) -replace '\s*\(.*\)$', '' })
    if ($apps.Count -gt 0) { $lines.Add(("{0} Removes {1} preinstalled app(s): {2}" -f $bullet, $apps.Count, ($apps -join ', '))) }
    foreach ($rid in $level.removals) {
        $r = @(Get-DzProperty $Config.debloat 'optionalRemovals' @()) | Where-Object { $_.id -eq $rid } | Select-Object -First 1
        if ($r) { $lines.Add(("{0} {1}" -f $bullet, $r.title)) }
    }
    $lines.Add(("{0} Never removed: Microsoft Store, Calculator, Photos, Notepad, Paint, Snipping Tool, Camera, Clock, Sticky Notes, Xbox apps, Windows Security." -f $bullet))
    $lines.Add("Based on Chris Titus Tech's WinUtil presets. Every change is recorded and undone by DayZero.cmd -Undo.")
    return ($lines -join $nl)
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

    $explicit = $opt.ContainsKey('explicitTweaks') -and [bool]$opt.explicitTweaks
    $levelId = $null
    if ($opt.ContainsKey('debloat')) { $levelId = Resolve-DzDebloatLevelId -Config $Config -Id ([string]$opt.debloat) }
    if (-not $levelId) { $levelId = Resolve-DzDebloatLevelId -Config $Config -Id ([string](Get-DzProperty $Mode 'debloat' '')) }
    if (-not $levelId -and $Config.debloat) { $levelId = Get-DzDefaultDebloatLevel -Config $Config }
    $level = if ($levelId) { Get-DzDebloatLevel -Config $Config -Id $levelId } else { $null }
    if ($level -and $level.rank -gt 0) {
        $keepApps = @($(if ($opt.ContainsKey('apps')) { $opt.apps } else { @() }) | Where-Object { $_ })
        & $add 'debloat' ("Remove preinstalled apps ({0} clean-up)" -f $level.title) 'debloat' 'Tweaks' @{ level = $level.id; keepApps = $keepApps } @('restorePoint')
    }
    $removalIds = New-Object System.Collections.Generic.List[string]
    foreach ($rid in @($(if ($opt.ContainsKey('removals')) { $opt.removals } else { @() }))) { if ($rid -and -not $removalIds.Contains([string]$rid)) { $removalIds.Add([string]$rid) } }
    if (-not $explicit -and $level) { foreach ($rid in @($level.removals)) { if (-not $removalIds.Contains([string]$rid)) { $removalIds.Add([string]$rid) } } }
    foreach ($rid in $removalIds) {
        $r = @(Get-DzProperty $Config.debloat 'optionalRemovals' @()) | Where-Object { $_.id -eq $rid } | Select-Object -First 1
        if ($r) { & $add "remove:$rid" ([string]$r.title) 'removal' 'Tweaks' @{ id = $rid } @('restorePoint') }
    }

    $tweakIds = New-Object System.Collections.Generic.List[string]
    if (-not $explicit) {
        foreach ($t in @($Mode.tweaks)) {
            $item = Get-DzCatalogItem -Catalog $Config.tweaks -Collection 'tweaks' -Id $t
            if ($item -and -not [bool](Get-DzProperty $item 'optional' $false) -and -not $tweakIds.Contains($t)) { $tweakIds.Add($t) }
        }
        if ($level) { foreach ($t in @($level.tweaks)) { if (-not $tweakIds.Contains([string]$t)) { $tweakIds.Add([string]$t) } } }
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
        if ([string](Get-DzProperty $item 'kind' '') -eq 'office') { continue }   # Microsoft 365 has its own step
        & $add "app:$a" ("Install {0}" -f $item.name) 'app' 'Apps' @{ id = $a } @('internet', 'winget')
    }
    $office = if ($opt.ContainsKey('office')) { [bool]$opt.office } else { [bool]$Mode.office }
    if ($office) { & $add 'office' 'Install Microsoft 365 Apps' 'office' 'Apps' @{} @('internet') }

    # Your own scripts: after the apps, before the late clean-up (so their temp files go too).
    if ($opt.ContainsKey('userScripts') -and [bool]$opt.userScripts) { & $add 'user-scripts' 'Run your own scripts' 'userScripts' 'Apps' }
    foreach ($item in $late) { & $add "tweak:$($item.id)" ([string]$item.title) 'tweak' 'Tweaks' @{ id = [string]$item.id } @('restorePoint') }
    & $add 'windows-update-final' 'Final Windows Update check' 'windowsUpdate' 'Windows' @{ final = $true } @('internet')

    return , $steps.ToArray()
}

Export-ModuleMember -Function @(
    'Test-DzApplicable', 'Test-DzInMode', 'Get-DzSelectionValue', 'Get-DzReviewModel', 'Set-DzReviewLevel', 'Get-DzModeSummary',
    'Get-DzDebloatLevelSummary', 'ConvertTo-DzPlanOption', 'New-DzPlan'
)
