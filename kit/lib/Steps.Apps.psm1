#Requires -Version 5.1
<#
    DayZero - app steps: "Get winget ready", one step per app, and Microsoft 365.
    Also registers the 'winget' requirement used by every app step.
#>

Set-StrictMode -Version 2.0

function Invoke-DzStepWinget {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $r = Initialize-DzWinget -Context $Context
    if ($r.Ok) { return (New-DzStepResult -Status Done -Message $r.Message) }
    return (New-DzStepResult -Status Failed -Message $r.Message)
}

function Invoke-DzStepApp {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $id = [string](Get-DzStepArg -Context $Context -Name 'id')
    $app = Get-DzCatalogItem -Catalog $Context.Config.apps -Collection 'apps' -Id $id
    if ($null -eq $app) { return (New-DzStepResult -Status Failed -Message "App '$id' is not in config\apps.json.") }
    $source = [string](Get-DzProperty $app 'source' 'winget')
    $package = if ($source -eq 'msstore') { [string](Get-DzProperty $app 'msstore' '') } else { [string](Get-DzProperty $app 'winget' '') }
    if (-not $package) { return (New-DzStepResult -Status Failed -Message "App '$id' has no package id in config\apps.json.") }
    return (Install-DzWingetPackage -Context $Context -Id $package -Name ([string]$app.name) -Source $source `
            -Elevated ([bool](Get-DzProperty $app 'elevated' $true)) -Scope ([string](Get-DzProperty $app 'scope' '')))
}

function Invoke-DzStepOffice {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    return (Install-DzOffice -Context $Context)
}

Register-DzStepType -Type 'winget' -Command 'Invoke-DzStepWinget'
Register-DzStepType -Type 'app' -Command 'Invoke-DzStepApp'
Register-DzStepType -Type 'office' -Command 'Invoke-DzStepOffice'

Register-DzRequirement -Name 'winget' -Check {
    param($Context)
    if ($Context.Flags['WingetPath']) { return $null }
    if ($Context.DryRun -and $Context.Flags['WingetDry']) { return $null }
    $path = Find-DzWinget
    if ($path -and (Get-DzWingetVersion -WingetPath $path)) { $Context.Flags['WingetPath'] = $path; return $null }
    if ($Context.DryRun) { return $null }
    return 'winget is not available yet (see "Get winget ready").'
}

Export-ModuleMember -Function @('Invoke-DzStepWinget', 'Invoke-DzStepApp', 'Invoke-DzStepOffice')
