#Requires -Version 5.1
<#
    DayZero - core helpers for the setup wizard: kit paths, settings, logging and the
    dry-run switch.

    DRY RUN: every step that changes the system must go through Invoke-DzAction. When
    dry-run is on, Invoke-DzAction only logs "[DRY-RUN] would: <description>" and skips
    the action, so a dry run is a faithful list of what a real run would do.

    LOGS: written to <kit>\Logs (C:\DayZero\Logs on the new PC) and, when the USB stick
    is plugged in, also to <USB>\DayZero\Logs\<computer>-<name>-<timestamp>.log.
#>

Set-StrictMode -Version 2.0

$script:KitRoot = Split-Path -Parent $PSScriptRoot
$script:DryRun = $false
$script:LogFile = $null
$script:UsbLogFile = $null
$script:LogListeners = New-Object System.Collections.Generic.List[scriptblock]

function Get-DzKitRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return $script:KitRoot
}

function Set-DzKitRoot {
    <# Points DayZero at another kit folder (used by tests and by the USB fallback). #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $script:KitRoot = $Path
}

function Join-DzPath {
    <# Joins path parts with the OS separator (PowerShell 5.1's Join-Path takes only two parts). #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true, ValueFromRemainingArguments = $true)][string[]]$Part)
    return [System.IO.Path]::Combine([string[]]$Part)
}

function Get-DzStatePath {
    <# The wizard's progress file: <kit>\state.json (C:\DayZero\state.json on the new PC). #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return (Join-DzPath $script:KitRoot 'state.json')
}

function Get-DzVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $file = Join-Path $script:KitRoot 'VERSION'
    if (Test-Path -LiteralPath $file) { return (Get-Content -LiteralPath $file -Raw).Trim() }
    return 'dev'
}

function Read-DzJsonFile {
    <# Reads a UTF-8 JSON file (PowerShell 5.1 safe). #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    return ($text | ConvertFrom-Json)
}

function Get-DzSettings {
    <#
        Settings written by the builder (config\settings.json). Falls back to safe
        defaults when the wizard is started by hand on a PC without a builder run.
    #>
    [CmdletBinding()]
    param()
    $path = Join-DzPath $script:KitRoot 'config' 'settings.json'
    $defaults = [ordered]@{
        schemaVersion = 1; buildId = $null; builtAt = $null; builderVersion = $null
        windowsVersion = $null; edition = 'auto'; userName = $env:USERNAME; computerName = $env:COMPUTERNAME
        temporaryPassword = $false; autoLogon = $false; autoLogonCount = 0
        defaultMode = 'gaming'; dryRun = $false
    }
    if (Test-Path -LiteralPath $path) {
        $loaded = Read-DzJsonFile -Path $path
        foreach ($p in $loaded.PSObject.Properties) { $defaults[$p.Name] = $p.Value }
    }
    return [pscustomobject]$defaults
}

function Find-DzUsbKit {
    <#
        Finds the DayZero folder on the USB stick (drive letters change between boots) by
        looking for its build marker. Returns the path to <USB>\DayZero or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][string]$BuildId)
    if ([string]::IsNullOrWhiteSpace($BuildId) -or -not $env:SystemDrive) { return $null }
    $systemRoot = $env:SystemDrive.TrimEnd('\') + '\'
    foreach ($drive in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        $root = [string]$drive.Root
        if (-not $root -or $root -ieq $systemRoot) { continue }
        $marker = Join-Path $root ('DayZero\build-' + $BuildId + '.marker')
        if (Test-Path -LiteralPath $marker -ErrorAction SilentlyContinue) { return (Join-Path $root 'DayZero') }
    }
    return $null
}

function Set-DzDryRun {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][bool]$Enabled)
    $script:DryRun = $Enabled
}

function Test-DzDryRun {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return $script:DryRun
}

function Initialize-DzLog {
    <#
        Starts a log file named <Name>-<timestamp>.log in <kit>\Logs, plus a copy on the USB
        stick when it is found. Returns the local log path.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][string]$BuildId
    )
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dir = Join-Path $script:KitRoot 'Logs'
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $script:LogFile = Join-Path $dir ("$Name-$stamp.log")
    $script:UsbLogFile = $null
    $usbKit = Find-DzUsbKit -BuildId $BuildId
    if ($usbKit -and ($usbKit -ine $script:KitRoot)) {
        $usbLogs = Join-Path $usbKit 'Logs'
        try {
            if (-not (Test-Path -LiteralPath $usbLogs)) { [void](New-Item -ItemType Directory -Path $usbLogs -Force) }
            $script:UsbLogFile = Join-Path $usbLogs ("$($env:COMPUTERNAME)-$Name-$stamp.log")
        }
        catch { $script:UsbLogFile = $null }
    }
    return $script:LogFile
}

function Add-DzLogListener {
    <# Registers a scriptblock called with (level, line) for every log line, e.g. the live log in the GUI. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][scriptblock]$Listener)
    $script:LogListeners.Add($Listener)
}

function Write-DzLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message,
        [ValidateSet('Info', 'Ok', 'Warn', 'Error', 'Step')][string]$Level = 'Info'
    )
    $line = '[{0}] {1,-5} {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level.ToUpperInvariant(), $Message
    foreach ($file in @($script:LogFile, $script:UsbLogFile)) {
        if (-not $file) { continue }
        try { [System.IO.File]::AppendAllText($file, $line + "`r`n", [System.Text.Encoding]::UTF8) }
        catch {
            # The USB stick may have been unplugged: stop writing there, keep the local log.
            if ($file -eq $script:UsbLogFile) { $script:UsbLogFile = $null }
        }
    }
    foreach ($listener in $script:LogListeners) {
        try { & $listener $Level $line } catch { Write-Verbose 'Log listener failed.' }
    }
    Write-Verbose $line
}

function Invoke-DzAction {
    <#
    .SYNOPSIS
        Runs a system-changing action, or only logs it in dry-run mode.
    .EXAMPLE
        Invoke-DzAction -Description 'Set power plan to High performance' -Action { powercfg /setactive SCHEME_MIN }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )
    if ($script:DryRun) {
        Write-DzLog -Message ("[DRY-RUN] would: $Description")
        return $null
    }
    Write-DzLog -Message $Description
    return (& $Action)
}

Export-ModuleMember -Function @(
    'Get-DzKitRoot', 'Set-DzKitRoot', 'Join-DzPath', 'Get-DzStatePath', 'Get-DzVersion', 'Read-DzJsonFile', 'Get-DzSettings', 'Find-DzUsbKit',
    'Set-DzDryRun', 'Test-DzDryRun', 'Initialize-DzLog', 'Add-DzLogListener', 'Write-DzLog', 'Invoke-DzAction'
)
