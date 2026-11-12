#Requires -Version 5.1
<#
.SYNOPSIS
    DayZero USB Builder.
.DESCRIPTION
    Adds an unattended-setup answer file (autounattend.xml) and the DayZero toolkit to a
    Windows installation USB stick that you made with Microsoft's Media Creation Tool or
    Rufus. It does not create bootable media and never touches the stick's boot files.

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
$script:GeneratedPassword = $null
$script:ThisPcFirmware = $null
$script:ui = $null
$script:Window = $null

# ------------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------------

function Write-BuilderLog {
    param([Parameter(Mandatory = $true)][string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    $script:LogLines.Add($line)
    if ($script:ui -and $script:ui.ContainsKey('LogText')) {
        $script:ui.LogText.AppendText($line + [Environment]::NewLine)
        $script:ui.LogText.ScrollToEnd()
    }
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
    Invoke-DzUiRefresh -Element $script:Window
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

function Update-TargetMode {
    $ui = $script:ui
    $isUsb = ($ui.TargetUsbRadio.IsChecked -eq $true)
    $ui.UsbPanel.Visibility = if ($isUsb) { 'Visible' } else { 'Collapsed' }
    $ui.FolderPanel.Visibility = if ($isUsb) { 'Collapsed' } else { 'Visible' }
    $ui.WriteButton.Content = if ($isUsb) { "_WRITE TO USB  $([char]0x25B6)" } else { "_EXPORT TO FOLDER  $([char]0x25B6)" }
    if ($isUsb) {
        Update-MediaInfo
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
    $isUsb = ($ui.TargetUsbRadio.IsChecked -eq $true)
    if ($isUsb) {
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
        $errors.Add("The stick contains Windows $($media.WindowsVersion), but Windows $winVer is selected.")
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
        $errors.Add("The stick has no plain Windows $winVer $edition edition.")
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
        $errors.Add("The display language must be one that is on the stick: $($media.Languages -join ', ').")
    }

    $mode = 'gaming'
    if ($ui.ModeOfficeRadio.IsChecked -eq $true) { $mode = 'office' }
    elseif ($ui.ModeEverythingRadio.IsChecked -eq $true) { $mode = 'everything' }

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
        dryRun            = $dryRun
        uiLanguage        = $display
        userLocale        = $region
        inputLocale       = $keyboard
        timeZone          = $timeZone
        mediaBuild        = $(if ($media) { $media.Build } else { $null })
    }
    return [pscustomobject]@{
        Errors   = $errors
        Warnings = $warnings
        IsUsb    = $isUsb
        Target   = $target
        Media    = $media
        Options  = $options
        Settings = $settings
    }
}

# ------------------------------------------------------------------------------------
# Actions
# ------------------------------------------------------------------------------------

function Show-ValidationErrors {
    param([Parameter(Mandatory = $true)][object]$InputData)
    $msg = "Please fix these first:`n`n - " + ($InputData.Errors -join "`n - ")
    Set-BuilderStatus -Text ($InputData.Errors[0]) -Kind Error
    [void](Show-DzMessage -Text $msg -Title 'DayZero Builder' -Kind Warning -Owner $script:Window)
}

function Invoke-Preview {
    $data = Get-BuilderInput
    # The preview can skip target errors; anything else must be valid to build the XML.
    $blocking = @($data.Errors | Where-Object { $_ -notmatch 'USB stick|export folder|Drive .* is gone' })
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

    $what = if ($data.IsUsb) { "the USB stick $($data.Target)" } else { "the folder $($data.Target)" }
    $summary = New-Object System.Collections.Generic.List[string]
    $summary.Add("Write DayZero to ${what}?")
    $summary.Add('')
    $summary.Add(("Windows {0}, edition: {1}" -f $data.Settings.windowsVersion, $data.Settings.edition))
    $summary.Add(("Account: {0}{1}" -f $data.Settings.userName, $(if ($data.Settings.temporaryPassword) { ' (temporary password)' } else { '' })))
    if ($script:GeneratedPassword -and $script:ui.PasswordBox1.Password -ceq $script:GeneratedPassword) {
        $summary.Add("Temporary password: $($script:GeneratedPassword)   <- write it down")
    }
    $summary.Add(("Default mode: {0}{1}" -f $data.Settings.defaultMode, $(if ($data.Settings.dryRun) { ' (DRY RUN)' } else { '' })))
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
    Set-BuilderStatus -Text 'Writing...'
    $script:Window.Cursor = [System.Windows.Input.Cursors]::Wait
    try {
        $xml = New-DzUnattendXml -Options $data.Options
        $result = Write-DzKitToTarget -TargetRoot $data.Target -KitSource $script:KitRoot -UnattendXml $xml -Settings $data.Settings -Log {
            param($m) Write-BuilderLog $m
        }
        $logFile = Join-Path $result.KitPath ('Logs\builder-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
        Write-DzUtf8File -Path $logFile -Text (($script:LogLines -join "`r`n") + "`r`n")
    }
    catch {
        Write-BuilderLog ("ERROR: " + $_.Exception.Message)
        Set-BuilderStatus -Text ('Failed: ' + $_.Exception.Message) -Kind Error
        [void](Show-DzMessage -Text ("Writing failed:`n`n" + $_.Exception.Message) -Title 'DayZero Builder' -Kind Error -Owner $script:Window)
        return
    }
    finally {
        $script:Window.Cursor = $null
    }

    Set-BuilderStatus -Text ("Done! Build $buildId written to $($data.Target)") -Kind Ok
    if ($data.IsUsb) {
        $next = "All done!`n`nNext steps:`n 1. Eject the stick safely.`n 2. Boot the PC from it (boot menu key is often F12, F11, F8 or Esc).`n 3. When Setup asks where to install Windows, pick the disk yourself.`n 4. Everything else runs on its own; the DayZero wizard starts after the first sign-in."
    }
    else {
        $next = "Exported!`n`nNext: run tools\New-DzTestIso.ps1 -SourceFolder `"$($data.Target)`" to make an ISO, attach it to your VM as a second DVD drive, and follow TESTING.md."
    }
    [void](Show-DzMessage -Text $next -Title 'DayZero Builder' -Kind Info -Owner $script:Window)
}

# ------------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------------

function Start-Builder {
    Import-Module (Join-Path $script:KitRoot 'lib\Ui.psm1') -Force
    Import-Module (Join-Path $script:BuilderRoot 'lib\Unattend.psm1') -Force
    Import-Module (Join-Path $script:BuilderRoot 'lib\Media.psm1') -Force
    Import-Module (Join-Path $script:BuilderRoot 'lib\UsbWriter.psm1') -Force

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
    $ui.RegionCombo.ItemsSource = Get-RegionItemList
    $ui.KeyboardCombo.ItemsSource = Get-KeyboardItemList
    $ui.TimeZoneCombo.ItemsSource = Get-TimeZoneItemList
    $ui.DisplayLanguageCombo.ItemsSource = Get-RegionItemList
    Set-RegionFromThisPc

    # Events
    $ui.RefreshDrivesButton.Add_Click({ $script:MediaByDrive = @{}; Update-DriveList })
    $ui.DriveCombo.Add_SelectionChanged({ Update-MediaInfo })
    $ui.TargetUsbRadio.Add_Checked({ Update-TargetMode })
    $ui.TargetFolderRadio.Add_Checked({ Update-TargetMode })
    $ui.BrowseFolderButton.Add_Click({ Select-ExportFolder })
    $ui.EditionCombo.Add_SelectionChanged({ Update-EditionHint })
    $ui.UseThisPcButton.Add_Click({ Set-RegionFromThisPc })
    $ui.PreviewButton.Add_Click({
            try { Invoke-Preview } catch { [void](Show-DzMessage -Text $_.Exception.Message -Kind Error -Owner $script:Window) }
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

    $script:Window.Add_ContentRendered({
            Update-DriveList
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
