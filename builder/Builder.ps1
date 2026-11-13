#Requires -Version 5.1
<#
.SYNOPSIS
    DayZero USB Builder.
.DESCRIPTION
    Makes a Windows installation USB stick (Windows is downloaded from Microsoft or taken
    from an ISO file you have; see lib\WinMedia.psm1) and puts an unattended-setup answer
    file (autounattend.xml) and the DayZero toolkit on it. It can also add those two to a
    stick you already made with the Media Creation Tool or Rufus, without touching the
    rest of that stick.

    Start it with Build-DayZeroUSB.cmd, which asks for administrator rights (needed to
    read the Windows image on the stick) and bypasses the execution policy for this one
    PowerShell process only.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$script:BuilderRoot = $PSScriptRoot
$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:KitRoot = Join-Path $script:RepoRoot 'kit'
$script:Version = (Get-Content -LiteralPath (Join-Path $script:KitRoot 'VERSION') -Raw).Trim()
$script:LogLines = New-Object System.Collections.Generic.List[string]
$script:MediaByDrive = @{}
$script:IsoMedia = $null
$script:Busy = $false
$script:GeneratedPassword = $null
$script:ThisPcFirmware = $null
$script:BuilderConfig = $null
$script:SelectedMode = 'gaming'
$script:SelectedLevel = 'standard'
$script:LevelCards = @()
$script:ModeCards = @()
$script:CustomSelection = $null
$script:ui = $null
$script:Window = $null

# ------------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------------

function Invoke-BuilderPump {
    <#
        Lets the window handle everything that is waiting (repaint, move, minimise, scroll the
        log) in the middle of a long job. Without it the window looks frozen until the job ends.
        Only used while Set-BuilderBusy has the form disabled, so no second job can start.
    #>
    if (-not $script:Window) { return }
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    [void]$script:Window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [System.Action] { $frame.Continue = $false })
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}

function Set-BuilderBusy {
    <# Disables the form while a long job runs (the window itself stays movable and the log readable). #>
    param([Parameter(Mandatory = $true)][bool]$Busy, [switch]$ShowProgress)
    $script:Busy = $Busy
    $ui = $script:ui
    $ui.BuildProgress.Value = 0
    $ui.BuildProgress.Visibility = if ($Busy -and $ShowProgress) { 'Visible' } else { 'Collapsed' }
    $ui.BodyGrid.IsEnabled = -not $Busy
    $ui.PreviewButton.IsEnabled = -not $Busy
    $ui.WriteButton.IsEnabled = -not $Busy
    $script:Window.Cursor = if ($Busy) { [System.Windows.Input.Cursors]::AppStarting } else { $null }
    Invoke-DzUiRefresh -Element $script:Window
}

function Write-BuilderLog {
    param([Parameter(Mandatory = $true)][string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    $script:LogLines.Add($line)
    if ($script:ui -and $script:ui.ContainsKey('LogText')) {
        $script:ui.LogText.AppendText($line + [Environment]::NewLine)
        $script:ui.LogText.ScrollToEnd()
    }
    if ($script:Busy) { Invoke-BuilderPump }
}

function Set-BuilderStatus {
    param([Parameter(Mandatory = $true)][string]$Text, [ValidateSet('Info', 'Ok', 'Warn', 'Error')][string]$Kind = 'Info')
    $brush = switch ($Kind) {
        'Ok' { 'DzGreen' }
        'Warn' { 'DzYellow' }
        'Error' { 'DzRed' }
        default { 'DzMuted' }
    }
    $script:ui.StatusText.Text = $Text
    $script:ui.StatusText.Foreground = [System.Windows.Application]::Current.FindResource($brush)
    if ($script:Busy) {
        # The bar only moves forward: each status line maps to a point in the whole job.
        $progress = Get-DzBuildProgress -Text $Text
        if ($null -ne $progress -and $progress -gt $script:ui.BuildProgress.Value) { $script:ui.BuildProgress.Value = $progress }
        Invoke-BuilderPump
    }
    else { Invoke-DzUiRefresh -Element $script:Window }
}

# ------------------------------------------------------------------------------------
# Data for the drop-downs
# ------------------------------------------------------------------------------------

function New-ListItem {
    param([string]$Label, [string]$Value)
    return [pscustomobject]@{ Label = $Label; Value = $Value }
}

function Get-CultureItem {
    param([Parameter(Mandatory = $true)][string]$Name)
    try {
        $c = [System.Globalization.CultureInfo]::GetCultureInfo($Name)
        return (New-ListItem -Label ('{0}  ({1})' -f $c.DisplayName, $c.Name) -Value $c.Name)
    }
    catch {
        return (New-ListItem -Label $Name -Value $Name)
    }
}

function Get-RegionItemList {
    $cultures = [System.Globalization.CultureInfo]::GetCultures([System.Globalization.CultureTypes]::SpecificCultures) |
        Sort-Object -Property DisplayName
    return @($cultures | ForEach-Object { New-ListItem -Label ('{0}  ({1})' -f $_.DisplayName, $_.Name) -Value $_.Name })
}

function Get-KeyboardItemList {
    # Keyboard layouts installed in Windows: HKLM\...\Keyboard Layouts\<KLID> 'Layout Text'.
    $items = New-Object System.Collections.Generic.List[object]
    $base = 'HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layouts'
    foreach ($key in @(Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue)) {
        $klid = $key.PSChildName
        if ($klid -notmatch '^[0-9A-Fa-f]{8}$') { continue }
        $text = $null
        try { $text = (Get-ItemProperty -LiteralPath $key.PSPath -Name 'Layout Text' -ErrorAction Stop).'Layout Text' } catch { $text = $null }
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        $value = ('{0}:{1}' -f $klid.Substring(4, 4), $klid).ToLowerInvariant()
        $items.Add((New-ListItem -Label ('{0}  ({1})' -f $text, $value) -Value $value))
    }
    return @($items | Sort-Object -Property Label)
}

function Get-TimeZoneItemList {
    return @([System.TimeZoneInfo]::GetSystemTimeZones() | ForEach-Object { New-ListItem -Label $_.DisplayName -Value $_.Id })
}

function Get-CurrentKeyboardValue {
    try {
        $tip = @((Get-WinUserLanguageList)[0].InputMethodTips)[0]
        if ($tip) { return ([string]$tip).ToLowerInvariant() }
    }
    catch { Write-Verbose 'Could not read the current keyboard layout.' }
    return '0409:00000409'
}

function Select-ComboValue {
    <# Selects the item whose Value matches; adds it to the list first if it is missing. #>
    param([Parameter(Mandatory = $true)][object]$Combo, [AllowNull()][string]$Value, [string]$Label)
    if ([string]::IsNullOrWhiteSpace($Value)) { return }
    $match = @($Combo.ItemsSource | Where-Object { $_.Value -ieq $Value }) | Select-Object -First 1
    if ($null -eq $match) {
        if (-not $Label) { $Label = $Value }
        $list = New-Object System.Collections.Generic.List[object]
        $list.Add((New-ListItem -Label $Label -Value $Value))
        foreach ($i in @($Combo.ItemsSource)) { $list.Add($i) }
        $Combo.ItemsSource = $list.ToArray()
        $match = $list[0]
    }
    $Combo.SelectedItem = $match
}

function Set-RegionFromThisPc {
    $ui = $script:ui
    Select-ComboValue -Combo $ui.DisplayLanguageCombo -Value (Get-UICulture).Name
    Select-ComboValue -Combo $ui.RegionCombo -Value (Get-Culture).Name
    $kb = Get-CurrentKeyboardValue
    Select-ComboValue -Combo $ui.KeyboardCombo -Value $kb -Label ("This PC's keyboard ($kb)")
    Select-ComboValue -Combo $ui.TimeZoneCombo -Value ([System.TimeZoneInfo]::Local.Id)
    Write-BuilderLog 'Copied language, region, keyboard and time zone from this PC.'
}

# ------------------------------------------------------------------------------------
# Target (USB stick or folder) and media info
# ------------------------------------------------------------------------------------

function Update-DriveList {
    $ui = $script:ui
    Set-BuilderStatus -Text 'Looking for Windows installation USB sticks...'
    $drives = @(Get-DzInstallMediaCandidate)
    $ui.DriveCombo.ItemsSource = $drives
    if ($drives.Count -gt 0) {
        $ui.DriveCombo.SelectedIndex = 0
        Write-BuilderLog ("Found {0} Windows installation drive(s)." -f $drives.Count)
        Set-BuilderStatus -Text 'Ready.'
    }
    else {
        $ui.MediaInfoText.Text = 'No Windows installation USB found. Make one with the Media Creation Tool or Rufus, plug it in, then press Refresh.'
        Set-BuilderStatus -Text 'No installation USB found yet.' -Kind Warn
        Write-BuilderLog 'No Windows installation media found.'
    }
}

function Update-MediaInfo {
    $ui = $script:ui
    $drive = $ui.DriveCombo.SelectedItem
    if ($null -eq $drive) { return }
    if (-not $script:MediaByDrive.ContainsKey($drive.Drive)) {
        Set-BuilderStatus -Text ("Reading the Windows image on {0} ..." -f $drive.Drive)
        $script:Window.Cursor = [System.Windows.Input.Cursors]::Wait
        try {
            $script:MediaByDrive[$drive.Drive] = Get-DzMediaInfo -ImagePath $drive.ImagePath
        }
        finally {
            $script:Window.Cursor = $null
        }
    }
    $info = $script:MediaByDrive[$drive.Drive]
    $lines = New-Object System.Collections.Generic.List[string]
    if ($info.Error) {
        $lines.Add("Could not read the Windows image: $($info.Error)")
        Write-BuilderLog "Media read error on $($drive.Drive): $($info.Error)"
    }
    else {
        $editionNames = @($info.Editions | ForEach-Object { ($_.Name -replace '^Windows 1[01] ', '') })
        $lines.Add(('Windows {0} (build {1}), {2}, language {3}.' -f $info.WindowsVersion, $info.Build, $info.Architecture, ($info.Languages -join ', ')))
        $lines.Add(('Editions: {0}' -f ($editionNames -join ', ')))
        if ($info.WindowsVersion -eq 10) { $ui.Win10Radio.IsChecked = $true } elseif ($info.WindowsVersion -eq 11) { $ui.Win11Radio.IsChecked = $true }
        if ($info.Architecture -eq 'x86') { $lines.Add('32-bit media is not supported by DayZero.') }
        Write-BuilderLog ("{0}: Windows {1} build {2} {3}, {4} edition(s)." -f $drive.Drive, $info.WindowsVersion, $info.Build, $info.Architecture, $info.Editions.Count)

        # Display language must exist on the media.
        if ($info.Languages.Count -gt 0) {
            $ui.DisplayLanguageCombo.ItemsSource = @($info.Languages | ForEach-Object { Get-CultureItem -Name $_ })
            Select-ComboValue -Combo $ui.DisplayLanguageCombo -Value $info.DefaultLanguage
        }
    }
    if ($drive.HasAnswer) {
        $lines.Add('This stick already has an autounattend.xml (for example from Rufus "Windows User Experience" options). It will be renamed to a backup, not deleted.')
    }
    if ($drive.FreeMB -lt 200) { $lines.Add(("Only {0} MB free on the stick. DayZero needs about 50 MB plus any drivers you add." -f $drive.FreeMB)) }
    $ui.MediaInfoText.Text = ($lines -join [Environment]::NewLine)
    Update-EditionHint
    Set-BuilderStatus -Text 'Ready.'
}

function Get-TargetKind {
    <# 'newusb' (make the Windows stick), 'usb' (a stick that already has Windows) or 'folder'. #>
    $ui = $script:ui
    if ($ui.TargetNewUsbRadio.IsChecked -eq $true) { return 'newusb' }
    if ($ui.TargetUsbRadio.IsChecked -eq $true) { return 'usb' }
    return 'folder'
}

function Update-UsbDiskList {
    $ui = $script:ui
    Set-BuilderStatus -Text 'Looking for USB sticks...'
    $all = @(Get-DzUsbDiskCandidate)
    foreach ($d in @($all | Where-Object { $_.Problem })) { Write-BuilderLog ("Not offered: {0}. {1}" -f $d.Display, $d.Problem) }
    $ok = @($all | Where-Object { -not $_.Problem })
    $ui.UsbDiskCombo.ItemsSource = $ok
    if ($ok.Count -gt 0) { $ui.UsbDiskCombo.SelectedIndex = 0 }
    Write-BuilderLog ("Found {0} USB stick(s) that can be used." -f $ok.Count)
    Update-NewUsbInfo
    if ($ok.Count -gt 0) { Set-BuilderStatus -Text 'Ready.' } else { Set-BuilderStatus -Text 'No USB stick found yet.' -Kind Warn }
}

function Update-NewUsbInfo {
    <# The hint under "Make a new Windows USB stick": what gets erased and where Windows comes from. #>
    $ui = $script:ui
    if ((Get-TargetKind) -ne 'newusb') { return }
    $lines = New-Object System.Collections.Generic.List[string]
    $disk = $ui.UsbDiskCombo.SelectedItem
    if ($null -eq $disk) {
        $lines.Add('No USB stick found. Plug one in (8 GB or more) and press Refresh. Internal disks and drives over 300 GB are never offered.')
    }
    else {
        $lines.Add(('EVERYTHING on this stick will be erased: {0}, {1} GB{2}.' -f $disk.Name, $disk.SizeGB, $(if ($disk.Volumes) { ', ' + $disk.Volumes } else { '' })))
        if ($disk.SizeGB -gt 33) { $lines.Add('It gets one 32 GB partition (the FAT32 limit); the rest of the stick stays unused.') }
    }
    if ($ui.SourceIsoRadio.IsChecked -eq $true) {
        $info = $script:IsoMedia
        if ($null -eq $info) { $lines.Add('Pick a Windows 10 or 11 ISO file from Microsoft.') }
        elseif ($info.Error) { $lines.Add("Could not read the ISO file: $($info.Error)") }
        else {
            $lines.Add(('ISO: Windows {0} (build {1}), {2}, language {3}.' -f $info.WindowsVersion, $info.Build, $info.Architecture, ($info.Languages -join ', ')))
            $lines.Add(('Editions: {0}' -f ((@($info.Editions | ForEach-Object { ($_.Name -replace '^Windows 1[01] ', '') })) -join ', ')))
        }
    }
    else {
        $winVer = if ($ui.Win10Radio.IsChecked -eq $true) { 10 } else { 11 }
        $lang = [string]$ui.DisplayLanguageCombo.SelectedValue
        $cached = $null
        if ($lang) { try { $cached = Get-DzPreparedMedia -WindowsVersion $winVer -Language $lang } catch { $cached = $null } }
        if ($cached) { $lines.Add("Windows $winVer ($lang) is already on this PC from last time; only a newer release would be downloaded.") }
        else { $lines.Add("Windows $winVer is downloaded from Microsoft (the files the Media Creation Tool uses), checked against Microsoft's checksum and kept for next time. The first time takes a while: about 5 GB to download, then 15 to 40 minutes to unpack.") }
    }
    $ui.MediaInfoText.Text = ($lines -join [Environment]::NewLine)
}

function Update-SourceMode {
    <# Download or ISO: fills the display-language list to match what the Windows media will contain. #>
    $ui = $script:ui
    $iso = ($ui.SourceIsoRadio.IsChecked -eq $true)
    $ui.IsoPanel.Visibility = if ($iso) { 'Visible' } else { 'Collapsed' }
    $info = $script:IsoMedia
    if ($iso -and $info -and -not $info.Error) {
        if ($info.WindowsVersion -eq 10) { $ui.Win10Radio.IsChecked = $true } elseif ($info.WindowsVersion -eq 11) { $ui.Win11Radio.IsChecked = $true }
        if (@($info.Languages).Count -gt 0) {
            $ui.DisplayLanguageCombo.ItemsSource = @($info.Languages | ForEach-Object { Get-CultureItem -Name $_ })
            Select-ComboValue -Combo $ui.DisplayLanguageCombo -Value $info.DefaultLanguage
        }
    }
    elseif (-not $iso) {
        $languages = @(Get-DzWindowsLanguageList)
        $ui.DisplayLanguageCombo.ItemsSource = @($languages | ForEach-Object { Get-CultureItem -Name $_ })
        $wanted = (Get-UICulture).Name
        if ($languages -notcontains $wanted) { $wanted = 'en-US' }
        Select-ComboValue -Combo $ui.DisplayLanguageCombo -Value $wanted
    }
    Update-NewUsbInfo
}

function Read-IsoMedia {
    <# Mounts the picked ISO for a moment and reads which Windows is inside. #>
    $path = $script:ui.IsoPathText.Text.Trim()
    $script:IsoMedia = $null
    if (-not $path) { Update-SourceMode; return }
    Set-BuilderStatus -Text 'Reading the ISO file...'
    $script:Window.Cursor = [System.Windows.Input.Cursors]::Wait
    try {
        $script:IsoMedia = Invoke-DzWithMountedIso -IsoPath $path -Action {
            param($root)
            $image = Find-DzInstallImage -Root $root
            if (-not $image) { throw 'It has no sources\install.wim or install.esd, so it is not Windows installation media.' }
            Get-DzMediaInfo -ImagePath $image
        }
    }
    catch {
        $script:IsoMedia = [pscustomobject]@{ Error = $_.Exception.Message }
    }
    finally {
        $script:Window.Cursor = $null
    }
    if ($script:IsoMedia.Error) { Write-BuilderLog "ISO read error: $($script:IsoMedia.Error)" }
    else { Write-BuilderLog ("ISO {0}: Windows {1} build {2} {3}." -f $path, $script:IsoMedia.WindowsVersion, $script:IsoMedia.Build, $script:IsoMedia.Architecture) }
    Update-SourceMode
    Set-BuilderStatus -Text 'Ready.'
}

function Select-IsoFile {
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Title = 'Pick a Windows 10 or 11 ISO file'
    $dialog.Filter = 'Windows ISO files (*.iso)|*.iso'
    if ($dialog.ShowDialog($script:Window) -eq $true) {
        $script:ui.IsoPathText.Text = $dialog.FileName
        Read-IsoMedia
    }
}

function Update-TargetMode {
    $ui = $script:ui
    $kind = Get-TargetKind
    $ui.NewUsbPanel.Visibility = if ($kind -eq 'newusb') { 'Visible' } else { 'Collapsed' }
    $ui.UsbPanel.Visibility = if ($kind -eq 'usb') { 'Visible' } else { 'Collapsed' }
    $ui.FolderPanel.Visibility = if ($kind -eq 'folder') { 'Visible' } else { 'Collapsed' }
    $ui.WriteButton.Content = switch ($kind) {
        'newusb' { "_CREATE WINDOWS USB  $([char]0x25B6)" }
        'usb' { "_WRITE TO USB  $([char]0x25B6)" }
        default { "_EXPORT TO FOLDER  $([char]0x25B6)" }
    }
    if ($kind -eq 'newusb') {
        Update-SourceMode
    }
    elseif ($kind -eq 'usb') {
        Update-DriveList
    }
    else {
        $ui.MediaInfoText.Text = ('Writes autounattend.xml and the DayZero folder into an empty folder. ' +
            'Make an ISO of it with tools\New-DzTestIso.ps1 and attach it to your test VM next to the Windows ISO (see TESTING.md).')
        $ui.DisplayLanguageCombo.ItemsSource = Get-RegionItemList
        Select-ComboValue -Combo $ui.DisplayLanguageCombo -Value (Get-UICulture).Name
    }
}

function Select-ExportFolder {
    # Shell folder picker (COM), so no Windows Forms dependency is needed.
    $shell = New-Object -ComObject Shell.Application
    $folder = $shell.BrowseForFolder(0, 'Pick an empty folder for the DayZero test files', 0x50, 0)
    if ($null -ne $folder) {
        $path = $folder.Self.Path
        if ($path -and (Test-Path -LiteralPath $path -PathType Container)) { $script:ui.FolderText.Text = $path }
    }
}

# ------------------------------------------------------------------------------------
# Edition and password helpers
# ------------------------------------------------------------------------------------

function Update-EditionHint {
    $ui = $script:ui
    $edition = [string]$ui.EditionCombo.SelectedValue
    $ui.ProductKeyText.Visibility = if ($edition -eq 'key') { 'Visible' } else { 'Collapsed' }
    $text = switch ($edition) {
        'auto' { "Setup reads the product key built into the PC's firmware (most laptops and prebuilt PCs have one), installs that edition, and Windows activates by itself. PCs without one show Setup's normal edition picker." }
        'home' { "Installs Home using Microsoft's generic install key. It selects the edition but never activates. Windows activates on its own only if the PC has a Home licence (firmware key or digital licence)." }
        'pro' { "Installs Pro using Microsoft's generic install key. It selects the edition but never activates. Windows activates on its own only if the PC has a Pro licence. A PC with a Home key would end up with an unactivated Pro." }
        'key' { 'Type your own product key. It decides the edition, and it is stored in plain text in autounattend.xml on the stick.' }
        default { '' }
    }
    if ($null -eq $script:ThisPcFirmware) { $script:ThisPcFirmware = [string](Get-DzThisPcFirmwareEdition) }
    $fw = $script:ThisPcFirmware
    if ($fw) { $text += " (This PC - the one running the builder - has a built-in $fw key.)" }
    $ui.EditionHintText.Text = $text
}

function New-TemporaryPassword {
    $words = @('Neon', 'Pixel', 'Laser', 'Turbo', 'Comet', 'Synth', 'Nova', 'Vapor', 'Retro', 'Rocket', 'Orbit', 'Cyber', 'Glitch', 'Arcade', 'Chrome', 'Sunset')
    $bytes = New-Object byte[] 4
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $number = ([System.BitConverter]::ToUInt16($bytes, 2) % 9000) + 1000
    return ('{0}-{1}-{2}' -f $words[$bytes[0] % $words.Count], $words[$bytes[1] % $words.Count], $number)
}

# ------------------------------------------------------------------------------------
# Collect + validate everything the user entered
# ------------------------------------------------------------------------------------

function Get-BuilderInput {
    $ui = $script:ui
    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]

    $target = $null
    $media = $null
    $kind = Get-TargetKind
    $isUsb = ($kind -eq 'usb')
    $usbDisk = $null
    $source = $null
    $isoPath = $null
    if ($kind -eq 'newusb') {
        $usbDisk = $ui.UsbDiskCombo.SelectedItem
        if ($null -eq $usbDisk) { $errors.Add('Pick the USB stick to make into a Windows installer (plug one in and press Refresh).') }
        if ($ui.SourceIsoRadio.IsChecked -eq $true) {
            $source = 'iso'
            $isoPath = $ui.IsoPathText.Text.Trim()
            if (-not $isoPath) { $errors.Add('Pick the Windows ISO file (or switch to the download).') }
            elseif (-not (Test-Path -LiteralPath $isoPath -PathType Leaf)) { $errors.Add('The Windows ISO file is gone.') }
            elseif ($null -eq $script:IsoMedia -or $script:IsoMedia.Error) { $errors.Add('The Windows ISO file could not be read. Pick another one.') }
            else { $media = $script:IsoMedia }
        }
        else { $source = 'download' }
    }
    elseif ($isUsb) {
        $drive = $ui.DriveCombo.SelectedItem
        if ($null -eq $drive) { $errors.Add('Pick the Windows installation USB stick (or switch to Folder).') }
        else {
            $target = $drive.Root
            if ($script:MediaByDrive.ContainsKey($drive.Drive)) { $media = $script:MediaByDrive[$drive.Drive] }
            if (-not (Test-Path -LiteralPath $drive.Root)) { $errors.Add("Drive $($drive.Drive) is gone. Plug it back in and press Refresh.") }
        }
    }
    else {
        $folder = $ui.FolderText.Text.Trim()
        if (-not $folder) { $errors.Add('Pick an export folder.') }
        elseif (-not (Test-Path -LiteralPath $folder -PathType Container)) { $errors.Add('The export folder does not exist.') }
        else { $target = $folder }
    }

    $winVer = if ($ui.Win10Radio.IsChecked -eq $true) { 10 } else { 11 }
    if ($media -and -not $media.Error -and $media.WindowsVersion -and $media.WindowsVersion -ne $winVer) {
        $errors.Add("The Windows media contains Windows $($media.WindowsVersion), but Windows $winVer is selected.")
    }
    $arch = 'amd64'
    if ($media -and -not $media.Error) {
        if ($media.Architecture -eq 'x86') { $errors.Add('32-bit Windows media is not supported.') }
        elseif ($media.Architecture -eq 'arm64') { $arch = 'arm64'; $warnings.Add('ARM64 media: the answer file works, but some DayZero apps and drivers are x64-only.') }
    }

    $edition = [string]$ui.EditionCombo.SelectedValue
    $productKey = $ui.ProductKeyText.Text.Trim().ToUpperInvariant()
    if ($edition -eq 'key') {
        $p = Test-DzProductKey -Key $productKey
        if ($p) { $errors.Add($p) } else { $warnings.Add('Your product key is stored in plain text in autounattend.xml.') }
    }
    if ($media -and -not $media.Error -and ($edition -eq 'home' -or $edition -eq 'pro') -and
        -not (Test-DzMediaHasEdition -Editions $media.Editions -Edition $edition)) {
        $errors.Add("The Windows media has no plain Windows $winVer $edition edition.")
    }

    $userName = $ui.UserNameText.Text.Trim()
    $computerName = $ui.ComputerNameText.Text.Trim()
    foreach ($p in @((Test-DzUserName -Name $userName -ComputerName $computerName), (Test-DzComputerName -Name $computerName))) {
        if ($p) { $errors.Add($p) }
    }
    $pw1 = $ui.PasswordBox1.Password
    $pw2 = $ui.PasswordBox2.Password
    $temporary = ($ui.TempPasswordCheck.IsChecked -eq $true)
    if ($pw1 -eq '') { $errors.Add('Enter a password.') }
    elseif ($pw1 -cne $pw2) { $errors.Add('The two passwords do not match.') }
    elseif (-not $temporary -and $pw1.Length -lt 8) { $warnings.Add('The password is shorter than 8 characters.') }
    if (-not $temporary) { $warnings.Add('The password is stored base64-encoded (not encrypted) on the stick. Consider a temporary password.') }

    $display = [string]$ui.DisplayLanguageCombo.SelectedValue
    $region = [string]$ui.RegionCombo.SelectedValue
    $keyboard = [string]$ui.KeyboardCombo.SelectedValue
    $timeZone = [string]$ui.TimeZoneCombo.SelectedValue
    if (-not $display) { $errors.Add('Pick the Windows display language.') }
    if (-not $region) { $errors.Add('Pick a region format.') }
    if (-not $keyboard) { $errors.Add('Pick a keyboard layout.') }
    elseif (Test-DzInputLocale -Value $keyboard) { $errors.Add((Test-DzInputLocale -Value $keyboard)) }
    if (-not $timeZone) { $errors.Add('Pick a time zone.') }
    if ($media -and -not $media.Error -and $media.Languages.Count -gt 0 -and $display -and ($media.Languages -notcontains $display)) {
        $errors.Add("The display language must be one that is on the Windows media: $($media.Languages -join ', ').")
    }
    if ($source -eq 'download' -and $display -and (@(Get-DzWindowsLanguageList) -notcontains $display)) {
        $errors.Add("Microsoft has no Windows download in $display. Pick another display language.")
    }

    $mode = [string]$script:SelectedMode
    $modeDef = Get-DzMode -Config $script:BuilderConfig -Id $mode
    if ($modeDef.custom -and $null -eq $script:CustomSelection) {
        $warnings.Add("Custom mode with nothing picked yet: you'll tick everything on the new PC.")
    }

    $autoLogon = ($ui.AutoLogonCheck.IsChecked -eq $true)
    $dryRun = ($ui.DryRunCheck.IsChecked -eq $true)
    if (-not $autoLogon) { $warnings.Add('Automatic sign-in is off: after each restart you must sign in yourself for DayZero to continue.') }

    $options = @{
        Architecture     = $arch
        UILanguage       = $display
        UserLocale       = $region
        SystemLocale     = $region
        InputLocale      = $keyboard
        TimeZone         = $timeZone
        Edition          = $edition
        ProductKey       = $productKey
        UserName         = $userName
        Password         = $pw1
        AutoLogon        = $autoLogon
        AutoLogonCount   = 10
        ComputerName     = $computerName
        GeneratorVersion = $script:Version
    }
    $settings = [ordered]@{
        schemaVersion     = 1
        buildId           = $null
        builtAt           = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        builderVersion    = $script:Version
        windowsVersion    = $winVer
        edition           = $edition
        userName          = $userName
        computerName      = $computerName
        temporaryPassword = $temporary
        autoLogon         = $autoLogon
        autoLogonCount    = 10
        defaultMode       = $mode
        debloatLevel      = [string]$script:SelectedLevel
        dryRun            = $dryRun
        officePlan        = [string]$ui.OfficePlanCombo.SelectedValue
        uiLanguage        = $display
        userLocale        = $region
        inputLocale       = $keyboard
        timeZone          = $timeZone
        mediaBuild        = $(if ($media) { $media.Build } else { $null })
    }
    if ($modeDef.custom -and $null -ne $script:CustomSelection) { $settings.customSelection = $script:CustomSelection }
    return [pscustomobject]@{
        Errors   = $errors
        Warnings = $warnings
        Kind     = $kind
        IsUsb    = $isUsb
        UsbDisk  = $usbDisk
        Source   = $source
        IsoPath  = $isoPath
        Target   = $target
        Media    = $media
        Options  = $options
        Settings = $settings
    }
}

# ------------------------------------------------------------------------------------
# Default mode, "what's included" and the Custom picker
# ------------------------------------------------------------------------------------

function New-BuilderCard {
    <# One big radio card (mode or clean-up level). #>
    param([string]$Group, [string]$Id, [string]$Emoji, [string]$Title, [string]$Tagline, [string]$AccessibleName)
    $rb = New-Object System.Windows.Controls.RadioButton
    $rb.GroupName = $Group
    $rb.Style = Get-DzResource 'DzModeCard'
    $rb.Tag = $Id
    $rb.Margin = New-Object System.Windows.Thickness(5)
    $panel = New-Object System.Windows.Controls.StackPanel
    if ($Emoji) {
        # Monochrome Segoe icon glyph (modes.json "icon"); falls back to the emoji font for anything else.
        $e = New-Object System.Windows.Controls.TextBlock
        $e.Text = $Emoji
        $e.FontSize = 22
        $e.FontFamily = if ($Emoji.Length -eq 1 -and [int][char]$Emoji -ge 0xE000 -and [int][char]$Emoji -le 0xF8FF) { Get-DzResource 'DzIconFont' } else { Get-DzResource 'DzEmoji' }
        $e.Foreground = Get-DzResource 'DzText'
        $e.HorizontalAlignment = 'Center'
        [void]$panel.Children.Add($e)
    }
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Title
    $t.FontSize = 14
    $t.FontWeight = [System.Windows.FontWeights]::Black
    $t.HorizontalAlignment = 'Center'
    $t.Margin = New-Object System.Windows.Thickness(0, 4, 0, 0)
    [void]$panel.Children.Add($t)
    $g = New-Object System.Windows.Controls.TextBlock
    $g.Text = $Tagline
    $g.FontSize = 11
    $g.Foreground = Get-DzResource 'DzMuted'
    $g.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $g.TextAlignment = 'Center'
    [void]$panel.Children.Add($g)
    $rb.Content = $panel
    [System.Windows.Automation.AutomationProperties]::SetName($rb, $AccessibleName)
    return $rb
}

function Initialize-BuilderModeCards {
    $ui = $script:ui
    $ui.ModeCardsPanel.Children.Clear()
    $cards = New-Object System.Collections.Generic.List[object]
    foreach ($m in @(Get-DzModeList -Config $script:BuilderConfig)) {
        $title = [string](Get-DzProperty $m 'title' $m.id)
        $tagline = [string](Get-DzProperty $m 'tagline' '')
        $glyph = [string](Get-DzProperty $m 'icon' (Get-DzProperty $m 'emoji' ''))
        $rb = New-BuilderCard -Group 'Mode' -Id ([string]$m.id) -Emoji $glyph -Title $title -Tagline $tagline -AccessibleName ('{0} mode: {1}' -f $title, $tagline)
        $rb.Add_Checked({
                param($src)
                try { Select-BuilderMode -Id ([string]$src.Tag) } catch { Write-BuilderLog ('Mode preview failed: ' + $_.Exception.Message) }
            })
        [void]$ui.ModeCardsPanel.Children.Add($rb)
        $cards.Add($rb)
    }
    $script:ModeCards = $cards.ToArray()
}

function Initialize-BuilderLevelCards {
    $ui = $script:ui
    $ui.LevelCardsPanel.Children.Clear()
    $cards = New-Object System.Collections.Generic.List[object]
    foreach ($l in @(Get-DzDebloatLevelList -Config $script:BuilderConfig)) {
        $rb = New-BuilderCard -Group 'Level' -Id ([string]$l.id) -Emoji '' -Title ([string]$l.title).ToUpperInvariant() -Tagline ([string]$l.tagline) -AccessibleName ('{0} clean-up: {1}' -f $l.title, $l.tagline)
        $rb.Add_Checked({
                param($src)
                try { Select-BuilderLevel -Id ([string]$src.Tag) } catch { Write-BuilderLog ('Clean-up level preview failed: ' + $_.Exception.Message) }
            })
        [void]$ui.LevelCardsPanel.Children.Add($rb)
        $cards.Add($rb)
    }
    $script:LevelCards = $cards.ToArray()
}

function Select-BuilderLevel {
    param([Parameter(Mandatory = $true)][string]$Id)
    $script:SelectedLevel = $Id
    foreach ($c in $script:LevelCards) { if ([string]$c.Tag -eq $Id -and -not $c.IsChecked) { $c.IsChecked = $true } }
    $level = Get-DzDebloatLevel -Config $script:BuilderConfig -Id $Id
    $script:ui.LevelIncludesTitle.Text = ('WHAT {0} DOES' -f ([string]$level.title).ToUpperInvariant())
    $script:ui.LevelIncludesText.Text = Get-DzDebloatLevelSummary -Config $script:BuilderConfig -LevelId $Id
}

function Select-BuilderMode {
    param([Parameter(Mandatory = $true)][string]$Id)
    $script:SelectedMode = $Id
    foreach ($c in $script:ModeCards) { if ([string]$c.Tag -eq $Id -and -not $c.IsChecked) { $c.IsChecked = $true } }
    Update-ModeIncludes
}

function Update-ModeIncludes {
    $ui = $script:ui
    $mode = Get-DzMode -Config $script:BuilderConfig -Id $script:SelectedMode
    $pre = if ($mode.custom) { $script:CustomSelection } else { $null }
    $ui.ModeIncludesTitle.Text = ('WHAT {0} INCLUDES' -f $mode.title)
    $ui.ModeIncludesText.Text = Get-DzModeSummary -Mode $mode -Config $script:BuilderConfig -Preselect $pre
    $ui.CustomizeButton.Visibility = if ($mode.custom) { 'Visible' } else { 'Collapsed' }
}

function Show-CustomPicker {
    $mode = Get-DzMode -Config $script:BuilderConfig -Id $script:SelectedMode
    $model = Get-DzReviewModel -Mode $mode -System $null -Config $script:BuilderConfig -Preselect $script:CustomSelection -DebloatLevel $script:SelectedLevel
    $path = Join-Path $script:BuilderRoot 'PickerWindow.xaml'
    $picker = Import-DzXaml -Path $path
    $names = Get-DzNamedElement -Root $picker -XamlPath $path
    # The clean-up level and its privacy switches are picked on the main window (CLEAN-UP LEVEL).
    $pickerOptions = @($model.Options | Where-Object { $_.Kind -eq 'removal' -or ($_.Kind -eq 'tweak' -and -not $_.LevelOwned) })
    $controls = @(Add-DzChoiceGroup -Panel $names.PickerAppsPanel -Items @($model.Apps) -GroupWidth 235 -RadioPrefix 'papp') +
    @(Add-DzChoiceGroup -Panel $names.PickerOptionsPanel -Items $pickerOptions -RadioPrefix 'popt')
    $countText = $names.PickerCountText
    $updateCount = {
        $n = @($controls | Where-Object { $_.IsChecked -eq $true -and $_.Tag.Kind -in @('app', 'office') }).Count
        $countText.Text = "$n app(s) ticked"
    }.GetNewClosure()
    foreach ($c in $controls) { $c.Add_Click($updateCount) }
    & $updateCount
    $names.PickerNoneButton.Add_Click({
            foreach ($c in $controls) {
                if ($c -is [System.Windows.Controls.RadioButton]) { $c.IsChecked = ($c.Tag.Kind -eq 'none') }
                else { $c.IsChecked = $false }
            }
            & $updateCount
        }.GetNewClosure())
    $names.PickerCancelButton.Add_Click({ $picker.Close() }.GetNewClosure())
    $names.PickerOkButton.Add_Click({ $picker.Tag = 'ok'; $picker.Close() }.GetNewClosure())
    $picker.Owner = $script:Window
    [void]$picker.ShowDialog()
    if ([string]$picker.Tag -ne 'ok') { return }

    Update-DzChoiceItem -Controls $controls
    $opt = ConvertTo-DzPlanOption -Apps @($model.Apps) -Options $pickerOptions
    $script:CustomSelection = [ordered]@{
        apps     = @($opt.apps)
        office   = [bool]$opt.office
        tweaks   = @($opt.tweaks)
        removals = @($opt.removals)
    }
    Write-BuilderLog ("Custom picks: {0} app(s){1}, {2} tweak(s), {3} removal(s)." -f @($opt.apps).Count, $(if ($opt.office) { ' + Microsoft 365' } else { '' }), @($opt.tweaks).Count, @($opt.removals).Count)
    Update-ModeIncludes
}

# ------------------------------------------------------------------------------------
# Actions
# ------------------------------------------------------------------------------------

function Update-ScriptsCount {
    <# Shows how many of your scripts will go on the stick (refreshed when the window gets focus back). #>
    $names = @(Get-ChildItem -LiteralPath (Join-Path $script:KitRoot 'Scripts') -File -ErrorAction SilentlyContinue |
            Where-Object { @('.cmd', '.bat', '.ps1') -contains $_.Extension.ToLowerInvariant() } | Sort-Object Name | ForEach-Object { $_.Name })
    $script:ui.ScriptsCountText.Text = if ($names.Count -eq 0) { 'none yet' } else { '{0} script(s): {1}' -f $names.Count, ($names -join ', ') }
}

function Show-ValidationErrors {
    param([Parameter(Mandatory = $true)][object]$InputData)
    $msg = "Please fix these first:`n`n - " + ($InputData.Errors -join "`n - ")
    Set-BuilderStatus -Text ($InputData.Errors[0]) -Kind Error
    [void](Show-DzMessage -Text $msg -Title 'DayZero Builder' -Kind Warning -Owner $script:Window)
}

function Invoke-Preview {
    $data = Get-BuilderInput
    # The preview can skip target errors; anything else must be valid to build the XML.
    $blocking = @($data.Errors | Where-Object { $_ -notmatch 'USB stick|ISO file|export folder|Drive .* is gone' })
    if ($blocking.Count -gt 0) {
        $data.Errors.Clear()
        foreach ($b in $blocking) { $data.Errors.Add($b) }
        Show-ValidationErrors -InputData $data
        return
    }
    $opts = $data.Options.Clone()
    $opts.BuildId = '00000000'
    $xml = New-DzUnattendXml -Options $opts
    $previewPath = Join-Path $script:BuilderRoot 'PreviewWindow.xaml'
    $preview = Import-DzXaml -Path $previewPath
    $names = Get-DzNamedElement -Root $preview -XamlPath $previewPath
    $names.PreviewText.Text = Get-DzUnattendPreview -Xml $xml
    $names.ClosePreviewButton.Add_Click({ $preview.Close() }.GetNewClosure())
    $preview.Add_PreviewKeyDown({
            param($src, $keyArgs)
            if ($keyArgs.Key -eq [System.Windows.Input.Key]::Escape) { $src.Close() }
        })
    $preview.Owner = $script:Window
    [void]$preview.ShowDialog()
}

function Invoke-Write {
    $data = Get-BuilderInput
    if ($data.Errors.Count -gt 0) { Show-ValidationErrors -InputData $data; return }

    $summary = New-Object System.Collections.Generic.List[string]
    if ($data.Kind -eq 'newusb') {
        $disk = $data.UsbDisk
        $summary.Add("Make a Windows $($data.Settings.windowsVersion) install USB with DayZero on this stick?")
        $summary.Add('')
        $summary.Add('EVERYTHING ON IT WILL BE ERASED:')
        $summary.Add(('   {0}, {1} GB, {2}' -f $disk.Name, $disk.SizeGB, $(if ($disk.Volumes) { $disk.Volumes } else { 'no drive letter' })))
        $summary.Add('')
        $summary.Add($(if ($data.Source -eq 'iso') { "Windows from: $($data.IsoPath)" } else { "Windows from: Microsoft download ($($data.Options.UILanguage))" }))
    }
    else {
        $what = if ($data.IsUsb) { "the USB stick $($data.Target)" } else { "the folder $($data.Target)" }
        $summary.Add("Write DayZero to ${what}?")
        $summary.Add('')
    }
    $summary.Add(("Windows {0}, edition: {1}" -f $data.Settings.windowsVersion, $data.Settings.edition))
    $summary.Add(("Account: {0}{1}" -f $data.Settings.userName, $(if ($data.Settings.temporaryPassword) { ' (temporary password)' } else { '' })))
    if ($script:GeneratedPassword -and $script:ui.PasswordBox1.Password -ceq $script:GeneratedPassword) {
        $summary.Add("Temporary password: $($script:GeneratedPassword)   <- write it down")
    }
    $summary.Add(("Default mode: {0}, clean-up level: {1}{2}" -f $data.Settings.defaultMode, $data.Settings.debloatLevel, $(if ($data.Settings.dryRun) { ' (DRY RUN)' } else { '' })))
    $summary.Add('')
    $summary.Add('Booting a PC from this stick starts an automatic Windows install, but Setup will always stop and let you choose the disk.')
    if ($data.Warnings.Count -gt 0) {
        $summary.Add('')
        $summary.Add('Please note:')
        foreach ($w in $data.Warnings) { $summary.Add(" - $w") }
    }
    $answer = Show-DzMessage -Text ($summary -join "`n") -Title 'DayZero Builder' -Kind Question -Owner $script:Window
    if ($answer -ne 'Yes') { Set-BuilderStatus -Text 'Cancelled.'; return }

    $buildId = New-DzBuildId
    $data.Options.BuildId = $buildId
    $data.Settings.buildId = $buildId
    Write-BuilderLog "Build id $buildId"
    Set-BuilderBusy -Busy $true -ShowProgress:($data.Kind -eq 'newusb')
    Set-BuilderStatus -Text 'Writing...'
    $erased = $false
    try {
        if ($data.Kind -eq 'newusb') {
            $log = { param($m) Write-BuilderLog $m }
            $tick = { param($t) if ($t) { Set-BuilderStatus -Text $t } else { Invoke-BuilderPump } }
            $script:ui.LogExpander.IsExpanded = $true
            # Get Windows ready first: if the download fails, the stick has not been touched yet.
            $tree = $null
            if ($data.Source -eq 'download') {
                $tree = Get-DzWindowsMediaTree -WindowsVersion ([int]$data.Settings.windowsVersion) -Language $data.Options.UILanguage -Tick $tick -Log $log
            }
            if ($tree) {
                $fit = Get-DzMediaFitProblem -MediaBytes (Get-DzFolderSize -Path $tree) -DiskBytes $data.UsbDisk.Size
                if ($fit) { throw $fit }
            }
            $erased = $true
            $data.Target = Initialize-DzUsbDisk -Disk $data.UsbDisk -Tick $tick -Log $log
            if ($tree) { Copy-DzMediaTree -Source $tree -TargetRoot $data.Target -Tick $tick }
            else { Copy-DzIsoToUsb -IsoPath $data.IsoPath -TargetRoot $data.Target -Tick $tick -Log $log }
            [void](Set-DzUsbBootSector -TargetRoot $data.Target -Log $log)
            Write-BuilderLog "Windows $($data.Settings.windowsVersion) is on the stick $($data.Target)"
            Set-BuilderStatus -Text 'Adding the answer file and the DayZero toolkit...'
        }
        $xml = New-DzUnattendXml -Options $data.Options
        $result = Write-DzKitToTarget -TargetRoot $data.Target -KitSource $script:KitRoot -UnattendXml $xml -Settings $data.Settings -Tick { Invoke-BuilderPump } -Log {
            param($m) Write-BuilderLog $m
        }
        $bundleNote = ''
        if ($script:ui.BundlesCheck.IsChecked -eq $true) {
            if ($data.IsUsb -and $data.Media -and $script:ui.DriveCombo.SelectedItem.FreeMB -lt 400) {
                Write-BuilderLog 'Not enough free space on the stick for the offline installers; skipped.'
                $bundleNote = "`n`nThe offline installers were skipped (less than 400 MB free on the stick)."
            }
            else {
                $bundles = Save-DzBundle -KitPath $result.KitPath -Log { param($m) Write-BuilderLog $m } -Status { param($t) Set-BuilderStatus -Text $t }
                $failed = @($bundles | Where-Object { -not $_.ok })
                if ($failed.Count -gt 0) {
                    $bundleNote = "`n`nThese offline installers could not be downloaded (the new PC will download them instead):`n - " + (($failed | ForEach-Object { "$($_.name): $($_.error)" }) -join "`n - ")
                }
            }
        }
        $logFile = Join-Path $result.KitPath ('Logs\builder-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
        Write-DzUtf8File -Path $logFile -Text (($script:LogLines -join "`r`n") + "`r`n")
    }
    catch {
        Write-BuilderLog ("ERROR: " + $_.Exception.Message)
        Set-BuilderStatus -Text ('Failed: ' + $_.Exception.Message) -Kind Error
        $after = if ($erased) { "`n`nThe USB stick may already be erased and is not usable yet. Fix the problem, press Refresh and try again." } else { '' }
        [void](Show-DzMessage -Text ("Writing failed:`n`n" + $_.Exception.Message + $after) -Title 'DayZero Builder' -Kind Error -Owner $script:Window)
        if ($data.Kind -eq 'newusb') { try { Update-UsbDiskList } catch { Write-BuilderLog ('Refresh failed: ' + $_.Exception.Message) } }
        return
    }
    finally {
        Set-BuilderBusy -Busy $false
    }

    Set-BuilderStatus -Text ("Done! Build $buildId written to $($data.Target)") -Kind Ok
    if ($data.Kind -eq 'newusb') { try { Update-UsbDiskList } catch { Write-BuilderLog ('Refresh failed: ' + $_.Exception.Message) } }
    if ($data.IsUsb -or $data.Kind -eq 'newusb') {
        $next = "All done!`n`nNext steps:`n 1. Eject the stick safely.`n 2. Boot the PC from it (boot menu key is often F12, F11, F8 or Esc).`n 3. When Setup asks where to install Windows, pick the disk yourself.`n 4. Everything else runs on its own; the DayZero wizard starts after the first sign-in."
    }
    else {
        $next = "Exported!`n`nNext: run tools\New-DzTestIso.ps1 -SourceFolder `"$($data.Target)`" to make an ISO, attach it to your VM as a second DVD drive, and follow TESTING.md."
    }
    [void](Show-DzMessage -Text ($next + $bundleNote) -Title 'DayZero Builder' -Kind Info -Owner $script:Window)
}

function Invoke-CheckApps {
    $winget = Find-DzWinget
    if (-not $winget) {
        [void](Show-DzMessage -Text 'winget was not found on this PC. Install or update "App Installer" from the Microsoft Store, then try again.' -Kind Warning -Owner $script:Window)
        return
    }
    $config = Get-DzConfig -KitRoot $script:KitRoot
    $items = Get-DzCatalogPackageList -Config $config
    $script:ui.LogExpander.IsExpanded = $true
    Write-BuilderLog ("Checking {0} package ids with {1} ({2})..." -f $items.Count, $winget, (Get-DzWingetVersion -WingetPath $winget))
    $script:Window.Cursor = [System.Windows.Input.Cursors]::Wait
    try {
        $n = 0
        $results = foreach ($i in $items) {
            $n++
            Set-BuilderStatus -Text ("Checking {0} of {1}: {2}" -f $n, $items.Count, $i.Id)
            Test-DzAppCatalog -WingetPath $winget -Items @($i) -Log { param($m) Write-BuilderLog $m }
        }
    }
    finally { $script:Window.Cursor = $null }
    $missing = @($results | Where-Object { -not $_.Found })
    if ($missing.Count -eq 0) {
        Set-BuilderStatus -Text ("All {0} package ids exist in winget." -f @($results).Count) -Kind Ok
    }
    else {
        Set-BuilderStatus -Text ("{0} package id(s) not found; see the log." -f $missing.Count) -Kind Warn
        [void](Show-DzMessage -Kind Warning -Owner $script:Window -Text ("Not found in winget:`n - " + (($missing | ForEach-Object { "$($_.Id) ($($_.Name))" }) -join "`n - ") + "`n`nThe log shows what 'winget search' found. Fix the ids in kit\config\apps.json or drivers.json."))
    }
}

# ------------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------------

function Start-Builder {
    foreach ($m in 'Core.psm1', 'Config.psm1', 'Engine.psm1', 'Plan.psm1', 'Download.psm1', 'Winget.psm1', 'Ui.psm1') {
        Import-Module (Join-Path $script:KitRoot "lib\$m") -Force -DisableNameChecking
    }
    Import-Module (Join-Path $script:BuilderRoot 'lib\Bundles.psm1') -Force
    Import-Module (Join-Path $script:BuilderRoot 'lib\Unattend.psm1') -Force
    Import-Module (Join-Path $script:BuilderRoot 'lib\Media.psm1') -Force
    Import-Module (Join-Path $script:BuilderRoot 'lib\UsbWriter.psm1') -Force
    Import-Module (Join-Path $script:BuilderRoot 'lib\WinMedia.psm1') -Force

    # Files downloaded from the internet carry a "blocked" mark; clear it so the copy on
    # the USB stick runs cleanly on the new PC.
    try { Get-ChildItem -LiteralPath $script:RepoRoot -Recurse -File | Unblock-File -ErrorAction SilentlyContinue } catch { Write-Verbose 'Unblock-File not available.' }

    [void](Initialize-DzTheme -ThemePath (Join-Path $script:KitRoot 'ui\Theme.xaml'))
    $xamlPath = Join-Path $script:BuilderRoot 'Builder.xaml'
    $script:Window = Import-DzXaml -Path $xamlPath
    $script:ui = Get-DzNamedElement -Root $script:Window -XamlPath $xamlPath
    $ui = $script:ui
    $ui.VersionText.Text = "USB BUILDER  $([char]0x00B7)  v$($script:Version)"

    # Drop-down contents
    $ui.EditionCombo.ItemsSource = @(
        (New-ListItem -Label "Auto - match the PC's built-in key (recommended)" -Value 'auto'),
        (New-ListItem -Label 'Home' -Value 'home'),
        (New-ListItem -Label 'Pro' -Value 'pro'),
        (New-ListItem -Label 'Use my own product key' -Value 'key')
    )
    $ui.EditionCombo.SelectedIndex = 0
    $script:BuilderConfig = Get-DzConfig -KitRoot $script:KitRoot
    foreach ($p in @(Test-DzConfig -Config $script:BuilderConfig)) { Write-BuilderLog "Config problem: $p" }
    Initialize-BuilderModeCards
    $defaultMode = [string](Get-DzProperty $script:BuilderConfig.modes 'defaultMode' 'gaming')
    Select-BuilderMode -Id $defaultMode
    Initialize-BuilderLevelCards
    $defaultLevel = Get-DzDefaultDebloatLevel -Config $script:BuilderConfig
    if ($defaultLevel) { Select-BuilderLevel -Id $defaultLevel }
    $ui.OfficePlanCombo.ItemsSource = @(
        (New-ListItem -Label 'Microsoft 365 Personal / Family' -Value 'personal'),
        (New-ListItem -Label 'Microsoft 365 Business Standard / Premium' -Value 'business'),
        (New-ListItem -Label 'Microsoft 365 E3 / E5 (enterprise)' -Value 'enterprise')
    )
    $ui.OfficePlanCombo.SelectedIndex = 0
    $ui.RegionCombo.ItemsSource = Get-RegionItemList
    $ui.KeyboardCombo.ItemsSource = Get-KeyboardItemList
    $ui.TimeZoneCombo.ItemsSource = Get-TimeZoneItemList
    $ui.DisplayLanguageCombo.ItemsSource = Get-RegionItemList
    Set-RegionFromThisPc

    # Events
    $ui.RefreshDrivesButton.Add_Click({ $script:MediaByDrive = @{}; Update-DriveList })
    $ui.DriveCombo.Add_SelectionChanged({ Update-MediaInfo })
    $ui.TargetUsbRadio.Add_Checked({ Update-TargetMode })
    $ui.TargetNewUsbRadio.Add_Checked({ Update-TargetMode })
    $ui.RefreshDisksButton.Add_Click({ Update-UsbDiskList })
    $ui.UsbDiskCombo.Add_SelectionChanged({ Update-NewUsbInfo })
    $ui.SourceDownloadRadio.Add_Checked({ Update-SourceMode })
    $ui.SourceIsoRadio.Add_Checked({ Update-SourceMode })
    $ui.BrowseIsoButton.Add_Click({
            try { Select-IsoFile } catch { [void](Show-DzMessage -Text $_.Exception.Message -Kind Error -Owner $script:Window) }
        })
    $ui.Win10Radio.Add_Checked({ Update-NewUsbInfo })
    $ui.Win11Radio.Add_Checked({ Update-NewUsbInfo })
    $ui.DisplayLanguageCombo.Add_SelectionChanged({ Update-NewUsbInfo })
    $ui.TargetFolderRadio.Add_Checked({ Update-TargetMode })
    $ui.BrowseFolderButton.Add_Click({ Select-ExportFolder })
    $ui.EditionCombo.Add_SelectionChanged({ Update-EditionHint })
    $ui.UseThisPcButton.Add_Click({ Set-RegionFromThisPc })
    $ui.PreviewButton.Add_Click({
            try { Invoke-Preview } catch { [void](Show-DzMessage -Text $_.Exception.Message -Kind Error -Owner $script:Window) }
        })
    $ui.CustomizeButton.Add_Click({
            try { Show-CustomPicker } catch { [void](Show-DzMessage -Text $_.Exception.Message -Kind Error -Owner $script:Window) }
        })
    Update-ScriptsCount
    $ui.OpenScriptsButton.Add_Click({
            try {
                $dir = Join-Path $script:KitRoot 'Scripts'
                if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
                Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $dir + '"')
            }
            catch { [void](Show-DzMessage -Text $_.Exception.Message -Kind Error -Owner $script:Window) }
        })
    $script:Window.Add_Activated({ try { Update-ScriptsCount } catch { Write-BuilderLog ('Scripts folder: ' + $_.Exception.Message) } })
    $ui.CheckAppsButton.Add_Click({
            try { Invoke-CheckApps } catch { [void](Show-DzMessage -Text $_.Exception.Message -Kind Error -Owner $script:Window) }
        })
    $ui.WriteButton.Add_Click({
            try { Invoke-Write } catch { [void](Show-DzMessage -Text $_.Exception.Message -Kind Error -Owner $script:Window) }
        })
    $ui.GeneratePasswordButton.Add_Click({
            $pw = New-TemporaryPassword
            $script:GeneratedPassword = $pw
            $script:ui.PasswordBox1.Password = $pw
            $script:ui.PasswordBox2.Password = $pw
            $script:ui.TempPasswordCheck.IsChecked = $true
            $script:ui.GeneratedPasswordText.Text = "Temporary password: $pw  - write it down. You type it once after DayZero finishes, then Windows asks you for a new one."
            $script:ui.GeneratedPasswordText.Visibility = 'Visible'
            Write-BuilderLog 'Generated a temporary password.'
        })

    $script:Window.Add_Closing({
            if ($script:Busy) {
                # Closing in the middle of formatting or copying would leave a half-made stick.
                $args[1].Cancel = $true
                $script:ui.StatusText.Text = 'Still working. The window can be closed when this is finished.'
            }
        })
    $script:Window.Add_ContentRendered({
            Update-SourceMode
            Update-UsbDiskList
            Update-EditionHint
            $script:ui.UserNameText.Focus()
        })

    Write-BuilderLog "DayZero Builder v$($script:Version) started."
    [void]$script:Window.ShowDialog()
}

try {
    Start-Builder
}
catch {
    $message = $_.Exception.Message + [Environment]::NewLine + $_.ScriptStackTrace
    $errorLog = Join-Path $env:TEMP 'DayZero-builder-error.log'
    try { Set-Content -LiteralPath $errorLog -Value $message -Encoding UTF8 } catch { Write-Verbose 'Could not write the error log.' }
    try {
        Add-Type -AssemblyName PresentationFramework
        [void][System.Windows.MessageBox]::Show("The DayZero Builder hit an error and has to close:`n`n$($_.Exception.Message)`n`nDetails: $errorLog", 'DayZero Builder', 'OK', 'Error')
    }
    catch {
        Write-Error $message
    }
    exit 1
}
