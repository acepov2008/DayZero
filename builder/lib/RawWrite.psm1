#Requires -Version 5.1
<#
    DayZero builder - write a disk image (a Linux ISO) to a USB stick byte for byte, the way
    Rufus' "DD mode", balenaEtcher or 'dd' do, then read it back and compare.

    Used for Linux ISOs DayZero has no automation for (Fedora, Linux Mint, Debian, ...): they
    are "hybrid" images that boot from a stick only when written whole. The stick must already
    be cleared (Windows: diskpart clean through Initialize-DzUsbDisk -CleanOnly, so no volume is
    mounted; Linux: every partition unmounted), and must have passed Test-DzUsbDiskAllowed.

    The first megabyte (partition table and boot code) is written LAST, so the operating
    system does not find and mount half-written partitions while the rest is copied.
#>

Set-StrictMode -Version 2.0

$script:Chunk = 4MB
$script:Head = 1MB

function Write-DzImageToStream {
    <#
    .SYNOPSIS
        Writes the image to an open, writable, seekable stream (a raw disk), then reads it back.
    .OUTPUTS
        The SHA-256 of what was read back (equal to the image's, or this throws).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$ImagePath,
        [Parameter(Mandatory = $true)][System.IO.Stream]$Stream,
        [int64]$DiskBytes = 0,
        [ValidateSet(512, 4096)][int]$SectorSize = 512,
        [scriptblock]$Tick
    )
    $size = [int64](Get-Item -LiteralPath $ImagePath).Length
    if ($size -lt $script:Head) { throw 'This file is too small to be a bootable disk image.' }
    if ($DiskBytes -gt 0 -and $size -gt $DiskBytes) { throw ('The image needs {0:N1} GB but the stick only holds {1:N1} GB.' -f ($size / 1GB), ($DiskBytes / 1GB)) }
    $tickText = {
        param($verb, $done)
        if ($Tick) { & $Tick ('{0}: {1:N1} of {2:N1} GB ({3:N0}%)' -f $verb, ($done / 1GB), ($size / 1GB), (100 * [double]$done / [double]$size)) }
    }
    $in = [System.IO.File]::OpenRead($ImagePath)
    $imageSha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $buffer = New-Object byte[] $script:Chunk
        # 1. everything after the first megabyte
        $null = $in.Seek($script:Head, [System.IO.SeekOrigin]::Begin)
        $null = $Stream.Seek($script:Head, [System.IO.SeekOrigin]::Begin)
        $done = [int64]$script:Head
        $next = [int64]0
        while (($read = Read-DzFull -Stream $in -Buffer $buffer) -gt 0) {
            $write = Get-DzPaddedLength -Length $read -SectorSize $SectorSize
            if ($write -gt $read) { [System.Array]::Clear($buffer, $read, $write - $read) }
            $Stream.Write($buffer, 0, $write)
            $done += $read
            if ($done -ge $next) { & $tickText 'Writing the image to the USB stick' $done; $next = $done + 64MB }
        }
        # 2. the first megabyte: partition table and boot code
        $head = New-Object byte[] $script:Head
        $null = $in.Seek(0, [System.IO.SeekOrigin]::Begin)
        [void](Read-DzFull -Stream $in -Buffer $head)
        $null = $Stream.Seek(0, [System.IO.SeekOrigin]::Begin)
        $Stream.Write($head, 0, $head.Length)
        $Stream.Flush()
        if ($Stream -is [System.IO.FileStream]) { $Stream.Flush($true) }

        # 3. read back exactly $size bytes and compare with the image
        $null = $in.Seek(0, [System.IO.SeekOrigin]::Begin)
        $null = $Stream.Seek(0, [System.IO.SeekOrigin]::Begin)
        $diskSha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $left = $size
            $other = New-Object byte[] $script:Chunk
            $done = [int64]0
            $next = [int64]0
            while ($left -gt 0) {
                $want = [int][math]::Min([double]$script:Chunk, [double](Get-DzPaddedLength -Length $left -SectorSize $SectorSize))
                $got = Read-DzFull -Stream $Stream -Buffer $buffer -Count $want
                if ($got -lt [math]::Min([double]$want, [double]$left)) { throw 'The USB stick returned less data than was written. It may be faulty or fake (smaller than it claims).' }
                $use = [int][math]::Min([double]$got, [double]$left)
                [void](Read-DzFull -Stream $in -Buffer $other -Count $use)
                [void]$imageSha.TransformBlock($other, 0, $use, $null, 0)
                [void]$diskSha.TransformBlock($buffer, 0, $use, $null, 0)
                $left -= $use
                $done += $use
                if ($done -ge $next) { & $tickText 'Checking what was written' $done; $next = $done + 64MB }
            }
            [void]$imageSha.TransformFinalBlock($buffer, 0, 0)
            [void]$diskSha.TransformFinalBlock($buffer, 0, 0)
            $a = ($imageSha.Hash | ForEach-Object { $_.ToString('x2') }) -join ''
            $b = ($diskSha.Hash | ForEach-Object { $_.ToString('x2') }) -join ''
            if ($a -ne $b) { throw 'What the USB stick returned differs from the image. The stick may be faulty or fake; try another one.' }
            return $b
        }
        finally { $diskSha.Dispose() }
    }
    finally {
        $imageSha.Dispose()
        $in.Dispose()
    }
}

function Read-DzFull {
    <# Reads until $Count bytes or the end; streams may return less per call. #>
    param([System.IO.Stream]$Stream, [byte[]]$Buffer, [int]$Count = -1)
    if ($Count -lt 0) { $Count = $Buffer.Length }
    $total = 0
    while ($total -lt $Count) {
        $n = $Stream.Read($Buffer, $total, $Count - $total)
        if ($n -le 0) { break }
        $total += $n
    }
    return $total
}

function Get-DzPaddedLength {
    <# $Length rounded up to whole sectors (a raw disk only takes whole sectors). #>
    [OutputType([int64])]
    param([int64]$Length, [int]$SectorSize = 512)
    return [int64]([math]::Ceiling([double]$Length / $SectorSize) * $SectorSize)
}

function Open-DzRawDisk {
    <#
    .SYNOPSIS
        Opens a whole disk for raw reading and writing: \\.\PhysicalDrive<Number> on Windows,
        a /dev path on Linux. Only call this for a disk that passed Test-DzUsbDiskAllowed.
    #>
    [CmdletBinding()]
    param([int]$Number = -1, [string]$DevicePath)
    if ($DevicePath) {
        if ($DevicePath -notmatch '^/dev/(sd[a-z]+|mmcblk[0-9]+|nvme[0-9]+n[0-9]+|vd[a-z]+|loop[0-9]+)$') { throw "Not a whole-disk device path: $DevicePath" }
        return (New-Object System.IO.FileStream($DevicePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::ReadWrite, 1))
    }
    if ($Number -lt 0 -or $Number -gt 99) { throw 'Disk number missing.' }
    if (-not ('DayZero.RawDisk' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace DayZero {
    public static class RawDisk {
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern SafeFileHandle CreateFile(string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
        public static SafeFileHandle Open(int number) {
            // GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, OPEN_EXISTING, FILE_FLAG_WRITE_THROUGH
            SafeFileHandle h = CreateFile(@"\\.\PhysicalDrive" + number, 0xC0000000, 3, IntPtr.Zero, 3, 0x80000000, IntPtr.Zero);
            if (h.IsInvalid) { throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()); }
            return h;
        }
    }
}
'@
    }
    $handle = [DayZero.RawDisk]::Open($Number)
    # Buffer size 1 = no extra buffering, so every read and write stays sector-aligned.
    return (New-Object System.IO.FileStream($handle, [System.IO.FileAccess]::ReadWrite, 1))
}

Export-ModuleMember -Function @('Write-DzImageToStream', 'Get-DzPaddedLength', 'Open-DzRawDisk')
