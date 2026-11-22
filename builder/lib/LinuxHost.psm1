#Requires -Version 7.2
<#
    DayZero builder on Linux (BuilderCli.ps1 under PowerShell 7): what Get-Disk, diskpart,
    robocopy, Mount-DiskImage, expand.exe and DISM do on Windows, done with lsblk, wipefs,
    parted, mkfs.vfat, mount (or mtools), xorriso/bsdtar, cabextract and wimlib-imagex.

    Safety is the same as on Windows: a disk is offered and erased only when
    Test-DzUsbDiskAllowed (WinMedia.psm1) agrees - USB, not holding the running system,
    not read-only, 7.5 - 300 GB - and it is read again and re-checked right before erasing.
    Nothing here ever touches a disk the user did not pick and confirm.
#>

Set-StrictMode -Version 2.0
# Any error stops the function (also when no caller has a try/catch): never carry on after a failed download or disk step.
$ErrorActionPreference = 'Stop'

$script:SystemMounts = @('/', '/boot', '/boot/efi', '/efi', '/usr', '/var', '/home', '/opt', '/srv', '/nix', '[SWAP]')
$script:UsbLabel = 'DAYZERO'
$script:Fat32MaxFile = 4294967295

function Invoke-DzTool {
    <# Runs a command-line tool, returns ExitCode and Output (stdout + stderr). Throws only when it cannot start. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCompatibleTypes', '', Justification = 'Linux only, PowerShell 7: ProcessStartInfo.ArgumentList passes each argument as-is, with no quoting rules.')]
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$FilePath, [string[]]$ArgumentList = @(), [scriptblock]$Tick, [string]$Activity = '')
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    foreach ($a in $ArgumentList) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.Environment['LC_ALL'] = 'C'
    $psi.Environment['MTOOLS_SKIP_CHECK'] = '1'
    $p = [System.Diagnostics.Process]::Start($psi)
    try {
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        while (-not $p.WaitForExit(500)) { if ($Tick -and $Activity) { & $Tick $Activity } }
        $p.WaitForExit()
        return [pscustomobject]@{ ExitCode = $p.ExitCode; Output = ($outTask.Result + $errTask.Result).Trim() }
    }
    finally { $p.Dispose() }
}

function Assert-DzTool {
    <# Throws a clear message naming the package when a tool is missing. #>
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][string]$Package)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) { throw "$Name is missing. Install the $Package package (for example: sudo apt install $Package) and start again." }
}

# ------------------------------------------------------------------------------------
# Disks
# ------------------------------------------------------------------------------------

function Get-DzLsblkMounts {
    <# Every mount point of a block device and everything inside it (partitions, LVM, crypt). #>
    param([object]$Node)
    $out = New-Object System.Collections.Generic.List[string]
    $mp = @()
    if ($Node.PSObject.Properties['mountpoints']) { $mp = @($Node.mountpoints) }
    elseif ($Node.PSObject.Properties['mountpoint']) { $mp = @($Node.mountpoint) }
    foreach ($m in $mp) { if ($m) { $out.Add([string]$m) } }
    if ($Node.PSObject.Properties['children']) { foreach ($c in @($Node.children)) { foreach ($m in (Get-DzLsblkMounts -Node $c)) { $out.Add($m) } } }
    return $out.ToArray()
}

function ConvertFrom-DzLsblkJson {
    <#
        lsblk -J -b -o NAME,PATH,SIZE,TRAN,RO,MODEL,VENDOR,SERIAL,TYPE,MOUNTPOINTS output -> one
        object per whole disk, shaped like Get-DzUsbDiskCandidate's (so Test-DzUsbDiskAllowed works).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Json)
    $data = $Json | ConvertFrom-Json
    $n = 0
    foreach ($d in @($data.blockdevices)) {
        if ([string]$d.type -ne 'disk') { continue }
        $mounts = @(Get-DzLsblkMounts -Node $d)
        $system = $false
        foreach ($m in $mounts) { if ($script:SystemMounts -contains $m) { $system = $true } }
        $vendor = if ($d.PSObject.Properties['vendor'] -and $d.vendor) { ([string]$d.vendor).Trim() } else { '' }
        $model = if ($d.model) { ([string]$d.model).Trim() } else { '' }
        $name = (($vendor, $model) | Where-Object { $_ }) -join ' '
        if (-not $name) { $name = [string]$d.name }
        $item = [pscustomobject]@{
            Number     = $n
            Path       = [string]$d.path
            Name       = $name
            Serial     = $(if ($d.serial) { ([string]$d.serial).Trim() } else { '' })
            BusType    = $(if ([string]$d.tran -eq 'usb') { 'USB' } else { [string]$d.tran })
            IsSystem   = $system
            IsBoot     = $false
            IsReadOnly = [bool]$d.ro
            Size       = [int64]$d.size
            SizeGB     = [math]::Round(([double]$d.size) / 1GB, 1)
            Letters    = @()
            Mounts     = $mounts
            Volumes    = ($mounts -join ', ')
            Problem    = $null
            Display    = $null
        }
        $item.Problem = Test-DzUsbDiskAllowed -Disk $item
        if ($item.Problem -eq 'Windows is running from it.') { $item.Problem = 'The running system is on it.' }
        $what = if ($item.Volumes) { $item.Volumes } else { 'not mounted' }
        $item.Display = ('{0}  {1} - {2} GB, {3}' -f $item.Path, $item.Name, $item.SizeGB, $what)
        $n++
        $item
    }
}

function Get-DzLinuxUsbDiskCandidate {
    <# Every whole disk lsblk sees, with Problem set when it may not be erased. #>
    [CmdletBinding()]
    param()
    Assert-DzTool -Name 'lsblk' -Package 'util-linux'
    $r = Invoke-DzTool -FilePath 'lsblk' -ArgumentList @('-J', '-b', '-o', 'NAME,PATH,SIZE,TRAN,RO,MODEL,VENDOR,SERIAL,TYPE,MOUNTPOINTS')
    if ($r.ExitCode -ne 0) { throw "lsblk failed: $($r.Output)" }
    return @(ConvertFrom-DzLsblkJson -Json $r.Output)
}

function Get-DzPartitionPath {
    <# '/dev/sdb' -> '/dev/sdb1'; '/dev/mmcblk0', '/dev/nvme0n1', '/dev/loop3' -> '...p1'. #>
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Disk, [int]$Number = 1)
    if ($Disk -match '\d$') { return ('{0}p{1}' -f $Disk, $Number) }
    return ('{0}{1}' -f $Disk, $Number)
}

function Update-DzPartitionTable {
    <# Tells the kernel to read the disk's partition table again and waits for udev. #>
    param([Parameter(Mandatory = $true)][string]$Device)
    if (Get-Command partprobe -ErrorAction SilentlyContinue) { [void](Invoke-DzTool -FilePath 'partprobe' -ArgumentList @($Device)) }
    elseif (Get-Command blockdev -ErrorAction SilentlyContinue) { [void](Invoke-DzTool -FilePath 'blockdev' -ArgumentList @('--rereadpt', $Device)) }
    if (Get-Command udevadm -ErrorAction SilentlyContinue) { [void](Invoke-DzTool -FilePath 'udevadm' -ArgumentList @('settle')) }
}

function Initialize-DzLinuxUsbDisk {
    <#
    .SYNOPSIS
        ERASES the given USB disk. Without -CleanOnly it then makes one FAT32 partition and
        returns its device path ('/dev/sdb1'); with -CleanOnly it returns $null.
    .DESCRIPTION
        $Disk is an item from Get-DzLinuxUsbDiskCandidate. Right before erasing, the disk list
        is read again: it must still be the same device (path, size, serial, name) and still
        allowed. Every partition of it is unmounted first.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Disk,
        [switch]$CleanOnly,
        [scriptblock]$Tick,
        [scriptblock]$Log
    )
    foreach ($t in @(@('wipefs', 'util-linux'), @('parted', 'parted'), @('mkfs.vfat', 'dosfstools'))) { Assert-DzTool -Name $t[0] -Package $t[1] }
    $now = @(Get-DzLinuxUsbDiskCandidate | Where-Object { $_.Path -eq $Disk.Path }) | Select-Object -First 1
    if ($null -eq $now) { throw 'The USB stick is gone. Plug it back in and start again.' }
    if ($now.Size -ne $Disk.Size -or $now.Serial -ne $Disk.Serial -or $now.Name -ne $Disk.Name) { throw 'The drives changed since you picked the USB stick. Start again and pick it again.' }
    if ($now.Problem) { throw "This drive cannot be used: $($now.Problem)" }
    $dev = [string]$now.Path
    if ($dev -notmatch '^/dev/(sd[a-z]+|vd[a-z]+|mmcblk\d+|nvme\d+n\d+|loop\d+)$') { throw "Unexpected device path: $dev" }

    if ($Log) { & $Log ('Erasing {0} ({1}, {2} GB){3}.' -f $dev, $now.Name, $now.SizeGB, $(if ($CleanOnly) { '' } else { ' and formatting it FAT32' })) }
    foreach ($m in @($now.Mounts | Sort-Object Length -Descending)) {
        if ($m -eq '[SWAP]') { throw 'The stick is used as swap. Turn that off first.' }
        $r = Invoke-DzTool -FilePath 'umount' -ArgumentList @($m)
        if ($r.ExitCode -ne 0) { throw "Could not unmount ${m}: $($r.Output). Close every window that shows the stick and try again." }
        if ($Log) { & $Log "Unmounted $m" }
    }
    # Old file system signatures on each partition first, then the partition table itself.
    $parts = @()
    $lp = Invoke-DzTool -FilePath 'lsblk' -ArgumentList @('-ln', '-o', 'PATH,TYPE', $dev)
    foreach ($line in ($lp.Output -split "`n")) { if ($line -match '^(\S+)\s+part\s*$') { $parts += $Matches[1] } }
    foreach ($target in @($parts) + @($dev)) {
        if ($target -ne $dev -and -not $target.StartsWith($dev)) { throw "Unexpected partition $target on $dev." }
        $r = Invoke-DzTool -FilePath 'wipefs' -ArgumentList @('-a', '-f', $target)
        if ($r.ExitCode -ne 0) { throw "Erasing the stick failed (wipefs): $($r.Output)" }
    }
    Update-DzPartitionTable -Device $dev
    if ($CleanOnly) { if ($Log) { & $Log "$dev is erased." }; return $null }

    $mb = Get-DzUsbPartitionSize -DiskBytes $now.Size
    $r = Invoke-DzTool -FilePath 'parted' -ArgumentList @('-s', $dev, 'mklabel', 'msdos', 'mkpart', 'primary', 'fat32', '1MiB', ('{0}MiB' -f ($mb + 1)), 'set', '1', 'boot', 'on') -Tick $Tick -Activity 'Erasing and formatting the USB stick'
    if ($r.ExitCode -ne 0) { throw "Partitioning the stick failed (parted): $($r.Output)" }
    Update-DzPartitionTable -Device $dev
    $part = Get-DzPartitionPath -Disk $dev
    for ($i = 0; $i -lt 40 -and -not (Test-Path -LiteralPath $part); $i++) { if ($Tick) { & $Tick 'Waiting for the new partition...' }; Start-Sleep -Milliseconds 250 }
    if (-not (Test-Path -LiteralPath $part)) { throw "The new partition $part did not appear. Unplug the stick, plug it back in and try again." }
    $r = Invoke-DzTool -FilePath 'mkfs.vfat' -ArgumentList @('-F', '32', '-n', $script:UsbLabel, $part) -Tick $Tick -Activity 'Erasing and formatting the USB stick'
    if ($r.ExitCode -ne 0) { throw "Formatting the stick failed (mkfs.vfat): $($r.Output)" }
    if ($Log) { & $Log "The stick is now $part (FAT32, label $($script:UsbLabel))." }
    return $part
}

# ------------------------------------------------------------------------------------
# Writing files onto the FAT32 partition: mounted, or with mtools when mounting is not possible
# ------------------------------------------------------------------------------------

function Open-DzFatTarget {
    <# Mounts the partition; when the kernel cannot (no vfat), falls back to mtools. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Partition, [scriptblock]$Log)
    $dir = Join-Path '/run/dayzero' ('stick-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void](New-Item -ItemType Directory -Path $dir -Force)
    $r = Invoke-DzTool -FilePath 'mount' -ArgumentList @('-t', 'vfat', '-o', 'utf8,flush', $Partition, $dir)
    if ($r.ExitCode -eq 0) {
        if ($Log) { & $Log "Mounted $Partition at $dir" }
        return [pscustomobject]@{ Kind = 'mount'; Partition = $Partition; Root = $dir }
    }
    Remove-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue
    if (-not (Get-Command mcopy -ErrorAction SilentlyContinue)) { throw "Could not mount $Partition ($($r.Output)), and mtools is not installed to write without mounting." }
    if ($Log) { & $Log "Mounting failed ($($r.Output)); writing with mtools instead." }
    return [pscustomobject]@{ Kind = 'mtools'; Partition = $Partition; Root = $null }
}

function Close-DzFatTarget {
    param([Parameter(Mandatory = $true)][object]$Target, [scriptblock]$Log)
    [void](Invoke-DzTool -FilePath 'sync')
    if ($Target.Kind -eq 'mount') {
        $r = Invoke-DzTool -FilePath 'umount' -ArgumentList @($Target.Root)
        if ($r.ExitCode -ne 0 -and $Log) { & $Log "Could not unmount $($Target.Root): $($r.Output)" }
        Remove-Item -LiteralPath $Target.Root -Force -ErrorAction SilentlyContinue
    }
    if ($Log) { & $Log 'Everything is written to the stick (synced).' }
}

function Copy-DzFileWithProgress {
    param([string]$Source, [string]$Destination, [byte[]]$Buffer, [hashtable]$State, [scriptblock]$Report)
    $in = [System.IO.File]::OpenRead($Source)
    try {
        $out = [System.IO.File]::Create($Destination)
        try {
            while (($n = $in.Read($Buffer, 0, $Buffer.Length)) -gt 0) {
                $out.Write($Buffer, 0, $n)
                $State.Done += $n
                & $Report
            }
        }
        finally { $out.Dispose() }
    }
    finally { $in.Dispose() }
}

function Copy-DzTreeToFat {
    <#
        Copies every file under $Source to the root of the stick, with real progress
        ("<Label>: x of y GB, z MB/s (n%)"). Files over 4 GB are refused (FAT32 cannot hold them).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][object]$Target,
        [string]$Label = 'Copying to the USB stick',
        [string[]]$ExcludeFile = @(),
        [scriptblock]$Tick
    )
    $src = (Resolve-Path -LiteralPath $Source).Path.TrimEnd('/')
    $files = @(Get-ChildItem -LiteralPath $src -Recurse -File -Force | Where-Object { $ExcludeFile -notcontains $_.Name })
    $big = @($files | Where-Object { $_.Length -gt $script:Fat32MaxFile })
    if ($big.Count -gt 0) { throw ('Too large for FAT32: ' + (($big | ForEach-Object { $_.Name }) -join ', ')) }
    $total = [double]0
    foreach ($f in $files) { $total += $f.Length }
    if ($total -lt 1) { $total = 1 }
    $state = @{ Done = [double]0; Next = [double]0 }
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $report = {
        if ($Tick -and $state.Done -ge $state.Next) {
            $speed = $state.Done / 1MB / [math]::Max([double]0.5, $clock.Elapsed.TotalSeconds)
            & $Tick ('{0}: {1:N1} of {2:N1} GB, {3:N0} MB/s ({4:N0}%)' -f $Label, ($state.Done / 1GB), ($total / 1GB), $speed, [math]::Min([double]99, 100 * $state.Done / $total))
            $state.Next = $state.Done + 32MB
        }
    }.GetNewClosure()
    $dirs = @(Get-ChildItem -LiteralPath $src -Recurse -Directory -Force | Sort-Object { $_.FullName.Length })
    if ($Target.Kind -eq 'mount') {
        foreach ($d in $dirs) { [void](New-Item -ItemType Directory -Path (Join-Path $Target.Root $d.FullName.Substring($src.Length)) -Force) }
        $buffer = New-Object byte[] (4MB)
        foreach ($f in $files) {
            Copy-DzFileWithProgress -Source $f.FullName -Destination (Join-Path $Target.Root $f.FullName.Substring($src.Length)) -Buffer $buffer -State $state -Report $report
        }
        return
    }
    # mtools: -i names the partition, '::/path' is the path on it; -D o overwrites.
    foreach ($d in $dirs) {
        $rel = $d.FullName.Substring($src.Length)
        $r = Invoke-DzTool -FilePath 'mmd' -ArgumentList @('-D', 'o', '-i', $Target.Partition, ('::' + $rel))
        if ($r.ExitCode -ne 0 -and $r.Output -notmatch 'exists') { throw "Could not make the folder $rel on the stick: $($r.Output)" }
    }
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($src.Length)
        $r = Invoke-DzTool -FilePath 'mcopy' -ArgumentList @('-o', '-i', $Target.Partition, $f.FullName, ('::' + $rel))
        if ($r.ExitCode -ne 0) { throw "Could not copy $rel to the stick: $($r.Output)" }
        $state.Done += $f.Length
        & $report
    }
}

function Get-DzFatFileList {
    <# Relative paths of every file on the stick (for checking an mtools write). #>
    param([Parameter(Mandatory = $true)][object]$Target)
    if ($Target.Kind -eq 'mount') {
        return @(Get-ChildItem -LiteralPath $Target.Root -Recurse -File -Force | ForEach-Object { $_.FullName.Substring($Target.Root.Length).Replace('\', '/') })
    }
    $r = Invoke-DzTool -FilePath 'mdir' -ArgumentList @('-/', '-b', '-i', $Target.Partition, '::/')
    if ($r.ExitCode -ne 0) { throw "Could not list the stick: $($r.Output)" }
    return @($r.Output -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^::/' -and $_ -notmatch '/$' } | ForEach-Object { $_.Substring(2) })
}

# ------------------------------------------------------------------------------------
# ISO files
# ------------------------------------------------------------------------------------

function Invoke-DzWithIsoContent {
    <#
        Runs $Action with a folder holding the ISO's files: mounted read-only (loop), or, where
        mounting is not possible, extracted with xorriso or bsdtar into $WorkDir (removed after).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$IsoPath,
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$WorkDir,
        [scriptblock]$Tick,
        [scriptblock]$Log
    )
    if (-not (Test-Path -LiteralPath $IsoPath -PathType Leaf)) { throw "ISO file not found: $IsoPath" }
    $dir = Join-Path $WorkDir ('iso-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void](New-Item -ItemType Directory -Path $dir -Force)
    $mounted = $false
    try {
        $r = Invoke-DzTool -FilePath 'mount' -ArgumentList @('-o', 'loop,ro', $IsoPath, $dir)
        if ($r.ExitCode -eq 0) { $mounted = $true; if ($Log) { & $Log "Mounted $IsoPath" } }
        else {
            if ($Log) { & $Log "Mounting the ISO failed ($($r.Output)); unpacking it instead." }
            if (Get-Command xorriso -ErrorAction SilentlyContinue) {
                $r = Invoke-DzTool -FilePath 'xorriso' -ArgumentList @('-osirrox', 'on', '-indev', $IsoPath, '-extract', '/', $dir) -Tick $Tick -Activity 'Unpacking the ISO file'
            }
            elseif (Get-Command bsdtar -ErrorAction SilentlyContinue) {
                $r = Invoke-DzTool -FilePath 'bsdtar' -ArgumentList @('-x', '-f', $IsoPath, '-C', $dir) -Tick $Tick -Activity 'Unpacking the ISO file'
            }
            else { throw 'Cannot open the ISO: mounting failed and neither xorriso nor bsdtar (libarchive-tools) is installed.' }
            if ($r.ExitCode -ne 0) { throw "Unpacking the ISO failed: $($r.Output)" }
            # Extracted files keep the ISO's read-only mode; the copy does not need more.
        }
        & $Action $dir
    }
    finally {
        if ($mounted) { [void](Invoke-DzTool -FilePath 'umount' -ArgumentList @($dir)) }
        else { Get-ChildItem -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Attributes = 'Normal' } catch { Write-Verbose 'attr' } } }
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ------------------------------------------------------------------------------------
# Windows media on Linux (Microsoft's catalogue + wimlib-imagex in place of DISM)
# ------------------------------------------------------------------------------------

function Get-DzWindowsCatalogLinux {
    <# Microsoft's catalogue (products.cab, unpacked with cabextract). Returns the entries. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet(10, 11)][int]$WindowsVersion, [Parameter(Mandatory = $true)][string]$WorkDir)
    Assert-DzTool -Name 'cabextract' -Package 'cabextract'
    $outDir = Join-Path $WorkDir "win$WindowsVersion"
    if (Test-Path -LiteralPath $outDir) { Remove-Item -LiteralPath $outDir -Recurse -Force }
    [void](New-Item -ItemType Directory -Path $outDir -Force)
    $cab = Join-Path $WorkDir "products-win$WindowsVersion.cab"
    if (Test-Path -LiteralPath $cab) { Remove-Item -LiteralPath $cab -Force }
    [void](Save-DzWebFile -Url (Get-DzWindowsCatalogUrl -WindowsVersion $WindowsVersion) -Path $cab)
    $r = Invoke-DzTool -FilePath 'cabextract' -ArgumentList @('-q', '-d', $outDir, $cab)
    $xml = Find-DzCatalogXml -Folder $outDir
    if (-not $xml) { throw "Could not unpack Microsoft's download catalogue: $($r.Output)" }
    $entries = @(ConvertFrom-DzProductsXml -Xml (Get-Content -LiteralPath $xml -Raw -Encoding UTF8))
    if ($entries.Count -eq 0) { throw "Microsoft's download catalogue is empty." }
    return $entries
}

function ConvertFrom-DzWimInfo {
    <# 'wimlib-imagex info' output -> Index/Name objects. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $index = $null
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^Index:\s+(\d+)\s*$') { $index = [int]$Matches[1]; continue }
        if ($null -ne $index -and $line -match '^Name:\s+(.+?)\s*$') {
            [pscustomobject]@{ Index = $index; Name = $Matches[1] }
            $index = $null
        }
    }
}

function Invoke-DzWimlib {
    param([string[]]$ArgumentList, [scriptblock]$Tick, [string]$Activity)
    $r = Invoke-DzTool -FilePath 'wimlib-imagex' -ArgumentList $ArgumentList -Tick $Tick -Activity $Activity
    if ($r.ExitCode -ne 0) { throw "wimlib-imagex $($ArgumentList[0]) failed: $((@($r.Output -split "`n") | Select-Object -Last 3) -join ' ')" }
    return $r
}

function New-DzMediaFromEsdLinux {
    <# Like New-DzMediaFromEsd (WinMedia.psm1), with wimlib-imagex in place of DISM. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$EsdPath,
        [Parameter(Mandatory = $true)][string]$OutDir,
        [scriptblock]$Tick,
        [scriptblock]$Log
    )
    Assert-DzTool -Name 'wimlib-imagex' -Package 'wimtools'
    $info = Invoke-DzWimlib -ArgumentList @('info', $EsdPath)
    $plan = Get-DzEsdImagePlan -Images @(ConvertFrom-DzWimInfo -Text $info.Output)
    if (Test-Path -LiteralPath $OutDir) { Remove-Item -LiteralPath $OutDir -Recurse -Force }
    [void](New-Item -ItemType Directory -Path $OutDir -Force)
    [void](Invoke-DzWimlib -ArgumentList @('apply', $EsdPath, [string]$plan.SetupMedia, $OutDir) -Tick $Tick -Activity 'Unpacking the Windows setup files')
    $sources = Join-Path $OutDir 'sources'
    if (-not (Test-Path -LiteralPath $sources)) { throw 'The setup files have no sources folder.' }
    $boot = Join-Path $sources 'boot.wim'
    [void](Invoke-DzWimlib -ArgumentList @('export', $EsdPath, [string]$plan.WinPE, $boot, '--compress=LZX') -Tick $Tick -Activity 'Unpacking Windows PE')
    [void](Invoke-DzWimlib -ArgumentList @('export', $EsdPath, [string]$plan.Setup, $boot, '--compress=LZX', '--boot') -Tick $Tick -Activity 'Unpacking Windows Setup')
    $install = Join-Path $sources 'install.wim'
    $editions = @(Select-DzEsdEdition -Editions $plan.Editions -Tier standard)
    if ($editions.Count -eq 0) { throw 'The download contains no Windows editions.' }
    $n = 0
    foreach ($e in $editions) {
        $n++
        [void](Invoke-DzWimlib -ArgumentList @('export', $EsdPath, [string]$e.Index, $install, '--compress=LZX') -Tick $Tick -Activity ('Unpacking {0} ({1} of {2}; this is the slow part)' -f $e.Name, $n, $editions.Count))
    }
    $size = (Get-Item -LiteralPath $install).Length
    $names = ($editions | ForEach-Object { $_.Name -replace '^Windows 1[01] ', '' }) -join ', '
    if ($size -gt $script:Fat32MaxFile) {
        Split-DzWimLinux -WimPath $install -Tick $Tick
        Remove-Item -LiteralPath $install -Force
        if ($Log) { & $Log ('Editions on the stick: {0} ({1:N1} GB, split into install.swm parts).' -f $names, ($size / 1GB)) }
    }
    elseif ($Log) { & $Log ('Editions on the stick: {0} (install.wim is {1:N1} GB).' -f $names, ($size / 1GB)) }
    return $OutDir
}

function Split-DzWimLinux {
    <# install.wim -> install.swm, install2.swm, ... (3800 MB parts), next to it. #>
    param([Parameter(Mandatory = $true)][string]$WimPath, [string]$OutDir, [scriptblock]$Tick)
    if (-not $OutDir) { $OutDir = Split-Path -Parent $WimPath }
    $swm = Join-Path $OutDir 'install.swm'
    [void](Invoke-DzWimlib -ArgumentList @('split', $WimPath, $swm, '3800') -Tick $Tick -Activity 'Splitting the Windows image for the USB stick')
    if (-not (Test-Path -LiteralPath $swm)) { throw 'Splitting the Windows image produced no install.swm.' }
}

function Get-DzWindowsMediaTreeLinux {
    <# Like Get-DzWindowsMediaTree: a folder with Windows installation media, made once and reused. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet(10, 11)][int]$WindowsVersion,
        [Parameter(Mandatory = $true)][string]$Language,
        [Parameter(Mandatory = $true)][string]$CacheRoot,
        [scriptblock]$Tick,
        [scriptblock]$Log
    )
    if (-not (Test-Path -LiteralPath $CacheRoot)) { [void](New-Item -ItemType Directory -Path $CacheRoot -Force) }
    $entry = $null
    try {
        if ($Tick) { & $Tick "Asking Microsoft for the current Windows $WindowsVersion download..." }
        $entries = Get-DzWindowsCatalogLinux -WindowsVersion $WindowsVersion -WorkDir (Join-Path $CacheRoot 'catalog')
        $entry = Select-DzWindowsDownload -Entries $entries -Language $Language
    }
    catch {
        $cached = Get-DzPreparedMedia -WindowsVersion $WindowsVersion -Language $Language -CacheRoot $CacheRoot
        if ($cached) { if ($Log) { & $Log "Could not reach Microsoft's catalogue ($($_.Exception.Message)); using the copy from last time." }; return $cached.Path }
        throw "Could not get Microsoft's Windows $WindowsVersion download list: $($_.Exception.Message)"
    }
    if ($null -eq $entry) { throw "Microsoft does not offer Windows $WindowsVersion in $Language. Pick another display language." }
    $cached = Get-DzPreparedMedia -WindowsVersion $WindowsVersion -Language $Language -CacheRoot $CacheRoot -Sha1 $entry.Sha1
    if ($cached) { if ($Log) { & $Log "Using the Windows $WindowsVersion ($Language) files prepared earlier: $($cached.Path)" }; return $cached.Path }
    $name = ('win{0}-{1}-x64-{2}' -f $WindowsVersion, $Language.ToLowerInvariant(), $entry.Sha1.Substring(0, 10))
    $dir = Join-Path $CacheRoot $name
    $esd = Join-Path $CacheRoot ($name + '.esd')
    $haveEsd = (Test-Path -LiteralPath $esd) -and ((Get-Item -LiteralPath $esd).Length -eq $entry.Size)
    if (-not $haveEsd) {
        if ($Log) { & $Log ('Downloading {0} ({1:N1} GB) from {2}' -f $entry.FileName, ($entry.Size / 1GB), ([System.Uri]$entry.Url).Host) }
        [void](Save-DzWebFile -Url $entry.Url -Path $esd -Activity "Downloading Windows $WindowsVersion from Microsoft" -Tick $Tick)
    }
    if ((Get-Item -LiteralPath $esd).Length -ne $entry.Size) { Remove-Item -LiteralPath $esd -Force; throw 'The downloaded file has the wrong size. Try again.' }
    $sha = Get-DzFileSha1 -Path $esd -Tick $Tick
    if ($sha -ne $entry.Sha1) { Remove-Item -LiteralPath $esd -Force; throw 'The downloaded file does not match Microsoft''s checksum, so it was deleted. Try again.' }
    if ($Log) { & $Log "SHA-1 matches Microsoft's catalogue: $sha" }
    [void](New-DzMediaFromEsdLinux -EsdPath $esd -OutDir $dir -Tick $Tick -Log $Log)
    $marker = Join-Path $CacheRoot ($name + '.ready.json')
    [ordered]@{ windowsVersion = $WindowsVersion; language = $Language; sha1 = $entry.Sha1; file = $entry.FileName; preparedAt = (Get-Date).ToString('s'); preparedOn = 'linux' } | ConvertTo-Json | Set-Content -LiteralPath $marker -Encoding UTF8
    Remove-Item -LiteralPath $esd -Force -ErrorAction SilentlyContinue
    return $dir
}

# ------------------------------------------------------------------------------------
# This Linux PC's settings, as Windows / Linux values
# ------------------------------------------------------------------------------------

function Get-DzLinuxHostDefaults {
    <# Culture ('ru-RU'), Windows keyboard id ('0419:00000419'), IANA time zone and Windows time zone of this PC. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCompatibleTypes', '', Justification = 'Linux only, PowerShell 7: TimeZoneInfo.TryConvertIanaIdToWindowsId is .NET 6+.')]
    [CmdletBinding()]
    param([string]$DataRoot)
    $lang = if ($env:LANG) { $env:LANG } else { 'en_US.UTF-8' }
    $culture = 'en-US'
    if ($lang -match '^([a-z]{2,3})_([A-Z]{2})') { $culture = '{0}-{1}' -f $Matches[1], $Matches[2] }
    $iana = 'Etc/UTC'
    if (Test-Path -LiteralPath '/etc/timezone') { $t = (Get-Content -LiteralPath '/etc/timezone' -TotalCount 1).Trim(); if ($t) { $iana = $t } }
    elseif (Test-Path -LiteralPath '/etc/localtime') {
        $target = (Get-Item -LiteralPath '/etc/localtime').Target
        if ($target -and ([string]$target) -match 'zoneinfo/(.+)$') { $iana = $Matches[1] }
    }
    $winTz = 'UTC'
    $out = $null
    try { if ([System.TimeZoneInfo]::TryConvertIanaIdToWindowsId($iana, [ref]$out)) { $winTz = $out } } catch { Write-Verbose 'No IANA conversion here.' }
    $xkb = 'us'
    if (Test-Path -LiteralPath '/etc/default/keyboard') {
        foreach ($l in Get-Content -LiteralPath '/etc/default/keyboard') { if ($l -match '^XKBLAYOUT="?([a-z,]+)"?') { $xkb = $Matches[1] } }
    }
    $layout = @($xkb -split ',' | Where-Object { $_ -and $_ -ne 'us' }) | Select-Object -First 1
    if (-not $layout) { $layout = 'us' }
    if (-not $DataRoot) { $DataRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'linux' }
    $kbData = Get-Content -Raw -LiteralPath (Join-Path $DataRoot 'keyboards.json') | ConvertFrom-Json
    $klid = '00000409'
    foreach ($p in $kbData.layouts.PSObject.Properties) {
        if ([string]$p.Value.layout -eq $layout -and -not $p.Value.PSObject.Properties['variant']) { $klid = $p.Name; break }
    }
    return [pscustomobject]@{
        Culture       = $culture
        InputLocale   = ('{0}:{1}' -f $klid.Substring(4, 4), $klid).ToLowerInvariant()
        TimeZoneIana  = $iana
        TimeZoneWin   = $winTz
    }
}

Export-ModuleMember -Function @(
    'Invoke-DzTool', 'Assert-DzTool', 'ConvertFrom-DzLsblkJson', 'Get-DzLinuxUsbDiskCandidate', 'Get-DzPartitionPath', 'Initialize-DzLinuxUsbDisk',
    'Open-DzFatTarget', 'Close-DzFatTarget', 'Copy-DzTreeToFat', 'Get-DzFatFileList', 'Invoke-DzWithIsoContent',
    'Get-DzWindowsCatalogLinux', 'ConvertFrom-DzWimInfo', 'New-DzMediaFromEsdLinux', 'Split-DzWimLinux', 'Get-DzWindowsMediaTreeLinux', 'Get-DzLinuxHostDefaults'
)
