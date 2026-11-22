#Requires -Version 5.1
<#
    DayZero builder - Linux install sticks.

    Works the same on Windows (the WPF builder) and on Linux (BuilderCli.ps1 under PowerShell 7).

    Where Linux comes from: the official HTTPS download folder listed in builder\linux\distros.json
    (releases.ubuntu.com). The ISO must match the SHA256SUMS file published next to it, byte for
    byte, or it is thrown away.

    What lands on the stick for Ubuntu (automation 'ubuntu-autoinstall'):
      * the ISO's files, copied onto one FAT32 partition (boots on UEFI PCs),
      * autoinstall.yaml in the root: account, language, keyboard, time zone, drivers, codecs.
        Its 'interactive-sections' always holds 'storage', and it never has a 'storage' key:
        the installer stops on the disk screen and the user picks the disk. DayZero never
        selects, wipes or partitions a disk on the new PC.
      * dayzero\ : the Linux kit (kit\linux), installed by a late-command into /opt/dayzero.
        It runs once at first boot as a systemd service (updates, drivers, apps, your scripts).

    Any other Linux ISO can be written to the stick as-is (raw), with no DayZero automation.
#>

Set-StrictMode -Version 2.0

$script:Fat32MaxFile = 4294967295
$script:KitFolder = 'dayzero'
$script:CryptAlphabet = './0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
$script:ReservedUsers = @(
    'root', 'daemon', 'bin', 'sys', 'sync', 'games', 'man', 'lp', 'mail', 'news', 'uucp', 'proxy', 'www-data',
    'backup', 'list', 'irc', 'gnats', 'nobody', 'messagebus', 'syslog', 'avahi', 'cups', 'gdm', 'sshd', 'admin', 'sudo', 'adm', 'ubuntu'
)

# ------------------------------------------------------------------------------------
# Data files (builder\linux\*.json)
# ------------------------------------------------------------------------------------

function Get-DzLinuxDataRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return (Join-Path (Split-Path -Parent $PSScriptRoot) 'linux')
}

function Read-DzLinuxJson {
    param([Parameter(Mandatory = $true)][string]$Name, [string]$DataRoot)
    if (-not $DataRoot) { $DataRoot = Get-DzLinuxDataRoot }
    $path = Join-Path $DataRoot $Name
    return (Get-Content -Raw -Encoding UTF8 -LiteralPath $path | ConvertFrom-Json)
}

function Get-DzLinuxCatalog {
    <# The distros.json catalogue: AllowedHosts, DefaultDistro and Distros (objects). #>
    [CmdletBinding()]
    param([string]$DataRoot)
    $raw = Read-DzLinuxJson -Name 'distros.json' -DataRoot $DataRoot
    return [pscustomobject]@{
        AllowedHosts  = @($raw.allowedHosts)
        DefaultDistro = [string]$raw.defaultDistro
        Distros       = @($raw.distros)
    }
}

function Get-DzLinuxDistro {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Id, [string]$DataRoot)
    $d = @((Get-DzLinuxCatalog -DataRoot $DataRoot).Distros | Where-Object { $_.id -eq $Id }) | Select-Object -First 1
    if ($null -eq $d) { throw "Unknown Linux system: $Id" }
    return $d
}

function Test-DzLinuxDownloadUrl {
    <# $true only for an https:// URL on one of the allowed hosts. #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][string]$Url, [Parameter(Mandatory = $true)][string[]]$AllowedHosts)
    $uri = $null
    if (-not [System.Uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$uri)) { return $false }
    if ($uri.Scheme -ne 'https') { return $false }
    if ($uri.UserInfo) { return $false }
    if (-not $uri.IsDefaultPort) { return $false }
    return ($AllowedHosts -contains $uri.Host.ToLowerInvariant())
}

# ------------------------------------------------------------------------------------
# Checksums and picking the ISO
# ------------------------------------------------------------------------------------

function ConvertFrom-DzSha256Sums {
    <# Parses a sha256sum file ("<hash> *name" or "<hash>  name") into Name/Sha256 objects. #>
    [CmdletBinding()]
    param([AllowEmptyString()][Parameter(Mandatory = $true)][string]$Text)
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^\s*([0-9A-Fa-f]{64})\s+\*?(\S+)\s*$') {
            [pscustomobject]@{ Name = $Matches[2]; Sha256 = $Matches[1].ToLowerInvariant() }
        }
    }
}

function Get-DzVersionKey {
    <# The first dotted version in a file name ('26.04.1') as a sortable key; none sorts first. #>
    param([string]$Name)
    $m = [regex]::Match($Name, '\d+(\.\d+)+')
    if (-not $m.Success) { return '' }
    $parts = @($m.Value.Split('.') | ForEach-Object { '{0:D6}' -f [int64]$_ })
    while ($parts.Count -lt 6) { $parts += '000000' }
    return ($parts -join '.')
}

function Select-DzLinuxIso {
    <# The newest ISO in the checksum list whose name matches the distro's isoPattern. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Sums,
        [Parameter(Mandatory = $true)][string]$Pattern
    )
    $hits = @($Sums | Where-Object { $_.Name -match $Pattern })
    if ($hits.Count -eq 0) { return $null }
    return (@($hits | Sort-Object -Property @{ Expression = { Get-DzVersionKey -Name $_.Name } } -Descending) | Select-Object -First 1)
}

function Get-DzFileSha256 {
    <# SHA-256 of a (large) file as lowercase hex, calling $Tick while it reads. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Path, [scriptblock]$Tick, [string]$Activity = 'Checking the download')
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $buffer = New-Object byte[] (4MB)
        $total = [double]$stream.Length
        if ($total -lt 1) { $total = 1 }
        $done = [int64]0
        $next = [int64]0
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            [void]$sha.TransformBlock($buffer, 0, $read, $null, 0)
            $done += $read
            if ($Tick -and $done -ge $next) {
                & $Tick ('{0} ({1:N0}%)' -f $Activity, (100 * $done / $total))
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

# ------------------------------------------------------------------------------------
# Download (plain HTTPS, resumes a partial file)
# ------------------------------------------------------------------------------------

function Get-DzLinuxCacheRoot {
    <# Where downloaded Linux ISOs are kept and reused. #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if ($env:LOCALAPPDATA) { return (Join-Path (Join-Path (Join-Path $env:LOCALAPPDATA 'DayZero') 'media') 'linux') }
    if ($env:DAYZERO_CACHE) { return (Join-Path $env:DAYZERO_CACHE 'linux') }
    return '/var/cache/dayzero/linux'
}

function Initialize-DzHttp {
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        Add-Type -AssemblyName System.Net.Http
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    }
}

function Get-DzWebText {
    <# Small text file over HTTPS (the checksum list). #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Url)
    Initialize-DzHttp
    $client = New-Object System.Net.Http.HttpClient
    try {
        $client.Timeout = [TimeSpan]::FromSeconds(60)
        return $client.GetStringAsync($Url).GetAwaiter().GetResult()
    }
    finally { $client.Dispose() }
}

function Save-DzWebFile {
    <#
        Downloads a large file to $Path. A $Path.part left over from an interrupted download is
        continued (HTTP Range) instead of starting again.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Activity = 'Downloading',
        [scriptblock]$Tick
    )
    Initialize-DzHttp
    $part = $Path + '.part'
    $have = [int64]0
    if (Test-Path -LiteralPath $part) { $have = (Get-Item -LiteralPath $part).Length }
    $handler = New-Object System.Net.Http.HttpClientHandler
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
    try {
        $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $Url)
        if ($have -gt 0) { $request.Headers.Range = New-Object System.Net.Http.Headers.RangeHeaderValue($have, $null) }
        $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        $code = [int]$response.StatusCode
        if ($code -eq 416) { $response.Dispose(); Move-Item -LiteralPath $part -Destination $Path -Force; return $Path }
        if (-not $response.IsSuccessStatusCode) { throw "The download failed: HTTP $code from $Url" }
        $append = ($have -gt 0 -and $code -eq 206)
        if (-not $append) { $have = 0 }
        $length = $response.Content.Headers.ContentLength
        $total = if ($length) { [double]$length + $have } else { [double]0 }
        $mode = if ($append) { [System.IO.FileMode]::Append } else { [System.IO.FileMode]::Create }
        $out = New-Object System.IO.FileStream($part, $mode, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, 1MB)
        $in = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        try {
            $buffer = New-Object byte[] (1MB)
            $done = [double]$have
            $next = [double]0
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            $startBytes = $done
            while (($read = $in.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $out.Write($buffer, 0, $read)
                $done += $read
                if ($Tick -and $done -ge $next) {
                    $speed = ($done - $startBytes) / [double][math]::Max(0.5, $watch.Elapsed.TotalSeconds) / 1MB
                    $text = if ($total -gt 0) { '{0}: {1:N1} of {2:N1} GB, {3:N0} MB/s ({4:N0}%)' -f $Activity, ($done / 1GB), ($total / 1GB), $speed, (100 * $done / $total) }
                    else { '{0}: {1:N1} GB' -f $Activity, ($done / 1GB) }
                    & $Tick $text
                    $next = $done + 16MB
                }
            }
        }
        finally {
            $in.Dispose()
            $out.Dispose()
            $response.Dispose()
        }
        if ($total -gt 0 -and (Get-Item -LiteralPath $part).Length -ne [int64]$total) { throw 'The download stopped before the end. Try again: it continues where it stopped.' }
    }
    finally {
        $client.Dispose()
    }
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    Move-Item -LiteralPath $part -Destination $Path -Force
    return $Path
}

function Get-DzLinuxIso {
    <#
    .SYNOPSIS
        The verified ISO of a distro from distros.json: from the cache, else downloaded.
    .OUTPUTS
        Object with Path, Name, Sha256, Url.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DistroId,
        [string]$CacheRoot,
        [string]$DataRoot,
        [scriptblock]$Tick,
        [scriptblock]$Log
    )
    $catalog = Get-DzLinuxCatalog -DataRoot $DataRoot
    $distro = Get-DzLinuxDistro -Id $DistroId -DataRoot $DataRoot
    if (-not $CacheRoot) { $CacheRoot = Get-DzLinuxCacheRoot }
    $base = [string]$distro.baseUrl
    if (-not $base.EndsWith('/')) { $base += '/' }
    $sumsUrl = $base + [string]$distro.sums
    if (-not (Test-DzLinuxDownloadUrl -Url $sumsUrl -AllowedHosts $catalog.AllowedHosts)) { throw "Refusing to download from $sumsUrl (not an allowed https address)." }
    if ($Tick) { & $Tick "Asking $([System.Uri]::new($sumsUrl).Host) for the newest $($distro.name)..." }
    $sums = @(ConvertFrom-DzSha256Sums -Text (Get-DzWebText -Url $sumsUrl))
    $pick = Select-DzLinuxIso -Sums $sums -Pattern ([string]$distro.isoPattern)
    if ($null -eq $pick) { throw "No $($distro.name) ISO is listed in $sumsUrl." }
    if ($pick.Name -notmatch '^[A-Za-z0-9._+-]+\.iso$') { throw "Unexpected ISO name in the checksum list: $($pick.Name)" }
    $url = $base + $pick.Name
    if (-not (Test-DzLinuxDownloadUrl -Url $url -AllowedHosts $catalog.AllowedHosts)) { throw "Refusing to download from $url (not an allowed https address)." }
    if ($Log) { & $Log "Newest $($distro.name): $($pick.Name), SHA-256 $($pick.Sha256)" }

    [void](New-Item -ItemType Directory -Path $CacheRoot -Force)
    $path = Join-Path $CacheRoot $pick.Name
    $stamp = $path + '.sha256'
    if ((Test-Path -LiteralPath $path) -and (Test-Path -LiteralPath $stamp)) {
        $item = Get-Item -LiteralPath $path
        $want = '{0} {1} {2}' -f $pick.Sha256, $item.Length, $item.LastWriteTimeUtc.Ticks
        if ((Get-Content -Raw -LiteralPath $stamp).Trim() -eq $want) {
            if ($Log) { & $Log "Using the copy checked earlier: $path" }
            return [pscustomobject]@{ Path = $path; Name = $pick.Name; Sha256 = $pick.Sha256; Url = $url }
        }
    }
    if (-not (Test-Path -LiteralPath $path)) {
        if ($Log) { & $Log "Downloading $url" }
        [void](Save-DzWebFile -Url $url -Path $path -Activity "Downloading $($distro.name)" -Tick $Tick)
    }
    $hash = Get-DzFileSha256 -Path $path -Tick $Tick -Activity "Checking $($distro.name)"
    if ($hash -ne $pick.Sha256) {
        Remove-Item -LiteralPath $path -Force
        Remove-Item -LiteralPath $stamp -Force -ErrorAction SilentlyContinue
        throw "The downloaded $($pick.Name) does not match its published SHA-256, so it was deleted. Try again."
    }
    $item = Get-Item -LiteralPath $path
    [System.IO.File]::WriteAllText($stamp, ('{0} {1} {2}' -f $hash, $item.Length, $item.LastWriteTimeUtc.Ticks))
    if ($Log) { & $Log "SHA-256 matches: $path" }
    return [pscustomobject]@{ Path = $path; Name = $pick.Name; Sha256 = $hash; Url = $url }
}

# ------------------------------------------------------------------------------------
# Account, language, keyboard, time zone
# ------------------------------------------------------------------------------------

function New-DzCryptSalt {
    [OutputType([string])]
    param([ValidateRange(8, 16)][int]$Length = 16)
    $bytes = New-Object byte[] $Length
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return (-join ($bytes | ForEach-Object { $script:CryptAlphabet[$_ % 64] }))
}

function Get-DzSha512 {
    <# SHA-512 of the byte arrays given, one after another. #>
    param([object[]]$Parts)
    $ms = New-Object System.IO.MemoryStream
    foreach ($x in $Parts) { if ($null -ne $x) { $b = [byte[]]$x; $ms.Write($b, 0, $b.Length) } }
    $sha = [System.Security.Cryptography.SHA512]::Create()
    try { return , ([byte[]]$sha.ComputeHash($ms.ToArray())) } finally { $sha.Dispose(); $ms.Dispose() }
}

function Get-DzRepeatedBytes {
    <# $Block repeated until $Length bytes. #>
    param([byte[]]$Block, [int]$Length)
    $out = New-Object byte[] $Length
    for ($i = 0; $i -lt $Length; $i += $Block.Length) {
        $n = [math]::Min($Block.Length, $Length - $i)
        [System.Array]::Copy($Block, 0, $out, $i, $n)
    }
    return , $out
}

function ConvertTo-DzSha512Crypt {
    <#
    .SYNOPSIS
        The password as a SHA-512 crypt string ($6$salt$hash), what Linux keeps in /etc/shadow
        and what Ubuntu's autoinstall wants. Same result as 'openssl passwd -6'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Password,
        [string]$Salt
    )
    if (-not $Salt) { $Salt = New-DzCryptSalt }
    if ($Salt.Length -gt 16) { $Salt = $Salt.Substring(0, 16) }
    if ($Salt -notmatch '^[./0-9A-Za-z]+$') { throw 'The salt may only use ./0-9A-Za-z.' }
    [byte[]]$p = [System.Text.Encoding]::UTF8.GetBytes($Password)
    [byte[]]$s = [System.Text.Encoding]::ASCII.GetBytes($Salt)
    $pl = $p.Length

    [byte[]]$b = Get-DzSha512 -Parts @($p, $s, $p)
    $a = New-Object System.Collections.Generic.List[object]
    $a.Add($p); $a.Add($s)
    if ($pl -gt 0) { $a.Add((Get-DzRepeatedBytes -Block $b -Length $pl)) }
    for ($n = $pl; $n -gt 0; $n = $n -shr 1) {
        if ($n -band 1) { $a.Add($b) } else { $a.Add($p) }
    }
    [byte[]]$c = Get-DzSha512 -Parts $a.ToArray()

    $dp = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $pl; $i++) { $dp.Add($p) }
    [byte[]]$pSeq = New-Object byte[] 0
    if ($pl -gt 0) { $pSeq = Get-DzRepeatedBytes -Block (Get-DzSha512 -Parts $dp.ToArray()) -Length $pl }
    $ds = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt (16 + [int]$c[0]); $i++) { $ds.Add($s) }
    [byte[]]$sSeq = Get-DzRepeatedBytes -Block (Get-DzSha512 -Parts $ds.ToArray()) -Length $s.Length

    $sha = [System.Security.Cryptography.SHA512]::Create()
    try {
        for ($r = 0; $r -lt 5000; $r++) {
            $ms = New-Object System.IO.MemoryStream
            if ($r -band 1) { $ms.Write($pSeq, 0, $pSeq.Length) } else { $ms.Write($c, 0, $c.Length) }
            if ($r % 3) { $ms.Write($sSeq, 0, $sSeq.Length) }
            if ($r % 7) { $ms.Write($pSeq, 0, $pSeq.Length) }
            if ($r -band 1) { $ms.Write($c, 0, $c.Length) } else { $ms.Write($pSeq, 0, $pSeq.Length) }
            $c = $sha.ComputeHash($ms.ToArray())
            $ms.Dispose()
        }
    }
    finally { $sha.Dispose() }

    $order = @(
        0, 21, 42, 22, 43, 1, 44, 2, 23, 3, 24, 45, 25, 46, 4, 47, 5, 26, 6, 27, 48, 28, 49, 7, 50, 8, 29, 9, 30, 51,
        31, 52, 10, 53, 11, 32, 12, 33, 54, 34, 55, 13, 56, 14, 35, 15, 36, 57, 37, 58, 16, 59, 17, 38, 18, 39, 60, 40, 61, 19, 62, 20, 41
    )
    $sb = New-Object System.Text.StringBuilder
    for ($g = 0; $g -lt 63; $g += 3) {
        $w = ([int]$c[$order[$g]] -shl 16) -bor ([int]$c[$order[$g + 1]] -shl 8) -bor [int]$c[$order[$g + 2]]
        for ($k = 0; $k -lt 4; $k++) { [void]$sb.Append($script:CryptAlphabet[$w -band 63]); $w = $w -shr 6 }
    }
    $w = [int]$c[63]
    for ($k = 0; $k -lt 2; $k++) { [void]$sb.Append($script:CryptAlphabet[$w -band 63]); $w = $w -shr 6 }
    return ('$6$' + $Salt + '$' + $sb.ToString())
}

function Test-DzLinuxUserName {
    <# Problem text, or $null when the name is a valid Linux user name. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return 'Enter a user name.' }
    if ($Name -cnotmatch '^[a-z][a-z0-9_-]{0,31}$') { return 'On Linux the user name must start with a small letter and use only small letters, digits, - and _ (up to 32).' }
    if ($script:ReservedUsers -contains $Name -or $Name.StartsWith('systemd-')) { return "The user name '$Name' is used by Linux itself. Pick another one." }
    return $null
}

function ConvertTo-DzLinuxUserName {
    <# A suggestion that passes Test-DzLinuxUserName ('Ivan Petrov' -> 'ivan-petrov'), or ''. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$Name)
    $n = ([string]$Name).ToLowerInvariant() -replace '[^a-z0-9_-]+', '-'
    $n = $n.Trim('-', '_')
    $n = $n -replace '^[^a-z]+', ''
    if ($n.Length -gt 32) { $n = $n.Substring(0, 32).TrimEnd('-', '_') }
    if (-not $n -or (Test-DzLinuxUserName -Name $n)) { return '' }
    return $n
}

function Test-DzLinuxHostName {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$Name)
    if ([string]::IsNullOrEmpty($Name)) { return $null }
    if ($Name -notmatch '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$') { return 'The computer name may use letters, digits and - (not at the start or end), up to 63.' }
    return $null
}

function ConvertTo-DzLinuxLocale {
    <# 'ru-RU' -> 'ru_RU.UTF-8'. Anything else falls back to en_US.UTF-8 (Known = $false). #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Culture)
    if ($Culture -match '^([a-z]{2,3})-([A-Z]{2})$') { return [pscustomobject]@{ Locale = ('{0}_{1}.UTF-8' -f $Matches[1], $Matches[2]); Known = $true } }
    if ($Culture -eq 'sr-Latn-RS') { return [pscustomobject]@{ Locale = 'sr_RS.UTF-8@latin'; Known = $true } }
    return [pscustomobject]@{ Locale = 'en_US.UTF-8'; Known = $false }
}

function ConvertTo-DzLinuxTimeZone {
    <# Windows time zone id -> IANA name. An IANA name passes through. Unknown -> Etc/UTC (Known = $false). #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Id, [string]$DataRoot)
    if ($Id -match '^[A-Za-z]+(/[A-Za-z0-9_+-]+)+$') { return [pscustomobject]@{ TimeZone = $Id; Known = $true } }
    $zones = (Read-DzLinuxJson -Name 'timezones.json' -DataRoot $DataRoot).zones
    $p = $zones.PSObject.Properties[$Id]
    if ($p) { return [pscustomobject]@{ TimeZone = [string]$p.Value; Known = $true } }
    return [pscustomobject]@{ TimeZone = 'Etc/UTC'; Known = $false }
}

function ConvertTo-DzLinuxKeyboard {
    <#
        Windows input locale ('0419:00000419') -> xkb Layout/Variant/Toggle. Non-Latin layouts
        get US English first (Alt+Shift switches), like a fresh Windows. Unknown -> us (Known = $false).
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$InputLocale, [string]$DataRoot)
    $data = Read-DzLinuxJson -Name 'keyboards.json' -DataRoot $DataRoot
    $klid = ''
    if ($InputLocale -match '^[0-9A-Fa-f]{4}:([0-9A-Fa-f]{8})$') { $klid = $Matches[1].ToUpperInvariant() }
    elseif ($InputLocale -match '^[0-9A-Fa-f]{8}$') { $klid = $InputLocale.ToUpperInvariant() }
    $entry = $null
    if ($klid) { $p = $data.layouts.PSObject.Properties[$klid]; if ($p) { $entry = $p.Value } }
    if ($null -eq $entry) { return [pscustomobject]@{ Layout = 'us'; Variant = ''; Toggle = ''; Known = $false } }
    $layout = [string]$entry.layout
    $variant = if ($entry.PSObject.Properties['variant']) { [string]$entry.variant } else { '' }
    if (@($data.nonLatin) -contains $layout) {
        return [pscustomobject]@{ Layout = "us,$layout"; Variant = ",$variant"; Toggle = 'alt_shift_toggle'; Known = $true }
    }
    return [pscustomobject]@{ Layout = $layout; Variant = $variant; Toggle = ''; Known = $true }
}

# ------------------------------------------------------------------------------------
# autoinstall.yaml
# ------------------------------------------------------------------------------------

function ConvertTo-DzYamlString {
    <# A YAML single-quoted scalar. Line breaks and control characters are refused. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][Parameter(Mandatory = $true)][string]$Value)
    if ($Value -match '[\x00-\x1F\x7F]') { throw 'A setting contains a line break or control character.' }
    return ("'" + $Value.Replace("'", "''") + "'")
}

function Get-DzKitLateCommand {
    <# The one late-command: run the kit's installer from the stick if it is there; never fail the install. #>
    [OutputType([string])]
    param()
    return ('for d in /cdrom /run/live/medium /isodevice; do if [ -f "$d/' + $script:KitFolder + '/install-kit.sh" ]; then exec sh "$d/' + $script:KitFolder + '/install-kit.sh" /target; fi; done; echo "DayZero kit not found on the install medium" >&2')
}

function New-DzAutoinstallYaml {
    <#
    .SYNOPSIS
        Ubuntu autoinstall.yaml text. The disk screen always stays interactive.
    .PARAMETER Options
        Hashtable: UserName, FullName, PasswordHash ($6$...), HostName, Locale, Keyboard
        (Layout/Variant/Toggle), TimeZone, BuildId, Drivers ($true/$false), Codecs ($true/$false).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Options)
    $user = [string]$Options.UserName
    $problem = Test-DzLinuxUserName -Name $user
    if ($problem) { throw $problem }
    $hostName = [string]$Options.HostName
    if (-not $hostName) { $hostName = ($user + '-pc') }
    $problem = Test-DzLinuxHostName -Name $hostName
    if ($problem) { throw $problem }
    $hash = [string]$Options.PasswordHash
    if ($hash -notmatch '^\$6\$[./0-9A-Za-z]{1,16}\$[./0-9A-Za-z]{86}$') { throw 'PasswordHash must be a SHA-512 crypt string.' }
    $buildId = [string]$Options.BuildId
    if ($buildId -notmatch '^[0-9a-f]{8}$') { throw 'BuildId must be 8 lowercase hex characters.' }
    $locale = [string]$Options.Locale
    if ($locale -notmatch '^[a-z]{2,3}_[A-Z]{2}\.UTF-8(@[a-z]+)?$') { throw "Unexpected locale: $locale" }
    $tz = [string]$Options.TimeZone
    if ($tz -notmatch '^[A-Za-z]+(/[A-Za-z0-9_+-]+)+$') { throw "Unexpected time zone: $tz" }
    $kb = $Options.Keyboard
    foreach ($v in @([string]$kb.Layout, [string]$kb.Variant, [string]$kb.Toggle)) { if ($v -notmatch '^[a-z0-9_,]*$') { throw "Unexpected keyboard setting: $v" } }
    $q = { param($v) ConvertTo-DzYamlString -Value ([string]$v) }
    $bool = { param($v) if ($v) { 'true' } else { 'false' } }

    $y = New-Object System.Collections.Generic.List[string]
    $y.Add("# DayZero build $buildId - Ubuntu autoinstall file, made by the DayZero USB builder.")
    $y.Add('# The installer still stops on the disk screen: DayZero never picks, wipes or partitions a disk.')
    $y.Add('# The password below is a SHA-512 hash, not the password itself.')
    $y.Add('autoinstall:')
    $y.Add('  version: 1')
    $y.Add('  interactive-sections:')
    $y.Add('    - storage')
    $y.Add('  locale: ' + (& $q $locale))
    $y.Add('  keyboard:')
    $y.Add('    layout: ' + (& $q $kb.Layout))
    $y.Add('    variant: ' + (& $q $kb.Variant))
    if ($kb.Toggle) { $y.Add('    toggle: ' + (& $q $kb.Toggle)) }
    $y.Add('  timezone: ' + (& $q $tz))
    $y.Add('  identity:')
    if ($Options.FullName) { $y.Add('    realname: ' + (& $q $Options.FullName)) }
    $y.Add('    username: ' + (& $q $user))
    $y.Add('    hostname: ' + (& $q $hostName))
    $y.Add('    password: ' + (& $q $hash))
    $y.Add('  codecs:')
    $y.Add('    install: ' + (& $bool $Options.Codecs))
    $y.Add('  drivers:')
    $y.Add('    install: ' + (& $bool $Options.Drivers))
    $y.Add('  updates: all')
    $y.Add('  late-commands:')
    $y.Add('    - ' + (& $q (Get-DzKitLateCommand)))
    $text = ($y -join "`n") + "`n"
    $bad = @(Get-DzForbiddenAutoinstallKey -Yaml $text)
    if ($bad.Count -gt 0) { throw ('Refusing to write autoinstall.yaml: ' + ($bad -join ' ')) }
    return $text
}

function Get-DzForbiddenAutoinstallKey {
    <#
        Problems that must never be in an autoinstall file DayZero writes: a 'storage' key (it
        would pick, wipe or partition a disk), a missing interactive 'storage' section (Ubuntu
        then wipes the only disk on its own), or reporting/early commands.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Yaml)
    $lines = @($Yaml -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' })
    foreach ($l in $lines) {
        if ($l -match '^\s{0,2}storage\s*:') { 'It has a storage section.' }
        if ($l -match '^\s{0,2}(early-commands|reporting|user-data|error-commands)\s*:') { "It has a $($Matches[1]) section." }
    }
    $inSections = $false
    $hasStorage = $false
    foreach ($l in $lines) {
        if ($l -match '^\s{2}interactive-sections\s*:') { $inSections = $true; continue }
        if ($inSections) {
            if ($l -match '^\s{4}-\s*storage\s*$' -or $l -match "^\s{4}-\s*'storage'\s*$" -or $l -match '^\s{4}-\s*"\*"\s*$' -or $l -match "^\s{4}-\s*'\*'\s*$") { $hasStorage = $true }
            elseif ($l -notmatch '^\s{4}-') { $inSections = $false }
        }
    }
    if (-not $hasStorage) { 'The disk screen (storage) is not interactive.' }
}

# ------------------------------------------------------------------------------------
# Writing the kit and checking a stick
# ------------------------------------------------------------------------------------

function Write-DzLinuxTextFile {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Copy-DzLinuxFile {
    <# Copies one file; shell scripts, Python, systemd and desktop files get LF line endings (sh refuses CRLF). #>
    param([Parameter(Mandatory = $true)][string]$Source, [Parameter(Mandatory = $true)][string]$Destination)
    if ($Source -match '\.(sh|py|service|desktop)$') {
        $bytes = [System.IO.File]::ReadAllBytes($Source)
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
        if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
        Write-DzLinuxTextFile -Path $Destination -Text ($text -replace "`r`n", "`n")
    }
    else { Copy-Item -LiteralPath $Source -Destination $Destination -Force }
}

function Test-DzIsLinuxSystemRoot {
    param([string]$Path)
    if (-not $Path) { return $true }
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    if ($full -eq '' -or $full -eq '/') { return $true }
    if ($env:SystemDrive -and $full -ieq $env:SystemDrive.TrimEnd('\')) { return $true }
    return $false
}

function Get-DzLinuxReadmeText {
    param([System.Collections.IDictionary]$Settings)
    $lines = @(
        'DayZero - Linux install stick',
        '=============================',
        '',
        ('System:  {0}' -f $Settings.distroName),
        ('Build:   {0}' -f $Settings.buildId),
        ('Account: {0}' -f $Settings.userName),
        ('Mode:    {0}' -f $Settings.defaultMode),
        '',
        'Boot the PC from this stick (UEFI). The Ubuntu installer reads autoinstall.yaml and only',
        'asks where to install: pick the disk yourself. DayZero never picks or wipes a disk.',
        '',
        'After the first start, DayZero runs once in the background: updates, drivers, the apps of',
        'your mode and your own scripts (dayzero/scripts/*.sh, run as root in name order).',
        'Progress: /var/log/dayzero/setup.log, and a window after you sign in.',
        '',
        'autoinstall.yaml holds the password only as a SHA-512 hash. Delete it from the stick after',
        'installing if you do not want to keep it.'
    )
    return (($lines -join "`n") + "`n")
}

function Write-DzLinuxKitToTarget {
    <#
    .SYNOPSIS
        Writes autoinstall.yaml, the Linux kit (dayzero/), settings.json and a README.
    .PARAMETER KitSource
        The repository's kit folder (kit/linux, kit/lang and kit/Scripts-Linux are used).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [Parameter(Mandatory = $true)][string]$KitSource,
        [Parameter(Mandatory = $true)][string]$AutoinstallYaml,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Settings,
        [scriptblock]$Log
    )
    if (-not (Test-Path -LiteralPath $TargetRoot)) { throw "Target not found: $TargetRoot" }
    if (Test-DzIsLinuxSystemRoot -Path $TargetRoot) { throw 'Refusing to write to the root of the running system. Pick the USB stick or a folder.' }
    if ([string]$Settings.buildId -notmatch '^[0-9a-f]{8}$') { throw 'Settings.buildId must be 8 lowercase hex characters.' }
    $bad = @(Get-DzForbiddenAutoinstallKey -Yaml $AutoinstallYaml)
    if ($bad.Count -gt 0) { throw ('Refusing to write autoinstall.yaml: ' + ($bad -join ' ')) }
    foreach ($k in @($Settings.Keys)) { if ([string]$k -match '(?i)password|secret|hash' -and [string]$k -ne 'temporaryPassword') { throw 'settings.json must not hold a password.' } }

    $answer = Join-Path $TargetRoot 'autoinstall.yaml'
    if (Test-Path -LiteralPath $answer) {
        $backup = Join-Path $TargetRoot ('autoinstall.backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.yaml')
        Move-Item -LiteralPath $answer -Destination $backup -Force
        if ($Log) { & $Log "Existing autoinstall.yaml saved as $(Split-Path -Leaf $backup)" }
    }
    Write-DzLinuxTextFile -Path $answer -Text $AutoinstallYaml
    if ($Log) { & $Log "Wrote $answer" }

    $kit = Join-Path $TargetRoot $script:KitFolder
    if (Test-Path -LiteralPath $kit) { Remove-Item -LiteralPath $kit -Recurse -Force }
    [void](New-Item -ItemType Directory -Path $kit -Force)
    $src = Join-Path $KitSource 'linux'
    foreach ($f in @(Get-ChildItem -LiteralPath $src -File -Recurse)) {
        if ($f.FullName -match '[\\/]__pycache__[\\/]' -or $f.Name -match '^test_' -or $f.Extension -eq '.pyc') { continue }
        $rel = $f.FullName.Substring($src.Length).TrimStart('\', '/')
        $dest = Join-Path $kit $rel
        $dir = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        Copy-DzLinuxFile -Source $f.FullName -Destination $dest
    }
    $lang = Join-Path $KitSource 'lang'
    if (Test-Path -LiteralPath $lang) {
        [void](New-Item -ItemType Directory -Path (Join-Path $kit 'lang') -Force)
        foreach ($f in @(Get-ChildItem -LiteralPath $lang -Filter '*.json' -File)) { Copy-Item -LiteralPath $f.FullName -Destination (Join-Path (Join-Path $kit 'lang') $f.Name) -Force }
    }
    $scripts = Join-Path $KitSource 'Scripts-Linux'
    [void](New-Item -ItemType Directory -Path (Join-Path $kit 'scripts') -Force)
    $count = 0
    if (Test-Path -LiteralPath $scripts) {
        foreach ($f in @(Get-ChildItem -LiteralPath $scripts -Filter '*.sh' -File | Sort-Object Name)) {
            Copy-DzLinuxFile -Source $f.FullName -Destination (Join-Path (Join-Path $kit 'scripts') $f.Name)
            $count++
        }
    }
    if ($Log) { & $Log "Copied the Linux kit to $kit ($count of your scripts)." }

    Write-DzLinuxTextFile -Path (Join-Path $kit 'settings.json') -Text (($Settings | ConvertTo-Json -Depth 6) + "`n")
    Write-DzLinuxTextFile -Path (Join-Path $kit ('build-' + $Settings.buildId + '.marker')) -Text "DayZero build $($Settings.buildId)`n"
    Write-DzLinuxTextFile -Path (Join-Path $TargetRoot 'DayZero-README.txt') -Text (Get-DzLinuxReadmeText -Settings $Settings)
    if ($Log) { & $Log 'Wrote dayzero/settings.json and DayZero-README.txt' }
    return [pscustomobject]@{ AnswerFile = $answer; KitPath = $kit; ScriptCount = $count }
}

function Get-DzFat32Problem {
    <# Files too large for FAT32 (4 GB - 1 byte) under $Root, as text; $null when all fit. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Root)
    $big = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt $script:Fat32MaxFile })
    if ($big.Count -eq 0) { return $null }
    $names = ($big | ForEach-Object { '{0} ({1:N1} GB)' -f $_.Name, ($_.Length / 1GB) }) -join ', '
    return "These files are too large for a FAT32 stick: $names. Write the ISO as-is instead (no DayZero automation)."
}

function Test-DzLinuxStick {
    <# Read-only checks of a Linux stick (or folder). Objects with Name, Ok, Detail. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Root, [switch]$KitOnly)
    $check = { param($name, $ok, $detail) [pscustomobject]@{ Name = $name; Ok = [bool]$ok; Detail = [string]$detail } }
    if (-not $KitOnly) {
        $efi = Join-Path $Root 'EFI/BOOT/BOOTX64.EFI'
        $efiOk = (Test-Path -LiteralPath $efi) -or (@(Get-ChildItem -LiteralPath (Join-Path $Root 'EFI') -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ieq 'bootx64.efi' }).Count -gt 0)
        & $check 'UEFI boot file' $efiOk $(if ($efiOk) { 'EFI/BOOT/BOOTX64.EFI' } else { 'missing: the stick will not boot' })
        $casper = Join-Path $Root 'casper'
        $squash = @(Get-ChildItem -LiteralPath $casper -Filter '*.squashfs' -File -ErrorAction SilentlyContinue)
        & $check 'Ubuntu system files' ($squash.Count -gt 0) $(if ($squash.Count -gt 0) { "$($squash.Count) squashfs files in casper/" } else { 'casper/*.squashfs missing' })
        & $check 'Boot menu' (Test-Path -LiteralPath (Join-Path $Root 'boot/grub/grub.cfg')) 'boot/grub/grub.cfg'
    }
    $answer = Join-Path $Root 'autoinstall.yaml'
    if (Test-Path -LiteralPath $answer) {
        $bad = @(Get-DzForbiddenAutoinstallKey -Yaml (Get-Content -Raw -LiteralPath $answer))
        & $check 'autoinstall.yaml leaves the disk to you' ($bad.Count -eq 0) $(if ($bad.Count -eq 0) { 'storage is interactive' } else { $bad -join ' ' })
    }
    else { & $check 'autoinstall.yaml leaves the disk to you' $false 'autoinstall.yaml is missing' }
    $kit = Join-Path $Root $script:KitFolder
    & $check 'DayZero Linux kit' ((Test-Path -LiteralPath (Join-Path $kit 'dayzero.py')) -and (Test-Path -LiteralPath (Join-Path $kit 'install-kit.sh'))) "$($script:KitFolder)/dayzero.py"
    $settings = Join-Path $kit 'settings.json'
    $sOk = $false
    $detail = 'settings.json missing'
    if (Test-Path -LiteralPath $settings) {
        try { $s = Get-Content -Raw -LiteralPath $settings | ConvertFrom-Json; $sOk = ([string]$s.buildId -match '^[0-9a-f]{8}$'); $detail = "build $($s.buildId)" }
        catch { $detail = 'settings.json is not valid JSON' }
    }
    & $check 'Settings' $sOk $detail
}

Export-ModuleMember -Function @(
    'Get-DzLinuxDataRoot', 'Get-DzLinuxCatalog', 'Get-DzLinuxDistro', 'Test-DzLinuxDownloadUrl',
    'ConvertFrom-DzSha256Sums', 'Select-DzLinuxIso', 'Get-DzFileSha256', 'Get-DzLinuxCacheRoot', 'Get-DzWebText', 'Save-DzWebFile', 'Get-DzLinuxIso',
    'ConvertTo-DzSha512Crypt', 'Test-DzLinuxUserName', 'ConvertTo-DzLinuxUserName', 'Test-DzLinuxHostName',
    'ConvertTo-DzLinuxLocale', 'ConvertTo-DzLinuxTimeZone', 'ConvertTo-DzLinuxKeyboard',
    'ConvertTo-DzYamlString', 'New-DzAutoinstallYaml', 'Get-DzForbiddenAutoinstallKey',
    'Write-DzLinuxKitToTarget', 'Get-DzFat32Problem', 'Test-DzLinuxStick'
)
