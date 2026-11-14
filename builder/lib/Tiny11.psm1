#Requires -Version 5.1
<#
    DayZero builder - optional "tiny11": a slimmed-down Windows 11 made with ntdevlabs'
    tiny11builder (https://github.com/ntdevlabs/tiny11builder).

    How it is used here:
      * tiny11builder is NOT part of DayZero and is not stored in this repository (it has no
        licence that would allow redistribution). The builder downloads tiny11maker.ps1 and its
        autounattend.xml from GitHub at one fixed commit and refuses them unless their SHA-256
        matches the values below, which are the files that were read and reviewed.
      * The script runs unchanged, in its own console window, on a copy of the Windows 11
        files. Its two questions (image index, "press Enter") are answered for it.
      * Its result (tiny11.iso) is kept in the Windows cache and written to the stick like any ISO.

    Only the standard tiny11 is offered. It keeps Windows Update and Microsoft Defender.
    "tiny11 core" (tiny11Coremaker.ps1) disables both and cannot be updated, which DayZero's
    rules do not allow, so it is deliberately not supported here.

    What standard tiny11 changes is baked into the Windows image and is NOT undone by
    DayZero.cmd -Undo: see Get-DzTiny11Summary.
#>

Set-StrictMode -Version 2.0

$script:Commit = '38f7ab6b1f177098c026a19b73ec84bca9c4b874'
$script:Files = @(
    [pscustomobject]@{ Name = 'tiny11maker.ps1'; Sha256 = '7a7baffa75742d9ae9512936d72887931c8bc2a91ac16ccd451a8869752b6f5e' },
    [pscustomobject]@{ Name = 'autounattend.xml'; Sha256 = 'ed9837ab4a19c812d28e20f5278ca5bb25815a6a01d1caddbce157be5d519dba' }
)

function Get-DzTiny11Source {
    <# Where the tiny11builder files come from: the pinned commit and, per file, its URL and SHA-256. #>
    [CmdletBinding()]
    param()
    $files = foreach ($f in $script:Files) {
        [pscustomobject]@{
            Name   = $f.Name
            Sha256 = $f.Sha256
            Url    = ('https://raw.githubusercontent.com/ntdevlabs/tiny11builder/{0}/{1}' -f $script:Commit, $f.Name)
        }
    }
    return [pscustomobject]@{ Commit = $script:Commit; Id = $script:Files[0].Sha256.Substring(0, 8); Files = @($files) }
}

function Get-DzTiny11Summary {
    <# What standard tiny11 does to Windows, as plain lines for the builder window. #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return @(
        'Removes Microsoft Edge and its WebView, OneDrive and about 50 built-in apps (Xbox apps, Terminal, Paint, Camera, Sticky Notes, Clock, Media Player, Quick Assist, Teams, Outlook, Copilot and more).',
        'Turns off telemetry, promoted apps and automatic BitLocker device encryption.',
        'Skips the Windows 11 hardware checks (TPM, Secure Boot, processor, memory).',
        'Holds one edition only (the Home or Pro you pick).',
        'Windows Update and Microsoft Defender stay on.',
        'These changes are built into Windows: DayZero.cmd -Undo cannot bring them back.'
    )
}

function Test-DzFileSha256 {
    <# True when the file exists and its SHA-256 is the expected one. #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-fA-F]{64}$')][string]$Sha256)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    return ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ieq $Sha256)
}

function Save-DzTiny11Script {
    <#
        Downloads the pinned tiny11builder files into $Folder and checks each against its
        SHA-256. A file that does not match is deleted and the call fails: nothing unreviewed
        is ever run. Returns the path of tiny11maker.ps1.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Folder, [scriptblock]$Log)
    try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12 }
    catch { Write-Verbose 'Could not change the TLS setting.' }
    if (-not (Test-Path -LiteralPath $Folder)) { [void](New-Item -ItemType Directory -Path $Folder -Force) }
    $source = Get-DzTiny11Source
    foreach ($f in $source.Files) {
        $path = Join-Path $Folder $f.Name
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        $wc = New-Object System.Net.WebClient
        try { $wc.DownloadFile($f.Url, $path) }
        catch { throw "Could not download $($f.Name) from GitHub: $($_.Exception.Message)" }
        finally { $wc.Dispose() }
        if (-not (Test-DzFileSha256 -Path $path -Sha256 $f.Sha256)) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            throw "$($f.Name) from GitHub is not the reviewed version (checksum mismatch), so it was not used."
        }
    }
    if ($Log) { & $Log ("tiny11builder {0} downloaded from GitHub and checked (SHA-256 matches the reviewed files)." -f $source.Commit.Substring(0, 7)) }
    return (Join-Path $Folder 'tiny11maker.ps1')
}

function Get-DzFreeDriveLetter {
    <# A drive letter nothing uses (Z downwards), or $null. -Used is for tests. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string[]]$Used)
    if ($null -eq $Used) { $Used = @([System.IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1) }) }
    $taken = @($Used | ForEach-Object { ([string]$_).Substring(0, 1).ToUpperInvariant() })
    foreach ($code in 90..68) {
        $letter = [string][char]$code
        if ($taken -notcontains $letter) { return $letter }
    }
    return $null
}

function Select-DzEditionIndex {
    <# The image index of plain Windows 11 Home or Pro in a list of images (Index + Name), or 0. #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Images,
        [Parameter(Mandatory = $true)][ValidateSet('home', 'pro')][string]$Edition
    )
    $name = if ($Edition -eq 'home') { 'Windows 11 Home' } else { 'Windows 11 Pro' }
    $hit = @($Images | Where-Object { [string]$_.Name -ceq $name }) | Select-Object -First 1
    if ($hit) { return [int]$hit.Index }
    return 0
}

function Get-DzTiny11IsoName {
    <#
        File name of a finished tiny11 ISO in the cache. It names everything the result depends
        on: language, edition, the Windows it was made from and the tiny11builder version.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$Language,
        [Parameter(Mandatory = $true)][ValidateSet('home', 'pro')][string]$Edition,
        [Parameter(Mandatory = $true)][string]$SourceId
    )
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try { $hash = ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($SourceId.ToLowerInvariant())) | ForEach-Object { $_.ToString('x2') }) -join '' }
    finally { $sha.Dispose() }
    return ('tiny11-win11-{0}-{1}-{2}-{3}.iso' -f $Language.ToLowerInvariant(), $Edition, $hash.Substring(0, 10), (Get-DzTiny11Source).Id)
}

function Test-DzTiny11Choice {
    <# Problem text when tiny11 cannot be made with these builder choices; $null when it can. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([int]$WindowsVersion, [string]$Edition, [string]$Architecture = 'amd64')
    if ($WindowsVersion -ne 11) { return 'tiny11 exists for Windows 11 only.' }
    if ($Architecture -ne 'amd64') { return 'tiny11 is offered here for 64-bit Intel/AMD Windows only.' }
    if (@('home', 'pro') -notcontains $Edition) { return 'tiny11 holds one edition only: pick Home or Pro as the edition.' }
    return $null
}

function Invoke-DzConsoleScript {
    <#
        Runs a PowerShell script in its own visible console window (it clears the screen and
        sets the window title, so it needs a real console) and types the given answers into
        its Read-Host questions. Returns the exit code, or throws after -TimeoutMinutes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string]$Arguments = '',
        [string[]]$Answers = @(),
        [int]$TimeoutMinutes = 240,
        [string]$Activity = 'Working',
        [scriptblock]$Tick
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $psi.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File "{0}" {1}' -f $ScriptPath, $Arguments).Trim()
    $psi.WorkingDirectory = Split-Path -Parent $ScriptPath
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $false
    $psi.RedirectStandardInput = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    try {
        foreach ($a in $Answers) { $p.StandardInput.WriteLine($a) }
        $p.StandardInput.Close()
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $p.HasExited) {
            if ($clock.Elapsed.TotalMinutes -gt $TimeoutMinutes) {
                try { $p.Kill() } catch { Write-Verbose 'The script had already ended.' }
                throw "$Activity did not finish within $TimeoutMinutes minutes and was stopped."
            }
            if ($Tick) { & $Tick ('{0} ({1:N0} min)' -f $Activity, [math]::Floor($clock.Elapsed.TotalMinutes)) }
            Start-Sleep -Milliseconds 300
        }
        return $p.ExitCode
    }
    finally {
        $p.Dispose()
    }
}

function New-DzTiny11Iso {
    <#
    .SYNOPSIS
        Makes tiny11.iso from Windows 11 installation files and returns its path.
    .DESCRIPTION
        $MediaRoot is a folder or drive with normal Windows 11 media (install.wim, .esd or split
        .swm). The chosen edition is exported to a single install.wim, tiny11builder runs on
        that copy, and its tiny11.iso is moved to $OutIso. $MediaRoot itself is never changed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$MediaRoot,
        [Parameter(Mandatory = $true)][ValidateSet('home', 'pro')][string]$Edition,
        [Parameter(Mandatory = $true)][string]$WorkDir,
        [Parameter(Mandatory = $true)][string]$OutIso,
        [scriptblock]$Tick,
        [scriptblock]$Log
    )
    $image = Find-DzInstallImage -Root $MediaRoot
    if (-not $image) { throw 'No Windows image (sources\install.wim, .esd or .swm) in the Windows files.' }
    $images = @(Get-WindowsImage -ImagePath $image -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Index = $_.ImageIndex; Name = $_.ImageName } })
    $index = Select-DzEditionIndex -Images $images -Edition $Edition
    if ($index -le 0) { throw "These Windows files have no plain Windows 11 $Edition edition, which tiny11 needs." }

    $drive = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID = '{0}'" -f ([System.IO.Path]::GetPathRoot($WorkDir).TrimEnd('\'))) -ErrorAction SilentlyContinue
    if ($drive -and [int64]$drive.FreeSpace -lt 25GB) {
        throw ('tiny11 needs about 25 GB of free space on {0}; only {1:N0} GB is free.' -f $drive.DeviceID, ($drive.FreeSpace / 1GB))
    }

    if (Test-Path -LiteralPath $WorkDir) {
        [void](Invoke-DzProcess -FilePath (Join-Path $env:SystemRoot 'System32\dism.exe') -Arguments '/Cleanup-Mountpoints')
        Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    $source = Join-Path $WorkDir 'source'
    $tool = Join-Path $WorkDir 'tool'
    [void](New-Item -ItemType Directory -Path (Join-Path $source 'sources') -Force)
    [void](New-Item -ItemType Directory -Path $tool -Force)

    # 1. The Windows files without the big image, then only the chosen edition as install.wim.
    $arguments = '{0} {1} /E /R:1 /W:1 /NP /NFL /NDL /NJH /NJS /XF install.wim install.esd install*.swm' -f (ConvertTo-DzRobocopyPath -Path $MediaRoot), (ConvertTo-DzRobocopyPath -Path $source)
    $r = Invoke-DzProcess -FilePath (Join-Path $env:SystemRoot 'System32\robocopy.exe') -Arguments $arguments -Activity 'Preparing the Windows files for tiny11' -Tick $Tick
    if ($r.ExitCode -ge 8) { throw "Copying the Windows files for tiny11 failed (robocopy exit code $($r.ExitCode))." }
    $export = '/Export-Image /SourceImageFile:"{0}" /SourceIndex:{1} /DestinationImageFile:"{2}" /Compress:max /CheckIntegrity' -f $image, $index, (Join-Path $source 'sources\install.wim')
    if ([System.IO.Path]::GetExtension($image) -ieq '.swm') { $export += (' /SWMFile:"{0}"' -f (Join-Path (Split-Path -Parent $image) 'install*.swm')) }
    Invoke-DzDism -Tick $Tick -Activity ('Preparing Windows 11 {0} for tiny11' -f $(if ($Edition -eq 'home') { 'Home' } else { 'Pro' })) -Arguments $export

    # 2. The reviewed tiny11builder script.
    $scriptPath = Save-DzTiny11Script -Folder $tool -Log $Log

    # 3. tiny11builder wants a drive letter, so the folder gets one for the duration.
    $letter = Get-DzFreeDriveLetter
    if (-not $letter) { throw 'No free drive letter for tiny11builder.' }
    $subst = Join-Path $env:SystemRoot 'System32\subst.exe'
    $r = Invoke-DzProcess -FilePath $subst -Arguments ('{0}: "{1}"' -f $letter, $source)
    if ($r.ExitCode -ne 0) { throw "Could not give the Windows files the drive letter ${letter}: $($r.Output)" }
    try {
        if ($Log) { & $Log "Starting tiny11builder in its own window (Windows files as ${letter}:, image index 1). This usually takes 30 to 90 minutes." }
        # Answers: the image index (the copy holds exactly one edition), then Enter at the end.
        [void](Invoke-DzConsoleScript -ScriptPath $scriptPath -Arguments ("-ISO $letter") -Answers @('1', '', '') -Activity 'tiny11builder is working in its own window' -Tick $Tick)
    }
    finally {
        [void](Invoke-DzProcess -FilePath $subst -Arguments ('{0}: /D' -f $letter))
    }

    # 4. Its result. The script always exits with 0, so the ISO itself is the proof.
    $made = Join-Path $tool 'tiny11.iso'
    if (-not (Test-Path -LiteralPath $made) -or (Get-Item -LiteralPath $made).Length -lt 1GB) {
        $logFile = @(Get-ChildItem -LiteralPath $tool -Filter 'tiny11_*.log' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending) | Select-Object -First 1
        $hint = if ($logFile) { " Its log is here: $($logFile.FullName)" } else { '' }
        throw "tiny11builder did not produce tiny11.iso.$hint"
    }
    $outDir = Split-Path -Parent $OutIso
    if (-not (Test-Path -LiteralPath $outDir)) { [void](New-Item -ItemType Directory -Path $outDir -Force) }
    if (Test-Path -LiteralPath $OutIso) { Remove-Item -LiteralPath $OutIso -Force }
    Move-Item -LiteralPath $made -Destination $OutIso -Force
    if ($Log) { & $Log ('tiny11 is ready: {0} ({1:N1} GB). It is kept for the next stick.' -f $OutIso, ((Get-Item -LiteralPath $OutIso).Length / 1GB)) }
    Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    return $OutIso
}

Export-ModuleMember -Function @(
    'Get-DzTiny11Source', 'Get-DzTiny11Summary', 'Test-DzFileSha256', 'Save-DzTiny11Script', 'Get-DzFreeDriveLetter',
    'Select-DzEditionIndex', 'Get-DzTiny11IsoName', 'Test-DzTiny11Choice', 'Invoke-DzConsoleScript', 'New-DzTiny11Iso'
)
