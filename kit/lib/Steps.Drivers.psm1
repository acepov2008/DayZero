#Requires -Version 5.1
<#
    DayZero - driver steps: Drivers\ folder, Windows Update (first pass and final check),
    graphics-card app and PC-brand update tool.
#>

Set-StrictMode -Version 2.0

function Invoke-DzStepDriversFolder {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    return (Install-DzDriverFolder -Context $Context)
}

function Invoke-DzStepWindowsUpdate {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    return (Invoke-DzWindowsUpdate -Context $Context -Final ([bool](Get-DzStepArg -Context $Context -Name 'final' -Default $false)))
}

function Invoke-DzStepGpuApp {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $vendor = [string](Get-DzStepArg -Context $Context -Name 'vendor')
    $item = @(Get-DzProperty $Context.Config.drivers 'gpuApps' @()) | Where-Object { $_.vendor -eq $vendor } | Select-Object -First 1
    if ($null -eq $item) { return (New-DzStepResult -Status Skipped -Message "No app configured for $vendor graphics.") }
    return (Install-DzVendorApp -Context $Context -Item $item)
}

function Invoke-DzStepOemTool {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $brand = [string](Get-DzStepArg -Context $Context -Name 'brand')
    $item = @(Get-DzProperty $Context.Config.drivers 'oemTools' @()) | Where-Object { $_.brand -eq $brand } | Select-Object -First 1
    if ($null -eq $item) { return (New-DzStepResult -Status Skipped -Message "No update tool configured for $brand.") }
    return (Install-DzVendorApp -Context $Context -Item $item)
}

Register-DzStepType -Type 'driversFolder' -Command 'Invoke-DzStepDriversFolder'
Register-DzStepType -Type 'windowsUpdate' -Command 'Invoke-DzStepWindowsUpdate'
Register-DzStepType -Type 'gpuApp' -Command 'Invoke-DzStepGpuApp'
Register-DzStepType -Type 'oemTool' -Command 'Invoke-DzStepOemTool'

Export-ModuleMember -Function @('Invoke-DzStepDriversFolder', 'Invoke-DzStepWindowsUpdate', 'Invoke-DzStepGpuApp', 'Invoke-DzStepOemTool')
