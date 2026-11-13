#Requires -Version 5.1
<#
    DayZero - the user's own scripts: every .cmd, .bat and .ps1 in C:\DayZero\Scripts
    (copied from the stick's DayZero\Scripts), run as administrator after the apps, in
    name order, each in its own visible window. Nothing here runs a script DayZero did
    not get from that folder.
#>

Set-StrictMode -Version 2.0

$script:ScriptExtensions = @('.cmd', '.bat', '.ps1')

function Get-DzUserScriptFolder {
    <# C:\DayZero\Scripts, or the stick's DayZero\Scripts when the local copy has no scripts. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$KitRoot, [AllowNull()][AllowEmptyString()][string]$BuildId = '')
    $local = Join-Path $KitRoot 'Scripts'
    if (@(Get-DzUserScript -Folder $local).Count -gt 0) { return $local }
    $usb = Find-DzUsbKit -BuildId $BuildId
    if ($usb) {
        $onStick = Join-Path $usb 'Scripts'
        if (@(Get-DzUserScript -Folder $onStick).Count -gt 0) { return $onStick }
    }
    return $local
}

function Get-DzUserScript {
    <# The scripts in a folder (top level only), sorted by name. #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Folder)
    if (-not $Folder -or -not (Test-Path -LiteralPath $Folder)) { return @() }
    return @(Get-ChildItem -LiteralPath $Folder -File -ErrorAction SilentlyContinue |
            Where-Object { $script:ScriptExtensions -contains $_.Extension.ToLowerInvariant() } |
            Sort-Object -Property Name)
}

function Get-DzScriptCommand {
    <# How a script is started: @{ FilePath; Arguments }. Pure. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([System.IO.Path]::GetExtension($Path).ToLowerInvariant() -eq '.ps1') {
        return [pscustomobject]@{ FilePath = 'powershell.exe'; Arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $Path)) }
    }
    return [pscustomobject]@{ FilePath = 'cmd.exe'; Arguments = @('/c', ('"{0}"' -f $Path)) }
}

function Start-DzUserScript {
    <# Runs one script in its own window and waits (at most -TimeoutSec). Returns @{ ExitCode; TimedOut }. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [int]$TimeoutSec = 7200)
    $cmd = Get-DzScriptCommand -Path $Path
    $p = Start-Process -FilePath $cmd.FilePath -ArgumentList $cmd.Arguments -WorkingDirectory (Split-Path -Parent $Path) -PassThru
    if (-not $p.WaitForExit([Math]::Max(1, $TimeoutSec) * 1000)) { return [pscustomobject]@{ ExitCode = $null; TimedOut = $true } }
    return [pscustomobject]@{ ExitCode = [int]$p.ExitCode; TimedOut = $false }
}

function Invoke-DzUserScripts {
    <# The 'userScripts' step: runs every script, carries on after a failure. Returns a step result. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $buildId = if ($Context.Settings) { [string](Get-DzProperty $Context.Settings 'buildId' '') } else { '' }
    $folder = Get-DzUserScriptFolder -KitRoot $Context.KitRoot -BuildId $buildId
    $scripts = @(Get-DzUserScript -Folder $folder)
    if ($scripts.Count -eq 0) { return (New-DzStepResult -Status Skipped -Message 'No scripts in the Scripts folder.') }
    $problems = New-Object System.Collections.Generic.List[string]
    foreach ($s in $scripts) {
        if ($Context.Progress) { & $Context.Progress ("Running your script {0} ..." -f $s.Name) }
        $r = Invoke-DzAction -Description ("Run your script {0}" -f $s.FullName) -Action { Start-DzUserScript -Path $s.FullName }
        if ($null -eq $r) { continue }   # dry run
        if ($r.TimedOut) { $problems.Add(("{0}: still running after 2 hours, DayZero moved on" -f $s.Name)); continue }
        Write-DzLog -Message ("Script {0} finished with exit code {1}." -f $s.Name, $r.ExitCode)
        if ($r.ExitCode -ne 0) { $problems.Add(("{0}: exit code {1}" -f $s.Name, $r.ExitCode)) }
    }
    $names = ($scripts | ForEach-Object { $_.Name }) -join ', '
    if (Test-DzDryRun) { return (New-DzStepResult -Status Done -Message ("[DRY-RUN] would run {0}." -f $names)) }
    if ($problems.Count -gt 0) { return (New-DzStepResult -Status Warn -Message ("Ran {0}. Problems: {1}." -f $names, ($problems -join '; '))) }
    return (New-DzStepResult -Status Done -Message ("Ran {0}." -f $names))
}

Register-DzStepType -Type 'userScripts' -Command 'Invoke-DzUserScripts'

Export-ModuleMember -Function @('Get-DzUserScriptFolder', 'Get-DzUserScript', 'Get-DzScriptCommand', 'Start-DzUserScript', 'Invoke-DzUserScripts')
