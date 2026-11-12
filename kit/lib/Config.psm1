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
        extras. Apps and tweaks are de-duplicated, in order. Debloat takes the most
        thorough profile ('full' beats 'light'); office is on if any part has it.
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
    $state = @{ debloat = 'none'; office = $false }

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
        $d = [string](Get-DzProperty $m 'debloat' 'none')
        $rank = @{ none = 0; light = 1; full = 2 }
        if ($rank.ContainsKey($d) -and $rank[$d] -gt $rank[$state.debloat]) { $state.debloat = $d }
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
        $d = [string](Get-DzProperty $m 'debloat' 'none')
        if ($d -notin @('none', 'light', 'full')) { $problems.Add("Mode '$($m.id)' has unknown debloat profile '$d'.") }
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

Export-ModuleMember -Function @('Get-DzConfig', 'Get-DzProperty', 'Get-DzModeList', 'Get-DzMode', 'Get-DzCatalogItem', 'Test-DzConfig')
