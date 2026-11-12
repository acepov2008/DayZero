#Requires -Version 5.1
<#
.SYNOPSIS
    Packs a DayZero export folder (autounattend.xml + DayZero\) into a small ISO for VM testing.
.DESCRIPTION
    Virtual machines cannot easily use a real USB stick, so for testing you:
      1. In the builder, choose "Folder (to test in a virtual machine)" and export.
      2. Run this script to turn that folder into DayZero-test.iso.
      3. Attach the Windows ISO as the first DVD drive and this ISO as a second one.
    Windows Setup looks for autounattend.xml in the root of every removable and CD/DVD
    drive, and DayZero finds its folder by the build marker, so this works like the USB.

    Uses the IMAPI2 file-system COM object built into Windows; no extra tools needed.
.EXAMPLE
    .\tools\New-DzTestIso.ps1 -SourceFolder D:\DayZeroExport
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SourceFolder,
    [string]$IsoPath,
    [string]$VolumeName = 'DAYZERO'
)

$ErrorActionPreference = 'Stop'
$SourceFolder = (Resolve-Path -LiteralPath $SourceFolder).Path
if (-not (Test-Path -LiteralPath (Join-Path $SourceFolder 'autounattend.xml'))) {
    throw "No autounattend.xml in $SourceFolder. Export from the DayZero Builder first."
}
if (-not $IsoPath) { $IsoPath = Join-Path (Split-Path -Parent $SourceFolder) 'DayZero-test.iso' }
if (Test-Path -LiteralPath $IsoPath) { Remove-Item -LiteralPath $IsoPath -Force }

if (-not ('DayZero.IsoWriter' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices.ComTypes;
namespace DayZero {
    public static class IsoWriter {
        public static void Write(object comStream, string path, int blockSize, int totalBlocks) {
            IStream stream = (IStream)comStream;
            byte[] buffer = new byte[blockSize];
            using (FileStream file = File.Create(path)) {
                for (int i = 0; i < totalBlocks; i++) {
                    stream.Read(buffer, blockSize, IntPtr.Zero);
                    file.Write(buffer, 0, blockSize);
                }
            }
        }
    }
}
'@
}

$image = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
$image.FileSystemsToCreate = 7   # ISO9660 + Joliet + UDF
$image.VolumeName = $VolumeName
$image.Root.AddTree($SourceFolder, $false)
$result = $image.CreateResultImage()
[DayZero.IsoWriter]::Write($result.ImageStream, $IsoPath, $result.BlockSize, $result.TotalBlocks)
Write-Output "Created $IsoPath"
