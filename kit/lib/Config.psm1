#Requires -Version 5.1
<#
    DayZero - loads and checks the editable JSON configuration in <kit>\config:

      modes.json     what each mode (gaming / office / everything) does
      apps.json      app catalog (winget IDs)                        [stage 3]
      office.json    Microsoft 365 Apps install settings              [stage 3]
      tweaks.json    documented, reversible tweaks                    [stage 4]
      debloat.json   preinstalled apps that may be removed            [stage 4]
      drivers.json   GPU vendor apps and PC-brand update tools        [stage 5]

    Missing files are fine (that part is simply skipped). Test-DzConfig reports broken
    references, so a typo in a JSON file shows up in the log instead of failing silently.
#>

Set-StrictMode -Version 2.0

$script:ConfigFiles = @('modes', 'apps', 'office', 'tweaks', 'debloat', 'drivers')

function Get-DzConfig {
    <# Returns a hashtable: modes, apps, office, tweaks, debloat, drivers (each $null if absent). #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory = $true)][string]$KitRoot)
    $config = @{}
    foreach ($name in $script:ConfigFiles) {
        $path = [System.IO.Path]::Combine($KitRoot, 'config', "$name.json")
        $config[$name] = $null
        if (Test-Path -LiteralPath $path) {
            try { $config[$name] = Read-DzJsonFile -Path $path }
            catch { throw "config\$name.json is not valid JSON: $($_.Exception.Message)" }
        }
    }
    return $config
}

function Get-DzProperty {
    <# Reads a property that may be missing (StrictMode-safe). #>
    [CmdletBinding()]
    param([AllowNull()][object]$Object, [Parameter(Mandatory = $true)][string]$Name, [AllowNull()][object]$Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $Default }
    return $p.Value
}

function Get-DzModeList {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Config)
    if ($null -eq $Config.modes) { return @() }
    return @($Config.modes.modes)
}

function Get-DzMode {
    <#
        Returns one mode with "includes" resolved: Everything = Gaming + Office + its own
        extras. Apps and tweaks are de-duplicated, in order. debloat is the mode's suggested
        clean-up level (the most thorough of its parts, '' when none is set); the builder's
        choice overrides it. office is on if any part has it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][string]$Id
    )
    $all = Get-DzModeList -Config $Config
    $visited = New-Object System.Collections.Generic.List[string]
    $apps = New-Object System.Collections.Generic.List[string]
    $tweaks = New-Object System.Collections.Generic.List[string]
    $state = @{ debloat = ''; office = $false }
    $rank = @{}
    foreach ($l in @(Get-DzDebloatLevelList -Config $Config)) { $rank[[string]$l.id] = [int]$l.rank }

    $collect = $null
    $collect = {
        param([string]$ModeId)
        if ($visited.Contains($ModeId)) { return }
        $visited.Add($ModeId)
        $m = @($all | Where-Object { $_.id -eq $ModeId }) | Select-Object -First 1
        if ($null -eq $m) { throw "Unknown mode '$ModeId' in modes.json." }
        foreach ($inc in @(Get-DzProperty $m 'includes' @())) { & $collect $inc }
        foreach ($a in @(Get-DzProperty $m 'apps' @())) { if (-not $apps.Contains($a)) { $apps.Add($a) } }
        foreach ($t in @(Get-DzProperty $m 'tweaks' @())) { if (-not $tweaks.Contains($t)) { $tweaks.Add($t) } }
        $d = Resolve-DzDebloatLevelId -Config $Config -Id ([string](Get-DzProperty $m 'debloat' ''))
        if ($d -and ($state.debloat -eq '' -or $rank[$d] -gt $rank[$state.debloat])) { $state.debloat = $d }
        if ([bool](Get-DzProperty $m 'office' $false)) { $state.office = $true }
    }
    & $collect $Id

    $mode = @($all | Where-Object { $_.id -eq $Id })[0]
    return [pscustomobject]@{
        id          = $Id
        title       = [string](Get-DzProperty $mode 'title' $Id)
        emoji       = [string](Get-DzProperty $mode 'emoji' '')
        tagline     = [string](Get-DzProperty $mode 'tagline' '')
        description = [string](Get-DzProperty $mode 'description' '')
        highlights  = @(Get-DzProperty $mode 'highlights' @())
        custom      = [bool](Get-DzProperty $mode 'custom' $false)
        modeIds     = $visited.ToArray()
        apps        = $apps.ToArray()
        tweaks      = $tweaks.ToArray()
        debloat     = $state.debloat
        office      = $state.office
    }
}

# ---------------------------------------------------------------------------------------
# Clean-up levels (debloat.json), modelled on WinUtil's Clear / Minimal / Standard / Advanced
# ---------------------------------------------------------------------------------------

$script:BuiltInLevelAliases = @{ none = 'clear'; light = 'minimal'; full = 'standard' }

function Get-DzDebloatLevelList {
    <#
        The clean-up levels in order. Each level also does what the levels before it do, so
        tweaks and removals here are cumulative. rank: 0 = the first level (Clear).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Config)
    $tweaks = New-Object System.Collections.Generic.List[string]
    $removals = New-Object System.Collections.Generic.List[string]
    $out = New-Object System.Collections.Generic.List[object]
    $rank = 0
    foreach ($l in @(Get-DzProperty $Config.debloat 'levels' @())) {
        if ($null -eq $l) { continue }
        foreach ($t in @(Get-DzProperty $l 'tweaks' @())) { if ($t -and -not $tweaks.Contains([string]$t)) { $tweaks.Add([string]$t) } }
        foreach ($r in @(Get-DzProperty $l 'removals' @())) { if ($r -and -not $removals.Contains([string]$r)) { $removals.Add([string]$r) } }
        $out.Add([pscustomobject]@{
                id          = [string]$l.id
                title       = [string](Get-DzProperty $l 'title' $l.id)
                tagline     = [string](Get-DzProperty $l 'tagline' '')
                description = [string](Get-DzProperty $l 'description' '')
                rank        = $rank
                ownTweaks   = @(Get-DzProperty $l 'tweaks' @())
                tweaks      = $tweaks.ToArray()
                removals    = $removals.ToArray()
            })
        $rank++
    }
    # No leading comma: callers wrap the result in @().
    return $out.ToArray()
}

function Resolve-DzDebloatLevelId {
    <# A level id (or an old name: none / light / full) -> the level's id; $null when unknown or empty. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][hashtable]$Config, [AllowNull()][AllowEmptyString()][string]$Id)
    if (-not $Id) { return $null }
    $ids = @(Get-DzDebloatLevelList -Config $Config | ForEach-Object { $_.id })
    $match = @($ids | Where-Object { $_ -ieq $Id }) | Select-Object -First 1
    if ($match) { return [string]$match }
    $alias = Get-DzProperty (Get-DzProperty $Config.debloat 'aliases' $null) $Id.ToLowerInvariant() $null
    if (-not $alias -and $script:BuiltInLevelAliases.ContainsKey($Id.ToLowerInvariant())) { $alias = $script:BuiltInLevelAliases[$Id.ToLowerInvariant()] }
    if ($alias -and ($ids -contains [string]$alias)) { return [string]$alias }
    return $null
}

function Get-DzDefaultDebloatLevel {
    <# debloat.json defaultLevel, or the first level. $null when there are no levels. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][hashtable]$Config)
    $d = Resolve-DzDebloatLevelId -Config $Config -Id ([string](Get-DzProperty $Config.debloat 'defaultLevel' ''))
    if ($d) { return $d }
    $first = @(Get-DzDebloatLevelList -Config $Config) | Select-Object -First 1
    if ($first) { return [string]$first.id }
    return $null
}

function Get-DzDebloatLevel {
    <# One level (cumulative tweaks / removals), by id or old name; $null when unknown. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Config, [AllowNull()][AllowEmptyString()][string]$Id)
    $resolved = Resolve-DzDebloatLevelId -Config $Config -Id $Id
    if (-not $resolved) { return $null }
    return (@(Get-DzDebloatLevelList -Config $Config | Where-Object { $_.id -eq $resolved }) | Select-Object -First 1)
}

function Get-DzCatalogItem {
    <# Finds an item by id in a config catalog (apps.json "apps", tweaks.json "tweaks", ...). #>
    [CmdletBinding()]
    param([AllowNull()][object]$Catalog, [Parameter(Mandatory = $true)][string]$Collection, [Parameter(Mandatory = $true)][string]$Id)
    if ($null -eq $Catalog) { return $null }
    return (@(Get-DzProperty $Catalog $Collection @()) | Where-Object { $_.id -eq $Id } | Select-Object -First 1)
}

function Test-DzConfig {
    <# Returns a list of human-readable problems (empty when the configuration is consistent). #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory = $true)][hashtable]$Config)
    $problems = New-Object System.Collections.Generic.List[string]
    $modes = Get-DzModeList -Config $Config
    if ($modes.Count -eq 0) { $problems.Add('modes.json is missing or has no modes.') }

    $checkUnique = {
        param($Items, [string]$What)
        $seen = @{}
        foreach ($i in @($Items)) {
            $id = [string](Get-DzProperty $i 'id' '')
            if (-not $id) { $problems.Add("$What entry without an id."); continue }
            if ($seen.ContainsKey($id)) { $problems.Add("$What id '$id' is used twice.") }
            $seen[$id] = $true
        }
    }
    & $checkUnique $modes 'Mode'

    $appIds = @{}
    if ($Config.apps) {
        & $checkUnique $Config.apps.apps 'App'
        $categoryIds = @{}
        foreach ($c in @(Get-DzProperty $Config.apps 'categories' @())) { $categoryIds[[string]$c.id] = $true }
        foreach ($a in @($Config.apps.apps)) {
            $appIds[[string]$a.id] = $true
            $cat = [string](Get-DzProperty $a 'category' '')
            if ($categoryIds.Count -gt 0 -and -not $categoryIds.ContainsKey($cat)) { $problems.Add("App '$($a.id)' has unknown category '$cat'.") }
            $kind = [string](Get-DzProperty $a 'kind' '')
            if ($kind -ne 'office' -and -not (Get-DzProperty $a 'winget' '') -and -not (Get-DzProperty $a 'msstore' '')) {
                $problems.Add("App '$($a.id)' has no winget or msstore id.")
            }
        }
    }
    $tweakIds = @{}
    if ($Config.tweaks) {
        & $checkUnique $Config.tweaks.tweaks 'Tweak'
        foreach ($t in @($Config.tweaks.tweaks)) { $tweakIds[[string]$t.id] = $true }
    }
    $modeIds = @{}
    foreach ($m in $modes) { $modeIds[[string]$m.id] = $true }

    foreach ($m in $modes) {
        foreach ($inc in @(Get-DzProperty $m 'includes' @())) {
            if (-not $modeIds.ContainsKey([string]$inc)) { $problems.Add("Mode '$($m.id)' includes unknown mode '$inc'.") }
        }
        if ($Config.apps) {
            foreach ($a in @(Get-DzProperty $m 'apps' @())) {
                if (-not $appIds.ContainsKey([string]$a)) { $problems.Add("Mode '$($m.id)' lists unknown app '$a'.") }
            }
        }
        if ($Config.tweaks) {
            foreach ($t in @(Get-DzProperty $m 'tweaks' @())) {
                if (-not $tweakIds.ContainsKey([string]$t)) { $problems.Add("Mode '$($m.id)' lists unknown tweak '$t'.") }
            }
        }
        $d = [string](Get-DzProperty $m 'debloat' '')
        if ($d -and $Config.debloat -and -not (Resolve-DzDebloatLevelId -Config $Config -Id $d)) { $problems.Add("Mode '$($m.id)' has unknown clean-up level '$d'.") }
    }
    if ($Config.debloat) {
        $levels = @(Get-DzDebloatLevelList -Config $Config)
        $levelIds = @($levels | ForEach-Object { $_.id })
        if ($levels.Count -eq 0) { $problems.Add('debloat.json has no levels.') }
        if (@($levelIds | Group-Object | Where-Object { $_.Count -gt 1 }).Count -gt 0) { $problems.Add('debloat.json has duplicate level ids.') }
        $dl = [string](Get-DzProperty $Config.debloat 'defaultLevel' '')
        if ($dl -and -not (Resolve-DzDebloatLevelId -Config $Config -Id $dl)) { $problems.Add("debloat.json defaultLevel '$dl' is not a level.") }
        $removalIds = @(@(Get-DzProperty $Config.debloat 'optionalRemovals' @()) | ForEach-Object { [string]$_.id })
        foreach ($l in @(Get-DzProperty $Config.debloat 'levels' @())) {
            if ($Config.tweaks) {
                foreach ($t in @(Get-DzProperty $l 'tweaks' @())) { if (-not $tweakIds.ContainsKey([string]$t)) { $problems.Add("Clean-up level '$($l.id)' lists unknown tweak '$t'.") } }
            }
            foreach ($r in @(Get-DzProperty $l 'removals' @())) { if ($removalIds -notcontains [string]$r) { $problems.Add("Clean-up level '$($l.id)' lists unknown removal '$r'.") } }
        }
        foreach ($p in @(Get-DzProperty $Config.debloat 'packages' @())) {
            $pl = [string](Get-DzProperty $p 'level' '')
            if ($levelIds -notcontains $pl) { $problems.Add("debloat.json package '$($p.name)' has unknown level '$pl'.") }
            $ua = [string](Get-DzProperty $p 'unlessApp' '')
            if ($ua -and $Config.apps -and -not $appIds.ContainsKey($ua)) { $problems.Add("debloat.json package '$($p.name)' refers to unknown app '$ua'.") }
        }
    }
    if ($modes.Count -gt 0) {
        $default = [string](Get-DzProperty $Config.modes 'defaultMode' '')
        if ($default -and -not $modeIds.ContainsKey($default)) { $problems.Add("defaultMode '$default' is not a mode.") }
        foreach ($m in $modes) {
            try { [void](Get-DzMode -Config $Config -Id $m.id) } catch { $problems.Add($_.Exception.Message) }
        }
    }
    return , $problems.ToArray()
}

Export-ModuleMember -Function @(
    'Get-DzConfig', 'Get-DzProperty', 'Get-DzModeList', 'Get-DzMode', 'Get-DzCatalogItem', 'Test-DzConfig',
    'Get-DzDebloatLevelList', 'Resolve-DzDebloatLevelId', 'Get-DzDefaultDebloatLevel', 'Get-DzDebloatLevel'
)
