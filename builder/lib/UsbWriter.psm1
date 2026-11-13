#Requires -Version 5.1
<#
    DayZero - writes the generated answer file and the toolkit to the USB stick
    (or to a plain folder, for building a VM test ISO).

    What it changes on the target, and nothing else:
      <root>\autounattend.xml            (an existing one is renamed to a .backup-*.xml first)
      <root>\DayZero-README.txt
      <root>\DayZero\...                 (toolkit; your Drivers\ and Logs\ are kept)
#>

Set-StrictMode -Version 2.0

$script:KitFolderName = 'DayZero'
# Top-level kit folders that belong to the user and are never deleted or overwritten.
$script:PreservedFolders = @('Drivers', 'Logs', 'bundled')
# Merged: files from the kit replace same-named files on the stick, other stick files stay.
$script:MergedFolders = @('Scripts')

function Write-DzUtf8File {
    <# Writes text as UTF-8 without BOM (works the same on PowerShell 5.1 and 7). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Test-DzIsSystemDriveRoot {
    <# True when Path is the root of the drive Windows is running from (e.g. C:\). #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not $env:SystemDrive) { return $false }   # not on Windows
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    return ($full -ieq $env:SystemDrive.TrimEnd('\'))
}

function Get-DzReadmeText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Settings)
    $nl = "`r`n"
    $lines = @(
        'DAYZERO - what is on this USB stick',
        '====================================',
        '',
        'This is a Windows installation USB with an answer file (autounattend.xml) made by',
        "the DayZero Builder on $($Settings.builtAt) (build $($Settings.buildId)).",
        '',
        'WHAT HAPPENS WHEN YOU BOOT A PC FROM IT',
        '  * Windows Setup runs mostly unattended.',
        '  * It will STOP and ask you which disk to install Windows on. DayZero never',
        '    picks, wipes or partitions a disk by itself. Read that screen carefully.',
        "  * The local account '$($Settings.userName)' is created and the DayZero setup",
        '    wizard starts at the first sign-in.',
        '',
        'SECURITY',
        '  * autounattend.xml contains your password in base64. That is NOT encryption:',
        '    anyone who has this USB stick can decode it in seconds.',
        '  * If you typed a product key, it is in that file in plain text.',
        '  * After installing, delete autounattend.xml from the stick (or rebuild it with a',
        '    temporary password) if other people can get hold of it.',
        '',
        'FILES',
        '  autounattend.xml     the answer file Windows Setup reads automatically',
        '  DayZero\             the toolkit (copied to C:\DayZero during setup)',
        '  DayZero\Drivers\     optional: put extra drivers (.inf folders) here',
        '  DayZero\Scripts\     optional: your own .cmd/.bat/.ps1 scripts, run after the apps',
        '  DayZero\Logs\        logs from the builder and from each PC set up with this stick'
    )
    return (($lines -join $nl) + $nl)
}

function Copy-DzKit {
    <#
        Copies the kit folder to <TargetRoot>\DayZero. Kit files are replaced so an old
        version never lingers; the user's Drivers\, Logs\ and bundled\ folders are kept,
        and Scripts\ is merged (kit files replace same-named ones, the stick's others stay).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$KitSource,
        [Parameter(Mandatory = $true)][string]$Destination,
        [scriptblock]$Log,
        [scriptblock]$Tick
    )
    if (-not (Test-Path -LiteralPath $KitSource)) { throw "Kit folder not found: $KitSource" }
    if (-not (Test-Path -LiteralPath $Destination)) { [void](New-Item -ItemType Directory -Path $Destination -Force) }

    foreach ($item in @(Get-ChildItem -LiteralPath $KitSource -Force)) {
        if ($item.Name -like 'build-*.marker') { continue }
        # Left over from trying the wizard on this PC (DayZero.cmd -DryRun): not for the new PC.
        if ($item.Name -like 'state.json*' -or $item.Name -eq 'backup' -or $item.Name -eq 'language.txt') { continue }
        if ($Tick) { & $Tick }   # lets the builder window stay responsive between items
        $target = Join-Path $Destination $item.Name
        if ($script:MergedFolders -contains $item.Name) {
            if (-not (Test-Path -LiteralPath $target)) { [void](New-Item -ItemType Directory -Path $target -Force) }
            foreach ($f in @(Get-ChildItem -LiteralPath $item.FullName -File -Force)) { Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $target $f.Name) -Force }
            if ($Log) { & $Log "Copied your $($item.Name)\ (scripts already on the stick were kept)." }
            continue
        }
        if ($script:PreservedFolders -contains $item.Name) {
            if (-not (Test-Path -LiteralPath $target)) { [void](New-Item -ItemType Directory -Path $target -Force) }
            # Only add our helper files (README, .gitkeep) if they are missing.
            foreach ($f in @(Get-ChildItem -LiteralPath $item.FullName -File -Force)) {
                $t = Join-Path $target $f.Name
                if (-not (Test-Path -LiteralPath $t)) { Copy-Item -LiteralPath $f.FullName -Destination $t -Force }
            }
            if ($Log) { & $Log "Kept your $($item.Name)\ folder." }
            continue
        }
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
        Copy-Item -LiteralPath $item.FullName -Destination $target -Recurse -Force
    }
    if ($Log) { & $Log "Copied the toolkit to $Destination" }
}

function Write-DzKitToTarget {
    <#
    .SYNOPSIS
        Writes autounattend.xml, the toolkit, settings.json and the build marker.
    .OUTPUTS
        Object with AnswerFile, Backup (or $null), KitPath, Marker.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [Parameter(Mandatory = $true)][string]$KitSource,
        [Parameter(Mandatory = $true)][string]$UnattendXml,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Settings,
        [scriptblock]$Log,
        [scriptblock]$Tick
    )
    if (-not (Test-Path -LiteralPath $TargetRoot)) { throw "Target not found: $TargetRoot" }
    if (Test-DzIsSystemDriveRoot -Path $TargetRoot) {
        throw 'Refusing to write to the root of the drive Windows is running from. Pick the USB stick or an export folder.'
    }
    $buildId = [string]$Settings.buildId
    if ($buildId -notmatch '^[0-9a-f]{8}$') { throw 'Settings.buildId must be 8 lowercase hex characters.' }

    # 1. answer file (keep any previous one as a backup)
    $answer = Join-Path $TargetRoot 'autounattend.xml'
    $backup = $null
    if (Test-Path -LiteralPath $answer) {
        $backup = Join-Path $TargetRoot ('autounattend.backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.xml')
        Move-Item -LiteralPath $answer -Destination $backup -Force
        if ($Log) { & $Log "Existing autounattend.xml saved as $(Split-Path -Leaf $backup)" }
    }
    Write-DzUtf8File -Path $answer -Text $UnattendXml
    if ($Log) { & $Log "Wrote $answer" }

    # 2. toolkit
    $kitPath = Join-Path $TargetRoot $script:KitFolderName
    Copy-DzKit -KitSource $KitSource -Destination $kitPath -Log $Log -Tick $Tick

    # 3. settings for the wizard (no passwords in here)
    $json = $Settings | ConvertTo-Json -Depth 6
    Write-DzUtf8File -Path (Join-Path $kitPath 'config\settings.json') -Text $json
    if ($Log) { & $Log 'Wrote DayZero\config\settings.json' }

    # 4. build marker: the answer file looks for exactly this file to find the USB.
    foreach ($old in @(Get-ChildItem -LiteralPath $kitPath -Filter 'build-*.marker' -File -Force -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $old.FullName -Force
    }
    $marker = Join-Path $kitPath ('build-' + $buildId + '.marker')
    Write-DzUtf8File -Path $marker -Text ("DayZero build $buildId - do not delete. The answer file uses this file to find the toolkit.`r`n")

    # 5. a plain-text explanation next to the answer file
    Write-DzUtf8File -Path (Join-Path $TargetRoot 'DayZero-README.txt') -Text (Get-DzReadmeText -Settings $Settings)

    return [pscustomobject]@{
        AnswerFile = $answer
        Backup     = $backup
        KitPath    = $kitPath
        Marker     = $marker
    }
}

function Test-DzUsbStick {
    <#
    .SYNOPSIS
        Checks a finished DayZero stick (or export folder) without changing it.
    .DESCRIPTION
        Returns one object per check: Name, Ok, Detail. Looks at the Windows Setup files, the
        Windows image parts, the answer file (well-formed, no disk settings, points at this
        stick's toolkit) and the toolkit itself. -ImageInfo (from Get-DzMediaInfo) and
        -FileSystem add what only Windows can tell: whether the image opens and how the
        stick is formatted. -ToolkitOnly skips the Windows files (for an export folder).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Used inside the nested script block, which the analyzer cannot follow.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [object]$ImageInfo,
        [string]$FileSystem,
        [switch]$ToolkitOnly
    )
    $results = New-Object System.Collections.Generic.List[object]
    $add = { param($name, $ok, $detail) $results.Add([pscustomobject]@{ Name = [string]$name; Ok = [bool]$ok; Detail = [string]$detail }) }
    $at = { param($relative) Join-Path $Root $relative }

    if (-not $ToolkitOnly) {
        $missing = @(@('setup.exe', 'sources\boot.wim') | Where-Object { -not (Test-Path -LiteralPath (& $at $_)) })
        & $add 'Windows Setup files' ($missing.Count -eq 0) $(if ($missing.Count) { 'Missing: ' + ($missing -join ', ') } else { 'setup.exe and sources\boot.wim are there.' })

        $efi = @(@('efi\boot\bootx64.efi', 'efi\boot\bootaa64.efi') | Where-Object { Test-Path -LiteralPath (& $at $_) })
        $bios = Test-Path -LiteralPath (& $at 'bootmgr')
        & $add 'Boot files' (@($efi).Count -gt 0) $(if (@($efi).Count -eq 0) { 'Missing: efi\boot\bootx64.efi. The stick will not boot.' } elseif ($bios) { 'UEFI and legacy BIOS boot files are there.' } else { 'UEFI boot files are there (no bootmgr for legacy BIOS).' })

        $sources = & $at 'sources'
        $parts = @(Get-ChildItem -LiteralPath $sources -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^install\d*\.(wim|esd|swm)$' })
        if ($parts.Count -eq 0) { & $add 'Windows image' $false 'Missing: sources\install.wim, install.esd or install.swm.' }
        else {
            $swm = @($parts | Where-Object { $_.Extension -ieq '.swm' })
            $gap = $null
            if ($swm.Count -gt 0) {
                if (-not ($swm | Where-Object { $_.Name -ieq 'install.swm' })) { $gap = 'install.swm' }
                for ($n = 2; $n -le $swm.Count -and -not $gap; $n++) { if (-not ($swm | Where-Object { $_.Name -ieq "install$n.swm" })) { $gap = "install$n.swm" } }
            }
            $size = 0.0
            foreach ($p in $parts) { $size += $p.Length }
            $big = @($parts | Where-Object { $_.Length -gt 4294967295 })
            if ($gap) { & $add 'Windows image' $false "A part of the split image is missing: $gap" }
            elseif ($big.Count -gt 0 -and $FileSystem -ieq 'FAT32') { & $add 'Windows image' $false "$($big[0].Name) is larger than 4 GB, which FAT32 cannot hold." }
            else { & $add 'Windows image' $true ('{0} file(s), {1:N1} GB.' -f $parts.Count, ($size / 1GB)) }
        }
        if ($ImageInfo) {
            if ($ImageInfo.Error) { & $add 'Windows image opens' $false ([string]$ImageInfo.Error) }
            else { & $add 'Windows image opens' (@($ImageInfo.Editions).Count -gt 0) ('Windows {0} build {1}: {2}' -f $ImageInfo.WindowsVersion, $ImageInfo.Build, ((@($ImageInfo.Editions) | ForEach-Object { ([string]$_.Name) -replace '^Windows 1[01] ', '' }) -join ', ')) }
        }
        if ($FileSystem) {
            & $add 'File system' $true $(if ($FileSystem -ieq 'FAT32') { 'FAT32: boots on UEFI (with Secure Boot) and legacy BIOS.' } else { "${FileSystem}: made by another tool; it boots only if that tool added its own boot helper." })
        }
    }

    $answer = & $at 'autounattend.xml'
    $buildId = $null
    if (-not (Test-Path -LiteralPath $answer)) { & $add 'Answer file' $false 'Missing: autounattend.xml. Windows Setup would ask every question itself.' }
    else {
        try {
            $text = [System.IO.File]::ReadAllText($answer)
            $doc = New-Object System.Xml.XmlDocument
            $doc.XmlResolver = $null
            $doc.LoadXml($text)
            $forbidden = @('DiskConfiguration', 'WipeDisk', 'InstallTo', 'CreatePartitions', 'ModifyPartitions', 'ImageInstall')
            $hit = @($doc.SelectNodes('//*') | Where-Object { $forbidden -contains $_.LocalName } | ForEach-Object { $_.LocalName } | Select-Object -Unique)
            $m = [regex]::Match($text, 'build-([0-9a-f]{8})\.marker')
            if ($m.Success) { $buildId = $m.Groups[1].Value }
            if ($hit.Count -gt 0) { & $add 'Answer file' $false ('It contains disk settings (' + ($hit -join ', ') + '). DayZero never writes those: do not use this stick.') }
            elseif (-not $buildId) { & $add 'Answer file' $false 'It was not made by DayZero (no toolkit marker in it).' }
            else { & $add 'Answer file' $true "Well-formed, no disk settings, build $buildId." }
        }
        catch { & $add 'Answer file' $false ('autounattend.xml is not valid XML: ' + $_.Exception.Message) }
    }

    $kit = & $at $script:KitFolderName
    $needed = @('DayZero.cmd', 'DayZero.ps1', 'VERSION', 'lib\Modules.ps1', 'lib\Core.psm1', 'bootstrap\CopyKit.cmd', 'bootstrap\FirstLogon.cmd', 'config\modes.json', 'config\apps.json', 'ui\Wizard.xaml')
    $gone = @($needed | Where-Object { -not (Test-Path -LiteralPath (Join-Path $kit $_)) })
    & $add 'DayZero toolkit' ($gone.Count -eq 0) $(if ($gone.Count) { 'Missing in DayZero\: ' + ($gone -join ', ') } else { 'All parts are there.' })

    if ($buildId) {
        $marker = Join-Path $kit "build-$buildId.marker"
        & $add 'Answer file finds the toolkit' (Test-Path -LiteralPath $marker) $(if (Test-Path -LiteralPath $marker) { "Marker build-$buildId.marker is there." } else { "DayZero\build-$buildId.marker is missing: the new PC would not find the toolkit. Write the stick again." })
    }
    $settingsPath = Join-Path $kit 'config\settings.json'
    try {
        $settings = [System.IO.File]::ReadAllText($settingsPath) | ConvertFrom-Json
        $value = { param($name) if ($settings.PSObject.Properties[$name]) { [string]$settings.$name } else { '-' } }
        $same = (-not $buildId) -or ((& $value 'buildId') -eq $buildId)
        & $add 'Your settings' $same $(if ($same) { ('Mode {0}, clean-up level {1}, account {2}.' -f (& $value 'defaultMode'), (& $value 'debloatLevel'), (& $value 'userName')) } else { 'settings.json belongs to another build than the answer file. Write the stick again.' })
    }
    catch { & $add 'Your settings' $false 'DayZero\config\settings.json is missing or unreadable.' }
    return $results.ToArray()
}

Export-ModuleMember -Function @('Test-DzUsbStick', 'Write-DzUtf8File', 'Test-DzIsSystemDriveRoot', 'Get-DzReadmeText', 'Copy-DzKit', 'Write-DzKitToTarget')
