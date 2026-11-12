#Requires -Version 5.1
<#
.SYNOPSIS
    Checks every winget package id DayZero uses (apps.json, drivers.json, office.json).
.DESCRIPTION
    Runs 'winget show --id <id> --exact' for each one on this PC. A missing id gets a
    'winget search' by name so you can see what to put in the JSON instead.
    Needs winget (App Installer). Read-only: nothing is installed.
.EXAMPLE
    .\tools\Test-DzAppIds.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$lib = Join-Path $repo 'kit\lib'
foreach ($m in 'Core.psm1', 'Config.psm1', 'Engine.psm1', 'Download.psm1', 'Winget.psm1') { Import-Module (Join-Path $lib $m) -Force -DisableNameChecking }
Import-Module (Join-Path $repo 'builder\lib\Bundles.psm1') -Force

$winget = Find-DzWinget
if (-not $winget) { throw 'winget was not found. Install or update "App Installer" from the Microsoft Store.' }
Write-Output ("Using {0} ({1})" -f $winget, (Get-DzWingetVersion -WingetPath $winget))

$config = Get-DzConfig -KitRoot (Join-Path $repo 'kit')
$items = Get-DzCatalogPackageList -Config $config
$results = Test-DzAppCatalog -WingetPath $winget -Items $items -Log { param($line) Write-Output $line }
$missing = @($results | Where-Object { -not $_.Found })
Write-Output ''
Write-Output ("{0} of {1} ids found." -f ($results.Count - $missing.Count), $results.Count)
if ($missing.Count -gt 0) { exit 1 }
