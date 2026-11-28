#Requires -Version 5.1
<#
    DayZero USB Builder - the LINUX side of the builder window (LinuxPanel.xaml, shown in
    Builder.xaml's LinuxHost when LINUX is picked in the header). Dot-sourced by Builder.ps1, so it
    shares the window, the language, the theme and the list helpers (Get-RegionItemList,
    Get-KeyboardItemList, Get-TimeZoneItemList, Select-ComboValue, New-ListItem).

    Three ways to make a Linux stick:
      * Ubuntu from ubuntu.com or your own Ubuntu ISO: the stick is erased, gets one FAT32
        partition with the ISO's files, autoinstall.yaml and the DayZero Linux kit (lib\Linux.psm1).
      * Add DayZero to an Ubuntu stick you already made (Rufus, ISO mode): only autoinstall.yaml
        and the kit are written; nothing is erased.
      * Any other Linux ISO: written to the stick byte for byte and read back (lib\RawWrite.psm1).
    Erasing goes through Initialize-DzUsbDisk, which re-checks Test-DzUsbDiskAllowed every time.
#>

$script:lx = $null
$script:LxWindow = $null   # the builder window (owner of dialogs, cursor, dispatcher)
$script:LxRoot = $null     # the loaded LinuxPanel.xaml
$script:LxBusy = $false
$script:LxLog = New-Object System.Collections.Generic.List[string]
$script:LxAppBoxes = @()
$script:LxDistroRadios = @()

function Invoke-LxPump {
    if (-not $script:LxWindow) { return }
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    [void]$script:LxWindow.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [System.Action] { $frame.Continue = $false })
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}

function Write-LxLog {
    param([Parameter(Mandatory = $true)][string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    $script:LxLog.Add($line)
    Write-BuilderLog ('Linux: ' + $Message)
    if ($script:lx) {
        $script:lx.LxLogText.AppendText($line + [Environment]::NewLine)
        $script:lx.LxLogText.ScrollToEnd()
    }
    if ($script:LxBusy) { Invoke-LxPump }
}

function Get-LxProgress {
    <# Where a status line sits in the whole job, 0-100 (the bar only moves forward). #>
    param([string]$Text)
    $p = 0.0
    $m = [regex]::Match($Text, '\((\d{1,3})%\)\s*$')
    if ($m.Success) { $p = [double]$m.Groups[1].Value / 100 }
    switch -Regex ($Text) {
        '^Downloading' { return 2 + 38 * $p }
        '^Checking (?!what)' { return 40 + 5 * $p }
        '^Erasing' { return 46 }
        '^Copying Ubuntu' { return 48 + 46 * $p }
        '^Adding DayZero' { return 96 }
        '^Writing the image' { return 5 + 75 * $p }
        '^Checking what was written' { return 80 + 19 * $p }
    }
    return $null
}

function Set-LxStatus {
    param([Parameter(Mandatory = $true)][string]$Text, [ValidateSet('Info', 'Ok', 'Warn', 'Error')][string]$Kind = 'Info')
    $brush = switch ($Kind) { 'Ok' { 'DzGreen' } 'Warn' { 'DzYellow' } 'Error' { 'DzRed' } default { 'DzMuted' } }
    $script:lx.LxStatusText.Text = Get-DzText $($Text)
    $script:lx.LxStatusText.Foreground = [System.Windows.Application]::Current.FindResource($brush)
    if ($script:LxBusy) {
        $v = Get-LxProgress -Text $Text
        if ($null -ne $v -and $v -gt $script:lx.LxProgress.Value) { $script:lx.LxProgress.Value = $v }
        Invoke-LxPump
    }
    else { Invoke-DzUiRefresh -Element $script:LxWindow }
}

function Set-LxBusy {
    param([Parameter(Mandatory = $true)][bool]$Busy, [switch]$ShowProgress)
    $script:LxBusy = $Busy
    $lx = $script:lx
    $lx.LxProgress.Value = 0
    $lx.LxProgress.Visibility = if ($Busy -and $ShowProgress) { 'Visible' } else { 'Collapsed' }
    foreach ($n in 'LxBodyGrid', 'LxVerifyButton', 'LxPreviewButton', 'LxWriteButton', 'LxNextButton') { $lx[$n].IsEnabled = -not $Busy }
    $lx.LxBackButton.IsEnabled = (-not $Busy) -and ($script:LxStep -gt 0)
    # No switching sides or language in the middle of a write.
    foreach ($n in 'OsWindowsRadio', 'OsLinuxRadio', 'LanguageButton') { $script:ui[$n].IsEnabled = -not $Busy }
    $script:LxWindow.Cursor = if ($Busy) { [System.Windows.Input.Cursors]::AppStarting } else { $null }
    Invoke-DzUiRefresh -Element $script:LxWindow
}

# ------------------------------------------------------------------------------------
# Choices
# ------------------------------------------------------------------------------------

function Get-LxSystem {
    <#
        Kind: 'download' (Ubuntu with DayZero, DistroId), 'download-raw' (another distro from its
        official site, written as it is, DistroId), 'ubuntu-iso' or 'raw-iso' (IsoPath).
    #>
    $lx = $script:lx
    if ($lx.LxUbuntuIsoRadio.IsChecked -eq $true) { return [pscustomobject]@{ Kind = 'ubuntu-iso'; DistroId = ''; IsoPath = [string]$lx.LxIsoPathText.Text } }
    if ($lx.LxRawIsoRadio.IsChecked -eq $true) { return [pscustomobject]@{ Kind = 'raw-iso'; DistroId = ''; IsoPath = [string]$lx.LxIsoPathText.Text } }
    $r = @($script:LxDistroRadios | Where-Object { $_.IsChecked -eq $true }) | Select-Object -First 1
    $id = if ($r) { [string]$r.Tag } else { (Get-DzLinuxCatalog).DefaultDistro }
    $kind = if ([string](Get-DzLinuxDistro -Id $id).automation -eq 'ubuntu-autoinstall') { 'download' } else { 'download-raw' }
    return [pscustomobject]@{ Kind = $kind; DistroId = $id; IsoPath = '' }
}

function Test-LxRawKind {
    <# $true when the stick gets an ISO written as it is (no DayZero on it). #>
    param([string]$Kind)
    return ($Kind -eq 'raw-iso' -or $Kind -eq 'download-raw')
}

function Initialize-LxDistros {
    $panel = $script:lx.LxDistroPanel
    $panel.Children.Clear()
    $catalog = Get-DzLinuxCatalog
    $radios = @()
    foreach ($d in $catalog.Distros) {
        $r = New-Object System.Windows.Controls.RadioButton
        $r.GroupName = 'LxSystem'
        $r.Tag = [string]$d.id
        $r.Margin = New-Object System.Windows.Thickness(0, 0, 0, 6)
        $r.Content = if ([string]$d.automation -eq 'ubuntu-autoinstall') { (Get-DzText '{0} - downloaded from ubuntu.com, with DayZero (supported until {1})') -f $d.name, $d.supportedUntil }
        else { (Get-DzText '{0} - downloaded from {1}, written as it is (no DayZero)') -f $d.name, $d.site }
        $r.IsChecked = ([string]$d.id -eq $catalog.DefaultDistro)
        $r.Add_Checked({ Update-LxSystemMode })
        [void]$panel.Children.Add($r)
        $radios += $r
    }
    $script:LxDistroRadios = $radios
}

function Update-LxSystemMode {
    $lx = $script:lx
    $sys = Get-LxSystem
    $raw = Test-LxRawKind -Kind $sys.Kind
    $lx.LxIsoPanel.Visibility = if ($sys.Kind -like 'download*') { 'Collapsed' } else { 'Visible' }
    foreach ($n in 'LxAccountCard', 'LxRegionCard', 'LxAppsCard', 'LxOptionsCard') { $lx[$n].IsEnabled = -not $raw }
    $lx.LxPreviewButton.IsEnabled = -not $raw
    if ($raw -and $lx.LxTargetExistingRadio.IsChecked -eq $true) { $lx.LxTargetNewRadio.IsChecked = $true }
    $lx.LxTargetExistingRadio.IsEnabled = -not $raw
    $hint = switch ($sys.Kind) {
        'download' { Get-DzText 'Downloaded once (about 6 GB) from releases.ubuntu.com, checked against Ubuntu''s published SHA-256 and kept for the next stick. The PC needs UEFI (any PC from the last ten years).' }
        'download-raw' { Get-DzText 'Downloaded once from the project''s own site, checked against its published SHA-256 and kept for the next stick, then written to the stick exactly as it is and read back. You install it by hand; your account, apps and scripts below are not used.' }
        'ubuntu-iso' { Get-DzText 'Pick an Ubuntu Desktop ISO, 24.04 or newer. Its files are copied to the stick, with DayZero added. The PC needs UEFI.' }
        default { Get-DzText 'The ISO is written to the stick exactly as it is and read back to check it, like Rufus in DD mode or balenaEtcher. You install it by hand; your account, apps and scripts below are not used.' }
    }
    $lx.LxSystemHintText.Text = $hint
    Update-LxTargetMode
    # Writing an ISO as it is has fewer steps: redraw the step line.
    if ($script:LxRoot -and $script:ui.LinuxHost.Visibility -eq 'Visible') {
        $script:LxReached = $script:LxStep
        Show-LxStep -Index $script:LxStep
    }
}

function Select-LxIsoFile {
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Title = Get-DzText 'Pick a Linux ISO file'
    $dialog.Filter = (Get-DzText 'Linux ISO files') + ' (*.iso;*.img)|*.iso;*.img'
    if ($dialog.ShowDialog($script:LxWindow) -eq $true) {
        $script:lx.LxIsoPathText.Text = $dialog.FileName
        Write-LxLog "ISO picked: $($dialog.FileName)"
    }
}

function Get-LxUbuntuStick {
    <# Removable drives that hold an Ubuntu live system (casper\), e.g. made by Rufus in ISO mode. #>
    foreach ($v in @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { [string]$_.DriveType -eq 'Removable' -and $_.DriveLetter } | Sort-Object DriveLetter)) {
        $root = "$($v.DriveLetter):\"
        if (-not (Test-Path -LiteralPath (Join-Path $root 'casper'))) { continue }
        $label = [string]$v.FileSystemLabel
        [pscustomobject]@{
            Root    = $root
            Display = ('{0}  {1}  - {2}, {3:N1} GB free' -f $root, $label, $v.FileSystem, ($v.SizeRemaining / 1GB))
            IsFat   = ([string]$v.FileSystem -like 'FAT*')
        }
    }
}

function Update-LxTargetMode {
    $lx = $script:lx
    $existing = ($lx.LxTargetExistingRadio.IsChecked -eq $true)
    $lx.LxUsbDiskCombo.Visibility = if ($existing) { 'Collapsed' } else { 'Visible' }
    $lx.LxDriveCombo.Visibility = if ($existing) { 'Visible' } else { 'Collapsed' }
    Update-LxTargetHint
}

function Update-LxDisks {
    $lx = $script:lx
    Set-LxStatus -Text 'Looking for USB sticks...'
    $all = @(Get-DzUsbDiskCandidate)
    foreach ($d in @($all | Where-Object { $_.Problem })) { Write-LxLog ("Not offered: {0}. {1}" -f $d.Display, $d.Problem) }
    $ok = @($all | Where-Object { -not $_.Problem })
    $lx.LxUsbDiskCombo.ItemsSource = $ok
    if ($ok.Count -gt 0) { $lx.LxUsbDiskCombo.SelectedIndex = 0 }
    $sticks = @(Get-LxUbuntuStick)
    $lx.LxDriveCombo.ItemsSource = $sticks
    if ($sticks.Count -gt 0) { $lx.LxDriveCombo.SelectedIndex = 0 }
    Write-LxLog ("Found {0} USB stick(s) that can be erased and {1} Ubuntu stick(s)." -f $ok.Count, $sticks.Count)
    Update-LxTargetHint
    Set-LxStatus -Text 'Ready.'
}

function Update-LxTargetHint {
    $lx = $script:lx
    if ($lx.LxTargetExistingRadio.IsChecked -eq $true) {
        $s = $lx.LxDriveCombo.SelectedItem
        $text = if ($null -eq $s) { 'No Ubuntu USB stick found. Make one with Rufus (ISO mode, FAT32), plug it in and press Refresh.' }
        elseif (-not $s.IsFat) { 'This stick is not FAT32, so DayZero may not be readable while Ubuntu installs. Make it again with Rufus in ISO mode and FAT32.' }
        else { 'Only autoinstall.yaml, the dayzero folder and a README are added. Nothing on the stick is erased.' }
        $lx.LxTargetHintText.Text = Get-DzText $($text)
        return
    }
    $disk = $lx.LxUsbDiskCombo.SelectedItem
    $lx.LxTargetHintText.Text = if ($null -eq $disk) {
        Get-DzText 'No USB stick found. Plug one in (8 GB or more) and press Refresh. Internal disks and drives over 300 GB are never offered.'
    }
    else {
        (Get-DzText 'EVERYTHING on this stick will be erased: {0}, {1} GB{2}.') -f $disk.Name, $disk.SizeGB, $(if ($disk.Volumes) { ', ' + $disk.Volumes } else { '' })
    }
}

function Update-LxRegionText {
    $lx = $script:lx
    $loc = ConvertTo-DzLinuxLocale -Culture ([string]$lx.LxLanguageCombo.SelectedValue)
    $kb = ConvertTo-DzLinuxKeyboard -InputLocale ([string]$lx.LxKeyboardCombo.SelectedValue)
    $tz = ConvertTo-DzLinuxTimeZone -Id ([string]$lx.LxTimeZoneCombo.SelectedValue)
    $keys = if ($kb.Toggle) { (Get-DzText '{0} (Alt+Shift switches)') -f $kb.Layout } else { $kb.Layout }
    $lines = @((Get-DzText 'On Linux: {0}, keyboard {1}, {2}') -f $loc.Locale, $keys, $tz.TimeZone)
    if (-not $loc.Known) { $lines += Get-DzText 'This language has no Linux name DayZero knows; English (US) is used.' }
    if (-not $kb.Known) { $lines += Get-DzText 'This keyboard has no Linux layout DayZero knows; US English is used. You can add yours in Settings after installing.' }
    if (-not $tz.Known) { $lines += Get-DzText 'This time zone has no Linux name DayZero knows; UTC is used.' }
    $lx.LxLinuxSettingsText.Text = $lines -join [Environment]::NewLine
}

function Set-LxRegionFromThisPc {
    $lx = $script:lx
    Select-ComboValue -Combo $lx.LxLanguageCombo -Value (Get-UICulture).Name
    $kb = Get-CurrentKeyboardValue
    Select-ComboValue -Combo $lx.LxKeyboardCombo -Value $kb -Label ("This PC's keyboard ($kb)")
    Select-ComboValue -Combo $lx.LxTimeZoneCombo -Value ([System.TimeZoneInfo]::Local.Id)
    Update-LxRegionText
}

function Get-LxAppCatalog {
    return (Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:KitRoot 'linux\apps.json') | ConvertFrom-Json)
}

function Initialize-LxModes {
    $lx = $script:lx
    $picked = [string]$lx.LxModeCombo.SelectedValue
    $modes = (Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:KitRoot 'config\modes.json') | ConvertFrom-Json)
    $lx.LxModeCombo.ItemsSource = @($modes.modes | ForEach-Object { New-ListItem -Label ([string]$_.title) -Value ([string]$_.id) })
    if (-not $picked) { $picked = [string]$modes.defaultMode }
    $lx.LxModeCombo.SelectedValue = $picked
}

function Initialize-LxApps {
    <# One tick box per app, under its category. Keeps the ticks when called again. #>
    $lx = $script:lx
    $was = @{}
    foreach ($b in $script:LxAppBoxes) { $was[[string]$b.Tag.id] = ($b.IsChecked -eq $true) }
    $panel = $lx.LxAppsPanel
    $panel.Children.Clear()
    $catalog = Get-LxAppCatalog
    $boxes = @()
    foreach ($c in $catalog.categories) {
        $apps = @($catalog.apps | Where-Object { $_.category -eq $c.id })
        if ($apps.Count -eq 0) { continue }
        $title = New-Object System.Windows.Controls.TextBlock
        $title.Text = Get-DzText ([string]$c.title)
        $title.Style = [System.Windows.Application]::Current.FindResource('DzLabel')
        [void]$panel.Children.Add($title)
        $wrap = New-Object System.Windows.Controls.WrapPanel
        foreach ($a in $apps) {
            $box = New-Object System.Windows.Controls.CheckBox
            $box.Content = [string]$a.name
            $box.Tag = $a
            $box.Margin = New-Object System.Windows.Thickness(0, 2, 14, 2)
            if ($was.ContainsKey([string]$a.id)) { $box.IsChecked = $was[[string]$a.id] }
            [void]$wrap.Children.Add($box)
            $boxes += $box
        }
        [void]$panel.Children.Add($wrap)
    }
    $script:LxAppBoxes = $boxes
    if ($was.Count -eq 0) { Set-LxAppsFromMode }
}

function Set-LxAppsFromMode {
    $mode = [string]$script:lx.LxModeCombo.SelectedValue
    foreach ($b in $script:LxAppBoxes) {
        $a = $b.Tag
        $b.IsChecked = ($mode -eq 'everything' -or @($a.modes) -contains $mode)
    }
}

function Update-LxScriptsCount {
    $dir = Join-Path $script:KitRoot 'Scripts-Linux'
    $n = @(Get-ChildItem -LiteralPath $dir -Filter '*.sh' -File -ErrorAction SilentlyContinue).Count
    $script:lx.LxScriptsCountText.Text = if ($n -eq 0) { Get-DzText 'No scripts yet.' } else { (Get-DzText '{0} script(s) will be copied.') -f $n }
}

# ------------------------------------------------------------------------------------
# Input
# ------------------------------------------------------------------------------------

function Get-LxInput {
    <# Everything entered, checked. Errors and Warnings are lists of shown texts. #>
    $lx = $script:lx
    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    $sys = Get-LxSystem
    $existing = ($lx.LxTargetExistingRadio.IsChecked -eq $true -and -not (Test-LxRawKind -Kind $sys.Kind))
    $disk = $null
    $root = $null
    if ($existing) {
        $s = $lx.LxDriveCombo.SelectedItem
        if ($null -eq $s) { $errors.Add('Pick the Ubuntu USB stick to add DayZero to.') } else { $root = $s.Root }
    }
    else {
        $disk = $lx.LxUsbDiskCombo.SelectedItem
        if ($null -eq $disk) { $errors.Add('Pick the USB stick to erase.') }
    }
    if ($sys.Kind -notlike 'download*' -and -not $existing) {
        if (-not $sys.IsoPath -or -not (Test-Path -LiteralPath $sys.IsoPath -PathType Leaf)) { $errors.Add('Pick the ISO file.') }
    }
    $data = [pscustomobject]@{ System = $sys; Existing = $existing; Disk = $disk; Root = $root; Errors = $errors; Warnings = $warnings; Options = $null; Settings = $null; DistroName = '' }
    if ($sys.Kind -eq 'download-raw') { $data.DistroName = [string](Get-DzLinuxDistro -Id $sys.DistroId).name }
    if (Test-LxRawKind -Kind $sys.Kind) { return $data }

    $user = ([string]$lx.LxUserNameText.Text).Trim()
    $problem = Test-DzLinuxUserName -Name $user
    if ($problem) {
        $suggest = ConvertTo-DzLinuxUserName -Name $user
        $errors.Add($problem)
        if ($suggest -and $suggest -ne $user) { $errors.Add(((Get-DzText 'For example: {0}') -f $suggest)) }
    }
    $hostName = ([string]$lx.LxComputerNameText.Text).Trim()
    $problem = Test-DzLinuxHostName -Name $hostName
    if ($problem) { $errors.Add($problem) }
    $pw1 = $lx.LxPasswordBox1.Password
    $pw2 = $lx.LxPasswordBox2.Password
    if (-not $pw1) { $errors.Add('Enter a password. Linux needs one (sudo asks for it).') }
    elseif ($pw1 -cne $pw2) { $errors.Add('The two passwords are not the same.') }
    elseif ($pw1.Length -lt 4) { $errors.Add('Use a password of at least 4 characters.') }
    $fullName = ([string]$lx.LxFullNameText.Text).Trim()
    if ($fullName -match '[\x00-\x1F]') { $errors.Add('Your name contains a line break or control character.') }
    if ($errors.Count -gt 0) { return $data }

    $loc = ConvertTo-DzLinuxLocale -Culture ([string]$lx.LxLanguageCombo.SelectedValue)
    $kb = ConvertTo-DzLinuxKeyboard -InputLocale ([string]$lx.LxKeyboardCombo.SelectedValue)
    $tz = ConvertTo-DzLinuxTimeZone -Id ([string]$lx.LxTimeZoneCombo.SelectedValue)
    if (-not $kb.Known) { $warnings.Add('The keyboard is set to US English (your layout has no Linux name DayZero knows).') }
    $apps = @($script:LxAppBoxes | Where-Object { $_.IsChecked -eq $true } | ForEach-Object { [string]$_.Tag.id })
    $distroName = if ($sys.Kind -eq 'download') { [string](Get-DzLinuxDistro -Id $sys.DistroId).name } else { 'Ubuntu' }
    $data.DistroName = $distroName
    $data.Options = @{
        UserName     = $user
        FullName     = $fullName
        Password     = $pw1
        HostName     = $hostName
        Locale       = $loc.Locale
        Keyboard     = @{ Layout = $kb.Layout; Variant = $kb.Variant; Toggle = $kb.Toggle }
        TimeZone     = $tz.TimeZone
        BuildId      = '00000000'
        Drivers      = ($lx.LxDriversCheck.IsChecked -eq $true)
        Codecs       = ($lx.LxCodecsCheck.IsChecked -eq $true)
    }
    $data.Settings = [ordered]@{
        buildId           = '00000000'
        builderVersion    = $script:Version
        createdAt         = (Get-Date).ToString('s')
        distro            = $(if ($sys.Kind -eq 'download') { $sys.DistroId } else { 'ubuntu-iso' })
        distroName        = $distroName
        userName          = $user
        defaultMode       = [string]$lx.LxModeCombo.SelectedValue
        apps              = $apps
        appsExact         = $true
        appLanguage       = (Get-DzLanguage)
        installDrivers    = ($lx.LxDriversCheck.IsChecked -eq $true)
        dryRun            = ($lx.LxDryRunCheck.IsChecked -eq $true)
        temporaryPassword = ($lx.LxTempPasswordCheck.IsChecked -eq $true)
    }
    return $data
}

function New-LxAutoinstall {
    <# autoinstall.yaml for $Data (the password is hashed here and never stored). #>
    param([Parameter(Mandatory = $true)][object]$Data, [Parameter(Mandatory = $true)][string]$BuildId)
    $o = @{}
    foreach ($k in $Data.Options.Keys) { if ($k -ne 'Password') { $o[$k] = $Data.Options[$k] } }
    $o.BuildId = $BuildId
    $o.PasswordHash = ConvertTo-DzSha512Crypt -Password $Data.Options.Password
    return (New-DzAutoinstallYaml -Options $o)
}

function Show-LxErrors {
    param([Parameter(Mandatory = $true)][object]$Data)
    $text = (Get-DzText 'Please fix this first:') + "`n`n" + (($Data.Errors | ForEach-Object { ' - ' + (Get-DzText $_) }) -join "`n")
    [void](Show-DzMessage -Text $text -Title 'DayZero Builder' -Kind Warning -Owner $script:LxWindow)
}

function Invoke-LxPreview {
    $data = Get-LxInput
    $blocking = @($data.Errors | Where-Object { $_ -notmatch 'USB stick|ISO file' })
    if ($blocking.Count -gt 0) { $data.Errors.Clear(); foreach ($b in $blocking) { $data.Errors.Add($b) }; Show-LxErrors -Data $data; return }
    if ($null -eq $data.Options) { return }
    $yaml = New-LxAutoinstall -Data $data -BuildId '00000000'
    $previewPath = Join-Path $script:BuilderRoot 'PreviewWindow.xaml'
    $preview = Import-DzXaml -Path $previewPath
    $names = Get-DzNamedElement -Root $preview -XamlPath $previewPath
    $names.PreviewText.Text = $yaml
    Update-DzTranslation -Root $preview
    $preview.Title = 'DayZero - autoinstall.yaml'
    $names.ClosePreviewButton.Add_Click({ $preview.Close() }.GetNewClosure())
    $preview.Owner = $script:LxWindow
    [void]$preview.ShowDialog()
}

# ------------------------------------------------------------------------------------
# Writing
# ------------------------------------------------------------------------------------

function Test-LxHybridIso {
    <# $true when the image has a boot record (0x55AA at byte 510), so it can boot from a stick. #>
    param([Parameter(Mandatory = $true)][string]$Path)
    $fs = [System.IO.File]::OpenRead($Path)
    try {
        $b = New-Object byte[] 512
        if ($fs.Read($b, 0, 512) -lt 512) { return $false }
        return ($b[510] -eq 0x55 -and $b[511] -eq 0xAA)
    }
    finally { $fs.Dispose() }
}

function Invoke-LxWrite {
    $data = Get-LxInput
    if ($data.Errors.Count -gt 0) { Show-LxErrors -Data $data; return }
    $sys = $data.System
    $summary = New-Object System.Collections.Generic.List[string]
    if ($data.Existing) {
        $summary.Add(((Get-DzText 'Add DayZero to the Ubuntu stick {0}?') -f $data.Root))
        $summary.Add('')
        $summary.Add((Get-DzText 'Nothing on it is erased.'))
    }
    else {
        $disk = $data.Disk
        $summary.Add($(if ($sys.Kind -eq 'raw-iso') { (Get-DzText 'Write {0} to this stick as it is?') -f (Split-Path -Leaf $sys.IsoPath) } elseif ($sys.Kind -eq 'download-raw') { (Get-DzText 'Download {0} and write it to this stick as it is?') -f $data.DistroName } else { (Get-DzText 'Make a {0} install USB with DayZero on this stick?') -f $data.DistroName }))
        $summary.Add('')
        $summary.Add((Get-DzText 'EVERYTHING ON IT WILL BE ERASED:'))
        $summary.Add(('   {0}, {1} GB, {2}' -f $disk.Name, $disk.SizeGB, $(if ($disk.Volumes) { $disk.Volumes } else { Get-DzText 'no drive letter' })))
    }
    if ($sys.Kind -eq 'raw-iso') {
        if (-not (Test-LxHybridIso -Path $sys.IsoPath)) { $summary.Add(''); $summary.Add((Get-DzText 'Warning: this file has no boot record, so it may not start from a USB stick.')) }
    }
    elseif ($sys.Kind -eq 'download-raw') {
        $summary.Add('')
        $summary.Add((Get-DzText 'It is downloaded from the project''s own site and checked against its published SHA-256 first. You install it by hand.'))
    }
    else {
        $summary.Add('')
        $summary.Add(((Get-DzText 'Account: {0}{1}') -f $data.Settings.userName, $(if ($data.Settings.temporaryPassword) { Get-DzText ' (temporary password)' } else { '' })))
        $summary.Add(((Get-DzText 'Mode: {0}, {1} apps') -f $data.Settings.defaultMode, @($data.Settings.apps).Count))
        $summary.Add('')
        $summary.Add((Get-DzText 'The Ubuntu installer will stop and let you choose the disk. Everything else runs on its own.'))
    }
    foreach ($w in $data.Warnings) { $summary.Add(' - ' + (Get-DzText $w)) }
    if ((Show-DzMessage -Text ($summary -join "`n") -Title 'DayZero Builder' -Kind Question -Owner $script:LxWindow) -ne 'Yes') { Set-LxStatus -Text 'Cancelled.'; return }

    $buildId = New-DzBuildId
    if ($data.Settings) { $data.Settings.buildId = $buildId }
    Write-LxLog "Build id $buildId"
    $log = { param($m) Write-LxLog $m }
    $tick = { param($t) if ($t) { Set-LxStatus -Text $t } else { Invoke-LxPump } }
    $erased = $false
    $target = $null
    $result = $null
    Set-LxBusy -Busy $true -ShowProgress:(-not $data.Existing)
    $script:lx.LxLogExpander.IsExpanded = $true
    try {
        if (Test-LxRawKind -Kind $sys.Kind) {
            $imagePath = $sys.IsoPath
            if ($sys.Kind -eq 'download-raw') { $imagePath = (Get-DzLinuxIso -DistroId $sys.DistroId -Tick $tick -Log $log).Path }
            $size = (Get-Item -LiteralPath $imagePath).Length
            if ($size -gt ($data.Disk.Size - 1MB)) { throw ((Get-DzText 'The image needs {0} GB but the stick only holds {1} GB.') -f ('{0:N1}' -f ($size / 1GB)), ('{0:N1}' -f ($data.Disk.Size / 1GB))) }
            $erased = $true
            Set-LxStatus -Text 'Erasing the USB stick...'
            [void](Initialize-DzUsbDisk -Disk $data.Disk -CleanOnly -Tick $tick -Log $log)
            $stream = Open-DzRawDisk -Number $data.Disk.Number
            try { $hash = Write-DzImageToStream -ImagePath $imagePath -Stream $stream -DiskBytes $data.Disk.Size -Tick $tick }
            finally { $stream.Dispose() }
            Write-LxLog "Written and read back, SHA-256 $hash"
            Set-LxStatus -Text 'Done! The ISO is on the stick and was checked.' -Kind Ok
            [void](Show-DzMessage -Text ((Get-DzText 'Done! {0} is on the stick and was read back to check it.') -f (Split-Path -Leaf $imagePath) + "`n`n" + (Get-DzText 'Windows may now say the stick needs formatting: do NOT format it. That is normal for Linux sticks.')) -Title 'DayZero Builder' -Kind Info -Owner $script:LxWindow)
            return
        }

        $yaml = New-LxAutoinstall -Data $data -BuildId $buildId
        if ($data.Existing) {
            $target = $data.Root
            if (-not (Test-Path -LiteralPath (Join-Path $target 'casper'))) { throw 'This stick has no casper folder, so it is not an Ubuntu stick.' }
        }
        else {
            $iso = if ($sys.Kind -eq 'download') { (Get-DzLinuxIso -DistroId $sys.DistroId -Tick $tick -Log $log).Path } else { $sys.IsoPath }
            $disk = $data.Disk
            $result = @{ Root = $null; Erased = $false }
            Invoke-DzWithMountedIso -IsoPath $iso -Action {
                param($isoRoot)
                if (-not (Test-Path -LiteralPath (Join-Path $isoRoot 'casper'))) { throw 'This ISO has no casper folder, so it is not Ubuntu Desktop. Use "Another Linux ISO file" for other systems.' }
                $fat = Get-DzFat32Problem -Root $isoRoot
                if ($fat) { throw $fat }
                $fit = Get-DzMediaFitProblem -MediaBytes (Get-DzFolderSize -Path $isoRoot) -DiskBytes $disk.Size
                if ($fit) { throw $fit }
                $result.Erased = $true
                $root = Initialize-DzUsbDisk -Disk $disk -Tick $tick -Log $log
                $result.Root = $root
                Copy-DzMediaTree -Source $isoRoot -TargetRoot $root -Tick $tick -Label 'Copying Ubuntu to the USB stick'
            }.GetNewClosure()
            $target = $result.Root
            Write-LxLog "Ubuntu is on the stick $target"
        }
        Set-LxStatus -Text 'Adding DayZero to the stick...'
        $written = Write-DzLinuxKitToTarget -TargetRoot $target -KitSource $script:KitRoot -AutoinstallYaml $yaml -Settings $data.Settings -Log $log
        [System.IO.File]::WriteAllText((Join-Path $written.KitPath ('builder-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')), (($script:LxLog -join "`n") + "`n"))
    }
    catch {
        if ($result -and $result.Erased) { $erased = $true }
        Write-LxLog ('ERROR: ' + $_.Exception.Message)
        Set-LxStatus -Text ('Failed: ' + $_.Exception.Message) -Kind Error
        $after = if ($erased) { "`n`n" + (Get-DzText 'The USB stick may already be erased and is not usable yet. Fix the problem, press Refresh and try again.') } else { '' }
        [void](Show-DzMessage -Text ((Get-DzText 'Writing failed:') + "`n`n" + (Get-DzText $_.Exception.Message) + $after) -Title 'DayZero Builder' -Kind Error -Owner $script:LxWindow)
        if (-not $data.Existing) { try { Update-LxDisks } catch { Write-LxLog ('Refresh failed: ' + $_.Exception.Message) } }
        return
    }
    finally {
        Set-LxBusy -Busy $false
    }

    $checks = @(Test-DzLinuxStick -Root $target)
    foreach ($c in $checks) { Write-LxLog ('Check: {0}: {1} ({2})' -f $c.Name, $(if ($c.Ok) { 'OK' } else { 'PROBLEM' }), $c.Detail) }
    $bad = @($checks | Where-Object { -not $_.Ok })
    $verdict = if ($bad.Count -eq 0) { Get-DzText 'The stick check found no problems.' } else { (Get-DzText 'The stick check found problems:') + "`n" + (($bad | ForEach-Object { ' - ' + (Get-DzText $_.Name) + ': ' + $_.Detail }) -join "`n") }
    Set-LxStatus -Text ("Done! Build $buildId written to $target") -Kind Ok
    $next = (Get-DzText 'All done!') + "`n`n" + (Get-DzText "Next steps:`n 1. Eject the stick safely.`n 2. Boot the PC from it (boot menu key is often F12, F11, F8 or Esc).`n 3. When the Ubuntu installer asks where to install, pick the disk yourself.`n 4. Everything else runs on its own; DayZero finishes the setup after the first start.")
    [void](Show-DzMessage -Text ($next + "`n`n" + $verdict) -Title 'DayZero Builder' -Kind Info -Owner $script:LxWindow)
    if (-not $data.Existing) { try { Update-LxDisks } catch { Write-LxLog ('Refresh failed: ' + $_.Exception.Message) } }
}

function Invoke-LxVerify {
    $sticks = @(Get-LxUbuntuStick)
    $root = $null
    if ($script:lx.LxTargetExistingRadio.IsChecked -eq $true -and $script:lx.LxDriveCombo.SelectedItem) { $root = $script:lx.LxDriveCombo.SelectedItem.Root }
    elseif ($sticks.Count -gt 0) { $root = $sticks[0].Root }
    if (-not $root) {
        [void](Show-DzMessage -Text 'No Ubuntu USB stick found. Plug it in and press Refresh.' -Title 'DayZero Builder' -Kind Info -Owner $script:LxWindow)
        return
    }
    $checks = @(Test-DzLinuxStick -Root $root)
    $lines = @($checks | ForEach-Object { '{0} {1}: {2}' -f $(if ($_.Ok) { 'OK ' } else { '!! ' }), (Get-DzText $_.Name), $_.Detail })
    foreach ($l in $lines) { Write-LxLog ("Check $root $l") }
    $head = if (@($checks | Where-Object { -not $_.Ok }).Count -eq 0) { Get-DzText 'The stick check found no problems.' } else { Get-DzText 'The stick check found problems:' }
    [void](Show-DzMessage -Text ($root + "`n`n" + $head + "`n" + ($lines -join "`n")) -Title 'DayZero Builder' -Kind Info -Owner $script:LxWindow)
}

# ------------------------------------------------------------------------------------
# The window
# ------------------------------------------------------------------------------------

# ------------------------------------------------------------------------------------
# Steps (the step line and Show-WinStep's twin for the Linux side)
# ------------------------------------------------------------------------------------

$script:LxStep = 0
$script:LxReached = 0
$script:LxAllPanels = @('LxStepWhich', 'LxStepWhere', 'LxStepAccount', 'LxStepPc', 'LxStepApps', 'LxStepOptions', 'LxStepReview')

function Get-LxSteps {
    <# The steps for what is picked: an ISO written as it is needs no account, PC, apps or options. #>
    $which = @{ Panel = 'LxStepWhich'; Label = 'WHICH LINUX'; Errors = 'ISO file' }
    $where = @{ Panel = 'LxStepWhere'; Label = 'WHERE TO WRITE'; Errors = 'USB stick' }
    $review = @{ Panel = 'LxStepReview'; Label = 'CREATE'; Errors = '' }
    if (Test-LxRawKind -Kind (Get-LxSystem).Kind) { return @($which, $where, $review) }
    return @(
        $which, $where,
        @{ Panel = 'LxStepAccount'; Label = 'YOUR ACCOUNT'; Errors = 'user name|password|Your name|For example' },
        @{ Panel = 'LxStepPc'; Label = 'PC AND LANGUAGE'; Errors = 'computer name' },
        @{ Panel = 'LxStepApps'; Label = 'MODE AND APPS'; Errors = '' },
        @{ Panel = 'LxStepOptions'; Label = 'OPTIONS'; Errors = '' },
        $review
    )
}

function Show-LxStep {
    <# Shows one step of the Linux side and sets the footer buttons for it. #>
    param([Parameter(Mandatory = $true)][int]$Index)
    $lx = $script:lx
    if (-not $lx) { return }
    $steps = @(Get-LxSteps)
    $last = $steps.Count - 1
    if ($Index -lt 0) { $Index = 0 }
    if ($Index -gt $last) { $Index = $last }
    $script:LxStep = $Index
    if ($script:LxReached -gt $last) { $script:LxReached = $last }
    if ($Index -gt $script:LxReached) { $script:LxReached = $Index }
    foreach ($p in $script:LxAllPanels) { $lx[$p].Visibility = if ($p -eq $steps[$Index].Panel) { 'Visible' } else { 'Collapsed' } }
    $lx.LxBackButton.IsEnabled = ($Index -gt 0) -and -not $script:LxBusy
    $lx.LxNextButton.Visibility = if ($Index -lt $last) { 'Visible' } else { 'Collapsed' }
    $raw = Test-LxRawKind -Kind (Get-LxSystem).Kind
    $lx.LxPreviewButton.Visibility = if ($Index -eq $last -and -not $raw) { 'Visible' } else { 'Collapsed' }
    $lx.LxWriteButton.Visibility = if ($Index -eq $last) { 'Visible' } else { 'Collapsed' }
    if ($Index -eq $last) { Update-LxReview }
    $lx.LxBodyScroll.ScrollToTop()
    Update-StepBar -Steps $steps -Index $Index -Reached $script:LxReached -OnJump { param($i) Show-LxStep -Index $i }
}

function Move-LxStep {
    <# Next (+1) checks the current step first; Back (-1) always works and loses nothing. #>
    param([Parameter(Mandatory = $true)][int]$Delta)
    if ($Delta -gt 0) {
        $pattern = [string](@(Get-LxSteps)[$script:LxStep].Errors)
        if ($pattern) {
            $problems = @((Get-LxInput).Errors | Where-Object { $_ -match $pattern })
            if ($problems.Count -gt 0) {
                $text = (Get-DzText 'Please fix this first:') + "`n`n" + (($problems | ForEach-Object { ' - ' + (Get-DzText $_) }) -join "`n")
                [void](Show-DzMessage -Text $text -Title 'DayZero Builder' -Kind Warning -Owner $script:LxWindow)
                return
            }
        }
    }
    Show-LxStep -Index ($script:LxStep + $Delta)
}

function Update-LxReview {
    <# The last step: everything that will be made, plus what still has to be fixed. #>
    $lx = $script:lx
    $data = Get-LxInput
    $sys = $data.System
    $lines = New-Object System.Collections.Generic.List[string]
    switch ($sys.Kind) {
        'raw-iso' { $lines.Add(((Get-DzText 'Write {0} to this stick as it is?') -f $(if ($sys.IsoPath) { Split-Path -Leaf $sys.IsoPath } else { '?' }))) }
        'download-raw' { $lines.Add(((Get-DzText 'Download {0} and write it to this stick as it is?') -f $data.DistroName)) }
        default { $lines.Add(((Get-DzText 'Make a {0} install USB with DayZero on this stick?') -f $data.DistroName)) }
    }
    $lines.Add('')
    if ($data.Existing) { $lines.Add(((Get-DzText 'Add DayZero to the Ubuntu stick {0}?') -f $data.Root)); $lines.Add((Get-DzText 'Nothing on it is erased.')) }
    elseif ($data.Disk) {
        $lines.Add((Get-DzText 'EVERYTHING ON IT WILL BE ERASED:'))
        $lines.Add(('   {0}, {1} GB, {2}' -f $data.Disk.Name, $data.Disk.SizeGB, $(if ($data.Disk.Volumes) { $data.Disk.Volumes } else { Get-DzText 'no drive letter' })))
    }
    if ($data.Settings) {
        $s = $data.Settings
        $lines.Add('')
        $lines.Add(((Get-DzText 'Account: {0}{1}') -f $s.userName, $(if ($s.temporaryPassword) { Get-DzText ' (temporary password)' } else { '' })))
        if ($lx.LxComputerNameText.Text) { $lines.Add(('{0}: {1}' -f (Get-DzText 'Computer name'), $lx.LxComputerNameText.Text)) }
        $lines.Add(((Get-DzText 'On Linux: {0}, keyboard {1}, {2}') -f $data.Options.Locale, $data.Options.Keyboard.Layout, $data.Options.TimeZone))
        $names = @($script:LxAppBoxes | Where-Object { $_.IsChecked -eq $true } | ForEach-Object { [string]$_.Tag.name })
        $lines.Add(((Get-DzText 'Mode: {0}, {1} apps') -f $s.defaultMode, $names.Count))
        if ($names.Count -gt 0) { $lines.Add('   ' + ($names -join ', ')) }
        $opts = @()
        if ($s.installDrivers) { $opts += Get-DzText 'drivers' }
        if ($data.Options.Codecs) { $opts += Get-DzText 'media codecs' }
        if ($s.dryRun) { $opts += Get-DzText 'DRY RUN' }
        if ($opts.Count -gt 0) { $lines.Add(((Get-DzText 'Also: {0}') -f ($opts -join ', '))) }
        $lines.Add('')
        $lines.Add((Get-DzText 'The Ubuntu installer will stop and let you choose the disk. Everything else runs on its own.'))
    }
    elseif (Test-LxRawKind -Kind $sys.Kind) {
        $lines.Add('')
        $lines.Add((Get-DzText 'You install it by hand; your account, apps and scripts are not used.'))
    }
    $lx.LxReviewText.Text = ($lines -join "`n")
    if ($data.Errors.Count -gt 0) {
        $lx.LxReviewProblemsText.Text = (Get-DzText 'Please fix this first:') + "`n" + (($data.Errors | ForEach-Object { ' - ' + (Get-DzText $_) }) -join "`n")
        $lx.LxReviewProblemsBox.Visibility = 'Visible'
    }
    else { $lx.LxReviewProblemsBox.Visibility = 'Collapsed' }
    $lx.LxWriteButton.IsEnabled = ($data.Errors.Count -eq 0 -and -not $script:LxBusy)
}

function Initialize-LinuxPanel {
    <# Loads LinuxPanel.xaml into the builder window once, fills it and wires its events. #>
    if ($script:lx) { return }
    Import-Module (Join-Path $script:BuilderRoot 'lib\Linux.psm1') -Force
    Import-Module (Join-Path $script:BuilderRoot 'lib\RawWrite.psm1') -Force
    $path = Join-Path $script:BuilderRoot 'LinuxPanel.xaml'
    $script:LxWindow = $script:Window
    $script:LxRoot = Import-DzXaml -Path $path
    $script:LxAppBoxes = @()
    $lx = Get-DzNamedElement -Root $script:LxRoot -XamlPath $path
    $script:ui.LinuxHost.Content = $script:LxRoot
    Update-DzTranslation -Root $script:LxRoot

    $script:lx = $lx
    Initialize-LxDistros
    $lx.LxLanguageCombo.ItemsSource = Get-RegionItemList
    $lx.LxKeyboardCombo.ItemsSource = Get-KeyboardItemList
    $lx.LxTimeZoneCombo.ItemsSource = Get-TimeZoneItemList
    Set-LxRegionFromThisPc
    Initialize-LxModes
    Initialize-LxApps
    Update-LxScriptsCount
    $suggest = ConvertTo-DzLinuxUserName -Name ([string]$script:ui.UserNameText.Text)
    if ($suggest) { $lx.LxUserNameText.Text = $suggest }

    $lx.LxUbuntuIsoRadio.Add_Checked({ Update-LxSystemMode })
    $lx.LxRawIsoRadio.Add_Checked({ Update-LxSystemMode })
    $lx.LxTargetNewRadio.Add_Checked({ Update-LxTargetMode })
    $lx.LxTargetExistingRadio.Add_Checked({ Update-LxTargetMode })
    $lx.LxUsbDiskCombo.Add_SelectionChanged({ Update-LxTargetHint })
    $lx.LxDriveCombo.Add_SelectionChanged({ Update-LxTargetHint })
    $lx.LxRefreshButton.Add_Click({ try { Update-LxDisks } catch { Write-LxLog ('Refresh failed: ' + $_.Exception.Message) } })
    $lx.LxBrowseIsoButton.Add_Click({ try { Select-LxIsoFile } catch { [void](Show-DzMessage -Text $_.Exception.Message -Kind Error -Owner $script:LxWindow) } })
    $lx.LxLanguageCombo.Add_SelectionChanged({ Update-LxRegionText })
    $lx.LxKeyboardCombo.Add_SelectionChanged({ Update-LxRegionText })
    $lx.LxTimeZoneCombo.Add_SelectionChanged({ Update-LxRegionText })
    $lx.LxUseThisPcButton.Add_Click({ Set-LxRegionFromThisPc })
    $lx.LxModeCombo.Add_SelectionChanged({ Set-LxAppsFromMode })
    $lx.LxOpenScriptsButton.Add_Click({
            try {
                $dir = Join-Path $script:KitRoot 'Scripts-Linux'
                if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
                Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $dir + '"')
            }
            catch { [void](Show-DzMessage -Text $_.Exception.Message -Kind Error -Owner $script:LxWindow) }
        })
    $lx.LxPreviewButton.Add_Click({ try { Invoke-LxPreview } catch { [void](Show-DzMessage -Text $_.Exception.Message -Kind Error -Owner $script:LxWindow) } })
    $lx.LxVerifyButton.Add_Click({ try { Invoke-LxVerify } catch { [void](Show-DzMessage -Text $_.Exception.Message -Kind Error -Owner $script:LxWindow) } })
    $lx.LxNextButton.Add_Click({ try { Move-LxStep -Delta 1 } catch { [void](Show-DzMessage -Text $_.Exception.Message -Kind Error -Owner $script:LxWindow) } })
    $lx.LxBackButton.Add_Click({ try { Move-LxStep -Delta -1 } catch { [void](Show-DzMessage -Text $_.Exception.Message -Kind Error -Owner $script:LxWindow) } })
    $lx.LxWriteButton.Add_Click({ try { Invoke-LxWrite } catch { [void](Show-DzMessage -Text $_.Exception.Message -Kind Error -Owner $script:LxWindow) } })

    Update-LxSystemMode
    Update-LxDisks
}

function Update-LinuxPanelLanguage {
    <# After the language button: every text of the Linux side again, keeping what was picked and typed. #>
    if (-not $script:lx) { return }
    $picked = Get-LxSystem
    Update-DzTranslation -Root $script:LxRoot
    Update-ListLanguage -Combo $script:lx.LxLanguageCombo -Kind culture
    Update-ListLanguage -Combo $script:lx.LxTimeZoneCombo -Kind timezone
    Initialize-LxDistros
    if ($picked.Kind -like 'download*') { foreach ($r in $script:LxDistroRadios) { $r.IsChecked = ([string]$r.Tag -eq $picked.DistroId) } }
    Initialize-LxModes
    Initialize-LxApps
    Update-LxSystemMode
    Update-LxRegionText
    Update-LxScriptsCount
    Set-LxStatus -Text 'Ready.'
}

function Show-BuilderSide {
    <# WINDOWS or LINUX in the header: shows that form and its buttons; what was entered on the other side stays. #>
    param([Parameter(Mandatory = $true)][ValidateSet('windows', 'linux')][string]$Side)
    $ui = $script:ui
    if ($Side -eq 'linux') {
        $script:Window.Cursor = [System.Windows.Input.Cursors]::Wait
        try { Initialize-LinuxPanel } finally { $script:Window.Cursor = $null }
    }
    $isLinux = ($Side -eq 'linux')
    $ui.WindowsBodyScroll.Visibility = if ($isLinux) { 'Collapsed' } else { 'Visible' }
    $ui.WindowsFooter.Visibility = if ($isLinux) { 'Collapsed' } else { 'Visible' }
    $ui.LinuxHost.Visibility = if ($isLinux) { 'Visible' } else { 'Collapsed' }
    if ($isLinux) { Update-LxScriptsCount; Show-LxStep -Index $script:LxStep }
    else { Show-WinStep -Index $script:WinStep }
    Write-BuilderLog "Showing the $Side side."
}

function Test-BuilderAnyBusy {
    <# $true while either side is writing a stick (then the switch and the window close are blocked). #>
    return ([bool]$script:Busy -or [bool]$script:LxBusy)
}
