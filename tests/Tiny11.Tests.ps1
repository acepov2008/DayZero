#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Tests for builder\lib\Tiny11.psm1: which tiny11builder files are accepted, and the choices
# around them. Running tiny11builder itself only works on Windows (see TESTING.md).

BeforeAll {
    $script:Repo = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:Repo 'builder/lib/WinMedia.psm1') -Force
    Import-Module (Join-Path $script:Repo 'builder/lib/Tiny11.psm1') -Force
    $script:Source = Get-Content -Raw -LiteralPath (Join-Path $script:Repo 'builder/lib/Tiny11.psm1')
}

Describe 'Where tiny11builder comes from' {
    It 'is pinned to one commit of ntdevlabs/tiny11builder, never a branch' {
        $s = Get-DzTiny11Source
        $s.Commit | Should -Match '^[0-9a-f]{40}$'
        foreach ($f in $s.Files) {
            $f.Url | Should -Be ("https://raw.githubusercontent.com/ntdevlabs/tiny11builder/$($s.Commit)/$($f.Name)")
            $f.Url | Should -Not -Match 'main|master|refs/heads'
            $f.Sha256 | Should -Match '^[0-9a-f]{64}$'
        }
        ($s.Files | ForEach-Object { $_.Name }) | Should -Be @('tiny11maker.ps1', 'autounattend.xml')
    }
    It 'never uses tiny11 core, which switches off Windows Update and Defender' {
        ($script:Source -replace '(?s)<#.*?#>', '') | Should -Not -Match '(?i)coremaker'
        (Get-DzTiny11Source).Files | ForEach-Object { $_.Name | Should -Not -Match '(?i)core' }
        (Get-Content -Raw -LiteralPath (Join-Path $script:Repo 'builder/Builder.ps1')) | Should -Not -Match '(?i)coremaker'
    }
    It 'is not stored in this repository' {
        @(Get-ChildItem -Path $script:Repo -Recurse -File -Include 'tiny11maker.ps1', 'tiny11Coremaker.ps1' | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' }) | Should -BeNullOrEmpty
    }
    It 'checks the SHA-256 before the script is run' {
        $body = [regex]::Match($script:Source, '(?s)function New-DzTiny11Iso \{.*?\n\}\r?\n').Value
        $body.IndexOf('Save-DzTiny11Script') | Should -BeGreaterThan 0
        $body.IndexOf('Save-DzTiny11Script') | Should -BeLessThan $body.IndexOf('Invoke-DzConsoleScript')
        $save = [regex]::Match($script:Source, '(?s)function Save-DzTiny11Script \{.*?\n\}\r?\n').Value
        $save | Should -Match 'Test-DzFileSha256'
        $save | Should -Match 'Remove-Item'
    }
}

Describe 'Test-DzFileSha256' {
    It 'accepts only the exact file' {
        $f = Join-Path $TestDrive 'abc.txt'
        [System.IO.File]::WriteAllText($f, 'abc')
        Test-DzFileSha256 -Path $f -Sha256 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad' | Should -BeTrue
        Test-DzFileSha256 -Path $f -Sha256 'BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD' | Should -BeTrue
        [System.IO.File]::WriteAllText($f, 'abd')
        Test-DzFileSha256 -Path $f -Sha256 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad' | Should -BeFalse
        Test-DzFileSha256 -Path (Join-Path $TestDrive 'missing.txt') -Sha256 ('0' * 64) | Should -BeFalse
        { Test-DzFileSha256 -Path $f -Sha256 'short' } | Should -Throw
    }
}

Describe 'tiny11 choices' {
    It 'needs Windows 11, 64-bit Intel/AMD and the Home or Pro edition' {
        Test-DzTiny11Choice -WindowsVersion 11 -Edition 'home' | Should -BeNullOrEmpty
        Test-DzTiny11Choice -WindowsVersion 11 -Edition 'pro' | Should -BeNullOrEmpty
        Test-DzTiny11Choice -WindowsVersion 10 -Edition 'pro' | Should -Match 'Windows 11 only'
        Test-DzTiny11Choice -WindowsVersion 11 -Edition 'auto' | Should -Match 'Home or Pro'
        Test-DzTiny11Choice -WindowsVersion 11 -Edition 'key' | Should -Match 'Home or Pro'
        Test-DzTiny11Choice -WindowsVersion 11 -Edition 'pro' -Architecture 'arm64' | Should -Match 'Intel/AMD'
    }
    It 'finds the plain Home and Pro images, not N or Single Language' {
        $images = @(
            [pscustomobject]@{ Index = 1; Name = 'Windows 11 Home' }, [pscustomobject]@{ Index = 2; Name = 'Windows 11 Home N' },
            [pscustomobject]@{ Index = 3; Name = 'Windows 11 Home Single Language' }, [pscustomobject]@{ Index = 4; Name = 'Windows 11 Education' },
            [pscustomobject]@{ Index = 5; Name = 'Windows 11 Pro N' }, [pscustomobject]@{ Index = 6; Name = 'Windows 11 Pro' }
        )
        Select-DzEditionIndex -Images $images -Edition home | Should -Be 1
        Select-DzEditionIndex -Images $images -Edition pro | Should -Be 6
        Select-DzEditionIndex -Images @($images | Where-Object { $_.Index -ne 6 }) -Edition pro | Should -Be 0
        Select-DzEditionIndex -Images @() -Edition home | Should -Be 0
    }
    It 'says what tiny11 changes, including that Update and Defender stay and Undo cannot revert it' {
        $text = (Get-DzTiny11Summary) -join ' '
        $text | Should -Match 'Edge'
        $text | Should -Match 'hardware checks'
        $text | Should -Match 'Windows Update and Microsoft Defender stay on'
        $text | Should -Match '-Undo cannot'
    }
}

Describe 'tiny11 cache' {
    It 'names the ISO after language, edition, source Windows and tiny11builder version' {
        $a = Get-DzTiny11IsoName -Language 'ru-RU' -Edition pro -SourceId 'win11-ru-ru-x64-920bd57e15'
        $a | Should -Match '^tiny11-win11-ru-ru-pro-[0-9a-f]{10}-7a7baffa\.iso$'
        Get-DzTiny11IsoName -Language 'ru-RU' -Edition pro -SourceId 'WIN11-ru-ru-x64-920bd57e15' | Should -Be $a
        Get-DzTiny11IsoName -Language 'ru-RU' -Edition home -SourceId 'win11-ru-ru-x64-920bd57e15' | Should -Not -Be $a
        Get-DzTiny11IsoName -Language 'ru-RU' -Edition pro -SourceId 'win11-ru-ru-x64-aaaaaaaaaa' | Should -Not -Be $a
    }
    It 'shows up in the downloaded-Windows manager and can be deleted there' {
        $cache = Join-Path $TestDrive 'tinycache'
        [void](New-Item -ItemType Directory -Path (Join-Path $cache 'tiny11-work/tool') -Force)
        $iso = Get-DzTiny11IsoName -Language 'en-US' -Edition home -SourceId 'x'
        Set-Content -LiteralPath (Join-Path $cache $iso) -Value ('z' * 4000)
        $items = @(Get-DzMediaCacheItem -CacheRoot $cache)
        $items.Count | Should -Be 2
        ($items | Where-Object { $_.Kind -eq 'windows' }).Display | Should -Match '^tiny11 \(Windows 11 Home\), en-us - '
        ($items | Where-Object { $_.Kind -eq 'leftover' }).Display | Should -Match '^Unfinished tiny11 build - '
        Remove-DzMediaCacheItem -Name $iso -CacheRoot $cache
        Remove-DzMediaCacheItem -Name 'tiny11-work' -CacheRoot $cache
        @(Get-DzMediaCacheItem -CacheRoot $cache) | Should -BeNullOrEmpty
        { Remove-DzMediaCacheItem -Name 'tiny11-work\..\..' -CacheRoot $cache } | Should -Throw
    }
}

Describe 'Free drive letter' {
    It 'takes the last free letter and never A, B or C' {
        Get-DzFreeDriveLetter -Used @('C', 'D', 'E') | Should -Be 'Z'
        Get-DzFreeDriveLetter -Used @('C:\', 'Z:\', 'y') | Should -Be 'X'
        Get-DzFreeDriveLetter -Used @([char[]](68..90) | ForEach-Object { [string]$_ }) | Should -BeNullOrEmpty
    }
}

Describe 'tiny11 progress' {
    It 'moves the bar while tiny11builder works in its own window, after unpacking and before formatting' {
        $a = Get-DzBuildProgress -Text 'Preparing the Windows files for tiny11'
        $b = Get-DzBuildProgress -Text 'Preparing Windows 11 Pro for tiny11 (50.0%)'
        $c = Get-DzBuildProgress -Text 'tiny11builder is working in its own window (1 min)'
        $d = Get-DzBuildProgress -Text 'tiny11builder is working in its own window (45 min)'
        $e = Get-DzBuildProgress -Text 'tiny11builder is working in its own window (300 min)'
        $a | Should -BeGreaterThan 68
        $b | Should -BeGreaterThan $a
        $c | Should -BeGreaterThan $b
        $d | Should -BeGreaterThan $c
        $e | Should -Be 74
        $e | Should -BeLessThan (Get-DzBuildProgress -Text 'Erasing and formatting the USB stick')
    }
}
