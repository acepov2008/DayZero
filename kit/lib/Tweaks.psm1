#Requires -Version 5.1
<#
    DayZero - applies the documented tweaks from config\tweaks.json and undoes them.

    Every change is recorded in <kit>\backup\tweaks.json BEFORE it is made: the registry
    value's old data and type, or the fact that it did not exist; the previous power plan;
    a service's previous start type; a machine environment variable's previous value; the
    registry key DayZero created. Undo-DzTweak walks that list backwards and restores it.
    The two clean-up actions (temporary files, superseded Windows components) only delete
    things Windows can do without, so there is nothing to put back.

    Hard safety rules, enforced here whatever the JSON says:
      * no registry path that belongs to Windows Update or Microsoft Defender
      * no start-type change for Windows Update, Defender, firewall, Store or installer services
      * only the action types below (no scripts)
#>

Set-StrictMode -Version 2.0

$script:ProtectedPatterns = @(
    '\\WindowsUpdate(\\|$)', '\\Windows Defender', '\\WinDefend', '\\wuauserv', '\\UsoSvc', '\\WaaSMedicSvc',
    '\\SecurityHealthService', '\\Sense(\\|$)', '\\WdNisSvc', '\\WdFilter', '\\MpsSvc', '\\mpssvc', '\\Microsoft Antimalware'
)
$script:ActionTypes = @('registry', 'registryKey', 'service', 'environment', 'powerPlan', 'startupDisable', 'cleanTemp', 'componentCleanup')
# Services DayZero never reconfigures: Windows Update and its helpers, Defender, the firewall,
# the Store / app installers and the core plumbing they all need.
$script:ProtectedServices = @(
    'wuauserv', 'UsoSvc', 'WaaSMedicSvc', 'BITS', 'DoSvc', 'TrustedInstaller', 'CryptSvc', 'msiserver',
    'WinDefend', 'WdNisSvc', 'WdNisDrv', 'WdFilter', 'WdBoot', 'Sense', 'SecurityHealthService', 'wscsvc', 'MDCoreSvc',
    'mpssvc', 'BFE', 'AppXSvc', 'ClipSVC', 'InstallService', 'StateRepository', 'RpcSs', 'RpcEptMapper', 'DcomLaunch',
    'EventLog', 'Winmgmt', 'Schedule', 'ProfSvc', 'LSM', 'SamSs', 'PlugPlay', 'Power'
)
$script:ServiceStartNames = @{ 0 = 'Boot'; 1 = 'System'; 2 = 'Automatic'; 3 = 'Manual'; 4 = 'Disabled' }
$script:ScStartArgs = @{ Automatic = 'auto'; AutomaticDelayed = 'delayed-auto'; Manual = 'demand'; Disabled = 'disabled' }
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
# Services, registry keys, environment variables, clean-up
# ---------------------------------------------------------------------------------------

function Test-DzProtectedService {
    <# True for services DayZero never reconfigures (Windows Update, Defender, firewall, Store...). #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][string]$Name)
    foreach ($p in $script:ProtectedServices) { if ($Name -ieq $p) { return $true } }
    return (Test-DzProtectedRegistryPath -Path ('\' + $Name))
}

function Get-DzServiceStart {
    <# A service's start type from the registry: Automatic, AutomaticDelayed, Manual, Disabled, Boot, System; $null when it is not installed. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Name)
    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
    if (-not (Test-Path -LiteralPath $key)) { return $null }
    $start = (Get-DzRegistryValue -Path $key -Name 'Start')
    if (-not $start.Exists) { return $null }
    $text = $script:ServiceStartNames[[int]$start.Value]
    if ($text -eq 'Automatic') {
        $delayed = Get-DzRegistryValue -Path $key -Name 'DelayedAutostart'
        if ($delayed.Exists -and [int]$delayed.Value -eq 1) { $text = 'AutomaticDelayed' }
    }
    return $text
}

function Set-DzServiceStart {
    <# Sets a service's start type with sc.exe (the service keeps running until the next restart). #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][string]$Startup)
    if (Test-DzProtectedService -Name $Name) { throw "Refusing to change the $Name service: DayZero never touches Windows Update, Defender, firewall or Store services." }
    if (-not $script:ScStartArgs.ContainsKey($Startup)) { throw "Unsupported start type '$Startup' for $Name." }
    $out = & sc.exe config $Name start= $script:ScStartArgs[$Startup] 2>&1
    if ($LASTEXITCODE -ne 0) { throw ("sc.exe config {0} failed ({1}): {2}" -f $Name, $LASTEXITCODE, (($out | Out-String).Trim())) }
}

function Get-DzMachineEnvironment {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)
    return [Environment]::GetEnvironmentVariable($Name, [EnvironmentVariableTarget]::Machine)
}

function Set-DzMachineEnvironment {
    <# Sets (or with $null / '' removes) a machine-wide environment variable. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name, [AllowNull()][object]$Value)
    $text = if ($null -eq $Value -or [string]$Value -eq '') { [NullString]::Value } else { [string]$Value }
    [Environment]::SetEnvironmentVariable($Name, $text, [EnvironmentVariableTarget]::Machine)
}

function Test-DzRegistryKey {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][string]$Path)
    return [bool](Test-Path -LiteralPath $Path)
}

function Get-DzParentRegistryPath {
    <# 'HKCU:\A\B\C' -> 'HKCU:\A\B'; $null at the hive. Pure (works the same on every OS). #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Path)
    $trimmed = $Path.TrimEnd('\')
    $i = $trimmed.LastIndexOf('\')
    if ($i -lt 0 -or $trimmed.Substring(0, $i).EndsWith(':')) { return $null }
    return $trimmed.Substring(0, $i)
}

function Get-DzMissingKeyRoot {
    <# The top-most key of $Path that does not exist yet (what undo has to delete); $null when $Path exists. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Path)
    if (Test-DzRegistryKey -Path $Path) { return $null }
    $root = $Path.TrimEnd('\')
    $parent = Get-DzParentRegistryPath -Path $root
    while ($parent -and -not (Test-DzRegistryKey -Path $parent)) {
        $root = $parent
        $parent = Get-DzParentRegistryPath -Path $root
    }
    return $root
}

function New-DzRegistryKey {
    <# Creates a key and sets its (Default) value. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [AllowEmptyString()][string]$DefaultValue = '')
    if (Test-DzProtectedRegistryPath -Path $Path) { throw "Refusing to change $Path : DayZero never touches Windows Update or Defender settings." }
    [void](New-Item -Path $Path -Force)
    Set-ItemProperty -LiteralPath $Path -Name '(default)' -Value $DefaultValue
}

function Remove-DzRegistryKey {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    if (Test-DzProtectedRegistryPath -Path $Path) { throw "Refusing to change $Path : DayZero never touches Windows Update or Defender settings." }
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
}

function Get-DzTempFolder {
    <# The folders the temp clean-up empties: the signed-in user's TEMP and Windows\Temp. #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($p in @($env:TEMP, $(if ($env:SystemRoot) { Join-Path $env:SystemRoot 'Temp' }))) {
        if ($p -and (Test-Path -LiteralPath $p) -and -not $list.Contains($p)) { $list.Add($p) }
    }
    return , $list.ToArray()
}

function Test-DzKeptTempItem {
    <# DayZero's own working folders and log files stay (logs help when something failed). Pure. #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][string]$Name)
    return ($Name -like 'DayZero*' -or $Name -like '*.log')
}

function Clear-DzTempFolder {
    <# Deletes what can be deleted in the temp folders; files in use are skipped. Returns the MB freed. #>
    [CmdletBinding()]
    [OutputType([double])]
    param()
    $freed = 0L
    foreach ($folder in (Get-DzTempFolder)) {
        foreach ($item in @(Get-ChildItem -LiteralPath $folder -Force -ErrorAction SilentlyContinue)) {
            if (Test-DzKeptTempItem -Name $item.Name) { continue }
            $size = 0L
            if ($item.PSIsContainer) { $size = [long](@(Get-ChildItem -LiteralPath $item.FullName -Recurse -Force -File -ErrorAction SilentlyContinue) | Measure-Object -Property Length -Sum).Sum }
            else { $size = [long]$item.Length }
            Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $item.FullName)) { $freed += $size }
        }
    }
    return [math]::Round($freed / 1MB, 1)
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
    $warnings = New-Object System.Collections.Generic.List[string]
    foreach ($a in @($Tweak.actions)) {
        $type = [string]$a.type
        if ($script:ActionTypes -notcontains $type) { throw "Tweak '$($Tweak.id)' uses unknown action type '$type'." }
        switch ($type) {
            'registry' {
                $value = Get-DzTweakTargetValue -Action $a -System $Context.System
                $r = Invoke-DzRegistryChange -Path ([string]$a.path) -Name ([string]$a.name) -Value $value -Kind ([string]$a.kind)
                if ($r) { $changes.Add($r) }
            }
            'registryKey' {
                $path = [string]$a.path
                if (Test-DzProtectedRegistryPath -Path $path) { throw "Refusing to change $path : DayZero never touches Windows Update or Defender settings." }
                $root = Get-DzMissingKeyRoot -Path $path
                if ($null -eq $root) { continue }   # already there
                $default = [string](Get-DzProperty $a 'defaultValue' '')
                Invoke-DzAction -Description ("Create {0} with an empty (Default) value" -f $path) -Action {
                    New-DzRegistryKey -Path $path -DefaultValue $default
                } | Out-Null
                $changes.Add([ordered]@{ type = 'registryKey'; path = $path; created = $root })
            }
            'service' {
                $name = [string]$a.name
                $wanted = [string]$a.startup
                if (Test-DzProtectedService -Name $name) { throw "Tweak '$($Tweak.id)' would change the $name service: DayZero never touches Windows Update, Defender, firewall or Store services." }
                if (-not $script:ScStartArgs.ContainsKey($wanted)) { throw "Tweak '$($Tweak.id)': unsupported start type '$wanted' for $name." }
                $previous = Get-DzServiceStart -Name $name
                if ($null -eq $previous) { $notes.Add("$name is not on this PC"); continue }
                if ($previous -eq $wanted) { continue }
                if ($previous -in @('Boot', 'System')) { $notes.Add("$name left alone (driver)"); continue }
                Invoke-DzAction -Description ("Service {0}: start type {1} -> {2}" -f $name, $previous, $wanted) -Action {
                    Set-DzServiceStart -Name $name -Startup $wanted
                } | Out-Null
                $changes.Add([ordered]@{ type = 'service'; name = $name; previous = $previous; startup = $wanted })
            }
            'environment' {
                $name = [string]$a.name
                $value = [string]$a.value
                $previous = Get-DzMachineEnvironment -Name $name
                if ([string]$previous -eq $value) { continue }
                Invoke-DzAction -Description ("Set machine environment variable {0}={1}" -f $name, $value) -Action {
                    Set-DzMachineEnvironment -Name $name -Value $value
                } | Out-Null
                $changes.Add([ordered]@{ type = 'environment'; name = $name; previous = $previous })
            }
            'cleanTemp' {
                if ($Context.Progress) { & $Context.Progress 'Deleting temporary files...' }
                $mb = Invoke-DzAction -Description ('Delete temporary files in ' + ((Get-DzTempFolder) -join ', ') + ' (files in use, DayZero folders and .log files are kept)') -Action { Clear-DzTempFolder }
                if ($null -ne $mb) { $notes.Add("freed $mb MB") }
            }
            'componentCleanup' {
                if ($Context.Progress) { & $Context.Progress 'Cleaning up superseded Windows components (DISM, can take a while)...' }
                $dism = $(if ($env:SystemRoot) { [string]$env:SystemRoot } else { 'C:\Windows' }) + '\System32\Dism.exe'
                $dismArgs = @('/Online', '/Cleanup-Image', '/StartComponentCleanup')
                $r = Invoke-DzAction -Description ('Run DISM ' + ($dismArgs -join ' ') + ' (no /ResetBase: installed updates stay uninstallable)') -Action {
                    Invoke-DzProcess -FilePath $dism -Arguments $dismArgs -TimeoutSec 3600
                }
                if ($null -ne $r) {
                    if ($r.TimedOut) { $warnings.Add('DISM component clean-up took over an hour and was stopped; Windows also does this by itself later.') }
                    elseif ($r.ExitCode -ne 0) { $warnings.Add(('DISM component clean-up returned {0}; it usually works after the next restart (Windows also runs it by itself).' -f $r.ExitCode)) }
                    else { $notes.Add('superseded Windows components cleaned up') }
                }
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
    if ($warnings.Count -gt 0) { return (New-DzStepResult -Status Warn -Message (($msg + ' ' + ($warnings -join ' ')).Trim())) }
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
                    'registryKey' {
                        Invoke-DzAction -Description ("Delete {0} (DayZero created it)" -f $c.created) -Action {
                            Remove-DzRegistryKey -Path ([string]$c.created)
                        } | Out-Null
                    }
                    'service' {
                        Invoke-DzAction -Description ("Service {0}: start type back to {1}" -f $c.name, $c.previous) -Action {
                            Set-DzServiceStart -Name ([string]$c.name) -Startup ([string]$c.previous)
                        } | Out-Null
                    }
                    'environment' {
                        $prev = if ($null -eq $c.previous) { $null } else { [string]$c.previous }
                        Invoke-DzAction -Description ("Machine environment variable {0} back to '{1}'" -f $c.name, $prev) -Action {
                            Set-DzMachineEnvironment -Name ([string]$c.name) -Value $prev
                        } | Out-Null
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
    'Test-DzProtectedService', 'Get-DzServiceStart', 'Set-DzServiceStart', 'Get-DzMachineEnvironment', 'Set-DzMachineEnvironment',
    'Test-DzRegistryKey', 'Get-DzParentRegistryPath', 'Get-DzMissingKeyRoot', 'New-DzRegistryKey', 'Remove-DzRegistryKey',
    'Get-DzTempFolder', 'Test-DzKeptTempItem', 'Clear-DzTempFolder',
    'Get-DzTweakTargetValue', 'Invoke-DzTweak', 'Undo-DzTweak'
)
