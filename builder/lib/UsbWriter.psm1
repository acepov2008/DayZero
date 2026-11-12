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
        '  DayZero\Logs\        logs from the builder and from each PC set up with this stick'
    )
    return (($lines -join $nl) + $nl)
}

function Copy-DzKit {
    <#
        Copies the kit folder to <TargetRoot>\DayZero. Kit files are replaced so an old
        version never lingers; the user's Drivers\, Logs\ and bundled\ folders are kept.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$KitSource,
        [Parameter(Mandatory = $true)][string]$Destination,
        [scriptblock]$Log
    )
    if (-not (Test-Path -LiteralPath $KitSource)) { throw "Kit folder not found: $KitSource" }
    if (-not (Test-Path -LiteralPath $Destination)) { [void](New-Item -ItemType Directory -Path $Destination -Force) }

    foreach ($item in @(Get-ChildItem -LiteralPath $KitSource -Force)) {
        if ($item.Name -like 'build-*.marker') { continue }
        $target = Join-Path $Destination $item.Name
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
        [scriptblock]$Log
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
    Copy-DzKit -KitSource $KitSource -Destination $kitPath -Log $Log

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

Export-ModuleMember -Function @('Write-DzUtf8File', 'Test-DzIsSystemDriveRoot', 'Get-DzReadmeText', 'Copy-DzKit', 'Write-DzKitToTarget')
