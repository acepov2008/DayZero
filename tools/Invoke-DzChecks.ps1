#Requires -Version 5.1
<#
.SYNOPSIS
    Runs all DayZero tests and static checks.
.DESCRIPTION
    Works on Windows PowerShell 5.1 and PowerShell 7 (Windows, Linux, macOS).
    Needs Pester 5 or newer. Windows ships an old Pester 3.4, so install a current one once:
        Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck
    Optional, for the PowerShell 5.1 compatibility analysis:
        Install-Module PSScriptAnalyzer -Scope CurrentUser -Force
.EXAMPLE
    .\tools\Invoke-DzChecks.ps1
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCompatibleCommands', '', Justification = 'Needs Pester 5+, not the Pester 3.4 that ships with Windows; checked below.')]
[CmdletBinding()]
param([string]$Output = 'Detailed')

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$pester = Get-Module -ListAvailable Pester | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester -or $pester.Version.Major -lt 5) {
    throw 'Pester 5 or newer is required: Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck'
}
Import-Module $pester.Path -Force

$config = New-PesterConfiguration
$config.Run.Path = (Join-Path $repo 'tests')
$config.Run.Exit = $true
$config.Output.Verbosity = $Output
Invoke-Pester -Configuration $config
