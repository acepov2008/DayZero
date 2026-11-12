#Requires -Version 5.1
<#
    DayZero - applies the documented tweaks from config\tweaks.json and undoes them.

    Every change is recorded in <kit>\backup\tweaks.json BEFORE it is made: the registry
    value's old data and type, or the fact that it did not exist; the previous power plan.
    Undo-DzTweak walks that list backwards and restores it.

    Hard safety rules, enforced here whatever the JSON says:
      * no registry path that belongs to Windows Update or Microsoft Defender
      * only the action types below (no services, no scripts)
#>

Set-StrictMode -Version 2.0

$script:ProtectedPatterns = @(
    '\\WindowsUpdate(\\|$)', '\\Windows Defender', '\\WinDefend', '\\wuauserv', '\\UsoSvc', '\\WaaSMedicSvc',
    '\\SecurityHealthService', '\\Sense(\\|$)', '\\WdNisSvc', '\\WdFilter', '\\MpsSvc', '\\mpssvc', '\\Microsoft Antimalware'
)
$script:ActionTypes = @('registry', 'powerPlan', 'startupDisable')
$script:ValueKinds = @('DWord', 'QWord', 'String', 'ExpandString', 'Binary', 'MultiString')
$script:UltimateTemplate = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
$script:HighPerformance = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$script:Balanced = '381b4222-f694-41f0-9685-ff5bb260df2e'
$script:GuidPattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
$script:StartupKeys = @(
    @{ Run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' },
    @{ Run = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' },
    @{ Run = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32' }
)
# StartupApproved data: first byte 02 = enabled, 03 = disabled (what Task Manager writes).
$script:StartupDisabledBytes = [byte[]](3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

# ---------------------------------------------------------------------------------------
# Safety + registry access (small functions so tests can replace them)
# ---------------------------------------------------------------------------------------

function Test-DzProtectedRegistryPath {
    <# True when a path belongs to Windows Update or Defender (DayZero never writes there). #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][string]$Path)
    foreach ($p in $script:ProtectedPatterns) { if ($Path -match $p) { return $true } }
    return $false
}

function Get-DzRegistryValue {
    <# @{ Exists; Value; Kind } for one registry value. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Name)
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{ Exists = $false; Value = $null; Kind = $null } }
    $key = Get-Item -LiteralPath $Path
    if (@($key.GetValueNames()) -notcontains $Name) { return [pscustomobject]@{ Exists = $false; Value = $null; Kind = $null } }
    $value = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    return [pscustomobject]@{ Exists = $true; Value = $value; Kind = [string]$key.GetValueKind($Name) }
}

function Set-DzRegistryValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Kind
    )
    if (Test-DzProtectedRegistryPath -Path $Path) { throw "Refusing to change $Path : DayZero never touches Windows Update or Defender settings." }
    if (-not (Test-Path -LiteralPath $Path)) { [void](New-Item -Path $Path -Force) }
    [void](New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Kind -Force)
}

function Remove-DzRegistryValue {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Name)
    if (Test-DzProtectedRegistryPath -Path $Path) { throw "Refusing to change $Path : DayZero never touches Windows Update or Defender settings." }
    if (Test-Path -LiteralPath $Path) { Remove-ItemProperty -LiteralPath $Path -Name $Name -Force -ErrorAction SilentlyContinue }
}

function Get-DzRegistryValueName {
    <# Value names under a key ($null-safe). #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @((Get-Item -LiteralPath $Path).GetValueNames())
}

function ConvertTo-DzStoredValue {
    <# Registry data -> JSON-safe form (binary as base64, multi-string as array). #>
    param([AllowNull()][object]$Value, [AllowNull()][string]$Kind)
    if ($null -eq $Value) { return $null }
    if ($Kind -eq 'Binary') { return [Convert]::ToBase64String([byte[]]$Value) }
    if ($Kind -eq 'MultiString') { return @($Value) }
    if ($Kind -eq 'DWord' -or $Kind -eq 'QWord') { return [int64]$Value }
    return [string]$Value
}

function ConvertFrom-DzStoredValue {
    param([AllowNull()][object]$Value, [AllowNull()][string]$Kind)
    if ($null -eq $Value) { return $null }
    switch ($Kind) {
        'Binary' { return , [Convert]::FromBase64String([string]$Value) }
        'MultiString' { return , [string[]]@($Value) }
        'DWord' { return [int]$Value }
        'QWord' { return [int64]$Value }
        default { return [string]$Value }
    }
}

# ---------------------------------------------------------------------------------------
# Backup file
# ---------------------------------------------------------------------------------------

function Get-DzBackupPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Name)
    return [System.IO.Path]::Combine((Get-DzKitRoot), 'backup', "$Name.json")
}

function Read-DzBackup {
    <# Returns the list of entries in backup\<Name>.json (empty when there is none). #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)
    $path = Get-DzBackupPath -Name $Name
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    $data = Read-DzJsonFile -Path $path
    # No leading comma: callers wrap the result in @(), so an empty backup must count as 0.
    return @($data.entries | Where-Object { $null -ne $_ })
}

function Add-DzBackupEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][object]$Entry)
    $path = Get-DzBackupPath -Name $Name
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($e in (Read-DzBackup -Name $Name)) { $entries.Add($e) }
    $entries.Add($Entry)
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $json = [ordered]@{ note = 'Written by DayZero. DayZero.cmd -Undo uses this file to put things back.'; entries = $entries.ToArray() } | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Close-DzBackup {
    <# After a successful undo, the backup is renamed so it is not applied twice. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)
    $path = Get-DzBackupPath -Name $Name
    if (Test-Path -LiteralPath $path) { Move-Item -LiteralPath $path -Destination ($path -replace '\.json$', ('.undone-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')) -Force }
}

# ---------------------------------------------------------------------------------------
# Power plan
# ---------------------------------------------------------------------------------------

function ConvertFrom-DzPowercfgGuid {
    <# First GUID in powercfg output ("Power Scheme GUID: 381b... (Balanced)"). #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object]$Output)
    $m = [regex]::Match(([string]($Output -join "`n")), $script:GuidPattern)
    if ($m.Success) { return $m.Value.ToLowerInvariant() }
    return $null
}

function Get-DzPowerSchemeList {
    [CmdletBinding()]
    param()
    $out = & powercfg.exe /list 2>&1
    return @([regex]::Matches(([string]($out -join "`n")), $script:GuidPattern) | ForEach-Object { $_.Value.ToLowerInvariant() })
}

function Set-DzPerformancePowerPlan {
    <#
        Activates Ultimate Performance (duplicated from Windows' hidden template), or High
        performance. Re-uses a copy DayZero made earlier. Returns @{ Previous; Active; Created; Name }.
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$ReuseGuid)
    $previous = ConvertFrom-DzPowercfgGuid -Output (& powercfg.exe /getactivescheme 2>&1)
    $schemes = Get-DzPowerSchemeList
    $created = $null
    $target = $null
    $name = 'Ultimate Performance'
    if ($ReuseGuid -and ($schemes -contains $ReuseGuid)) { $target = $ReuseGuid }
    else {
        $dup = & powercfg.exe -duplicatescheme $script:UltimateTemplate 2>&1
        $g = ConvertFrom-DzPowercfgGuid -Output $dup
        if ($LASTEXITCODE -eq 0 -and $g) { $target = $g; $created = $g }
    }
    if ($target) {
        & powercfg.exe /setactive $target 2>&1 | Out-Null
        if ((ConvertFrom-DzPowercfgGuid -Output (& powercfg.exe /getactivescheme 2>&1)) -ne $target) {
            if ($created) { & powercfg.exe /delete $created 2>&1 | Out-Null; $created = $null }
            $target = $null
        }
    }
    if (-not $target) {
        $name = 'High performance'
        $target = $script:HighPerformance
        if ($schemes -notcontains $script:HighPerformance) {
            $dup = & powercfg.exe -duplicatescheme $script:HighPerformance 2>&1
            $g = ConvertFrom-DzPowercfgGuid -Output $dup
            if ($g) { $target = $g; $created = $g }
        }
        & powercfg.exe /setactive $target 2>&1 | Out-Null
        if ((ConvertFrom-DzPowercfgGuid -Output (& powercfg.exe /getactivescheme 2>&1)) -ne $target) {
            if ($created) { & powercfg.exe /delete $created 2>&1 | Out-Null }
            return [pscustomobject]@{ Previous = $previous; Active = $previous; Created = $null; Name = $null }
        }
    }
    return [pscustomobject]@{ Previous = $previous; Active = $target; Created = $created; Name = $name }
}

# ---------------------------------------------------------------------------------------
# Startup entries
# ---------------------------------------------------------------------------------------

function Select-DzStartupName {
    <# Which value names match the patterns (wildcards allowed, case-insensitive). Pure. #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowEmptyCollection()][string[]]$ValueNames = @(), [AllowEmptyCollection()][string[]]$Patterns = @())
    return @($ValueNames | Where-Object { $n = $_; @($Patterns | Where-Object { $n -like $_ }).Count -gt 0 })
}

# ---------------------------------------------------------------------------------------
# Applying a tweak
# ---------------------------------------------------------------------------------------

function Get-DzTweakTargetValue {
    <# The value a registry action wants on this PC (valueByEdition wins when the edition matches). #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Action, [AllowNull()][object]$System)
    $byEdition = Get-DzProperty $Action 'valueByEdition' $null
    if ($null -ne $byEdition -and $null -ne $System -and $System.EditionId) {
        $v = Get-DzProperty $byEdition ([string]$System.EditionId) $null
        if ($null -ne $v) { return $v }
    }
    return $Action.value
}

function Test-DzSameRegistryValue {
    param([object]$Current, [object]$Wanted, [string]$Kind)
    if (-not $Current.Exists) { return $false }
    if ($Current.Kind -and $Current.Kind -ne $Kind) { return $false }
    if ($Kind -eq 'Binary') { return ([Convert]::ToBase64String([byte[]]$Current.Value) -eq [Convert]::ToBase64String([byte[]]$Wanted)) }
    return ([string]$Current.Value -eq [string]$Wanted)
}

function Invoke-DzRegistryChange {
    <# Sets one value after recording what was there. Returns the change record, or $null if nothing changed. #>
    param([string]$Path, [string]$Name, [object]$Value, [string]$Kind)
    if ($script:ValueKinds -notcontains $Kind) { throw "Unknown registry type '$Kind' for $Path\$Name." }
    if (Test-DzProtectedRegistryPath -Path $Path) { throw "Refusing to change $Path : DayZero never touches Windows Update or Defender settings." }
    $current = Get-DzRegistryValue -Path $Path -Name $Name
    if (Test-DzSameRegistryValue -Current $current -Wanted $Value -Kind $Kind) { return $null }
    $record = [ordered]@{
        type = 'registry'; path = $Path; name = $Name
        existed = [bool]$current.Exists; kind = $current.Kind; value = (ConvertTo-DzStoredValue -Value $current.Value -Kind $current.Kind)
    }
    $shown = if ($Kind -eq 'Binary') { 'binary ' + [BitConverter]::ToString([byte[]]$Value) } else { [string]$Value }
    Invoke-DzAction -Description ("Set {0}\{1} = {2} ({3})" -f $Path, $Name, $shown, $Kind) -Action {
        Set-DzRegistryValue -Path $Path -Name $Name -Value $Value -Kind $Kind
    } | Out-Null
    return $record
}

function Invoke-DzTweak {
    <#
        Applies one tweak (catalog item) and returns a step result. Records the changes in
        backup\tweaks.json (not in dry-run mode, where nothing changes).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Tweak, [Parameter(Mandatory = $true)][hashtable]$Context)
    $changes = New-Object System.Collections.Generic.List[object]
    $notes = New-Object System.Collections.Generic.List[string]
    foreach ($a in @($Tweak.actions)) {
        $type = [string]$a.type
        if ($script:ActionTypes -notcontains $type) { throw "Tweak '$($Tweak.id)' uses unknown action type '$type'." }
        switch ($type) {
            'registry' {
                $value = Get-DzTweakTargetValue -Action $a -System $Context.System
                $r = Invoke-DzRegistryChange -Path ([string]$a.path) -Name ([string]$a.name) -Value $value -Kind ([string]$a.kind)
                if ($r) { $changes.Add($r) }
            }
            'startupDisable' {
                $patterns = @($a.names)
                foreach ($k in $script:StartupKeys) {
                    foreach ($n in (Select-DzStartupName -ValueNames (Get-DzRegistryValueName -Path $k.Run) -Patterns $patterns)) {
                        $r = Invoke-DzRegistryChange -Path $k.Approved -Name $n -Value $script:StartupDisabledBytes -Kind 'Binary'
                        if ($r) { $changes.Add($r); $notes.Add($n) }
                    }
                }
                if ($notes.Count -eq 0) { $notes.Add('none of these apps has a startup entry yet') }
            }
            'powerPlan' {
                $reuse = $null
                foreach ($e in (Read-DzBackup -Name 'tweaks')) { foreach ($c in @($e.changes)) { if ($c.type -eq 'powerPlan' -and $c.created) { $reuse = [string]$c.created } } }
                if (Test-DzDryRun) { Write-DzLog -Message '[DRY-RUN] would: activate the Ultimate Performance (or High performance) power plan'; continue }
                $p = Set-DzPerformancePowerPlan -ReuseGuid $reuse
                if (-not $p.Name) {
                    return (New-DzStepResult -Status Warn -Message 'This PC only offers the Balanced plan (Modern Standby). Use Settings > System > Power > Power mode > Best performance instead.')
                }
                if ($p.Previous -ne $p.Active) {
                    $changes.Add([ordered]@{ type = 'powerPlan'; previous = $p.Previous; created = $p.Created; active = $p.Active })
                    Write-DzLog -Message ("Power plan: {0} ({1}), was {2}" -f $p.Name, $p.Active, $p.Previous)
                }
                $notes.Add($p.Name)
            }
        }
    }
    if ($changes.Count -gt 0 -and -not (Test-DzDryRun)) {
        Add-DzBackupEntry -Name 'tweaks' -Entry ([ordered]@{ tweakId = [string]$Tweak.id; title = [string]$Tweak.title; appliedAt = (Get-Date).ToString('o'); changes = $changes.ToArray() })
    }
    $msg = if ($changes.Count -gt 0) { "Changed $($changes.Count) setting(s)." } else { 'Already set.' }
    if (Test-DzDryRun) { $msg = '[DRY-RUN] see the log for what would change.' }
    if ($notes.Count -gt 0) { $msg += ' ' + ($notes -join ', ') + '.' }
    if ([bool](Get-DzProperty $Tweak 'needsRestart' $false)) { $msg += ' Takes effect after a restart.'; $Context.Flags['RestartRecommended'] = $true }
    elseif ([bool](Get-DzProperty $Tweak 'needsSignOut' $false)) { $msg += ' Takes effect after signing out.' }
    return (New-DzStepResult -Status Done -Message $msg.Trim())
}

# ---------------------------------------------------------------------------------------
# Undo
# ---------------------------------------------------------------------------------------

function Undo-DzTweak {
    <# Restores every recorded change, newest first. Returns @{ Restored; Failed; Messages }. #>
    [CmdletBinding()]
    param()
    $entries = @(Read-DzBackup -Name 'tweaks')
    $restored = 0
    $failed = 0
    $messages = New-Object System.Collections.Generic.List[string]
    for ($i = $entries.Count - 1; $i -ge 0; $i--) {
        $e = $entries[$i]
        $changes = @($e.changes)
        for ($j = $changes.Count - 1; $j -ge 0; $j--) {
            $c = $changes[$j]
            try {
                switch ([string]$c.type) {
                    'registry' {
                        if ($c.existed) {
                            $value = ConvertFrom-DzStoredValue -Value $c.value -Kind ([string]$c.kind)
                            Invoke-DzAction -Description ("Restore {0}\{1}" -f $c.path, $c.name) -Action {
                                Set-DzRegistryValue -Path ([string]$c.path) -Name ([string]$c.name) -Value $value -Kind ([string]$c.kind)
                            } | Out-Null
                        }
                        else {
                            Invoke-DzAction -Description ("Remove {0}\{1} (it did not exist before DayZero)" -f $c.path, $c.name) -Action {
                                Remove-DzRegistryValue -Path ([string]$c.path) -Name ([string]$c.name)
                            } | Out-Null
                        }
                    }
                    'powerPlan' {
                        Invoke-DzAction -Description ("Switch back to power plan {0}" -f $c.previous) -Action {
                            & powercfg.exe /setactive ([string]$c.previous) 2>&1 | Out-Null
                            if ($c.created) { & powercfg.exe /delete ([string]$c.created) 2>&1 | Out-Null }
                        } | Out-Null
                    }
                }
                $restored++
            }
            catch {
                $failed++
                $messages.Add(("{0}: {1}" -f $e.title, $_.Exception.Message))
            }
        }
    }
    if ($failed -eq 0 -and $entries.Count -gt 0 -and -not (Test-DzDryRun)) { Close-DzBackup -Name 'tweaks' }
    return [pscustomobject]@{ Restored = $restored; Failed = $failed; Messages = $messages.ToArray() }
}

Export-ModuleMember -Function @(
    'Test-DzProtectedRegistryPath', 'Get-DzRegistryValue', 'Set-DzRegistryValue', 'Remove-DzRegistryValue', 'Get-DzRegistryValueName',
    'Get-DzBackupPath', 'Read-DzBackup', 'Add-DzBackupEntry', 'Close-DzBackup',
    'ConvertFrom-DzPowercfgGuid', 'Get-DzPowerSchemeList', 'Set-DzPerformancePowerPlan', 'Select-DzStartupName',
    'Get-DzTweakTargetValue', 'Invoke-DzTweak', 'Undo-DzTweak'
)
