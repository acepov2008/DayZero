#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Tests for builder/lib/LinuxHost.psm1 (the builder on Linux). The parsing tests run anywhere
# PowerShell 7 runs. The disk tests need Linux, root, losetup, parted, mkfs.vfat and mtools: they
# use a loop device (a file pretending to be a disk). Loop devices are never offered as USB
# sticks, so those tests replace the disk list inside the module instead of weakening the check.
# Set DAYZERO_E2E_ISO to an Ubuntu Desktop ISO to also make a whole Ubuntu stick on a loop device.

BeforeDiscovery {
    $script:IsLinuxRoot = $IsLinux -and ((& id -u) -eq '0')
    $script:CanLoop = $script:IsLinuxRoot -and [bool](Get-Command losetup -ErrorAction SilentlyContinue) -and [bool](Get-Command parted -ErrorAction SilentlyContinue) -and
        [bool](Get-Command mkfs.vfat -ErrorAction SilentlyContinue) -and [bool](Get-Command mcopy -ErrorAction SilentlyContinue)
    $script:CanIso = $script:CanLoop -and [bool](Get-Command xorriso -ErrorAction SilentlyContinue)
    $script:E2eIso = if ($env:DAYZERO_E2E_ISO -and (Test-Path -LiteralPath $env:DAYZERO_E2E_ISO)) { $env:DAYZERO_E2E_ISO } else { $null }
}

BeforeAll {
    $script:Repo = Split-Path -Parent $PSScriptRoot
    $env:MTOOLS_SKIP_CHECK = '1'
    if ($PSVersionTable.PSVersion.Major -lt 7) { return }
    foreach ($m in 'WinMedia.psm1', 'Linux.psm1', 'RawWrite.psm1', 'LinuxHost.psm1') { Import-Module (Join-Path $script:Repo "builder/lib/$m") -Force }
    $script:Lsblk = @'
{"blockdevices": [
 {"name":"nvme0n1","path":"/dev/nvme0n1","size":512110190592,"tran":"nvme","ro":false,"model":"Samsung SSD","vendor":null,"serial":"S1","type":"disk","mountpoints":[null],
  "children":[{"name":"nvme0n1p1","path":"/dev/nvme0n1p1","type":"part","mountpoints":["/boot/efi"]},{"name":"nvme0n1p2","path":"/dev/nvme0n1p2","type":"part","mountpoints":[null],
   "children":[{"name":"vg-root","path":"/dev/mapper/vg-root","type":"lvm","mountpoints":["/"]}]}]},
 {"name":"sdb","path":"/dev/sdb","size":15664676864,"tran":"usb","ro":false,"model":"DataTraveler 3.0","vendor":"Kingston","serial":"ABC123","type":"disk","mountpoints":[null],
  "children":[{"name":"sdb1","path":"/dev/sdb1","type":"part","mountpoints":["/media/ivan/STICK"]}]},
 {"name":"sdc","path":"/dev/sdc","size":2000398934016,"tran":"usb","ro":false,"model":"Portable","vendor":"WD","serial":"X","type":"disk","mountpoints":[null]},
 {"name":"sdd","path":"/dev/sdd","size":31037849600,"tran":"usb","ro":false,"model":"Boot stick","vendor":"","serial":"Y","type":"disk","mountpoints":[null],
  "children":[{"name":"sdd1","path":"/dev/sdd1","type":"part","mountpoints":["/"]}]},
 {"name":"sde","path":"/dev/sde","size":15664676864,"tran":"usb","ro":true,"model":"Locked","vendor":"","serial":"Z","type":"disk","mountpoints":[null]},
 {"name":"loop0","path":"/dev/loop0","size":15664676864,"tran":null,"ro":false,"model":null,"serial":null,"type":"loop","mountpoints":["/snap/core/1"]}
]}
'@
}

Describe 'Reading the disk list (lsblk)' -Skip:($PSVersionTable.PSVersion.Major -lt 7) {
    It 'offers only a USB stick that does not hold the running system' {
        $d = @(ConvertFrom-DzLsblkJson -Json $script:Lsblk)
        $d.Count | Should -Be 5
        $ok = @($d | Where-Object { -not $_.Problem })
        $ok.Count | Should -Be 1
        $ok[0].Path | Should -Be '/dev/sdb'
        $ok[0].Name | Should -Be 'Kingston DataTraveler 3.0'
        $ok[0].Mounts | Should -Be @('/media/ivan/STICK')
    }
    It 'refuses the internal disk, a big drive, the stick the system runs from and a locked stick' {
        $d = @(ConvertFrom-DzLsblkJson -Json $script:Lsblk)
        ($d | Where-Object Path -eq '/dev/nvme0n1').Problem | Should -Match 'not a USB'
        ($d | Where-Object Path -eq '/dev/nvme0n1').IsSystem | Should -BeTrue
        ($d | Where-Object Path -eq '/dev/sdc').Problem | Should -Match '300 GB'
        ($d | Where-Object Path -eq '/dev/sdd').Problem | Should -Match 'running system'
        ($d | Where-Object Path -eq '/dev/sde').Problem | Should -Match 'write-protected'
    }
    It 'never lists loop devices, partitions or LVM volumes as disks' {
        @(ConvertFrom-DzLsblkJson -Json $script:Lsblk | Where-Object { $_.Path -match 'loop|p\d$|mapper' }).Count | Should -Be 0
    }
    It 'names the first partition of each kind of disk' {
        Get-DzPartitionPath -Disk '/dev/sdb' | Should -Be '/dev/sdb1'
        Get-DzPartitionPath -Disk '/dev/nvme0n1' | Should -Be '/dev/nvme0n1p1'
        Get-DzPartitionPath -Disk '/dev/mmcblk0' | Should -Be '/dev/mmcblk0p1'
        Get-DzPartitionPath -Disk '/dev/loop7' | Should -Be '/dev/loop7p1'
    }
    It 'reads the images in a Windows .esd from wimlib-imagex info' {
        $info = "WIM Information:`n----------------`nImage Count:      3`n`nAvailable Images:`n-----------------`nIndex:                  1`nName:                   Windows Setup Media`nDescription:            x`n`nIndex:                  2`nName:                   Microsoft Windows PE (amd64)`n`nIndex:                  3`nName:                   Microsoft Windows Setup (amd64)`n`nIndex:                  4`nName:                   Windows 11 Pro`n"
        $imgs = @(ConvertFrom-DzWimInfo -Text $info)
        $imgs.Count | Should -Be 4
        $imgs[3].Name | Should -Be 'Windows 11 Pro'
        $plan = Get-DzEsdImagePlan -Images $imgs
        $plan.SetupMedia | Should -Be 1
        $plan.WinPE | Should -Be 2
        $plan.Setup | Should -Be 3
        @($plan.Editions).Count | Should -Be 1
    }
}

Describe 'Safety of the Linux disk code' {
    It 're-checks the disk and its permission right before erasing, and erases nothing else' {
        $src = Get-Content -Raw -LiteralPath (Join-Path $script:Repo 'builder/lib/LinuxHost.psm1')
        $body = [regex]::Match($src, '(?s)function Initialize-DzLinuxUsbDisk \{.*?\n\}\r?\n').Value
        $body.IndexOf('$now.Problem') | Should -BeGreaterThan 0
        $body.IndexOf('$now.Problem') | Should -BeLessThan $body.IndexOf("-FilePath 'wipefs'")
        $body.IndexOf('$now.Serial -ne $Disk.Serial') | Should -BeLessThan $body.IndexOf("-FilePath 'wipefs'")
        $code = [regex]::Replace($src, '(?s)<#.*?#>', '')
        [regex]::Matches($code, "'wipefs'").Count | Should -Be 2   # Assert-DzTool + the one call
        [regex]::Matches($code, "'mkfs\.vfat'").Count | Should -Be 2
        $code | Should -Not -Match "'dd'|'sgdisk'|'mkfs\.ext|'shred'|blkdiscard"
    }
}

Describe 'Disk work on a loop device' -Skip:(-not $script:CanLoop) {
    BeforeAll {
        $script:Img = Join-Path $TestDrive 'stick.img'
        & truncate -s 9G $script:Img
        $script:Loop = (& losetup -f --show -P $script:Img).Trim()
        $script:Fake = [pscustomobject]@{
            Number = 0; Path = $script:Loop; Name = 'Test stick'; Serial = 'T1'; BusType = 'USB'; IsSystem = $false; IsBoot = $false; IsReadOnly = $false
            Size = [int64](9GB); SizeGB = 9; Letters = @(); Mounts = @(); Volumes = ''; Problem = $null; Display = 'test'
        }
        $fake = $script:Fake
        Mock -ModuleName LinuxHost Get-DzLinuxUsbDiskCandidate { $fake }.GetNewClosure()
    }
    AfterAll { if ($script:Loop) { & losetup -d $script:Loop 2>$null } }

    It 'refuses when the disk changed since it was picked' {
        $other = $script:Fake.PSObject.Copy()
        $other.Serial = 'other'
        { Initialize-DzLinuxUsbDisk -Disk $other } | Should -Throw '*changed*'
    }
    It 'makes one FAT32 partition, writes a tree to it and reads the same files back' {
        $part = Initialize-DzLinuxUsbDisk -Disk $script:Fake
        $part | Should -Be ($script:Loop + 'p1')
        (& blkid -o value -s TYPE $part) | Should -Be 'vfat'
        (& blkid -o value -s LABEL $part) | Should -Be 'DAYZERO'
        $src = Join-Path $TestDrive 'tree'
        [void](New-Item -ItemType Directory -Path (Join-Path $src 'casper/sub') -Force)
        [System.IO.File]::WriteAllText((Join-Path $src 'casper/a.squashfs'), ('x' * 100000))
        [System.IO.File]::WriteAllText((Join-Path $src 'casper/sub/b.txt'), 'hello')
        [System.IO.File]::WriteAllText((Join-Path $src 'autoinstall.yaml'), 'autoinstall:')
        $t = Open-DzFatTarget -Partition $part
        try {
            Copy-DzTreeToFat -Source $src -Target $t
            $files = @(Get-DzFatFileList -Target $t | Sort-Object)
            $files | Should -Be @('/autoinstall.yaml', '/casper/a.squashfs', '/casper/sub/b.txt')
            if ($t.Kind -eq 'mtools') { (& mtype -i $part '::/casper/sub/b.txt') | Should -Be 'hello' }
            else { Get-Content -Raw (Join-Path $t.Root 'casper/sub/b.txt') | Should -Be 'hello' }
        }
        finally { Close-DzFatTarget -Target $t }
    }
    It 'erases only (no partition) for a raw image, then writes and reads it back' {
        $null = Initialize-DzLinuxUsbDisk -Disk $script:Fake -CleanOnly
        (& lsblk -n -o NAME $script:Loop | Measure-Object).Count | Should -Be 1
        $iso = Join-Path $TestDrive 'raw.iso'
        $bytes = New-Object byte[] (3MB)
        (New-Object System.Random 3).NextBytes($bytes)
        $bytes[510] = 0x55; $bytes[511] = 0xAA
        [System.IO.File]::WriteAllBytes($iso, $bytes)
        $s = Open-DzRawDisk -DevicePath $script:Loop
        try { $hash = Write-DzImageToStream -ImagePath $iso -Stream $s -DiskBytes $script:Fake.Size } finally { $s.Dispose() }
        $hash | Should -Be (Get-FileHash -LiteralPath $iso -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

Describe 'ISO files on Linux' -Skip:(-not $script:CanIso) {
    It 'opens an ISO (mounted, or unpacked when mounting is not possible) and cleans up' {
        $src = Join-Path $TestDrive 'isosrc'
        [void](New-Item -ItemType Directory -Path (Join-Path $src 'casper') -Force)
        [System.IO.File]::WriteAllText((Join-Path $src 'casper/filesystem.squashfs'), 'sq')
        $iso = Join-Path $TestDrive 'test.iso'
        & xorriso -as mkisofs -quiet -r -J -o $iso $src 2>$null
        $work = Join-Path $TestDrive 'work'
        $seen = @{}
        Invoke-DzWithIsoContent -IsoPath $iso -WorkDir $work -Action { param($root) $seen.Files = @(Get-ChildItem -LiteralPath $root -Recurse -File | ForEach-Object Name) }
        $seen.Files | Should -Contain 'filesystem.squashfs'
        @(Get-ChildItem -LiteralPath $work -Force).Count | Should -Be 0
    }
}

Describe 'A whole Ubuntu stick on a loop device (DAYZERO_E2E_ISO)' -Skip:(-not ($script:CanIso -and $script:E2eIso)) {
    BeforeAll {
        $script:Img = Join-Path $TestDrive 'ubuntu.img'
        & truncate -s 16G $script:Img
        $script:Loop = (& losetup -f --show -P $script:Img).Trim()
        $fake = [pscustomobject]@{
            Number = 0; Path = $script:Loop; Name = 'Test stick'; Serial = 'T2'; BusType = 'USB'; IsSystem = $false; IsBoot = $false; IsReadOnly = $false
            Size = [int64](16GB); SizeGB = 16; Letters = @(); Mounts = @(); Volumes = ''; Problem = $null; Display = 'test'
        }
        $script:Fake = $fake
        Mock -ModuleName LinuxHost Get-DzLinuxUsbDiskCandidate { $fake }.GetNewClosure()
    }
    AfterAll { if ($script:Loop) { & losetup -d $script:Loop 2>$null } }
    It 'copies Ubuntu, adds autoinstall.yaml and the kit, and the stick has everything' {
        $kit = Join-Path $script:Repo 'kit'
        $yaml = New-DzAutoinstallYaml -Options @{
            UserName = 'ivan'; FullName = ''; HostName = ''; PasswordHash = (ConvertTo-DzSha512Crypt -Password 'test'); Locale = 'ru_RU.UTF-8'
            Keyboard = @{ Layout = 'us,ru'; Variant = ','; Toggle = 'alt_shift_toggle' }; TimeZone = 'Europe/Moscow'; BuildId = 'e2e0e2e0'; Drivers = $true; Codecs = $true
        }
        $settings = [ordered]@{ buildId = 'e2e0e2e0'; distro = 'ubuntu-iso'; distroName = 'Ubuntu'; userName = 'ivan'; defaultMode = 'gaming'; apps = @('steam'); appsExact = $true; appLanguage = 'ru' }
        $staging = Join-Path $TestDrive 'staging'
        [void](New-Item -ItemType Directory -Path $staging)
        $part = Initialize-DzLinuxUsbDisk -Disk $script:Fake
        $t = Open-DzFatTarget -Partition $part
        try {
            Invoke-DzWithIsoContent -IsoPath $env:DAYZERO_E2E_ISO -WorkDir (Join-Path $TestDrive 'w') -Action {
                param($root)
                Get-DzFat32Problem -Root $root | Should -BeNullOrEmpty
                Copy-DzTreeToFat -Source $root -Target $t -Label 'Copying Ubuntu to the USB stick'
                $script:IsoCount = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force).Count
            }
            [void](Write-DzLinuxKitToTarget -TargetRoot $staging -KitSource $kit -AutoinstallYaml $yaml -Settings $settings)
            Copy-DzTreeToFat -Source $staging -Target $t
            $files = @(Get-DzFatFileList -Target $t)
            $files | Should -Contain '/EFI/boot/bootx64.efi'
            $files | Should -Contain '/boot/grub/grub.cfg'
            $files | Should -Contain '/autoinstall.yaml'
            $files | Should -Contain '/dayzero/install-kit.sh'
            @($files | Where-Object { $_ -like '/casper/*.squashfs' }).Count | Should -BeGreaterThan 2
            $files.Count | Should -Be ($script:IsoCount + @(Get-ChildItem -LiteralPath $staging -Recurse -File).Count)
        }
        finally { Close-DzFatTarget -Target $t }
    }
}

Describe 'The terminal builder, start to finish, on a loop device' -Skip:(-not $script:CanIso) {
    BeforeAll {
        $script:Img = Join-Path $TestDrive 'cli.img'
        & truncate -s 9G $script:Img
        $script:Loop = (& losetup -f --show -P $script:Img).Trim()
        # A small ISO laid out like Ubuntu Desktop.
        $src = Join-Path $TestDrive 'ubuntu-like'
        foreach ($f in 'casper/minimal.squashfs', 'casper/vmlinuz', 'EFI/boot/bootx64.efi', 'boot/grub/grub.cfg', '.disk/info') {
            $p = Join-Path $src $f
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $p) -Force)
            [System.IO.File]::WriteAllText($p, ('data ' + $f))
        }
        $script:Iso = Join-Path $TestDrive 'ubuntu-like.iso'
        & xorriso -as mkisofs -quiet -r -J -o $script:Iso $src 2>$null
        # Runs BuilderCli.ps1 in its own pwsh. Only there, the disk list is replaced by the loop
        # device (in the module and for the script), because loop devices are never offered.
        $script:Wrapper = Join-Path $TestDrive 'run-cli.ps1'
        $fake = "[pscustomobject]@{ Number = 0; Path = '$($script:Loop)'; Name = 'Test stick'; Serial = 'T3'; BusType = 'USB'; IsSystem = `$false; IsBoot = `$false; IsReadOnly = `$false; Size = [int64]9663676416; SizeGB = 9; Letters = @(); Mounts = @(); Volumes = ''; Problem = `$null; Display = '$($script:Loop) Test stick - 9 GB' }"
        @"
foreach (`$m in 'Core', 'Lang', 'Config') { Import-Module '$($script:Repo)/kit/lib/' + `$m + '.psm1' -DisableNameChecking }
foreach (`$m in 'Unattend', 'UsbWriter', 'WinMedia', 'Linux', 'RawWrite', 'LinuxHost') { Import-Module ('$($script:Repo)/builder/lib/' + `$m + '.psm1') -DisableNameChecking }
`$fake = [scriptblock]::Create("$($fake.Replace('"', '`"').Replace('$', '`$'))")
& (Get-Module LinuxHost) { param(`$f) Set-Item -Path function:script:Get-DzLinuxUsbDiskCandidate -Value `$f } `$fake
Set-Item -Path function:global:Get-DzLinuxUsbDiskCandidate -Value `$fake
& '$($script:Repo)/builder/BuilderCli.ps1' @args
exit `$LASTEXITCODE
"@ | Set-Content -LiteralPath $script:Wrapper -Encoding UTF8
        $script:RunCli = {
            param([string[]]$CliArgs, [string]$Stdin)
            $psi = New-Object System.Diagnostics.ProcessStartInfo 'pwsh'
            foreach ($a in @('-NoProfile', '-NonInteractive', '-File', $script:Wrapper) + $CliArgs) { $psi.ArgumentList.Add($a) }
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.Environment['DAYZERO_CACHE'] = (Join-Path $TestDrive 'cache')
            $p = [System.Diagnostics.Process]::Start($psi)
            $p.StandardInput.Write($Stdin)
            $p.StandardInput.Close()
            $out = $p.StandardOutput.ReadToEndAsync()
            $err = $p.StandardError.ReadToEndAsync()
            $p.WaitForExit()
            return [pscustomobject]@{ Code = $p.ExitCode; Output = $out.Result + $err.Result }
        }
        $script:Args = @('-System', 'ubuntu-iso', '-IsoPath', $script:Iso, '-Disk', $script:Loop, '-UserName', 'ivan', '-FullName', 'Ivan', '-ComputerName', 'ivan-pc',
            '-Language', 'ru-RU', '-Keyboard', '0419:00000419', '-TimeZone', 'Europe/Moscow', '-Mode', 'gaming', '-PasswordStdin', '-AppLanguage', 'en')
    }
    AfterAll { if ($script:Loop) { & losetup -d $script:Loop 2>$null } }

    It 'stops without touching the stick when the typed name does not match' {
        $r = & $script:RunCli $script:Args "secret1`nwrong`n"
        $r.Code | Should -Be 2 -Because $r.Output
        $r.Output | Should -Match 'Cancelled'
        (& blkid -o value -s TYPE ($script:Loop + 'p1') 2>$null) | Should -BeNullOrEmpty
    }
    It 'makes the stick: Ubuntu files, autoinstall.yaml that leaves the disk to you, and the kit' {
        $leaf = Split-Path -Leaf $script:Loop
        $r = & $script:RunCli $script:Args "secret1`n$leaf`n"
        $r.Code | Should -Be 0 -Because $r.Output
        $r.Output | Should -Match 'All done'
        $part = $script:Loop + 'p1'
        $list = (& mdir -/ -b -i $part '::/') -join "`n"
        foreach ($f in '::/casper/minimal.squashfs', '::/EFI/boot/bootx64.efi', '::/autoinstall.yaml', '::/dayzero/dayzero.py', '::/dayzero/install-kit.sh', '::/dayzero/settings.json', '::/DayZero-README.txt') {
            $list | Should -Match ([regex]::Escape($f))
        }
        $yaml = (& mtype -i $part '::/autoinstall.yaml') -join "`n"
        $yaml | Should -Match "username: 'ivan'"
        $yaml | Should -Match "hostname: 'ivan-pc'"
        $yaml | Should -Match "layout: 'us,ru'"
        $yaml | Should -Match "timezone: 'Europe/Moscow'"
        $yaml | Should -Match '(?m)^  interactive-sections:\n    - storage$'
        $yaml | Should -Not -Match 'secret1'
        @(Get-DzForbiddenAutoinstallKey -Yaml $yaml).Count | Should -Be 0
        $settings = (& mtype -i $part '::/dayzero/settings.json') -join "`n" | ConvertFrom-Json
        $settings.userName | Should -Be 'ivan'
        @($settings.apps) | Should -Contain 'steam'
        $settings.PSObject.Properties.Name | Should -Not -Contain 'password'
    }
    It 'writes any Linux ISO as it is, and the stick then holds exactly that image' {
        $raw = Join-Path $TestDrive 'other-linux.iso'
        $bytes = New-Object byte[] (5MB)
        (New-Object System.Random 11).NextBytes($bytes)
        $bytes[510] = 0x55; $bytes[511] = 0xAA
        [System.IO.File]::WriteAllBytes($raw, $bytes)
        $leaf = Split-Path -Leaf $script:Loop
        $r = & $script:RunCli @('-System', 'linux-iso', '-IsoPath', $raw, '-Disk', $script:Loop, '-PasswordStdin', '-AppLanguage', 'en') "$leaf`n"
        $r.Code | Should -Be 0 -Because $r.Output
        $r.Output | Should -Match 'read back'
        $fs = [System.IO.File]::OpenRead($script:Loop)
        try { $back = New-Object byte[] $bytes.Length; [void]$fs.Read($back, 0, $back.Length) } finally { $fs.Dispose() }
        [System.Linq.Enumerable]::SequenceEqual([byte[]]$back, [byte[]]$bytes) | Should -BeTrue
    }
    It 'names the systems it knows when -System is wrong' {
        $r = & $script:RunCli @('-System', 'windows95', '-Disk', $script:Loop, '-PasswordStdin') ''
        $r.Code | Should -Be 1
        $r.Output | Should -Match 'fedora-workstation'
        $r.Output | Should -Match 'cachyos-desktop'
    }
    It 'refuses a disk that is not offered' {
        $a = $script:Args.Clone()
        $a[5] = '/dev/vda'
        $r = & $script:RunCli $a "secret1`n"
        $r.Code | Should -Be 1
        $r.Output | Should -Match 'cannot be used'
    }
}
