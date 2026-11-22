#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Tests for builder\lib\RawWrite.psm1 (whole-image writes for Linux ISOs) and the clean-only
# diskpart script that comes before it.

BeforeAll {
    $script:Repo = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:Repo 'builder/lib/RawWrite.psm1') -Force
    Import-Module (Join-Path $script:Repo 'builder/lib/WinMedia.psm1') -Force
    $script:NewImage = {
        param([int]$Length)
        $p = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.iso')
        $bytes = New-Object byte[] $Length
        (New-Object System.Random 7).NextBytes($bytes)
        [System.IO.File]::WriteAllBytes($p, $bytes)
        return $p
    }
}

Describe 'Write-DzImageToStream' {
    It 'writes the image byte for byte and returns the SHA-256 read back' {
        $img = & $script:NewImage (3MB + 2048)
        $disk = New-Object System.IO.MemoryStream
        $hash = Write-DzImageToStream -ImagePath $img -Stream $disk
        $written = $disk.ToArray()
        $want = [System.IO.File]::ReadAllBytes($img)
        $written.Length | Should -Be $want.Length
        [System.Linq.Enumerable]::SequenceEqual([byte[]]$written, [byte[]]$want) | Should -BeTrue
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $hash | Should -Be (($sha.ComputeHash($want) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    It 'pads the last piece to whole sectors with zeros' {
        $img = & $script:NewImage (1MB + 100)
        $disk = New-Object System.IO.MemoryStream
        [void](Write-DzImageToStream -ImagePath $img -Stream $disk)
        $out = $disk.ToArray()
        $out.Length | Should -Be (1MB + 512)
        @($out[(1MB + 100)..(1MB + 511)] | Where-Object { $_ -ne 0 }).Count | Should -Be 0
    }
    It 'refuses an image larger than the stick or too small to boot' {
        $img = & $script:NewImage (2MB)
        { Write-DzImageToStream -ImagePath $img -Stream (New-Object System.IO.MemoryStream) -DiskBytes 1MB } | Should -Throw '*only holds*'
        $tiny = & $script:NewImage 4096
        { Write-DzImageToStream -ImagePath $tiny -Stream (New-Object System.IO.MemoryStream) } | Should -Throw '*too small*'
    }
    It 'fails when the stick cannot hold what was written' {
        $img = & $script:NewImage (3MB)
        $small = New-Object System.IO.MemoryStream (, (New-Object byte[] (2MB)))
        { Write-DzImageToStream -ImagePath $img -Stream $small } | Should -Throw
    }
    It 'reports progress' {
        $img = & $script:NewImage (2MB)
        $seen = New-Object System.Collections.Generic.List[string]
        [void](Write-DzImageToStream -ImagePath $img -Stream (New-Object System.IO.MemoryStream) -Tick { param($t) $seen.Add($t) })
        @($seen | Where-Object { $_ -like 'Writing the image*' }).Count | Should -BeGreaterThan 0
        @($seen | Where-Object { $_ -like 'Checking what was written*' }).Count | Should -BeGreaterThan 0
    }
    It 'rounds to whole sectors' {
        Get-DzPaddedLength -Length 1 | Should -Be 512
        Get-DzPaddedLength -Length 512 | Should -Be 512
        Get-DzPaddedLength -Length 513 -SectorSize 4096 | Should -Be 4096
    }
    It 'opens only whole-disk device paths on Linux' {
        { Open-DzRawDisk -DevicePath '/dev/sda1' } | Should -Throw '*whole-disk*'
        { Open-DzRawDisk -DevicePath '/etc/passwd' } | Should -Throw '*whole-disk*'
    }
}

Describe 'Clean-only diskpart script' {
    It 'only selects and cleans the disk, nothing else' {
        $s = New-DzDiskpartScript -DiskNumber 3 -PartitionMB 15000 -CleanOnly
        $s | Should -Be "select disk 3`r`nclean`r`nexit`r`n"
    }
    It 'still makes the FAT32 script by default' {
        New-DzDiskpartScript -DiskNumber 3 -PartitionMB 15000 | Should -Match 'format fs=fat32'
    }
}

Describe 'Safety of the raw writer' {
    It 'never erases or formats anything itself, and checks sizes as [double]' {
        $src = Get-Content -Raw -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'builder/lib/RawWrite.psm1')
        $src = [regex]::Replace($src, '(?s)<#.*?#>', '')
        $src = [regex]::Replace($src, '(?m)^\s*(#|//).*$', '')
        $src | Should -Not -Match "diskpart|'clean'|Clear-Disk|Format-Volume|wipefs|mkfs"
        foreach ($m in [regex]::Matches($src, '\[math\]::(Max|Min)\(([^,]+),')) { $m.Groups[2].Value | Should -Match '^\[double\]' -Because $m.Value }
    }
}
