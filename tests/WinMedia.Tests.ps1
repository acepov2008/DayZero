#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Tests for builder\lib\WinMedia.psm1: the parts that decide WHAT gets downloaded and WHICH
# disk may be erased. Downloading, DISM and diskpart themselves only run on Windows
# (see TESTING.md, "Make the Windows stick").

BeforeAll {
    $repo = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repo 'builder/lib/WinMedia.psm1') -Force

    function New-TestEntryXml {
        param([string]$File, [string]$Lang, [string]$Edition, [string]$Arch = 'x64', [string]$Size = '4680320173',
            [string]$Sha1 = '8ceab2838f8e90180ac7490e8752157fb05588cb', [string]$UrlHost = 'dl.delivery.mp.microsoft.com')
        return "<File id=`"`"><FileName>$File</FileName><LanguageCode>$Lang</LanguageCode><Language>x</Language><Edition>$Edition</Edition>" +
        "<Architecture>$Arch</Architecture><Size>$Size</Size><Sha1>$Sha1</Sha1><FilePath>http://$UrlHost/files/abc/$File</FilePath><Key /></File>"
    }
    function New-TestCatalogXml {
        param([string[]]$Files)
        return '<MCT><Catalogs><Catalog version="2.0"><PublishedMedia id="" release=""><Files>' + ($Files -join '') + '</Files></PublishedMedia></Catalog></Catalogs></MCT>'
    }
    function New-TestDisk {
        param([string]$BusType = 'USB', [bool]$IsSystem = $false, [bool]$IsBoot = $false, [bool]$IsReadOnly = $false,
            [int64]$Size = 32000000000, [string[]]$Letters = @('E'))
        return [pscustomobject]@{ BusType = $BusType; IsSystem = $IsSystem; IsBoot = $IsBoot; IsReadOnly = $IsReadOnly; Size = $Size; Letters = $Letters }
    }
    $script:Consumer = '26100.4349.250607-1500.ge_release_svc_refresh_CLIENTCONSUMER_RET_x64FRE_en-us.esd'
    $script:Catalog = New-TestCatalogXml -Files @(
        (New-TestEntryXml -File '26100.4349.250607-1500.ge_release_svc_refresh_CLIENTBUSINESS_VOL_x64FRE_en-us.esd' -Lang 'en-us' -Edition 'Enterprise' -Sha1 ('a' * 40)),
        (New-TestEntryXml -File $script:Consumer -Lang 'en-us' -Edition 'Core'),
        (New-TestEntryXml -File $script:Consumer -Lang 'en-us' -Edition 'Professional'),
        (New-TestEntryXml -File ($script:Consumer -replace 'x64FRE', 'A64FRE') -Lang 'en-us' -Edition 'Professional' -Arch 'ARM64' -Sha1 ('b' * 40)),
        (New-TestEntryXml -File ($script:Consumer -replace 'en-us', 'de-de') -Lang 'de-de' -Edition 'Professional' -Sha1 ('c' * 40))
    )
    $script:EsdImages = @(
        [pscustomobject]@{ Index = 1; Name = 'Windows Setup Media' },
        [pscustomobject]@{ Index = 2; Name = 'Microsoft Windows PE (x64)' },
        [pscustomobject]@{ Index = 3; Name = 'Microsoft Windows Setup (x64)' },
        [pscustomobject]@{ Index = 4; Name = 'Windows 11 Home' },
        [pscustomobject]@{ Index = 5; Name = 'Windows 11 Home N' },
        [pscustomobject]@{ Index = 6; Name = 'Windows 11 Home Single Language' },
        [pscustomobject]@{ Index = 7; Name = 'Windows 11 Education' },
        [pscustomobject]@{ Index = 8; Name = 'Windows 11 Education N' },
        [pscustomobject]@{ Index = 9; Name = 'Windows 11 Pro' },
        [pscustomobject]@{ Index = 10; Name = 'Windows 11 Pro N' }
    )
}

Describe 'Microsoft download catalogue' {
    It 'uses a microsoft.com HTTPS link for the Windows <_> catalogue' -ForEach @(10, 11) {
        Get-DzWindowsCatalogUrl -WindowsVersion $_ | Should -Match '^https://go\.microsoft\.com/fwlink/\?LinkId=\d+$'
    }
    It 'parses products.xml into entries' {
        $e = @(ConvertFrom-DzProductsXml -Xml $script:Catalog)
        $e.Count | Should -Be 5
        $e[1].FileName | Should -Be $script:Consumer
        $e[1].Size | Should -Be 4680320173
        $e[1].Sha1 | Should -Be '8ceab2838f8e90180ac7490e8752157fb05588cb'
        $e[1].Url | Should -Match '^http://dl\.delivery\.mp\.microsoft\.com/'
    }
    It 'picks the x64 consumer image for the language, never the volume-licence one' {
        $e = @(ConvertFrom-DzProductsXml -Xml $script:Catalog)
        $pick = Select-DzWindowsDownload -Entries $e -Language 'en-US'
        $pick.FileName | Should -Be $script:Consumer
        $pick.Architecture | Should -Be 'x64'
        (Select-DzWindowsDownload -Entries $e -Language 'de-DE').Sha1 | Should -Be ('c' * 40)
    }
    It 'returns nothing for a language Microsoft does not publish' {
        Select-DzWindowsDownload -Entries @(ConvertFrom-DzProductsXml -Xml $script:Catalog) -Language 'xx-XX' | Should -BeNullOrEmpty
    }
    It 'refuses a download that is not on microsoft.com' {
        $xml = New-TestCatalogXml -Files @((New-TestEntryXml -File $script:Consumer -Lang 'en-us' -Edition 'Professional' -UrlHost 'microsoft.com.example.org'))
        { Select-DzWindowsDownload -Entries @(ConvertFrom-DzProductsXml -Xml $xml) -Language 'en-us' } | Should -Throw '*not on microsoft.com*'
    }
    It 'refuses an entry without a checksum, with a tiny size or with an odd file name' {
        $good = @(ConvertFrom-DzProductsXml -Xml $script:Catalog)[2]
        Test-DzWindowsDownloadEntry -Entry $good | Should -BeNullOrEmpty
        foreach ($change in @(@{ Sha1 = '' }, @{ Size = 1000 }, @{ FileName = '..\evil.esd' }, @{ FileName = 'setup.exe' }, @{ Url = 'ftp://dl.delivery.mp.microsoft.com/x.esd' })) {
            $bad = $good.PSObject.Copy()
            foreach ($k in $change.Keys) { $bad.$k = $change[$k] }
            Test-DzWindowsDownloadEntry -Entry $bad | Should -Not -BeNullOrEmpty
        }
    }
    It 'finds the unpacked catalogue whatever expand.exe called it, and ignores the .cab' {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $dir)
        Find-DzCatalogXml -Folder $dir | Should -BeNullOrEmpty
        [System.IO.File]::WriteAllBytes((Join-Path $dir 'a.cab'), [byte[]](@(77, 83, 67, 70) + (@(0) * 2000)))
        Find-DzCatalogXml -Folder $dir | Should -BeNullOrEmpty
        Set-Content -LiteralPath (Join-Path $dir 'products-win11.cab') -Value ($script:Catalog + (' ' * 1000))
        Split-Path -Leaf (Find-DzCatalogXml -Folder $dir) | Should -Be 'products-win11.cab'
        Set-Content -LiteralPath (Join-Path $dir 'products.xml') -Value ($script:Catalog + (' ' * 1000))
        Split-Path -Leaf (Find-DzCatalogXml -Folder $dir) | Should -Be 'products.xml'
    }
    It 'lists 38 languages, each a real culture name, including en-US' {
        $l = @(Get-DzWindowsLanguageList)
        $l.Count | Should -Be 38
        $l | Should -Contain 'en-US'
        foreach ($x in $l) { $x | Should -Match '^[a-z]{2}(-[A-Z][a-z]{3})?-[A-Z]{2}$' }
    }
}

Describe 'Unpacking the Microsoft image' {
    It 'finds the setup files, Windows PE, Windows Setup and the editions' {
        $p = Get-DzEsdImagePlan -Images $script:EsdImages
        $p.SetupMedia | Should -Be 1
        $p.WinPE | Should -Be 2
        $p.Setup | Should -Be 3
        @($p.Editions).Count | Should -Be 7
    }
    It 'refuses a file that is not laid out like installation media' {
        { Get-DzEsdImagePlan -Images @($script:EsdImages | Where-Object { $_.Index -ne 2 }) } | Should -Throw
        { Get-DzEsdImagePlan -Images @($script:EsdImages | Where-Object { $_.Index -le 3 }) } | Should -Throw
    }
    It 'puts every edition except the N ones on the stick, so Auto, Home and Pro all work' {
        $names = @(Select-DzEsdEdition -Editions (Get-DzEsdImagePlan -Images $script:EsdImages).Editions | ForEach-Object { $_.Name })
        $names | Should -Be @('Windows 11 Home', 'Windows 11 Home Single Language', 'Windows 11 Education', 'Windows 11 Pro')
    }
    It 'falls back to Home, Home Single Language and Pro when the image is too big' {
        $names = @(Select-DzEsdEdition -Editions (Get-DzEsdImagePlan -Images $script:EsdImages).Editions -Tier small | ForEach-Object { $_.Name })
        $names | Should -Be @('Windows 11 Home', 'Windows 11 Home Single Language', 'Windows 11 Pro')
    }
    It 'works for Windows 10 names too' {
        $ten = @($script:EsdImages | ForEach-Object { [pscustomobject]@{ Index = $_.Index; Name = ($_.Name -replace 'Windows 11', 'Windows 10') } })
        @(Select-DzEsdEdition -Editions (Get-DzEsdImagePlan -Images $ten).Editions).Count | Should -Be 4
    }
}

Describe 'Prepared Windows cache' {
    BeforeEach {
        $script:cache = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $script:cache)
    }
    It 'finds nothing in an empty or missing cache' {
        Get-DzPreparedMedia -WindowsVersion 11 -Language 'en-US' -CacheRoot $script:cache | Should -BeNullOrEmpty
        Get-DzPreparedMedia -WindowsVersion 11 -Language 'en-US' -CacheRoot (Join-Path $script:cache 'nope') | Should -BeNullOrEmpty
    }
    It 'only trusts a folder that has its ready marker and the Windows image' {
        $name = 'win11-en-us-x64-8ceab2838f'
        [void](New-Item -ItemType Directory -Path (Join-Path $script:cache "$name/sources") -Force)
        Get-DzPreparedMedia -WindowsVersion 11 -Language 'en-US' -CacheRoot $script:cache | Should -BeNullOrEmpty
        Set-Content -LiteralPath (Join-Path $script:cache "$name.ready.json") -Value '{"sha1":"8ceab2838f8e90180ac7490e8752157fb05588cb"}'
        Get-DzPreparedMedia -WindowsVersion 11 -Language 'en-US' -CacheRoot $script:cache | Should -BeNullOrEmpty
        Set-Content -LiteralPath (Join-Path $script:cache "$name/sources/install.esd") -Value 'x'
        $hit = Get-DzPreparedMedia -WindowsVersion 11 -Language 'en-US' -CacheRoot $script:cache
        Split-Path -Leaf $hit.Path | Should -Be $name
        $hit.Info.sha1 | Should -Be '8ceab2838f8e90180ac7490e8752157fb05588cb'
        Get-DzPreparedMedia -WindowsVersion 11 -Language 'en-US' -CacheRoot $script:cache -Sha1 ('8ceab2838f' + ('0' * 30)) | Should -Not -BeNullOrEmpty
        Get-DzPreparedMedia -WindowsVersion 11 -Language 'en-US' -CacheRoot $script:cache -Sha1 ('f' * 40) | Should -BeNullOrEmpty
        Get-DzPreparedMedia -WindowsVersion 10 -Language 'en-US' -CacheRoot $script:cache | Should -BeNullOrEmpty
        Get-DzPreparedMedia -WindowsVersion 11 -Language 'de-DE' -CacheRoot $script:cache | Should -BeNullOrEmpty
    }
}

Describe 'Which disk may be erased' {
    It 'allows an ordinary USB stick' {
        Test-DzUsbDiskAllowed -Disk (New-TestDisk) | Should -BeNullOrEmpty
        Test-DzUsbDiskAllowed -Disk (New-TestDisk -Size 256000000000 -Letters @()) | Should -BeNullOrEmpty
    }
    It 'refuses <Why>' -ForEach @(
        @{ Why = 'an internal NVMe disk'; Disk = @{ BusType = 'NVMe' } },
        @{ Why = 'an internal SATA disk'; Disk = @{ BusType = 'SATA' } },
        @{ Why = 'a disk with no bus type'; Disk = @{ BusType = '' } },
        @{ Why = 'the system disk'; Disk = @{ IsSystem = $true } },
        @{ Why = 'the boot disk'; Disk = @{ IsBoot = $true } },
        @{ Why = 'a write-protected stick'; Disk = @{ IsReadOnly = $true } },
        @{ Why = 'a stick under 8 GB'; Disk = @{ Size = 4000000000 } },
        @{ Why = 'an external hard drive (over 300 GB)'; Disk = @{ Size = 1000000000000 } }
    ) {
        $d = New-TestDisk @Disk
        Test-DzUsbDiskAllowed -Disk $d | Should -Not -BeNullOrEmpty
    }
    It 'refuses a disk that holds the drive Windows runs from' {
        $old = $env:SystemDrive
        try {
            $env:SystemDrive = 'C:'
            Test-DzUsbDiskAllowed -Disk (New-TestDisk -Letters @('D', 'c')) | Should -Match 'Windows is running'
            Test-DzUsbDiskAllowed -Disk (New-TestDisk -Letters @('D')) | Should -BeNullOrEmpty
        }
        finally { $env:SystemDrive = $old }
    }
}

Describe 'diskpart script' {
    It 'erases exactly the chosen disk and makes one active FAT32 partition' {
        $lines = @((New-DzDiskpartScript -DiskNumber 3 -PartitionMB 30000) -split "`r`n" | Where-Object { $_ })
        $lines[0] | Should -Be 'select disk 3'
        $lines[1] | Should -Be 'clean'
        @($lines | Where-Object { $_ -match '^select disk' }).Count | Should -Be 1
        $lines | Should -Contain 'create partition primary size=30000'
        $lines | Should -Contain 'active'
        $lines | Should -Contain 'format fs=fat32 quick label=DAYZERO'
        $lines[-1] | Should -Be 'exit'
    }
    It 'uses CRLF line endings and plain ASCII' {
        $s = New-DzDiskpartScript -DiskNumber 1 -PartitionMB 8000
        ($s -replace "`r`n", '') | Should -Not -Match "[`r`n]"
        $s | Should -Not -Match '[^\x00-\x7F]'
    }
    It 'rejects a partition over 32 GB, a label with spaces or commands, and odd disk numbers' {
        { New-DzDiskpartScript -DiskNumber 1 -PartitionMB 64000 } | Should -Throw
        { New-DzDiskpartScript -DiskNumber 1 -PartitionMB 8000 -Label 'A B' } | Should -Throw
        { New-DzDiskpartScript -DiskNumber 1 -PartitionMB 8000 -Label "X`r`nselect disk 0" } | Should -Throw
        { New-DzDiskpartScript -DiskNumber -1 -PartitionMB 8000 } | Should -Throw
    }
    It 'sizes the partition to the stick, capped at 32 GB' {
        Get-DzUsbPartitionSize -DiskBytes 8000000000 | Should -Be 7565
        Get-DzUsbPartitionSize -DiskBytes 16000000000 | Should -Be 15194
        Get-DzUsbPartitionSize -DiskBytes 64000000000 | Should -Be 32000
        Get-DzUsbPartitionSize -DiskBytes 256000000000 | Should -Be 32000
    }
    It 'the smallest allowed stick still gets a valid script' {
        { New-DzDiskpartScript -DiskNumber 1 -PartitionMB (Get-DzUsbPartitionSize -DiskBytes 7500000000) } | Should -Not -Throw
    }
}

Describe 'Progress bar' {
    It 'maps <Text> to <Expected>' -ForEach @(
        @{ Text = 'Asking Microsoft for the current Windows 11 download...'; Expected = 0 },
        @{ Text = 'Downloading Windows 11 from Microsoft: 2.1 of 4.2 GB (50%)'; Expected = 15.5 },
        @{ Text = 'Checking the download (100%)'; Expected = 34 },
        @{ Text = 'Unpacking Windows PE (50.0%)'; Expected = 37.5 },
        @{ Text = 'Unpacking Windows 11 Home (1 of 4; this is the slow part)'; Expected = 42 },
        @{ Text = 'Unpacking Windows 11 Education (3 of 4; this is the slow part) (50.0%)'; Expected = 58.25 },
        @{ Text = 'Unpacking Windows 11 Pro (4 of 4; this is the slow part) (100.0%)'; Expected = 68 },
        @{ Text = 'Splitting the Windows image for the USB stick (50,0%)'; Expected = 71 },
        @{ Text = 'Erasing and formatting the USB stick'; Expected = 75 },
        @{ Text = 'Copying Windows to the USB stick (50%)'; Expected = 86 },
        @{ Text = 'Adding the answer file and the DayZero toolkit...'; Expected = 97 }
    ) {
        Get-DzBuildProgress -Text $Text | Should -Be $Expected
    }
    It 'ignores lines that belong to no stage' {
        Get-DzBuildProgress -Text 'Ready.' | Should -BeNullOrEmpty
        Get-DzBuildProgress -Text 'Downloading App Installer (winget)... 12 MB' | Should -BeNullOrEmpty
        Get-DzBuildProgress -Text '' | Should -BeNullOrEmpty
    }
    It 'never leaves 0-100 and never goes backwards through the stages' {
        Get-DzBuildProgress -Text 'Copying Windows to the USB stick (250%)' | Should -Be 96
        $order = @('Asking Microsoft', 'Downloading Windows 11 (99%)', 'Checking the download (1%)', 'Unpacking the Windows setup files', 'Unpacking Windows PE',
            'Unpacking Windows Setup (x)', 'Unpacking Windows 11 Home (1 of 2; x) (5.0%)', 'Unpacking Windows 11 Pro (2 of 2; x) (5.0%)',
            'Splitting the Windows image', 'Erasing and formatting the USB stick', 'Copying Windows to the USB stick (1%)', 'Adding the answer file')
        $last = -1
        foreach ($t in $order) { $v = Get-DzBuildProgress -Text $t; $v | Should -BeGreaterThan $last -Because $t; $last = $v }
    }
}

Describe 'Does Windows fit the stick' {
    It 'accepts a 16 GB stick and refuses an 8 GB one for a 7.3 GB Windows' {
        Get-DzMediaFitProblem -MediaBytes 7.3GB -DiskBytes 16000000000 | Should -BeNullOrEmpty
        Get-DzMediaFitProblem -MediaBytes 7.3GB -DiskBytes 8000000000 | Should -Match '16 GB'
    }
    It 'accepts an 8 GB stick for a 5 GB Windows and handles sizes over 2 GB without overflow' {
        Get-DzMediaFitProblem -MediaBytes 5GB -DiskBytes 8000000000 | Should -BeNullOrEmpty
        Get-DzMediaFitProblem -MediaBytes 4529505309 -DiskBytes 256000000000 | Should -BeNullOrEmpty
    }
    It 'adds up a folder' {
        $d = Join-Path $TestDrive 'size'
        [void](New-Item -ItemType Directory -Path (Join-Path $d 'sub') -Force)
        Set-Content -LiteralPath (Join-Path $d 'a.txt') -Value 'abc' -NoNewline
        Set-Content -LiteralPath (Join-Path $d 'sub/b.txt') -Value 'defgh' -NoNewline
        Get-DzFolderSize -Path $d | Should -Be 8
    }
}

Describe 'Copy progress from robocopy output' {
    It 'counts bytes really written, file by file' {
        $s = @{ Done = [double]0; Current = [double]0; Percent = [double]0; Seen = $false }
        Update-DzCopyState -State $s -Line ''
        Update-DzCopyState -State $s -Line "`t`t     1000`tC:\media\setup.exe"
        $s.Seen | Should -BeTrue
        Get-DzCopyStateBytes -State $s | Should -Be 0
        Update-DzCopyState -State $s -Line '100%  '
        Get-DzCopyStateBytes -State $s | Should -Be 1000
        Update-DzCopyState -State $s -Line "`t`t     4000000000`tC:\media\sources\install.swm"
        Get-DzCopyStateBytes -State $s | Should -Be 1000
        Update-DzCopyState -State $s -Line '  0.0%'
        Update-DzCopyState -State $s -Line ' 25.5%'
        Get-DzCopyStateBytes -State $s | Should -Be 1020001000
        Update-DzCopyState -State $s -Line ' 50,0%'
        Get-DzCopyStateBytes -State $s | Should -Be 2000001000
        Update-DzCopyState -State $s -Line "`t`t     10`tC:\media\sources\last.txt"
        Get-DzCopyStateBytes -State $s | Should -Be 4000001000
    }
    It 'ignores lines that are neither a file nor a percentage' {
        $s = @{ Done = [double]0; Current = [double]0; Percent = [double]0; Seen = $false }
        foreach ($l in @('------', 'ERROR 5 (0x00000005) Access denied', 'Waiting 3 seconds... Retrying...')) { Update-DzCopyState -State $s -Line $l }
        $s.Seen | Should -BeFalse
        Get-DzCopyStateBytes -State $s | Should -Be 0
    }
}

Describe 'robocopy paths' {
    It 'passes a drive root bare (a quoted E:\ would swallow the closing quote)' {
        ConvertTo-DzRobocopyPath -Path 'E:\' | Should -Be 'E:\'
        ConvertTo-DzRobocopyPath -Path 'E:' | Should -Be 'E:\'
    }
    It 'quotes folders and drops the trailing backslash' {
        ConvertTo-DzRobocopyPath -Path 'C:\Users\Some One\media\win11\' | Should -Be '"C:\Users\Some One\media\win11"'
    }
}

Describe 'Invoke-DzProcess' {
    BeforeAll { $script:Pwsh = (Get-Process -Id $PID).Path }
    It 'returns the exit code and the output' {
        $r = Invoke-DzProcess -FilePath $script:Pwsh -Arguments '-NoProfile -Command "Write-Output hello; exit 3"'
        $r.ExitCode | Should -Be 3
        $r.Output | Should -Match 'hello'
    }
    It 'hands every line to OnLine and keeps ticking while the program prints without a pause' {
        $got = New-Object System.Collections.Generic.List[string]
        $ticks = @{ n = 0 }
        $r = Invoke-DzProcess -FilePath $script:Pwsh -OnLine { param($l) $got.Add($l) } -Tick { $ticks.n++ } -Arguments '-NoProfile -Command "$end = (Get-Date).AddMilliseconds(1200); while ((Get-Date) -lt $end) { Write-Output ''12.5%'' }; Write-Output last"'
        $r.ExitCode | Should -Be 0
        $got | Should -Contain '12.5%'
        $got | Should -Contain 'last'
        $ticks.n | Should -BeGreaterThan 2
    }
    It 'reports percentages to the status callback and keeps them out of the output' {
        $seen = New-Object System.Collections.Generic.List[string]
        $r = Invoke-DzProcess -FilePath $script:Pwsh -Activity 'Unpacking' -Tick { param($t) $seen.Add($t) } -Arguments '-NoProfile -Command "Write-Output ''[== 42.5% ==]''; Start-Sleep -Milliseconds 900; Write-Output done"'
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'done'
        $r.Output | Should -Not -Match '42'
        $seen | Should -Contain 'Unpacking (42.5%)'
    }
}

Describe 'Get-DzFileSha1' {
    It 'matches a known SHA-1' {
        $f = Join-Path $TestDrive 'abc.txt'
        [System.IO.File]::WriteAllText($f, 'abc')
        Get-DzFileSha1 -Path $f | Should -Be 'a9993e364706816aba3e25717850c26c9cd0d89d'
    }
}

Describe 'Safety of the media module' {
    BeforeAll { $script:Source = Get-Content -Raw -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'builder/lib/WinMedia.psm1') }
    It 'erases disks in one place only, through diskpart on a re-checked USB disk' {
        [regex]::Matches($script:Source, "'clean'").Count | Should -Be 1
        $script:Source | Should -Not -Match 'Clear-Disk|Format-Volume|Remove-Partition|Initialize-Disk'
        $body = [regex]::Match($script:Source, '(?s)function Initialize-DzUsbDisk \{.*?\n\}\r?\n').Value
        $body.IndexOf('$now.Problem') | Should -BeGreaterThan 0
        $body.IndexOf('$now.Problem') | Should -BeLessThan $body.IndexOf('diskpart.exe')
        $body.IndexOf('$now.Serial -ne $Disk.Serial') | Should -BeLessThan $body.IndexOf('diskpart.exe')
    }
    It 'does no [math]::Max/Min on file sizes without [double] (PowerShell 5.1 picks Int32 and fails over 2 GB)' {
        foreach ($m in [regex]::Matches($script:Source, '\[math\]::(Max|Min)\(([^,]+),')) {
            $m.Groups[2].Value | Should -Match '^\[double\]' -Because $m.Value
        }
    }
    It 'splits a Windows image that is too big for FAT32 instead of giving up' {
        $body = [regex]::Match($script:Source, '(?s)function New-DzMediaFromEsd \{.*?\n\}\r?\n').Value
        $body | Should -Match '/Split-Image'
        $body | Should -Not -Match 'does not fit'
    }
    It 'copy progress uses closures, so it cannot pick up Invoke-DzProcess own $Tick and recurse' {
        $body = [regex]::Match($script:Source, '(?s)function Copy-DzMediaTree \{.*?\n\}\r?\n').Value
        [regex]::Matches($body, '\}\.GetNewClosure\(\)').Count | Should -Be 2
        ($body -split "`n" | Where-Object { $_ -match '^\s*\$arguments = ' }) | Should -Not -Match '/NP\b|/NFL\b'
    }
    It 'checks size and SHA-1 before unpacking a download' {
        $body = [regex]::Match($script:Source, '(?s)function Get-DzWindowsMediaTree \{.*?\n\}\r?\n').Value
        $body.IndexOf('$sha -ne $entry.Sha1') | Should -BeGreaterThan 0
        $body.IndexOf('$sha -ne $entry.Sha1') | Should -BeLessThan $body.IndexOf('New-DzMediaFromEsd')
    }
}
