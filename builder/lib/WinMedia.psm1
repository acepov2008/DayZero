#Requires -Version 5.1
<#
    DayZero builder - makes the Windows installation USB stick itself, so no Media Creation
    Tool or Rufus is needed.

    Where Windows comes from (both are Microsoft's own, untouched files):
      * Download: the same catalogue the Media Creation Tool reads (products.cab, fetched over
        HTTPS from microsoft.com). It lists one .esd per language with its size and SHA-1.
        The .esd is downloaded from dl.delivery.mp.microsoft.com, checked against that size
        and SHA-1, and unpacked with DISM into a normal install-media folder. That folder is
        kept in %LOCALAPPDATA%\DayZero\media and reused for the next stick.
      * ISO: an ISO file you already have is mounted and copied.

    What it does to the USB stick: ERASES it (diskpart clean), creates one FAT32 partition
    (up to 32 GB, so it boots on UEFI and legacy BIOS) and copies Windows on. This happens
    only on the disk you picked and confirmed, and only if Test-DzUsbDiskAllowed agrees:
    USB bus, not the system or boot disk, 7.5 - 300 GB. Internal disks are always refused.

    This has nothing to do with the answer file: autounattend.xml still never selects,
    wipes or partitions a disk on the new PC.
#>

Set-StrictMode -Version 2.0

$script:CatalogLinks = @{
    10 = 'https://go.microsoft.com/fwlink/?LinkId=841361'
    11 = 'https://go.microsoft.com/fwlink/?LinkId=2156292'
}
$script:MinUsbBytes = 7500000000
$script:MaxUsbBytes = 300000000000
$script:Fat32MaxFile = 4294967295
$script:UsbLabel = 'DAYZERO'
$script:Languages = @(
    'ar-SA', 'bg-BG', 'cs-CZ', 'da-DK', 'de-DE', 'el-GR', 'en-GB', 'en-US', 'es-ES', 'es-MX', 'et-EE', 'fi-FI', 'fr-CA',
    'fr-FR', 'he-IL', 'hr-HR', 'hu-HU', 'it-IT', 'ja-JP', 'ko-KR', 'lt-LT', 'lv-LV', 'nb-NO', 'nl-NL', 'pl-PL', 'pt-BR',
    'pt-PT', 'ro-RO', 'ru-RU', 'sk-SK', 'sl-SI', 'sr-Latn-RS', 'sv-SE', 'th-TH', 'tr-TR', 'uk-UA', 'zh-CN', 'zh-TW'
)

# ------------------------------------------------------------------------------------
# Small helpers
# ------------------------------------------------------------------------------------

function Get-DzWindowsLanguageList {
    <# The languages Microsoft publishes Windows 10/11 consumer media in. #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    return $script:Languages
}

function Get-DzWindowsCatalogUrl {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][ValidateSet(10, 11)][int]$WindowsVersion)
    return $script:CatalogLinks[$WindowsVersion]
}

function Get-DzMediaCacheRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $base = $env:LOCALAPPDATA
    if (-not $base) { $base = [System.IO.Path]::GetTempPath() }
    return (Join-Path (Join-Path $base 'DayZero') 'media')
}

function Invoke-DzTick {
    <# Calls the GUI's status callback (if any) so the window keeps repainting. #>
    [CmdletBinding()]
    param([AllowNull()][scriptblock]$Tick, [string]$Text)
    if ($Tick) { & $Tick $Text }
}

function Get-DzBuildProgress {
    <#
        Overall progress (0-100) of making the stick, worked out from a status line such as
        "Unpacking Windows 11 Pro (4 of 4; this is the slow part) (35.0%)". $null when the
        line belongs to no known stage. Stages that are skipped (Windows already prepared)
        simply make the bar jump ahead.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $part = [double]0
    $m = [regex]::Match($Text, '\((\d{1,3}(?:[.,]\d)?)\s?%\)\s*$')
    if ($m.Success) {
        $part = [double]::Parse($m.Groups[1].Value.Replace(',', '.'), [System.Globalization.CultureInfo]::InvariantCulture) / 100
        if ($part -gt 1) { $part = 1 }
    }
    $from = $null
    $to = $null
    switch -Regex ($Text) {
        '^Asking Microsoft' { $from = 0; $to = 1; break }
        '^Downloading Windows' { $from = 1; $to = 30; break }
        '^Checking the download' { $from = 30; $to = 34; break }
        '^Unpacking the Windows setup files' { $from = 34; $to = 36; break }
        '^Unpacking Windows PE' { $from = 36; $to = 39; break }
        '^Unpacking Windows Setup' { $from = 39; $to = 42; break }
        '^Unpacking .*\((\d+) of (\d+);' {
            $n = [double]$Matches[1]
            $count = [double]$Matches[2]
            if ($count -lt 1) { $count = 1 }
            $part = (($n - 1) + $part) / $count
            $from = 42; $to = 68; break
        }
        '^Splitting the Windows image' { $from = 68; $to = 69; break }
        '^Preparing the Windows files for tiny11' { $from = 69; $to = 70; break }
        '^Preparing Windows 11 (Home|Pro) for tiny11' { $from = 70; $to = 71; break }
        '^tiny11builder is working in its own window \((\d+) min\)' {
            # No real progress from the other window: move slowly towards the end of its usual hour.
            $part = [double]$Matches[1] / 60
            $from = 71; $to = 74; break
        }
        '^(Erasing and formatting|Waiting for the new drive)' { $from = 75; $to = 75; break }
        '^Copying Windows to the USB stick' { $from = 76; $to = 96; break }
        '^Adding the answer file' { $from = 97; $to = 97; break }
    }
    if ($null -eq $from) { return $null }
    if ($part -lt 0) { $part = 0 }
    if ($part -gt 1) { $part = 1 }
    return [double]($from + ($to - $from) * $part)
}

function Invoke-DzProcess {
    <#
        Runs a console program hidden, waits for it and returns ExitCode + Output.
        While it runs, $Tick gets "$Activity (NN.N%)" whenever the program prints a percentage
        (DISM does), so the GUI can show progress.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string]$Arguments = '',
        [string]$Activity = '',
        [scriptblock]$Tick,
        [scriptblock]$OnLine
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$p.Start()
    try {
        $errTask = $p.StandardError.ReadToEndAsync()
        $lineTask = $p.StandardOutput.ReadLineAsync()
        $percent = ''
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        while ($true) {
            $ready = $lineTask.IsCompleted
            if ($ready) {
                $line = $lineTask.Result
                if ($null -eq $line) { break }
                if ($line.Trim()) {
                    if ($OnLine) { & $OnLine $line }
                    $m = [regex]::Match($line, '(\d{1,3}(?:[.,]\d)?)\s?%')
                    if ($m.Success) { $percent = $m.Groups[1].Value } else { $lines.Add($line.Trim()) }
                }
                $lineTask = $p.StandardOutput.ReadLineAsync()
            }
            # Tick at least every 200 ms, also while the program prints without a pause
            # (robocopy does), so the window never stops responding.
            if (-not $ready -or $clock.ElapsedMilliseconds -ge 200) {
                $text = if ($percent) { '{0} ({1}%)' -f $Activity, $percent } else { $Activity }
                Invoke-DzTick -Tick $Tick -Text $text
                $clock.Restart()
            }
            if (-not $ready) { Start-Sleep -Milliseconds 200 }
        }
        $p.WaitForExit()
        $err = [string]$errTask.Result
        if ($err.Trim()) { $lines.Add($err.Trim()) }
        return [pscustomobject]@{ ExitCode = $p.ExitCode; Output = ($lines -join [Environment]::NewLine) }
    }
    finally {
        $p.Dispose()
    }
}

function Invoke-DzDism {
    <# Runs dism.exe and throws with its last lines when it fails. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Arguments,
        [Parameter(Mandatory = $true)][string]$Activity,
        [scriptblock]$Tick
    )
    $dism = Join-Path $env:SystemRoot 'System32\dism.exe'
    $r = Invoke-DzProcess -FilePath $dism -Arguments ($Arguments + ' /English') -Activity $Activity -Tick $Tick
    if ($r.ExitCode -ne 0) {
        $tail = (@($r.Output -split "`r?`n") | Select-Object -Last 4) -join ' '
        throw "$Activity failed (DISM exit code $($r.ExitCode)): $tail"
    }
}

# ------------------------------------------------------------------------------------
# Microsoft's download catalogue
# ------------------------------------------------------------------------------------

function ConvertFrom-DzProductsXml {
    <# Turns the text of products.xml into one object per downloadable file. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Xml)
    $doc = New-Object System.Xml.XmlDocument
    $doc.XmlResolver = $null
    $doc.LoadXml($Xml)
    foreach ($f in @($doc.SelectNodes('//Files/File'))) {
        $size = [int64]0
        [void][int64]::TryParse([string]$f.Size, [ref]$size)
        [pscustomobject]@{
            FileName     = [string]$f.FileName
            Language     = [string]$f.LanguageCode
            Edition      = [string]$f.Edition
            Architecture = [string]$f.Architecture
            Size         = $size
            Sha1         = ([string]$f.Sha1).ToLowerInvariant()
            Url          = [string]$f.FilePath
        }
    }
}

function Test-DzWindowsDownloadEntry {
    <# Problem text when a catalogue entry is not safe to use; $null when it is fine. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][object]$Entry)
    $uri = $null
    if (-not [System.Uri]::TryCreate([string]$Entry.Url, [System.UriKind]::Absolute, [ref]$uri)) { return 'The catalogue entry has no valid download address.' }
    if ($uri.Scheme -ne 'http' -and $uri.Scheme -ne 'https') { return 'The download address is not http(s).' }
    if ($uri.Host -notmatch '(^|\.)microsoft\.com$') { return "The download address is not on microsoft.com: $($uri.Host)" }
    if ([string]$Entry.Sha1 -notmatch '^[0-9a-f]{40}$') { return 'The catalogue entry has no SHA-1 checksum.' }
    if ([int64]$Entry.Size -lt 1000000000) { return 'The catalogue entry has an implausible size.' }
    if ([string]$Entry.FileName -notmatch '^[A-Za-z0-9._-]+\.esd$') { return 'The catalogue entry has an unexpected file name.' }
    return $null
}

function Select-DzWindowsDownload {
    <#
        Picks the consumer (Home / Pro / Education) image for a language. Every edition of
        that image is listed separately but points at the same file, so one entry is enough.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Entries,
        [Parameter(Mandatory = $true)][string]$Language,
        [ValidateSet('x64', 'ARM64')][string]$Architecture = 'x64'
    )
    $match = @($Entries | Where-Object {
            $_.Language -ieq $Language -and $_.Architecture -ieq $Architecture -and $_.FileName -match 'CLIENTCONSUMER_RET'
        })
    if ($match.Count -eq 0) { return $null }
    $pick = @($match | Where-Object { $_.Edition -eq 'Professional' }) + $match | Select-Object -First 1
    $problem = Test-DzWindowsDownloadEntry -Entry $pick
    if ($problem) { throw $problem }
    return $pick
}

function Find-DzCatalogXml {
    <# The unpacked catalogue in a folder: products.xml, or any file that starts like its XML. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Folder)
    $files = @(Get-ChildItem -LiteralPath $Folder -File -ErrorAction SilentlyContinue | Sort-Object { $_.Name -ne 'products.xml' }, Name)
    foreach ($f in $files) {
        if ($f.Length -lt 1000) { continue }
        $head = ''
        try {
            $reader = New-Object System.IO.StreamReader($f.FullName)
            try { $buffer = New-Object char[] 200; $n = $reader.Read($buffer, 0, 200); $head = New-Object string ($buffer, 0, $n) } finally { $reader.Dispose() }
        }
        catch { $head = '' }
        if ($head -match '<MCT>|<Catalogs>') { return $f.FullName }
    }
    return $null
}

function Get-DzWindowsCatalog {
    <# Downloads and unpacks Microsoft's catalogue for Windows 10 or 11. Returns the entries. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet(10, 11)][int]$WindowsVersion,
        [Parameter(Mandatory = $true)][string]$WorkDir
    )
    try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12 }
    catch { Write-Verbose 'Could not change the TLS setting.' }
    if (-not (Test-Path -LiteralPath $WorkDir)) { [void](New-Item -ItemType Directory -Path $WorkDir -Force) }
    $cab = Join-Path $WorkDir "products-win$WindowsVersion.cab"
    # Unpack into its own empty folder: expand.exe names the output after the .cab when the
    # cabinet holds one file, and then refuses to "expand the file onto itself".
    $outDir = Join-Path $WorkDir "win$WindowsVersion"
    $xml = Join-Path $outDir 'products.xml'
    if (Test-Path -LiteralPath $cab) { Remove-Item -LiteralPath $cab -Force }
    if (Test-Path -LiteralPath $outDir) { Remove-Item -LiteralPath $outDir -Recurse -Force }
    [void](New-Item -ItemType Directory -Path $outDir -Force)
    $wc = New-Object System.Net.WebClient
    try { $wc.DownloadFile((Get-DzWindowsCatalogUrl -WindowsVersion $WindowsVersion), $cab) } finally { $wc.Dispose() }
    $expand = Join-Path $env:SystemRoot 'System32\expand.exe'
    $output = ''
    # expand.exe behaves differently for one-file cabinets between Windows versions, so try
    # both spellings and accept whatever XML file comes out.
    foreach ($arguments in @(('"{0}" -F:products.xml "{1}"' -f $cab, $outDir), ('"{0}" "{1}"' -f $cab, $xml))) {
        $r = Invoke-DzProcess -FilePath $expand -Arguments $arguments
        $output = $r.Output
        $found = Find-DzCatalogXml -Folder $outDir
        if ($found) { $xml = $found; break }
    }
    if (-not (Find-DzCatalogXml -Folder $outDir)) { throw "Could not unpack Microsoft's download catalogue: $output" }
    $entries = @(ConvertFrom-DzProductsXml -Xml (Get-Content -LiteralPath $xml -Raw -Encoding UTF8))
    if ($entries.Count -eq 0) { throw "Microsoft's download catalogue is empty." }
    return $entries
}

function Get-DzFileSha1 {
    <# SHA-1 of a (large) file as lowercase hex, calling $Tick while it reads. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Path, [scriptblock]$Tick, [string]$Activity = 'Checking the download')
    $sha = [System.Security.Cryptography.SHA1]::Create()
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $buffer = New-Object byte[] (4MB)
        # No [math]::Max here: PowerShell 5.1 picks the Int32 overload and fails on files over 2 GB.
        $total = [double]$stream.Length
        if ($total -lt 1) { $total = 1 }
        $done = [int64]0
        $next = [int64]0
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            [void]$sha.TransformBlock($buffer, 0, $read, $null, 0)
            $done += $read
            if ($done -ge $next) {
                Invoke-DzTick -Tick $Tick -Text ('{0} ({1:N0}%)' -f $Activity, (100 * $done / $total))
                $next = $done + 32MB
            }
        }
        [void]$sha.TransformFinalBlock($buffer, 0, 0)
        return (($sha.Hash | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally {
        $stream.Dispose()
        $sha.Dispose()
    }
}

function Save-DzLargeFile {
    <# Downloads a multi-gigabyte file with BITS (it retries by itself when the connection drops). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Activity = 'Downloading',
        [scriptblock]$Tick
    )
    Import-Module BitsTransfer -ErrorAction Stop
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    $job = Start-BitsTransfer -Source $Url -Destination $Path -Asynchronous -Priority Foreground -DisplayName 'DayZero Windows download'
    $finished = $false
    try {
        $stalled = 0
        while (@('Queued', 'Connecting', 'Transferring', 'TransientError') -contains [string]$job.JobState) {
            if ([string]$job.JobState -eq 'TransientError') { $stalled++ } else { $stalled = 0 }
            if ($stalled -gt 600) { throw 'The download keeps failing. Check the internet connection and try again.' }
            $total = [double]$job.BytesTotal
            $text = if ($total -gt 0 -and $total -lt 1e15) {
                '{0}: {1:N1} of {2:N1} GB ({3:N0}%)' -f $Activity, ($job.BytesTransferred / 1GB), ($total / 1GB), (100 * $job.BytesTransferred / $total)
            }
            else { "$Activity ..." }
            Invoke-DzTick -Tick $Tick -Text $text
            Start-Sleep -Milliseconds 500
        }
        if ([string]$job.JobState -ne 'Transferred') { throw "The download failed: $($job.ErrorDescription)" }
        Complete-BitsTransfer -BitsJob $job
        $finished = $true
    }
    finally {
        if (-not $finished) { try { Remove-BitsTransfer -BitsJob $job -ErrorAction Stop } catch { Write-Verbose 'The BITS job was already gone.' } }
    }
    return $Path
}

# ------------------------------------------------------------------------------------
# From Microsoft's .esd to a normal install-media folder
# ------------------------------------------------------------------------------------

function Get-DzEsdImagePlan {
    <#
        Sorts the images inside a Microsoft .esd into: the setup media files, Windows PE,
        Windows Setup, and the Windows editions. Throws when the file is not laid out that way.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Images)
    $media = @($Images | Where-Object { [string]$_.Name -match 'Setup Media' }) | Select-Object -First 1
    $pe = @($Images | Where-Object { [string]$_.Name -match 'Windows PE' }) | Select-Object -First 1
    $setup = @($Images | Where-Object { [string]$_.Name -match 'Windows Setup \(' }) | Select-Object -First 1
    $editions = @($Images | Where-Object { [string]$_.Name -match '^Windows 1[01] ' } | Sort-Object { [int]$_.Index })
    if (-not $media -or -not $pe -or -not $setup -or $editions.Count -eq 0) {
        throw 'This download does not look like Microsoft installation media (setup files, Windows PE, Windows Setup and editions are expected).'
    }
    return [pscustomobject]@{
        SetupMedia = [int]$media.Index
        WinPE      = [int]$pe.Index
        Setup      = [int]$setup.Index
        Editions   = $editions
    }
}

function Select-DzEsdEdition {
    <#
        Which editions go on the stick. 'standard': everything except the N editions (for
        markets without media player). 'small': Home, Home Single Language and Pro only,
        used when 'standard' would not fit FAT32's 4 GB file limit.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Editions,
        [ValidateSet('standard', 'small')][string]$Tier = 'standard'
    )
    if ($Tier -eq 'small') {
        return @($Editions | Where-Object { [string]$_.Name -match '^Windows 1[01] (Home|Home Single Language|Pro)$' })
    }
    return @($Editions | Where-Object { [string]$_.Name -notmatch ' N$' })
}

function New-DzMediaFromEsd {
    <#
        Unpacks a Microsoft .esd into $OutDir so it looks like the contents of a Windows ISO:
        setup files, sources\boot.wim and sources\install.wim (or install.swm parts). Uses only DISM.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$EsdPath,
        [Parameter(Mandatory = $true)][string]$OutDir,
        [scriptblock]$Tick,
        [scriptblock]$Log
    )
    $images = @(Get-WindowsImage -ImagePath $EsdPath -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Index = $_.ImageIndex; Name = $_.ImageName } })
    $plan = Get-DzEsdImagePlan -Images $images
    if (Test-Path -LiteralPath $OutDir) { Remove-Item -LiteralPath $OutDir -Recurse -Force }
    [void](New-Item -ItemType Directory -Path $OutDir -Force)

    Invoke-DzDism -Tick $Tick -Activity 'Unpacking the Windows setup files' -Arguments ('/Apply-Image /ImageFile:"{0}" /Index:{1} /ApplyDir:"{2}"' -f $EsdPath, $plan.SetupMedia, $OutDir)
    $sources = Join-Path $OutDir 'sources'
    if (-not (Test-Path -LiteralPath $sources)) { throw 'The setup files have no sources folder.' }
    $boot = Join-Path $sources 'boot.wim'
    Invoke-DzDism -Tick $Tick -Activity 'Unpacking Windows PE' -Arguments ('/Export-Image /SourceImageFile:"{0}" /SourceIndex:{1} /DestinationImageFile:"{2}" /Compress:max /CheckIntegrity' -f $EsdPath, $plan.WinPE, $boot)
    Invoke-DzDism -Tick $Tick -Activity 'Unpacking Windows Setup' -Arguments ('/Export-Image /SourceImageFile:"{0}" /SourceIndex:{1} /DestinationImageFile:"{2}" /Compress:max /CheckIntegrity /Bootable' -f $EsdPath, $plan.Setup, $boot)

    # The editions go into install.wim. Microsoft's current images are larger than the 4 GB a
    # FAT32 stick allows per file (even as .esd with only Home and Pro), so a big install.wim
    # is split into install.swm parts, which Windows Setup reads natively.
    $install = Join-Path $sources 'install.wim'
    $editions = @(Select-DzEsdEdition -Editions $plan.Editions -Tier standard)
    if ($editions.Count -eq 0) { throw 'The download contains no Windows editions.' }
    $n = 0
    foreach ($e in $editions) {
        $n++
        Invoke-DzDism -Tick $Tick -Activity ('Unpacking {0} ({1} of {2}; this is the slow part)' -f $e.Name, $n, $editions.Count) -Arguments ('/Export-Image /SourceImageFile:"{0}" /SourceIndex:{1} /DestinationImageFile:"{2}" /Compress:max /CheckIntegrity' -f $EsdPath, $e.Index, $install)
    }
    $size = (Get-Item -LiteralPath $install).Length
    $names = ($editions | ForEach-Object { $_.Name -replace '^Windows 1[01] ', '' }) -join ', '
    if ($size -gt $script:Fat32MaxFile) {
        $swm = Join-Path $sources 'install.swm'
        Invoke-DzDism -Tick $Tick -Activity 'Splitting the Windows image for the USB stick' -Arguments ('/Split-Image /ImageFile:"{0}" /SWMFile:"{1}" /FileSize:3800' -f $install, $swm)
        if (-not (Test-Path -LiteralPath $swm)) { throw 'Splitting the Windows image produced no install.swm.' }
        Remove-Item -LiteralPath $install -Force
        if ($Log) { & $Log ('Editions on the stick: {0} ({1:N1} GB, split into install.swm parts).' -f $names, ($size / 1GB)) }
    }
    elseif ($Log) { & $Log ('Editions on the stick: {0} (install.wim is {1:N1} GB).' -f $names, ($size / 1GB)) }
    return $OutDir
}

function Get-DzPreparedMedia {
    <# The newest ready-to-copy Windows folder in the cache for this version and language, or $null. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$WindowsVersion,
        [Parameter(Mandatory = $true)][string]$Language,
        [string]$CacheRoot = (Get-DzMediaCacheRoot),
        [string]$Sha1
    )
    if (-not (Test-Path -LiteralPath $CacheRoot)) { return $null }
    $prefix = ('win{0}-{1}-x64-' -f $WindowsVersion, $Language.ToLowerInvariant())
    $filter = if ($Sha1) { $prefix + $Sha1.Substring(0, 10) + '.ready.json' } else { $prefix + '*.ready.json' }
    foreach ($marker in @(Get-ChildItem -LiteralPath $CacheRoot -Filter $filter -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
        $dir = Join-Path $CacheRoot ($marker.Name -replace '\.ready\.json$', '')
        if (Find-DzInstallImage -Root $dir) {
            $info = $null
            try { $info = Get-Content -LiteralPath $marker.FullName -Raw | ConvertFrom-Json } catch { Write-Verbose 'Unreadable cache marker.' }
            return [pscustomobject]@{ Path = $dir; Marker = $marker.FullName; Info = $info }
        }
    }
    return $null
}

function Get-DzMediaCacheItem {
    <#
        What the builder keeps in its Windows cache: every prepared Windows (Kind 'windows'),
        plus leftovers of a download or unpack that did not finish (Kind 'leftover').
        Each item: Kind, Name, WindowsVersion, Language, Bytes, SizeGB, Prepared, Display.
    #>
    [CmdletBinding()]
    param([string]$CacheRoot = (Get-DzMediaCacheRoot))
    if (-not (Test-Path -LiteralPath $CacheRoot)) { return }
    $pattern = '^win(\d+)-([a-z0-9-]+)-x64-[0-9a-f]{10}$'
    foreach ($entry in @(Get-ChildItem -LiteralPath $CacheRoot -Force -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $tiny = [regex]::Match($entry.Name, '^tiny11-win11-([a-z0-9-]+)-(home|pro)-[0-9a-f]{10}-[0-9a-f]{8}\.iso$')
        if ($tiny.Success -or $entry.Name -eq 'tiny11-work') {
            $isWork = -not $tiny.Success
            $bytes = if ($entry.PSIsContainer) { Get-DzFolderSize -Path $entry.FullName } else { [double]$entry.Length }
            $sizeGB = [math]::Round($bytes / 1GB, 1)
            $what = if ($isWork) { 'Unfinished tiny11 build' } else { 'tiny11 (Windows 11 {0}), {1}' -f $(if ($tiny.Groups[2].Value -eq 'home') { 'Home' } else { 'Pro' }), $tiny.Groups[1].Value }
            [pscustomobject]@{
                Kind           = $(if ($isWork) { 'leftover' } else { 'windows' })
                Name           = $entry.Name
                WindowsVersion = 11
                Language       = $(if ($isWork) { '' } else { $tiny.Groups[1].Value })
                Bytes          = $bytes
                SizeGB         = $sizeGB
                Prepared       = $entry.LastWriteTime
                Display        = ('{0} - {1:N1} GB' -f $what, $sizeGB)
            }
            continue
        }
        $base = $entry.Name -replace '\.esd$', ''
        if ($entry.Name -like '*.ready.json' -or $base -notmatch $pattern) { continue }
        $version = [int]$Matches[1]
        $language = [string]$Matches[2]
        $isFolder = [bool]$entry.PSIsContainer
        $ready = $isFolder -and (Test-Path -LiteralPath (Join-Path $CacheRoot ($entry.Name + '.ready.json'))) -and [bool](Find-DzInstallImage -Root $entry.FullName)
        $bytes = if ($isFolder) { Get-DzFolderSize -Path $entry.FullName } else { [double]$entry.Length }
        $kind = if ($ready) { 'windows' } else { 'leftover' }
        $sizeGB = [math]::Round($bytes / 1GB, 1)
        $what = if ($ready) { 'Windows {0}, {1}' -f $version, $language }
        elseif ($isFolder) { 'Unfinished unpack of Windows {0}, {1}' -f $version, $language }
        else { 'Unfinished download of Windows {0}, {1}' -f $version, $language }
        [pscustomobject]@{
            Kind           = $kind
            Name           = $entry.Name
            WindowsVersion = $version
            Language       = $language
            Bytes          = $bytes
            SizeGB         = $sizeGB
            Prepared       = $entry.LastWriteTime
            Display        = ('{0} - {1:N1} GB' -f $what, $sizeGB)
        }
    }
}

function Remove-DzMediaCacheItem {
    <#
        Deletes one cache item (its folder or file, and its ready marker). Only names that
        Get-DzMediaCacheItem can return are accepted, so nothing outside the cache is touched.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$CacheRoot = (Get-DzMediaCacheRoot)
    )
    $known = '^win\d+-[a-z0-9-]+-x64-[0-9a-f]{10}(\.esd)?$|^tiny11-win11-[a-z0-9-]+-(home|pro)-[0-9a-f]{10}-[0-9a-f]{8}\.iso$|^tiny11-work$'
    if ($Name -notmatch $known) { throw "Not a DayZero cache item: $Name" }
    $base = $Name -replace '\.esd$', ''
    foreach ($leaf in @(($base + '.ready.json'), $Name)) {
        $path = Join-Path $CacheRoot $leaf
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
    }
}

function Get-DzWindowsMediaTree {
    <#
    .SYNOPSIS
        Returns a folder with complete Windows installation media for the version and
        language, downloading and unpacking it the first time and reusing it afterwards.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet(10, 11)][int]$WindowsVersion,
        [Parameter(Mandatory = $true)][string]$Language,
        [string]$CacheRoot = (Get-DzMediaCacheRoot),
        [scriptblock]$Tick,
        [scriptblock]$Log
    )
    if (-not (Test-Path -LiteralPath $CacheRoot)) { [void](New-Item -ItemType Directory -Path $CacheRoot -Force) }
    $entry = $null
    try {
        Invoke-DzTick -Tick $Tick -Text "Asking Microsoft for the current Windows $WindowsVersion download..."
        $entries = Get-DzWindowsCatalog -WindowsVersion $WindowsVersion -WorkDir (Join-Path $CacheRoot 'catalog')
        $entry = Select-DzWindowsDownload -Entries $entries -Language $Language
    }
    catch {
        $cached = Get-DzPreparedMedia -WindowsVersion $WindowsVersion -Language $Language -CacheRoot $CacheRoot
        if ($cached) {
            if ($Log) { & $Log "Could not reach Microsoft's catalogue ($($_.Exception.Message)); using the copy of Windows $WindowsVersion from last time." }
            return $cached.Path
        }
        throw "Could not get Microsoft's Windows $WindowsVersion download list: $($_.Exception.Message)"
    }
    if ($null -eq $entry) { throw "Microsoft does not offer Windows $WindowsVersion in $Language. Pick another display language." }

    $cached = Get-DzPreparedMedia -WindowsVersion $WindowsVersion -Language $Language -CacheRoot $CacheRoot -Sha1 $entry.Sha1
    if ($cached) {
        if ($Log) { & $Log "Using the Windows $WindowsVersion ($Language) files prepared earlier: $($cached.Path)" }
        return $cached.Path
    }

    $name = ('win{0}-{1}-x64-{2}' -f $WindowsVersion, $Language.ToLowerInvariant(), $entry.Sha1.Substring(0, 10))
    $dir = Join-Path $CacheRoot $name
    $esd = Join-Path $CacheRoot ($name + '.esd')
    $need = [int64]($entry.Size * 4)
    $drive = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID = '{0}'" -f ([System.IO.Path]::GetPathRoot($CacheRoot).TrimEnd('\'))) -ErrorAction SilentlyContinue
    if ($drive -and [int64]$drive.FreeSpace -lt $need) {
        throw ('Not enough free space on {0} to prepare Windows: {1:N0} GB needed, {2:N0} GB free.' -f $drive.DeviceID, ($need / 1GB), ($drive.FreeSpace / 1GB))
    }

    $haveEsd = (Test-Path -LiteralPath $esd) -and ((Get-Item -LiteralPath $esd).Length -eq $entry.Size)
    if (-not $haveEsd) {
        if ($Log) { & $Log ('Downloading {0} ({1:N1} GB) from {2}' -f $entry.FileName, ($entry.Size / 1GB), ([System.Uri]$entry.Url).Host) }
        [void](Save-DzLargeFile -Url $entry.Url -Path $esd -Activity "Downloading Windows $WindowsVersion from Microsoft" -Tick $Tick)
    }
    if ((Get-Item -LiteralPath $esd).Length -ne $entry.Size) {
        Remove-Item -LiteralPath $esd -Force
        throw 'The downloaded file has the wrong size. Try again.'
    }
    $sha = Get-DzFileSha1 -Path $esd -Tick $Tick
    if ($sha -ne $entry.Sha1) {
        Remove-Item -LiteralPath $esd -Force
        throw "The downloaded file does not match Microsoft's checksum, so it was deleted. Try again."
    }
    if ($Log) { & $Log "Download checked: SHA-1 $sha matches Microsoft's catalogue." }

    [void](New-DzMediaFromEsd -EsdPath $esd -OutDir $dir -Tick $Tick -Log $Log)

    # Mark the folder as complete, then drop the big download and older copies of this Windows.
    $marker = Join-Path $CacheRoot ($name + '.ready.json')
    $info = [ordered]@{ windowsVersion = $WindowsVersion; language = $Language; fileName = $entry.FileName; sha1 = $entry.Sha1; preparedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
    [System.IO.File]::WriteAllText($marker, ($info | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    Remove-Item -LiteralPath $esd -Force
    $prefix = ('win{0}-{1}-x64-' -f $WindowsVersion, $Language.ToLowerInvariant())
    foreach ($old in @(Get-ChildItem -LiteralPath $CacheRoot -Force | Where-Object { $_.Name.StartsWith($prefix) -and -not $_.Name.StartsWith($name) })) {
        Remove-Item -LiteralPath $old.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($Log) { & $Log "Windows $WindowsVersion ($Language) is ready in $dir and will be reused next time." }
    return $dir
}

# ------------------------------------------------------------------------------------
# The USB stick
# ------------------------------------------------------------------------------------

function Test-DzUsbDiskAllowed {
    <#
        Problem text when a disk must not be erased; $null when it may be.
        Disk needs: BusType, IsSystem, IsBoot, IsReadOnly, Size, Letters (drive letters on it).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][object]$Disk)
    if ([string]$Disk.BusType -ne 'USB') { return 'It is not a USB drive.' }
    if ($Disk.IsSystem -or $Disk.IsBoot) { return 'Windows is running from it.' }
    $system = if ($env:SystemDrive) { $env:SystemDrive.Substring(0, 1) } else { '' }
    foreach ($l in @($Disk.Letters)) { if ($system -and ([string]$l) -ieq $system) { return 'It holds the drive Windows is running from.' } }
    if ($Disk.IsReadOnly) { return 'It is write-protected.' }
    $size = [int64]$Disk.Size
    if ($size -lt $script:MinUsbBytes) { return 'It is smaller than 8 GB.' }
    if ($size -gt $script:MaxUsbBytes) { return 'It is larger than 300 GB, so it looks like an external hard drive, not a USB stick.' }
    return $null
}

function Get-DzUsbDiskCandidate {
    <# Every USB disk, with what is on it and (in Problem) why it may not be used. #>
    [CmdletBinding()]
    param()
    foreach ($d in @(Get-Disk -ErrorAction SilentlyContinue | Where-Object { [string]$_.BusType -eq 'USB' } | Sort-Object Number)) {
        $letters = New-Object System.Collections.Generic.List[string]
        $volumes = New-Object System.Collections.Generic.List[string]
        foreach ($p in @(Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue)) {
            if (-not $p.DriveLetter -or [int][char]$p.DriveLetter -eq 0) { continue }
            $letter = [string]$p.DriveLetter
            $letters.Add($letter)
            $label = ''
            try { $label = [string](Get-Volume -DriveLetter $letter -ErrorAction Stop).FileSystemLabel } catch { $label = '' }
            $volumes.Add($(if ($label) { "${letter}: ($label)" } else { "${letter}:" }))
        }
        $item = [pscustomobject]@{
            Number     = [int]$d.Number
            Name       = ([string]$d.FriendlyName).Trim()
            Serial     = ([string]$d.SerialNumber).Trim()
            BusType    = [string]$d.BusType
            IsSystem   = [bool]$d.IsSystem
            IsBoot     = [bool]$d.IsBoot
            IsReadOnly = [bool]$d.IsReadOnly
            Size       = [int64]$d.Size
            SizeGB     = [math]::Round(([double]$d.Size) / 1GB, 1)
            Letters    = $letters.ToArray()
            Volumes    = ($volumes -join ', ')
            Problem    = $null
            Display    = $null
        }
        $item.Problem = Test-DzUsbDiskAllowed -Disk $item
        $what = if ($item.Volumes) { $item.Volumes } else { 'no drive letter' }
        $item.Display = ('{0}  - {1} GB, {2}' -f $item.Name, $item.SizeGB, $what)
        $item
    }
}

function New-DzDiskpartScript {
    <# The diskpart commands that erase one disk and leave a single active FAT32 partition. #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][ValidateRange(0, 99)][int]$DiskNumber,
        [Parameter(Mandatory = $true)][ValidateRange(7000, 32000)][int]$PartitionMB,
        [ValidatePattern('^[A-Z0-9]{1,11}$')][string]$Label = 'DAYZERO'
    )
    # No "remove ... dismount" before "clean": on a removable stick that works like Eject, and
    # the stick then answers "The device is not ready" until it is unplugged and plugged in again.
    $lines = @(
        "select disk $DiskNumber",
        'clean',
        'convert mbr noerr',
        "create partition primary size=$PartitionMB",
        'select partition 1',
        'active',
        "format fs=fat32 quick label=$Label",
        'assign',
        'exit'
    )
    return (($lines -join "`r`n") + "`r`n")
}

function Get-DzUsbPartitionSize {
    <# Partition size in MB: the whole stick, but no more than FAT32's practical 32 GB. #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory = $true)][int64]$DiskBytes)
    $mb = [math]::Floor(([double]$DiskBytes) / 1MB) - 64
    if ($mb -gt 32000) { $mb = 32000 }
    return [int]$mb
}

function Get-DzMediaFitProblem {
    <# Problem text when Windows (plus room for the toolkit) does not fit the stick; $null when it does. #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][double]$MediaBytes,
        [Parameter(Mandatory = $true)][int64]$DiskBytes
    )
    $room = ([double](Get-DzUsbPartitionSize -DiskBytes $DiskBytes)) * 1MB
    $need = $MediaBytes + 400MB
    if ($need -gt $room) {
        return ('This Windows needs {0:N1} GB on the stick, but the stick only holds {1:N1} GB. Use a 16 GB (or larger) stick.' -f ($need / 1GB), ($room / 1GB))
    }
    return $null
}

function Get-DzFolderSize {
    [CmdletBinding()]
    [OutputType([double])]
    param([Parameter(Mandatory = $true)][string]$Path)
    $total = [double]0
    foreach ($f in @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue)) { $total += $f.Length }
    return $total
}

function Stop-DzStaleCopy {
    <#
        Ends robocopy processes that are still copying onto the given drive letters, left over
        from an earlier attempt that was interrupted. They would keep the stick locked.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][string[]]$Letter = @(), [scriptblock]$Log)
    foreach ($l in $Letter) {
        if ($l -notmatch '^[A-Za-z]$') { continue }
        $pattern = '(?i)\s"?' + $l + ':\\'
        foreach ($proc in @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'robocopy.exe'" -ErrorAction SilentlyContinue)) {
            if ([string]$proc.CommandLine -notmatch $pattern) { continue }
            try {
                Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
                if ($Log) { & $Log "Stopped a copy to ${l}: left over from an earlier attempt." }
            }
            catch { if ($Log) { & $Log "Could not stop the earlier copy to ${l}: $($_.Exception.Message)" } }
        }
    }
}

function Initialize-DzUsbDisk {
    <#
    .SYNOPSIS
        ERASES the given USB disk and formats it FAT32. Returns the new drive root ('E:\').
    .DESCRIPTION
        $Disk is an item from Get-DzUsbDiskCandidate. Right before erasing, the disk is read
        again and must still be the same device (number, size, serial) and still be allowed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Disk,
        [scriptblock]$Tick,
        [scriptblock]$Log
    )
    $now = @(Get-DzUsbDiskCandidate | Where-Object { $_.Number -eq $Disk.Number }) | Select-Object -First 1
    if ($null -eq $now) { throw 'The USB stick is gone. Plug it back in and press Refresh.' }
    if ($now.Size -ne $Disk.Size -or $now.Serial -ne $Disk.Serial -or $now.Name -ne $Disk.Name) {
        throw 'The drives changed since you picked the USB stick. Press Refresh and pick it again.'
    }
    if ($now.Problem) { throw "This drive cannot be used: $($now.Problem)" }

    if ($Log) { & $Log ("Erasing disk {0} ({1}, {2} GB) and formatting it FAT32." -f $now.Number, $now.Name, $now.SizeGB) }
    $file = Join-Path ([System.IO.Path]::GetTempPath()) ('dayzero-diskpart-' + [guid]::NewGuid().ToString('N') + '.txt')
    $failure = $null
    try {
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            # Read the disk again before every attempt: same device, still allowed, current letters.
            $cur = @(Get-DzUsbDiskCandidate | Where-Object { $_.Number -eq $now.Number }) | Select-Object -First 1
            if ($null -eq $cur) { throw 'The USB stick is gone. Plug it back in and press Refresh.' }
            if ($cur.Size -ne $now.Size -or $cur.Serial -ne $now.Serial -or $cur.Name -ne $now.Name -or $cur.Problem) {
                throw 'The drives changed while formatting. Press Refresh and pick the USB stick again.'
            }
            Stop-DzStaleCopy -Letter $cur.Letters -Log $Log
            $commands = New-DzDiskpartScript -DiskNumber $cur.Number -PartitionMB (Get-DzUsbPartitionSize -DiskBytes $cur.Size) -Label $script:UsbLabel
            [System.IO.File]::WriteAllText($file, $commands, [System.Text.Encoding]::ASCII)
            $r = Invoke-DzProcess -FilePath (Join-Path $env:SystemRoot 'System32\diskpart.exe') -Arguments ('/s "{0}"' -f $file) -Activity 'Erasing and formatting the USB stick' -Tick $Tick
            if ($r.ExitCode -eq 0) { $failure = $null; break }
            $failure = "diskpart exit code $($r.ExitCode): $((@($r.Output -split "`r?`n") | Select-Object -Last 3) -join ' ')"
            if ($Log) { & $Log "Formatting attempt $attempt failed ($failure)." }
            # "Access is denied" usually clears by itself: the failed clean has already made Windows
            # let go of the stick, so a second try a few seconds later goes through.
            for ($w = 0; $w -lt 10 -and $attempt -lt 3; $w++) { Invoke-DzTick -Tick $Tick -Text 'Erasing and formatting the USB stick (trying again)'; Start-Sleep -Milliseconds 500 }
        }
    }
    finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
    if ($failure) {
        throw "Formatting the USB stick failed ($failure) Unplug the stick, plug it back in, press Refresh and try again. If it says access is denied, also close every File Explorer window that shows the stick."
    }

    $letter = $null
    for ($i = 0; $i -lt 40 -and -not $letter; $i++) {
        $part = @(Get-Partition -DiskNumber $now.Number -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -and [int][char]$_.DriveLetter -ne 0 }) | Select-Object -First 1
        if ($part) { $letter = [string]$part.DriveLetter } else { Invoke-DzTick -Tick $Tick -Text 'Waiting for the new drive letter...'; Start-Sleep -Milliseconds 500 }
    }
    if (-not $letter) { throw 'The USB stick was formatted but Windows gave it no drive letter. Unplug it, plug it back in and use "A Windows USB stick I already made".' }
    if ($env:SystemDrive -and $letter -ieq $env:SystemDrive.Substring(0, 1)) { throw 'Refusing to continue: the new drive letter is the system drive.' }
    $root = "${letter}:\"
    $fs = [string](Get-Volume -DriveLetter $letter -ErrorAction Stop).FileSystem
    if ($fs -ne 'FAT32') { throw "The USB stick should be FAT32 after formatting but is '$fs'." }
    if ($Log) { & $Log "The stick is now $root (FAT32, label $($script:UsbLabel))." }
    return $root
}

function ConvertTo-DzRobocopyPath {
    <#
        A path as a robocopy argument. A quoted drive root ("E:\") would end in \" which the
        command line reads as an escaped quote, so roots are passed bare and folders quoted
        without a trailing backslash.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Path)
    $trimmed = $Path.TrimEnd('\')
    if ($trimmed -match '^[A-Za-z]:$') { return ($trimmed + '\') }
    return ('"{0}"' -f $trimmed)
}

function Update-DzCopyState {
    <#
        Follows robocopy's output (/BYTES /NC, per-file percentages on) to know how many bytes
        have really been written. A file line is "<size> <path>"; it is followed by "12.3%"
        lines for that file. $State needs Done, Current and Percent (all numbers) and Seen.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [AllowNull()][AllowEmptyString()][string]$Line
    )
    if ([string]::IsNullOrWhiteSpace($Line)) { return }
    $m = [regex]::Match($Line, '^\s*(\d{1,3}(?:[.,]\d+)?)\s?%\s*$')
    if ($m.Success) {
        $State.Percent = [double]::Parse($m.Groups[1].Value.Replace(',', '.'), [System.Globalization.CultureInfo]::InvariantCulture)
        if ($State.Percent -gt 100) { $State.Percent = 100 }
        return
    }
    $m = [regex]::Match($Line, '^\s*(\d+)\s+\S')
    if ($m.Success) {
        $State.Done = [double]$State.Done + [double]$State.Current   # the previous file is complete
        $State.Current = [double]::Parse($m.Groups[1].Value, [System.Globalization.CultureInfo]::InvariantCulture)
        $State.Percent = [double]0
        $State.Seen = $true
    }
}

function Get-DzCopyStateBytes {
    <# Bytes written so far according to Update-DzCopyState. #>
    [CmdletBinding()]
    [OutputType([double])]
    param([Parameter(Mandatory = $true)][hashtable]$State)
    return ([double]$State.Done + ([double]$State.Current * [double]$State.Percent / 100))
}

function Copy-DzMediaTree {
    <# Copies a folder onto the stick with robocopy, showing how much has really been written. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Used inside the nested script block, which the analyzer cannot follow.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [string[]]$ExcludeFile = @(),
        [scriptblock]$Tick
    )
    # No /NP and no /NFL: robocopy then prints each file's size and its percentage, which is
    # the only honest progress. (Free space on the stick is useless for that: Windows reserves
    # a whole 3.8 GB file the moment its copy starts.)
    $arguments = '{0} {1} /E /J /R:2 /W:3 /NDL /NJH /NJS /NC /BYTES /XD "System Volume Information" "$RECYCLE.BIN"' -f (ConvertTo-DzRobocopyPath -Path $Source), (ConvertTo-DzRobocopyPath -Path $TargetRoot)
    foreach ($x in $ExcludeFile) { $arguments += (' /XF "{0}"' -f $x) }
    $total = [double]0
    foreach ($f in @(Get-ChildItem -LiteralPath $Source -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        if ($ExcludeFile -notcontains $f.Name) { $total += $f.Length }
    }
    $state = @{ Done = [double]0; Current = [double]0; Percent = [double]0; Seen = $false }
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    # Closures: Invoke-DzProcess has its own $Tick and $clock, which plain script blocks would pick up instead.
    $onLine = { param($line) Update-DzCopyState -State $state -Line $line }.GetNewClosure()
    $progress = {
        $label = 'Copying Windows to the USB stick'
        if ($state.Seen -and $total -gt 0) {
            $bytes = Get-DzCopyStateBytes -State $state
            $percent = 100 * $bytes / $total
            if ($percent -gt 99) { $percent = 99 }
            $speed = if ($clock.Elapsed.TotalSeconds -gt 5) { $bytes / 1MB / $clock.Elapsed.TotalSeconds } else { 0 }
            $label = if ($speed -gt 0) { '{0}: {1:N1} of {2:N1} GB, {3:N0} MB/s ({4:N0}%)' -f $label, ($bytes / 1GB), ($total / 1GB), $speed, $percent }
            else { '{0}: {1:N1} of {2:N1} GB ({3:N0}%)' -f $label, ($bytes / 1GB), ($total / 1GB), $percent }
        }
        if ($Tick) { & $Tick $label }
    }.GetNewClosure()
    $r = Invoke-DzProcess -FilePath (Join-Path $env:SystemRoot 'System32\robocopy.exe') -Arguments $arguments -Tick $progress -OnLine $onLine
    # robocopy: 0-7 mean success (files copied / nothing to do / extras), 8 and up mean failures.
    if ($r.ExitCode -ge 8) { throw "Copying Windows to the USB stick failed (robocopy exit code $($r.ExitCode)): $((@($r.Output -split "`r?`n") | Select-Object -Last 4) -join ' ')" }
}

function Invoke-DzWithMountedIso {
    <# Mounts an ISO, runs $Action with its drive root ('F:\') and always unmounts it again. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$IsoPath,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )
    if (-not (Test-Path -LiteralPath $IsoPath -PathType Leaf)) { throw "ISO file not found: $IsoPath" }
    $image = Mount-DiskImage -ImagePath $IsoPath -StorageType ISO -Access ReadOnly -PassThru -ErrorAction Stop
    try {
        $letter = $null
        for ($i = 0; $i -lt 20 -and -not $letter; $i++) {
            $vol = $image | Get-Volume -ErrorAction SilentlyContinue
            if ($vol -and $vol.DriveLetter -and [int][char]$vol.DriveLetter -ne 0) { $letter = [string]$vol.DriveLetter } else { Start-Sleep -Milliseconds 500 }
        }
        if (-not $letter) { throw 'The ISO was mounted but got no drive letter.' }
        & $Action "${letter}:\"
    }
    finally {
        [void](Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue)
    }
}

function Find-DzInstallImage {
    <# Path of sources\install.wim / .esd / .swm under a media root, or $null. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Root)
    foreach ($name in @('install.wim', 'install.esd', 'install.swm')) {
        $p = Join-Path (Join-Path $Root 'sources') $name
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Copy-DzIsoToUsb {
    <#
        Copies a Windows ISO onto the stick. An install.wim larger than FAT32's 4 GB file
        limit is split into install.swm parts with DISM (Windows Setup reads those natively).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Used inside the nested script block, which the analyzer cannot follow.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$IsoPath,
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [scriptblock]$Tick,
        [scriptblock]$Log
    )
    Invoke-DzWithMountedIso -IsoPath $IsoPath -Action {
        param($isoRoot)
        $image = Find-DzInstallImage -Root $isoRoot
        if (-not $image) { throw 'This ISO has no sources\install.wim or install.esd, so it is not Windows installation media.' }
        $tooBig = ((Get-Item -LiteralPath $image).Length -gt $script:Fat32MaxFile)
        if ($tooBig -and [System.IO.Path]::GetExtension($image) -ine '.wim') { throw 'The Windows image in this ISO is larger than 4 GB and cannot be split. Use the download option instead.' }
        $exclude = @()
        if ($tooBig) { $exclude = @('install.wim') }
        Copy-DzMediaTree -Source $isoRoot -TargetRoot $TargetRoot -ExcludeFile $exclude -Tick $Tick
        if ($tooBig) {
            if ($Log) { & $Log 'install.wim is larger than 4 GB; splitting it into install.swm parts for the FAT32 stick.' }
            $swm = Join-Path (Join-Path $TargetRoot 'sources') 'install.swm'
            Invoke-DzDism -Tick $Tick -Activity 'Splitting the Windows image for the USB stick' -Arguments ('/Split-Image /ImageFile:"{0}" /SWMFile:"{1}" /FileSize:3800' -f $image, $swm)
        }
    }
}

function Set-DzUsbBootSector {
    <#
        Makes the stick bootable on legacy BIOS PCs with Microsoft's bootsect.exe from the
        media itself. UEFI PCs boot from \efi\boot and do not need this, so failure is only logged.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][string]$TargetRoot, [scriptblock]$Log)
    $bootsect = Join-Path $TargetRoot 'boot\bootsect.exe'
    if (-not (Test-Path -LiteralPath $bootsect)) {
        if ($Log) { & $Log 'No boot\bootsect.exe on the media: the stick boots on UEFI PCs only.' }
        return $false
    }
    try {
        $r = Invoke-DzProcess -FilePath $bootsect -Arguments ('/nt60 {0} /force /mbr' -f $TargetRoot.Substring(0, 2))
        if ($r.ExitCode -eq 0) { if ($Log) { & $Log 'Boot code written (legacy BIOS boot).' }; return $true }
        if ($Log) { & $Log "bootsect exit code $($r.ExitCode): the stick still boots on UEFI PCs." }
    }
    catch {
        if ($Log) { & $Log "bootsect could not run ($($_.Exception.Message)): the stick still boots on UEFI PCs." }
    }
    return $false
}

Export-ModuleMember -Function @(
    'Get-DzWindowsLanguageList', 'Get-DzWindowsCatalogUrl', 'Get-DzMediaCacheRoot', 'Get-DzBuildProgress', 'Invoke-DzProcess', 'Invoke-DzDism',
    'ConvertFrom-DzProductsXml', 'Test-DzWindowsDownloadEntry', 'Select-DzWindowsDownload', 'Find-DzCatalogXml', 'Get-DzWindowsCatalog',
    'Get-DzFileSha1', 'Save-DzLargeFile', 'Get-DzEsdImagePlan', 'Select-DzEsdEdition', 'New-DzMediaFromEsd',
    'Get-DzPreparedMedia', 'Get-DzMediaCacheItem', 'Remove-DzMediaCacheItem', 'Get-DzWindowsMediaTree', 'Test-DzUsbDiskAllowed', 'Get-DzUsbDiskCandidate',
    'New-DzDiskpartScript', 'Get-DzUsbPartitionSize', 'Get-DzMediaFitProblem', 'Get-DzFolderSize', 'Initialize-DzUsbDisk', 'ConvertTo-DzRobocopyPath', 'Update-DzCopyState', 'Get-DzCopyStateBytes', 'Copy-DzMediaTree',
    'Invoke-DzWithMountedIso', 'Find-DzInstallImage', 'Copy-DzIsoToUsb', 'Set-DzUsbBootSector'
)
