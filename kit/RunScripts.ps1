#Requires -Version 5.1
<#
    DayZero - runs your own scripts again (C:\DayZero\Scripts), the same way the setup
    did: in name order, each in its own window, as administrator. Started by the
    "Run my scripts" button on the summary screen, or by RunScripts.cmd.
#>
param([string]$Folder = (Join-Path $PSScriptRoot 'Scripts'))

$scripts = @(Get-ChildItem -LiteralPath $Folder -File -ErrorAction SilentlyContinue |
        Where-Object { @('.cmd', '.bat', '.ps1') -contains $_.Extension.ToLowerInvariant() } | Sort-Object -Property Name)
if ($scripts.Count -eq 0) { Write-Output "No scripts in $Folder"; Read-Host 'Press Enter to close'; return }
foreach ($s in $scripts) {
    Write-Output ("Running {0} ..." -f $s.Name)
    if ($s.Extension -ieq '.ps1') { $exe = 'powershell.exe'; $scriptArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $s.FullName)) }
    else { $exe = 'cmd.exe'; $scriptArgs = @('/c', ('"{0}"' -f $s.FullName)) }
    $p = Start-Process -FilePath $exe -ArgumentList $scriptArgs -WorkingDirectory $Folder -PassThru -Wait
    Write-Output ("  finished, exit code {0}" -f $p.ExitCode)
}
Read-Host 'All scripts finished. Press Enter to close'
