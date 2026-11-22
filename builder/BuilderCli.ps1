#Requires -Version 7.2
<#
.SYNOPSIS
    DayZero USB Builder for Linux (terminal version). Start it with build-dayzero-usb.sh.
.DESCRIPTION
    Makes the same sticks as the Windows builder, from a Linux PC:
      * Windows 11 / 10 from Microsoft (or your Windows ISO), with autounattend.xml and the
        DayZero kit. Unpacked with wimlib-imagex instead of DISM. The stick boots on UEFI PCs
        (Windows' legacy BIOS boot code can only be written from Windows).
      * Ubuntu 26.04 / 24.04 LTS from ubuntu.com (or your Ubuntu ISO), with autoinstall.yaml
        and the DayZero Linux kit.
      * Any other Linux ISO, written as it is and read back.
    Only a USB stick that passes Test-DzUsbDiskAllowed is offered, and it is erased only after
    you type its name. On the new PC, the installer always lets you pick the disk.
.EXAMPLE
    sudo ./build-dayzero-usb.sh
.EXAMPLE
    sudo ./build-dayzero-usb.sh -System ubuntu-26.04 -Disk /dev/sdb -UserName ivan -Mode gaming
.EXAMPLE
    ./build-dayzero-usb.sh -ListDisks
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive terminal program.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCompatibleCommands', '', Justification = 'Linux only, PowerShell 7.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCompatibleTypes', '', Justification = 'Linux only, PowerShell 7.')]
[CmdletBinding()]
param(
    # windows11, windows10, windows-iso, ubuntu-iso, linux-iso, or a distro id from builder/linux/distros.json
    # (ubuntu-26.04, ubuntu-24.04, fedora-workstation, debian-gnome, linuxmint-cinnamon, cachyos-desktop).
    [ValidatePattern('^[a-z0-9.-]*$')][string]$System = '',
    [string]$Disk,
    [string]$IsoPath,
    [string]$UserName,
    [string]$FullName,
    [string]$ComputerName,
    [string]$Language,
    [string]$Keyboard,
    [string]$TimeZone,
    [ValidateSet('', 'gaming', 'office', 'everything', 'custom')][string]$Mode = '',
    [ValidateSet('auto', 'home', 'pro')][string]$Edition = 'auto',
    [ValidateSet('clear', 'minimal', 'standard', 'advanced')][string]$CleanupLevel = 'standard',
    [switch]$TemporaryPassword,
    [switch]$PasswordStdin,
    [switch]$DryRun,
    [switch]$NoDrivers,
    [switch]$NoCodecs,
    [switch]$ListDisks,
    [string]$Verify,
    [ValidateSet('', 'en', 'ru')][string]$AppLanguage = ''
)

$ErrorActionPreference = 'Stop'
$script:BuilderRoot = $PSScriptRoot
$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:KitRoot = Join-Path $script:RepoRoot 'kit'
$script:Version = (Get-Content -LiteralPath (Join-Path $script:KitRoot 'VERSION') -Raw).Trim()
$script:CacheBase = if ($env:DAYZERO_CACHE) { $env:DAYZERO_CACHE } else { '/var/cache/dayzero' }
$script:Log = New-Object System.Collections.Generic.List[string]

# Modules already loaded are kept (the end-to-end test loads them first); normally none are.
foreach ($m in 'Core.psm1', 'Lang.psm1', 'Config.psm1') { if (-not (Get-Module ($m -replace '\.psm1$'))) { Import-Module (Join-Path $script:KitRoot "lib/$m") -DisableNameChecking } }
foreach ($m in 'Unattend.psm1', 'UsbWriter.psm1', 'WinMedia.psm1', 'Linux.psm1', 'RawWrite.psm1', 'LinuxHost.psm1') {
    if (-not (Get-Module ($m -replace '\.psm1$'))) { Import-Module (Join-Path $script:BuilderRoot "lib/$m") -DisableNameChecking }
}

# ------------------------------------------------------------------------------------
# Terminal helpers (texts are translated where they are shown; the log stays English)
# ------------------------------------------------------------------------------------

function Say {
    param([AllowEmptyString()][string]$Text = '', [string]$Color = '')
    $t = [string](Get-DzText $Text)
    if ($Color) { Write-Host $t -ForegroundColor $Color } else { Write-Host $t }
}

function Write-CliLog {
    param([string]$Message)
    $script:Log.Add(('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message))
    Write-Host ('  ' + $Message) -ForegroundColor DarkGray
}

$script:LastTick = ''
function Write-CliTick {
    param([string]$Text)
    if (-not $Text -or $Text -eq $script:LastTick) { return }
    $script:LastTick = $Text
    $t = [string](Get-DzText $Text)
    $width = 100
    try { if ([Console]::WindowWidth -ge 40) { $width = [Console]::WindowWidth - 1 } } catch { $width = 100 }
    if ($t.Length -gt $width) { $t = $t.Substring(0, $width) }
    Write-Host ("`r" + $t.PadRight($width)) -NoNewline
}

function Read-CliLine {
    param([string]$Prompt, [string]$Default = '')
    $p = [string](Get-DzText $Prompt)
    if ($Default) { $p += " [$Default]" }
    $a = Read-Host -Prompt $p
    if ([string]::IsNullOrWhiteSpace($a)) { return $Default }
    return $a.Trim()
}

function Read-CliChoice {
    <# Numbered menu; returns the chosen item's Value. #>
    param([string]$Prompt, [object[]]$Items, [int]$Default = 1)
    Say $Prompt 'Cyan'
    for ($i = 0; $i -lt $Items.Count; $i++) { Write-Host ('  {0}) {1}' -f ($i + 1), (Get-DzText ([string]$Items[$i].Label))) }
    while ($true) {
        $a = Read-CliLine -Prompt 'Number' -Default ([string]$Default)
        $n = 0
        if ([int]::TryParse($a, [ref]$n) -and $n -ge 1 -and $n -le $Items.Count) { return $Items[$n - 1].Value }
        Say 'Type one of the numbers above.' 'Yellow'
    }
}

function Read-CliYesNo {
    param([string]$Prompt, [bool]$Default = $false)
    $a = Read-CliLine -Prompt ($Prompt + ' (y/n)') -Default $(if ($Default) { 'y' } else { 'n' })
    $da = [string][char]0x0434 + [char]0x0430   # Russian 'da' (yes), written as code points: .ps1 files stay ASCII
    return ($a -match '^(y|yes|d|da)$' -or $a -eq $da -or $a -eq $da.Substring(0, 1))
}

function Read-CliPassword {
    if ($PasswordStdin) {
        $line = [Console]::In.ReadLine()
        if ($null -eq $line) { throw 'No password on standard input.' }
        return $line
    }
    while ($true) {
        $a = Read-Host -Prompt (Get-DzText 'Password') -MaskInput
        $b = Read-Host -Prompt (Get-DzText 'Confirm password') -MaskInput
        if (-not $a) { Say 'Enter a password.' 'Yellow'; continue }
        if ($a -cne $b) { Say 'The two passwords are not the same.' 'Yellow'; continue }
        return $a
    }
}

# ------------------------------------------------------------------------------------
# Steps
# ------------------------------------------------------------------------------------

function Show-Disks {
    $all = @(Get-DzLinuxUsbDiskCandidate)
    if ($all.Count -eq 0) { Say 'No disks found.'; return @() }
    foreach ($d in $all) {
        if ($d.Problem) { Write-Host ('  -  {0}   ({1})' -f $d.Display, (Get-DzText $d.Problem)) -ForegroundColor DarkGray }
        else { Write-Host ('  +  {0}' -f $d.Display) -ForegroundColor Green }
    }
    return @($all | Where-Object { -not $_.Problem })
}

function Get-SystemChoice {
    <# Every kind of stick this builder makes: Value (what -System takes), Label, Kind (windows, ubuntu, raw). #>
    $items = New-Object System.Collections.Generic.List[object]
    $items.Add([pscustomobject]@{ Label = 'Windows 11 (downloaded from Microsoft)'; Value = 'windows11'; Kind = 'windows' })
    $items.Add([pscustomobject]@{ Label = 'Windows 10 (downloaded from Microsoft)'; Value = 'windows10'; Kind = 'windows' })
    $items.Add([pscustomobject]@{ Label = 'Windows from an ISO file I already have'; Value = 'windows-iso'; Kind = 'windows' })
    foreach ($d in (Get-DzLinuxCatalog).Distros) {
        if ([string]$d.automation -eq 'ubuntu-autoinstall') {
            $items.Add([pscustomobject]@{ Label = ((Get-DzText '{0} - downloaded from ubuntu.com, with DayZero (supported until {1})') -f $d.name, $d.supportedUntil); Value = [string]$d.id; Kind = 'ubuntu' })
        }
    }
    $items.Add([pscustomobject]@{ Label = 'Ubuntu from an ISO file I already have (with DayZero)'; Value = 'ubuntu-iso'; Kind = 'ubuntu' })
    foreach ($d in (Get-DzLinuxCatalog).Distros) {
        if ([string]$d.automation -ne 'ubuntu-autoinstall') {
            $items.Add([pscustomobject]@{ Label = ((Get-DzText '{0} - downloaded from {1}, written as it is (no DayZero)') -f $d.name, $d.site); Value = [string]$d.id; Kind = 'raw' })
        }
    }
    $items.Add([pscustomobject]@{ Label = 'Another Linux ISO file, written as it is (no DayZero)'; Value = 'linux-iso'; Kind = 'raw' })
    return $items.ToArray()
}

function Select-System {
    $choices = @(Get-SystemChoice)
    if ($System) {
        $c = @($choices | Where-Object { $_.Value -eq $System }) | Select-Object -First 1
        if (-not $c) { throw ('Unknown -System {0}. Use one of: {1}' -f $System, (($choices | ForEach-Object { $_.Value }) -join ', ')) }
        return $c
    }
    $menu = @($choices | ForEach-Object { [pscustomobject]@{ Label = $_.Label; Value = $_ } })
    $default = [array]::IndexOf(@($choices | ForEach-Object { $_.Value }), 'ubuntu-26.04') + 1
    if ($default -lt 1) { $default = 1 }
    return (Read-CliChoice -Prompt 'What should the stick install?' -Items $menu -Default $default)
}

function Select-Disk {
    Say ''
    Say 'USB sticks (+ can be used, - is never offered):' 'Cyan'
    $ok = @(Show-Disks)
    if ($Disk) {
        $d = @($ok | Where-Object { $_.Path -eq $Disk }) | Select-Object -First 1
        if (-not $d) { throw "$Disk cannot be used. Only the disks marked + above can." }
        return $d
    }
    if ($ok.Count -eq 0) { throw 'No USB stick that can be used. Plug one in (8 GB or more) and start again. Internal disks and drives over 300 GB are never offered.' }
    $items = @($ok | ForEach-Object { [pscustomobject]@{ Label = $_.Display; Value = $_ } })
    return (Read-CliChoice -Prompt 'Which USB stick? EVERYTHING on it will be erased.' -Items $items -Default 1)
}

function Read-Account {
    param([bool]$ForLinux)
    $o = @{}
    $defaults = Get-DzLinuxHostDefaults
    while ($true) {
        $u = if ($UserName) { $UserName } else { Read-CliLine -Prompt 'User name' -Default $(if ($ForLinux) { ConvertTo-DzLinuxUserName -Name $env:SUDO_USER } else { '' }) }
        $p = if ($ForLinux) { Test-DzLinuxUserName -Name $u } else { Test-DzUserName -Name $u -ComputerName $ComputerName }
        if (-not $p) { $o.UserName = $u; break }
        Say $p 'Yellow'
        if ($UserName) { throw $p }
    }
    if ($ForLinux) { $o.FullName = if ($FullName) { $FullName } elseif ($UserName) { '' } else { Read-CliLine -Prompt 'Your name (optional)' } }
    $o.ComputerName = if ($ComputerName) { $ComputerName } else { Read-CliLine -Prompt 'Computer name (empty = automatic)' }
    $hostProblem = if ($ForLinux) { Test-DzLinuxHostName -Name $o.ComputerName } else { Test-DzComputerName -Name $o.ComputerName }
    if ($hostProblem) { throw $hostProblem }
    $o.Password = Read-CliPassword
    $o.Temporary = [bool]$TemporaryPassword
    $o.Language = if ($Language) { $Language } else { Read-CliLine -Prompt 'Language (like en-US, ru-RU, de-DE)' -Default $defaults.Culture }
    $o.Keyboard = if ($Keyboard) { $Keyboard } else { $defaults.InputLocale }
    $o.TimeZone = if ($TimeZone) { $TimeZone } elseif ($ForLinux) { $defaults.TimeZoneIana } else { $defaults.TimeZoneWin }
    $modes = @('gaming', 'office', 'everything', 'custom')
    $o.Mode = if ($Mode) { $Mode } else { Read-CliChoice -Prompt 'Mode' -Items @($modes | ForEach-Object { [pscustomobject]@{ Label = $_.ToUpperInvariant(); Value = $_ } }) -Default 1 }
    return $o
}

function Confirm-Erase {
    param([object]$Target, [string[]]$Summary)
    Say ''
    foreach ($l in $Summary) { Say $l }
    Say ''
    Say 'EVERYTHING ON IT WILL BE ERASED:' 'Red'
    Write-Host ('   ' + $Target.Display) -ForegroundColor Red
    $name = Split-Path -Leaf $Target.Path
    $a = if ($PasswordStdin) { [Console]::In.ReadLine() } else { Read-Host -Prompt ((Get-DzText 'Type {0} to erase it, or anything else to stop') -f $name) }
    if ([string]$a -cne $name) { Say 'Cancelled.' 'Yellow'; exit 2 }
}

function New-StagingDir {
    $d = Join-Path $script:CacheBase ('staging-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void](New-Item -ItemType Directory -Path $d -Force)
    return $d
}

function Write-UbuntuStick {
    param([object]$Target, [hashtable]$Account, [string]$Kind)
    $loc = ConvertTo-DzLinuxLocale -Culture $Account.Language
    $kb = ConvertTo-DzLinuxKeyboard -InputLocale $Account.Keyboard
    $tz = ConvertTo-DzLinuxTimeZone -Id $Account.TimeZone
    if (-not $kb.Known) { Say 'The keyboard is set to US English (your layout has no Linux name DayZero knows).' 'Yellow' }
    $catalog = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:KitRoot 'linux/apps.json') | ConvertFrom-Json
    $apps = @($catalog.apps | Where-Object { $Account.Mode -eq 'everything' -or @($_.modes) -contains $Account.Mode } | ForEach-Object { [string]$_.id })
    $distroName = if ($Kind -eq 'ubuntu-iso') { 'Ubuntu' } else { [string](Get-DzLinuxDistro -Id $Kind).name }
    $buildId = New-DzBuildId
    $settings = [ordered]@{
        buildId = $buildId; builderVersion = $script:Version; createdAt = (Get-Date).ToString('s'); builtOn = 'linux'
        distro = $(if ($Kind -eq 'ubuntu-iso') { 'ubuntu-iso' } else { $Kind }); distroName = $distroName
        userName = $Account.UserName; defaultMode = $Account.Mode; apps = $apps; appsExact = $true
        appLanguage = (Get-DzLanguage); installDrivers = (-not $NoDrivers); dryRun = [bool]$DryRun; temporaryPassword = $Account.Temporary
    }
    $yaml = New-DzAutoinstallYaml -Options @{
        UserName = $Account.UserName; FullName = $Account.FullName; HostName = $Account.ComputerName
        PasswordHash = (ConvertTo-DzSha512Crypt -Password $Account.Password); Locale = $loc.Locale
        Keyboard = @{ Layout = $kb.Layout; Variant = $kb.Variant; Toggle = $kb.Toggle }; TimeZone = $tz.TimeZone
        BuildId = $buildId; Drivers = (-not $NoDrivers); Codecs = (-not $NoCodecs)
    }
    Confirm-Erase -Target $Target -Summary @(
        ((Get-DzText 'Make a {0} install USB with DayZero on this stick?') -f $distroName),
        ((Get-DzText 'Account: {0}{1}') -f $Account.UserName, $(if ($Account.Temporary) { Get-DzText ' (temporary password)' } else { '' })),
        ((Get-DzText 'On Linux: {0}, keyboard {1}, {2}') -f $loc.Locale, $kb.Layout, $tz.TimeZone),
        ((Get-DzText 'Mode: {0}, {1} apps') -f $Account.Mode, $apps.Count),
        'The Ubuntu installer will stop and let you choose the disk. Everything else runs on its own.'
    )
    $tick = { param($t) Write-CliTick $t }
    $log = { param($m) Write-Host ''; Write-CliLog $m }
    $iso = if ($Kind -eq 'ubuntu-iso') { $IsoPath } else { (Get-DzLinuxIso -DistroId $Kind -CacheRoot (Join-Path $script:CacheBase 'linux') -Tick $tick -Log $log).Path }
    $staging = New-StagingDir
    try {
        Invoke-DzWithIsoContent -IsoPath $iso -WorkDir $script:CacheBase -Tick $tick -Log $log -Action {
            param($root)
            if (-not (Test-Path -LiteralPath (Join-Path $root 'casper'))) { throw 'This ISO has no casper folder, so it is not Ubuntu Desktop. Use "Another Linux ISO file" for other systems.' }
            $fat = Get-DzFat32Problem -Root $root
            if ($fat) { throw $fat }
            $fit = Get-DzMediaFitProblem -MediaBytes (Get-DzFolderSize -Path $root) -DiskBytes $Target.Size
            if ($fit) { throw $fit }
            $part = Initialize-DzLinuxUsbDisk -Disk $Target -Tick $tick -Log $log
            $fatTarget = Open-DzFatTarget -Partition $part -Log $log
            try {
                Copy-DzTreeToFat -Source $root -Target $fatTarget -Label 'Copying Ubuntu to the USB stick' -Tick $tick
                Write-Host ''
                [void](Write-DzLinuxKitToTarget -TargetRoot $staging -KitSource $script:KitRoot -AutoinstallYaml $yaml -Settings $settings -Log $log)
                Copy-DzTreeToFat -Source $staging -Target $fatTarget -Label 'Adding DayZero to the stick' -Tick $tick
                Write-Host ''
                if ($fatTarget.Kind -eq 'mount') { $checks = @(Test-DzLinuxStick -Root $fatTarget.Root) }
                else {
                    $have = @(Get-DzFatFileList -Target $fatTarget)
                    $checks = @(Test-DzLinuxStick -Root $staging -KitOnly) + @([pscustomobject]@{ Name = 'Ubuntu system files'; Ok = (@($have | Where-Object { $_ -like '/casper/*.squashfs' }).Count -gt 0); Detail = "$($have.Count) files on the stick" })
                }
                foreach ($c in $checks) { Write-CliLog ('Check: {0}: {1} ({2})' -f $c.Name, $(if ($c.Ok) { 'OK' } else { 'PROBLEM' }), $c.Detail) }
                if (@($checks | Where-Object { -not $_.Ok }).Count -gt 0) { throw 'The stick check found problems (see above).' }
            }
            finally { Close-DzFatTarget -Target $fatTarget -Log $log }
        }
    }
    finally { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
    Say ''
    Say 'All done!' 'Green'
    Say "Next steps:`n 1. Eject the stick safely.`n 2. Boot the PC from it (boot menu key is often F12, F11, F8 or Esc).`n 3. When the Ubuntu installer asks where to install, pick the disk yourself.`n 4. Everything else runs on its own; DayZero finishes the setup after the first start."
}

function Write-WindowsStick {
    param([object]$Target, [hashtable]$Account, [string]$Kind)
    $winVer = if ($Kind -eq 'windows10') { 10 } else { 11 }
    $culture = $Account.Language
    if ($Kind -ne 'windows-iso' -and (@(Get-DzWindowsLanguageList) -notcontains $culture)) { throw "Microsoft has no Windows download in $culture. Pick another display language." }
    $kbProblem = Test-DzInputLocale -Value $Account.Keyboard
    if ($kbProblem) { throw $kbProblem }
    $tzWin = $Account.TimeZone
    if ($tzWin -match '/') { $w = $null; if ([System.TimeZoneInfo]::TryConvertIanaIdToWindowsId($tzWin, [ref]$w)) { $tzWin = $w } else { $tzWin = 'UTC' } }
    $buildId = New-DzBuildId
    $options = @{
        Architecture = 'amd64'; UILanguage = $culture; UserLocale = $culture; SystemLocale = $culture; InputLocale = $Account.Keyboard
        TimeZone = $tzWin; Edition = $Edition; ProductKey = ''; UserName = $Account.UserName; Password = $Account.Password
        AutoLogon = $true; AutoLogonCount = 10; ComputerName = $Account.ComputerName; GeneratorVersion = $script:Version; BuildId = $buildId
    }
    $settings = [ordered]@{
        schemaVersion = 1; buildId = $buildId; builtAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); builderVersion = $script:Version
        builtOn = 'linux'; windowsVersion = $winVer; edition = $Edition; userName = $Account.UserName; computerName = $Account.ComputerName
        temporaryPassword = $Account.Temporary; autoLogon = $true; autoLogonCount = 10; defaultMode = $Account.Mode; debloatLevel = $CleanupLevel
        dryRun = [bool]$DryRun; appLanguage = (Get-DzLanguage); tiny11 = $false; officePlan = 'personal'; uiLanguage = $culture
        userLocale = $culture; inputLocale = $Account.Keyboard; timeZone = $tzWin; mediaBuild = $null
    }
    $xml = New-DzUnattendXml -Options $options
    Confirm-Erase -Target $Target -Summary @(
        ("Make a Windows $winVer install USB with DayZero on this stick?"),
        ((Get-DzText 'Account: {0}{1}') -f $Account.UserName, $(if ($Account.Temporary) { Get-DzText ' (temporary password)' } else { '' })),
        ("Default mode: $($Account.Mode), clean-up level: $CleanupLevel$(if ($DryRun) { ' (DRY RUN)' })"),
        'Booting a PC from this stick starts an automatic Windows install, but Setup will always stop and let you choose the disk.',
        'Made on Linux, the stick boots on UEFI PCs only.'
    )
    $tick = { param($t) Write-CliTick $t }
    $log = { param($m) Write-Host ''; Write-CliLog $m }
    $staging = New-StagingDir
    try {
        $copy = {
            param($root, [string[]]$exclude)
            $fit = Get-DzMediaFitProblem -MediaBytes (Get-DzFolderSize -Path $root) -DiskBytes $Target.Size
            if ($fit) { throw $fit }
            $bigWim = $null
            $wim = Join-Path $root 'sources/install.wim'
            if ((Test-Path -LiteralPath $wim) -and (Get-Item -LiteralPath $wim).Length -gt 4294967295) { $bigWim = $wim }
            $part = Initialize-DzLinuxUsbDisk -Disk $Target -Tick $tick -Log $log
            $fatTarget = Open-DzFatTarget -Partition $part -Log $log
            try {
                Copy-DzTreeToFat -Source $root -Target $fatTarget -Label 'Copying Windows to the USB stick' -ExcludeFile $(if ($bigWim) { @('install.wim') } else { @() }) -Tick $tick
                Write-Host ''
                if ($bigWim) {
                    $split = Join-Path $staging 'sources'
                    [void](New-Item -ItemType Directory -Path $split -Force)
                    Split-DzWimLinux -WimPath $bigWim -OutDir $split -Tick $tick
                }
                [void](Write-DzKitToTarget -TargetRoot $staging -KitSource $script:KitRoot -UnattendXml $xml -Settings $settings -Log $log)
                Copy-DzTreeToFat -Source $staging -Target $fatTarget -Label 'Adding DayZero to the stick' -Tick $tick
                Write-Host ''
                if ($fatTarget.Kind -eq 'mount') {
                    $checks = @(Test-DzUsbStick -Root $fatTarget.Root)
                    foreach ($c in $checks) { Write-CliLog ('Check: {0}' -f (($c.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ' ')) }
                }
                Write-CliLog 'No legacy BIOS boot code: bootsect only runs on Windows. The stick boots on UEFI PCs.'
            }
            finally { Close-DzFatTarget -Target $fatTarget -Log $log }
        }
        if ($Kind -eq 'windows-iso') {
            Invoke-DzWithIsoContent -IsoPath $IsoPath -WorkDir $script:CacheBase -Tick $tick -Log $log -Action {
                param($root)
                if (-not (Find-DzInstallImage -Root $root)) { throw 'This ISO has no sources\install.wim or install.esd, so it is not Windows installation media.' }
                & $copy $root
            }
        }
        else {
            $tree = Get-DzWindowsMediaTreeLinux -WindowsVersion $winVer -Language $culture -CacheRoot (Join-Path $script:CacheBase 'windows') -Tick $tick -Log $log
            & $copy $tree
        }
    }
    finally { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
    Say ''
    Say 'All done!' 'Green'
    Say "Next steps:`n 1. Eject the stick safely.`n 2. Boot the PC from it (boot menu key is often F12, F11, F8 or Esc).`n 3. When Setup asks where to install Windows, pick the disk yourself.`n 4. Everything else runs on its own; the DayZero wizard starts after the first sign-in."
}

function Write-RawStick {
    <# An ISO written to the stick as it is: your file (-IsoPath), or a distro downloaded from its own site. #>
    param([object]$Target, [string]$DistroId)
    $tick = { param($t) Write-CliTick $t }
    $log = { param($m) Write-Host ''; Write-CliLog $m }
    $image = $IsoPath
    $what = Split-Path -Leaf ([string]$IsoPath)
    if ($DistroId) {
        # Downloaded and checked before anything is erased: if this fails, the stick is untouched.
        $image = (Get-DzLinuxIso -DistroId $DistroId -CacheRoot (Join-Path $script:CacheBase 'linux') -Tick $tick -Log $log).Path
        Write-Host ''
        $what = Split-Path -Leaf $image
    }
    if (-not $image -or -not (Test-Path -LiteralPath $image -PathType Leaf)) { throw 'Pick the ISO file.' }
    $size = (Get-Item -LiteralPath $image).Length
    if ($size -gt ($Target.Size - 1MB)) { throw ((Get-DzText 'The image needs {0} GB but the stick only holds {1} GB.') -f ('{0:N1}' -f ($size / 1GB)), ('{0:N1}' -f ($Target.Size / 1GB))) }
    Confirm-Erase -Target $Target -Summary @(((Get-DzText 'Write {0} to this stick as it is?') -f $what))
    [void](Initialize-DzLinuxUsbDisk -Disk $Target -CleanOnly -Tick $tick -Log $log)
    $stream = Open-DzRawDisk -DevicePath $Target.Path
    try { $hash = Write-DzImageToStream -ImagePath $image -Stream $stream -DiskBytes $Target.Size -Tick $tick }
    finally { $stream.Dispose() }
    [void](Invoke-DzTool -FilePath 'sync')
    Write-Host ''
    Write-CliLog "Written and read back, SHA-256 $hash"
    Say ((Get-DzText 'Done! {0} is on the stick and was read back to check it.') -f $what) 'Green'
}

# ------------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------------

[void](Import-DzLanguage -KitRoot $script:KitRoot)
$langCode = if ($AppLanguage) { $AppLanguage } elseif ($env:LANG -like 'ru*') { 'ru' } else { 'en' }
[void](Set-DzLanguage -Code $langCode)

Say ("DAYZERO USB BUILDER  v$($script:Version)  (Linux)") 'Cyan'
if ($ListDisks) { [void](Show-Disks); exit 0 }
if ($Verify) {
    $checks = if (Test-Path -LiteralPath (Join-Path $Verify 'autoinstall.yaml')) { @(Test-DzLinuxStick -Root $Verify) } else { @(Test-DzUsbStick -Root $Verify) }
    $checks | Format-Table -AutoSize | Out-String | Write-Host
    exit 0
}
if ([System.Environment]::UserName -ne 'root' -and (& id -u) -ne '0') { Say 'Run this as root: sudo ./build-dayzero-usb.sh' 'Red'; exit 1 }

try {
    $choice = Select-System
    $kind = [string]$choice.Value
    if (@('windows-iso', 'ubuntu-iso', 'linux-iso') -contains $kind -and -not $IsoPath) { $IsoPath = Read-CliLine -Prompt 'Path of the ISO file' }
    if ($IsoPath -and -not (Test-Path -LiteralPath $IsoPath -PathType Leaf)) { throw "ISO file not found: $IsoPath" }
    $target = Select-Disk
    switch ($choice.Kind) {
        'raw' { Write-RawStick -Target $target -DistroId $(if ($kind -eq 'linux-iso') { '' } else { $kind }) }
        'windows' { Write-WindowsStick -Target $target -Account (Read-Account -ForLinux $false) -Kind $kind }
        default { Write-UbuntuStick -Target $target -Account (Read-Account -ForLinux $true) -Kind $kind }
    }
    exit 0
}
catch {
    Write-Host ''
    Say ('Failed: ' + (Get-DzText $_.Exception.Message)) 'Red'
    Write-CliLog ('ERROR: ' + $_.Exception.Message)
    exit 1
}
