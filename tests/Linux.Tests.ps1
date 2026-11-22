#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Tests for builder\lib\Linux.psm1 (Linux install sticks) and the Linux kit in kit\linux.

BeforeAll {
    $script:Repo = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:Repo 'builder/lib/Linux.psm1') -Force
    $script:Catalog = Get-DzLinuxCatalog
    $script:Kb = @{ Layout = 'us'; Variant = ''; Toggle = '' }
    $script:Hash = '$6$saltstring$svn8UoSVapNtMuq1ukKS4tPQd8iKwSMHWjl/O817G3uBnIFNjnQJuesI68u4OTLiBFdcbYEdFCoEOfaS35inz1'
    $script:NewOptions = {
        @{
            UserName = 'ivan'; FullName = 'Ivan'; PasswordHash = $script:Hash; HostName = ''; Locale = 'ru_RU.UTF-8'
            Keyboard = $script:Kb; TimeZone = 'Europe/Moscow'; BuildId = '0123abcd'; Drivers = $true; Codecs = $true
        }
    }
    $script:Sums2404 = @'
faabcf33ae53976d2b8207a001ff32f4e5daae013505ac7188c9ea63988f8328 *ubuntu-24.04.3-desktop-amd64.iso
c3514bf0056180d09376462a7a1b4f213c1d6e8ea67fae5c25099c6fd3d8274b *ubuntu-24.04.3-live-server-amd64.iso
3a4c9877b483ab46d7c3fbe165a0db275e1ae3cfe56a5657e5a47c2f99a99d1e *ubuntu-24.04.4-desktop-amd64.iso
97f3d7ffb032c3eb3b23d2c8be9cc76e60c2c1f2c0146ba5ba9fe01cafae0fd8 *ubuntu-24.04.5-live-server-amd64.iso
4da4a0c9035da8e68a59a838674f403f0a54472c78a83b4fb7f78d03588f85a7 *ubuntu-24.04.5.1-desktop-amd64.iso
'@
    $script:Sums2604 = @'
487f87faaf547ea30e0aba4d5b53346292571256b25333a978db1692bcee9dd2 *ubuntu-26.04-desktop-amd64.iso
dec49008a71f6098d0bcfc822021f4d042d5f2db279e4d75bdd981304f1ca5d9 *ubuntu-26.04-live-server-amd64.iso
601e30fbf5d97759367c632e2c33630665039b7e2158fd068403da3ccf1bda1f *ubuntu-26.04.1-desktop-amd64.iso
'@
}

Describe 'Linux catalogue (builder\linux\distros.json)' {
    It 'downloads only over https from each project''s own hosts' {
        $script:Catalog.AllowedHosts | Should -Be @('releases.ubuntu.com', 'cdimage.ubuntu.com', 'dl.fedoraproject.org', 'cdimage.debian.org', 'mirrors.edge.kernel.org', 'cachyos.org', 'mirror.cachyos.org')
        foreach ($d in $script:Catalog.Distros) {
            Test-DzLinuxDownloadUrl -Url ([string]$d.baseUrl) -AllowedHosts $script:Catalog.AllowedHosts | Should -BeTrue -Because $d.id
            if ($d.PSObject.Properties['latestFrom']) { Test-DzLinuxDownloadUrl -Url ([string]$d.latestFrom.page) -AllowedHosts $script:Catalog.AllowedHosts | Should -BeTrue -Because $d.id }
        }
    }
    It 'offers Ubuntu with DayZero, and Fedora, Debian, Linux Mint and CachyOS written as they are' {
        $ids = @($script:Catalog.Distros | ForEach-Object { $_.id })
        foreach ($id in 'ubuntu-26.04', 'ubuntu-24.04', 'fedora-workstation', 'debian-gnome', 'linuxmint-cinnamon', 'cachyos-desktop') { $ids | Should -Contain $id }
        foreach ($d in $script:Catalog.Distros) {
            @('ubuntu-autoinstall', 'none') | Should -Contain ([string]$d.automation)
            if ($d.automation -eq 'ubuntu-autoinstall') { [string]$d.family | Should -Be 'ubuntu' }
            [string]$d.name | Should -Not -BeNullOrEmpty
        }
    }
    It 'has a default that exists and only files that fit FAT32' {
        @($script:Catalog.Distros | Where-Object { $_.id -eq $script:Catalog.DefaultDistro }).Count | Should -Be 1
        foreach ($d in $script:Catalog.Distros) { [int64]$d.largestFile | Should -BeLessThan 4294967296 }
    }
    It 'refuses http, other hosts, user info and odd ports' {
        $h = $script:Catalog.AllowedHosts
        Test-DzLinuxDownloadUrl -Url 'http://releases.ubuntu.com/26.04/SHA256SUMS' -AllowedHosts $h | Should -BeFalse
        Test-DzLinuxDownloadUrl -Url 'https://releases.ubuntu.com.evil.example/x.iso' -AllowedHosts $h | Should -BeFalse
        Test-DzLinuxDownloadUrl -Url 'https://user@releases.ubuntu.com/x.iso' -AllowedHosts $h | Should -BeFalse
        Test-DzLinuxDownloadUrl -Url 'https://releases.ubuntu.com:8443/x.iso' -AllowedHosts $h | Should -BeFalse
        Test-DzLinuxDownloadUrl -Url 'not a url' -AllowedHosts $h | Should -BeFalse
    }
    It 'picks the newest desktop ISO from the published checksum list' {
        $d24 = Get-DzLinuxDistro -Id 'ubuntu-24.04'
        $pick = Select-DzLinuxIso -Sums @(ConvertFrom-DzSha256Sums -Text $script:Sums2404) -Pattern $d24.isoPattern
        $pick.Name | Should -Be 'ubuntu-24.04.5.1-desktop-amd64.iso'
        $pick.Sha256 | Should -Be '4da4a0c9035da8e68a59a838674f403f0a54472c78a83b4fb7f78d03588f85a7'
        $d26 = Get-DzLinuxDistro -Id 'ubuntu-26.04'
        (Select-DzLinuxIso -Sums @(ConvertFrom-DzSha256Sums -Text $script:Sums2604) -Pattern $d26.isoPattern).Name | Should -Be 'ubuntu-26.04.1-desktop-amd64.iso'
        Select-DzLinuxIso -Sums @(ConvertFrom-DzSha256Sums -Text $script:Sums2604) -Pattern $d24.isoPattern | Should -BeNullOrEmpty
    }
    It 'reads both sha256sum line styles and ignores junk' {
        $s = @(ConvertFrom-DzSha256Sums -Text ("AB" * 32 + "  a.iso`r`nnonsense`n" + "cd" * 32 + " *b.iso"))
        $s.Count | Should -Be 2
        $s[0].Sha256 | Should -Be ('ab' * 32)
        $s[1].Name | Should -Be 'b.iso'
    }
    It 'reads BSD-style checksum lines (Fedora) and skips PGP signature text' {
        $t = "-----BEGIN PGP SIGNED MESSAGE-----`nHash: SHA256`n`n# Fedora-Workstation-Live-45-1.4.x86_64.iso: 2925092864 bytes`nSHA256 (Fedora-Workstation-Live-45-1.4.x86_64.iso) = 68338C6BFE4F0D64151F2E47EFE9F44A8855AD05B460E56B844FB3FA2C9A3BEB`n-----BEGIN PGP SIGNATURE-----`niQIzBAEBCAAdFiEET1Cm`n"
        $s = @(ConvertFrom-DzSha256Sums -Text $t)
        $s.Count | Should -Be 1
        $s[0].Name | Should -Be 'Fedora-Workstation-Live-45-1.4.x86_64.iso'
        $s[0].Sha256 | Should -Be '68338c6bfe4f0d64151f2e47efe9f44a8855ad05b460e56b844fb3fa2c9a3beb'
    }
    It 'reads the names in a web server folder listing, and nothing outside it' {
        $html = '<a href="../">..</a><a href="?C=N;O=D">Name</a><a href="22.3/">22.3/</a><a href="./22/">22/</a><a href="https://evil.example/x.iso">x</a><a href="/pub/">pub</a><a href="a&amp;b.iso">a</a><a href="22.3/">dup</a>'
        @(ConvertFrom-DzHtmlLinks -Html $html) | Should -Be @('22.3/', '22/', 'a&b.iso')
    }
    It 'picks the highest version, also for plain numbers and dates' {
        Select-DzLatestName -Names @('21.3/', '22/', '22.3/', '22.10/') -Pattern '^[0-9.]+/$' | Should -Be '22.10/'
        Select-DzLatestName -Names @('44/', '45/', '9/', 'test/') -Pattern '^[0-9]+/$' | Should -Be '45/'
        Select-DzLatestName -Names @('260628', '260809') -Pattern '.' | Should -Be '260809'
        Select-DzLatestName -Names @('x') -Pattern '^y$' | Should -BeNullOrEmpty
    }
    It 'hashes files with SHA-256' {
        $f = Join-Path $TestDrive 'abc.bin'
        [System.IO.File]::WriteAllText($f, 'abc')
        Get-DzFileSha256 -Path $f | Should -Be 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
    }
}

Describe 'Account, language, keyboard, time zone' {
    It 'hashes passwords exactly like openssl passwd -6' {
        ConvertTo-DzSha512Crypt -Password 'Hello world!' -Salt 'saltstring' | Should -BeExactly $script:Hash
        ConvertTo-DzSha512Crypt -Password ('p' + [char]0xE4 + 'ssw' + [char]0xF6 + 'rd') -Salt 'abc' |
            Should -BeExactly '$6$abc$wXvLgMChht3U87i888StiQy1W/EK2Ge3H6rxIRM8l0prwhG1icmLmgEOcYMiXbSth/t5JyRjjVGbqvVEQ7j9n/'
        ConvertTo-DzSha512Crypt -Password 'x' -Salt 'toolongsaltstring123' |
            Should -BeExactly '$6$toolongsaltstrin$m5UCdGkMg16fnZB/afayhHcFYEQvnTRoKod8GIJKB0rGGl9IQGUPKeGHHw5xPOFVPjhTAcuzioT6ZcDqsMKJ80'
    }
    It 'uses a fresh random salt each time' {
        $a = ConvertTo-DzSha512Crypt -Password 'same'
        $b = ConvertTo-DzSha512Crypt -Password 'same'
        $a | Should -Not -Be $b
        $a | Should -Match '^\$6\$[./0-9A-Za-z]{16}\$[./0-9A-Za-z]{86}$'
    }
    It 'accepts Linux user names and explains the rules' {
        Test-DzLinuxUserName -Name 'ivan' | Should -BeNullOrEmpty
        Test-DzLinuxUserName -Name 'ivan_p-2' | Should -BeNullOrEmpty
        Test-DzLinuxUserName -Name 'Ivan' | Should -Match 'small letter'
        Test-DzLinuxUserName -Name '1ivan' | Should -Not -BeNullOrEmpty
        Test-DzLinuxUserName -Name 'root' | Should -Match 'used by Linux'
        Test-DzLinuxUserName -Name '' | Should -Not -BeNullOrEmpty
    }
    It 'suggests a Linux user name from a Windows one' {
        ConvertTo-DzLinuxUserName -Name 'Ivan Petrov' | Should -Be 'ivan-petrov'
        ConvertTo-DzLinuxUserName -Name '2Gamer' | Should -Be 'gamer'
        ConvertTo-DzLinuxUserName -Name 'Root' | Should -Be ''
    }
    It 'checks computer names' {
        Test-DzLinuxHostName -Name 'my-pc' | Should -BeNullOrEmpty
        Test-DzLinuxHostName -Name '' | Should -BeNullOrEmpty
        Test-DzLinuxHostName -Name '-pc' | Should -Not -BeNullOrEmpty
        Test-DzLinuxHostName -Name 'my pc' | Should -Not -BeNullOrEmpty
    }
    It 'turns Windows cultures into Linux locales' {
        (ConvertTo-DzLinuxLocale -Culture 'ru-RU').Locale | Should -Be 'ru_RU.UTF-8'
        (ConvertTo-DzLinuxLocale -Culture 'en-US').Locale | Should -Be 'en_US.UTF-8'
        $x = ConvertTo-DzLinuxLocale -Culture 'nonsense'
        $x.Locale | Should -Be 'en_US.UTF-8'
        $x.Known | Should -BeFalse
    }
    It 'turns Windows time zones into IANA names (CLDR table)' {
        (ConvertTo-DzLinuxTimeZone -Id 'Russian Standard Time').TimeZone | Should -Be 'Europe/Moscow'
        (ConvertTo-DzLinuxTimeZone -Id 'Pacific Standard Time').TimeZone | Should -Be 'America/Los_Angeles'
        (ConvertTo-DzLinuxTimeZone -Id 'UTC').TimeZone | Should -Be 'Etc/UTC'
        (ConvertTo-DzLinuxTimeZone -Id 'Europe/Berlin').TimeZone | Should -Be 'Europe/Berlin'
        (ConvertTo-DzLinuxTimeZone -Id 'Mars Standard Time').Known | Should -BeFalse
    }
    It 'turns Windows keyboards into xkb layouts, adding US English before non-Latin ones' {
        $ru = ConvertTo-DzLinuxKeyboard -InputLocale '0419:00000419'
        $ru.Layout | Should -Be 'us,ru'
        $ru.Toggle | Should -Be 'alt_shift_toggle'
        (ConvertTo-DzLinuxKeyboard -InputLocale '0407:00000407').Layout | Should -Be 'de'
        $intl = ConvertTo-DzLinuxKeyboard -InputLocale '0409:00020409'
        $intl.Layout | Should -Be 'us'
        $intl.Variant | Should -Be 'intl'
        (ConvertTo-DzLinuxKeyboard -InputLocale '0000:12345678').Known | Should -BeFalse
    }
    It 'maps only layouts that xkb and Windows both know' {
        $data = Get-Content -Raw -LiteralPath (Join-Path $script:Repo 'builder/linux/keyboards.json') | ConvertFrom-Json
        foreach ($p in $data.layouts.PSObject.Properties) {
            $p.Name | Should -Match '^[0-9A-F]{8}$'
            $p.Value.layout | Should -Match '^[a-z]{2,5}$'
        }
    }
}

Describe 'autoinstall.yaml' {
    It 'always leaves the disk screen to the user and has no storage section' {
        $y = New-DzAutoinstallYaml -Options (& $script:NewOptions)
        $y | Should -Match '(?m)^  interactive-sections:\n    - storage$'
        $y | Should -Not -Match '(?m)^\s*storage\s*:'
        @(Get-DzForbiddenAutoinstallKey -Yaml $y).Count | Should -Be 0
    }
    It 'holds the account, language and the kit late-command, never the plain password' {
        $y = New-DzAutoinstallYaml -Options (& $script:NewOptions)
        $y | Should -Match "username: 'ivan'"
        $y | Should -Match "hostname: 'ivan-pc'"
        $y | Should -Match "locale: 'ru_RU.UTF-8'"
        $y | Should -Match "timezone: 'Europe/Moscow'"
        $y | Should -Match ([regex]::Escape("password: '" + $script:Hash + "'"))
        $y | Should -Match 'install-kit\.sh'
        $y | Should -Match '(?m)^  updates: all$'
        $y | Should -Not -Match 'Hello world'
    }
    It 'quotes names safely and refuses line breaks' {
        $o = & $script:NewOptions
        $o.FullName = "Ann O'Neil"
        New-DzAutoinstallYaml -Options $o | Should -Match "realname: 'Ann O''Neil'"
        $o.FullName = "a`nstorage: {layout: {name: direct}}"
        { New-DzAutoinstallYaml -Options $o } | Should -Throw
    }
    It 'refuses bad values' {
        foreach ($change in @(
                @{ UserName = 'Root' }, @{ PasswordHash = 'plain' }, @{ BuildId = 'xyz' }, @{ Locale = 'ru' },
                @{ TimeZone = 'Russian Standard Time' }, @{ HostName = 'bad name' }, @{ Keyboard = @{ Layout = 'us;x'; Variant = ''; Toggle = '' } })) {
            $o = & $script:NewOptions
            foreach ($k in $change.Keys) { $o[$k] = $change[$k] }
            { New-DzAutoinstallYaml -Options $o } | Should -Throw
        }
    }
    It 'spots a storage section, a missing interactive disk screen and early commands' {
        Get-DzForbiddenAutoinstallKey -Yaml "autoinstall:`n  version: 1`n  interactive-sections:`n    - storage`n  storage:`n    layout:`n      name: lvm`n" | Should -Match 'storage section'
        Get-DzForbiddenAutoinstallKey -Yaml "autoinstall:`n  version: 1`n  interactive-sections:`n    - network`n" | Should -Match 'not interactive'
        Get-DzForbiddenAutoinstallKey -Yaml "autoinstall:`n  interactive-sections:`n    - storage`n  early-commands:`n    - x`n" | Should -Match 'early-commands'
        @(Get-DzForbiddenAutoinstallKey -Yaml "autoinstall:`n  interactive-sections:`n    - '*'`n").Count | Should -Be 0
    }
    It 'runs the kit only from the stick and cannot fail the install' {
        $y = New-DzAutoinstallYaml -Options (& $script:NewOptions)
        $line = @($y -split "`n" | Where-Object { $_ -match 'install-kit' })[0]
        $line | Should -Match '/cdrom'
        $line | Should -Match 'exec sh'
        $line | Should -Match 'echo "DayZero kit not found'
        $line | Should -Not -Match 'curl|wget|http'
    }
}

Describe 'Writing and checking a Linux stick' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $script:Root)
        $script:Kit = Join-Path $TestDrive 'kit'
        if (-not (Test-Path $script:Kit)) {
            Copy-Item -LiteralPath (Join-Path $script:Repo 'kit/linux') -Destination (Join-Path $script:Kit 'linux') -Recurse
            Copy-Item -LiteralPath (Join-Path $script:Repo 'kit/lang') -Destination (Join-Path $script:Kit 'lang') -Recurse
            [void](New-Item -ItemType Directory -Path (Join-Path $script:Kit 'Scripts-Linux'))
            [System.IO.File]::WriteAllText((Join-Path $script:Kit 'Scripts-Linux/10-hello.sh'), "#!/bin/bash`r`necho hello`r`n")
            [System.IO.File]::WriteAllText((Join-Path $script:Kit 'Scripts-Linux/notes.txt'), 'not a script')
            [System.IO.File]::WriteAllText((Join-Path $script:Kit 'linux/test_x.py'), 'test file')
        }
        $script:Settings = [ordered]@{ buildId = '0123abcd'; distro = 'ubuntu-26.04'; distroName = 'Ubuntu 26.04 LTS'; userName = 'ivan'; defaultMode = 'gaming'; appLanguage = 'ru'; temporaryPassword = $false }
        $script:Yaml = New-DzAutoinstallYaml -Options (& $script:NewOptions)
    }
    It 'writes autoinstall.yaml, the kit, settings and the README' {
        $r = Write-DzLinuxKitToTarget -TargetRoot $script:Root -KitSource $script:Kit -AutoinstallYaml $script:Yaml -Settings $script:Settings
        Test-Path (Join-Path $script:Root 'autoinstall.yaml') | Should -BeTrue
        Test-Path (Join-Path $script:Root 'dayzero/dayzero.py') | Should -BeTrue
        Test-Path (Join-Path $script:Root 'dayzero/install-kit.sh') | Should -BeTrue
        Test-Path (Join-Path $script:Root 'dayzero/lang/ru.json') | Should -BeTrue
        Test-Path (Join-Path $script:Root 'dayzero/build-0123abcd.marker') | Should -BeTrue
        Test-Path (Join-Path $script:Root 'DayZero-README.txt') | Should -BeTrue
        Test-Path (Join-Path $script:Root 'dayzero/test_x.py') | Should -BeFalse
        $r.ScriptCount | Should -Be 1
        (Get-Content -Raw (Join-Path $script:Root 'dayzero/settings.json') | ConvertFrom-Json).buildId | Should -Be '0123abcd'
    }
    It 'gives your scripts LF line endings' {
        [void](Write-DzLinuxKitToTarget -TargetRoot $script:Root -KitSource $script:Kit -AutoinstallYaml $script:Yaml -Settings $script:Settings)
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $script:Root 'dayzero/scripts/10-hello.sh'))
        $bytes | Should -Not -Contain ([byte]13)
        Test-Path (Join-Path $script:Root 'dayzero/scripts/notes.txt') | Should -BeFalse
    }
    It 'keeps an earlier answer file as a backup' {
        [System.IO.File]::WriteAllText((Join-Path $script:Root 'autoinstall.yaml'), 'old')
        [void](Write-DzLinuxKitToTarget -TargetRoot $script:Root -KitSource $script:Kit -AutoinstallYaml $script:Yaml -Settings $script:Settings)
        @(Get-ChildItem -LiteralPath $script:Root -Filter 'autoinstall.backup-*.yaml').Count | Should -Be 1
    }
    It 'refuses passwords in settings, a forbidden answer file and the system root' {
        $s = [ordered]@{ buildId = '0123abcd'; password = 'x' }
        { Write-DzLinuxKitToTarget -TargetRoot $script:Root -KitSource $script:Kit -AutoinstallYaml $script:Yaml -Settings $s } | Should -Throw '*password*'
        { Write-DzLinuxKitToTarget -TargetRoot $script:Root -KitSource $script:Kit -AutoinstallYaml "autoinstall:`n  storage:`n" -Settings $script:Settings } | Should -Throw '*storage*'
        $sys = if ($env:SystemDrive) { $env:SystemDrive + '\' } else { '/' }
        { Write-DzLinuxKitToTarget -TargetRoot $sys -KitSource $script:Kit -AutoinstallYaml $script:Yaml -Settings $script:Settings } | Should -Throw '*root*'
    }
    It 'passes the stick check after writing, on a copied Ubuntu tree' {
        foreach ($f in 'EFI/BOOT/BOOTX64.EFI', 'casper/minimal.squashfs', 'boot/grub/grub.cfg') {
            $p = Join-Path $script:Root $f
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $p) -Force)
            [System.IO.File]::WriteAllText($p, 'x')
        }
        [void](Write-DzLinuxKitToTarget -TargetRoot $script:Root -KitSource $script:Kit -AutoinstallYaml $script:Yaml -Settings $script:Settings)
        $checks = @(Test-DzLinuxStick -Root $script:Root)
        @($checks | Where-Object { -not $_.Ok }) | Should -BeNullOrEmpty
        $checks.Count | Should -Be 6
    }
    It 'fails the check on an empty stick' {
        @(Test-DzLinuxStick -Root $script:Root | Where-Object { -not $_.Ok }).Count | Should -BeGreaterThan 3
    }
    It 'finds files too large for FAT32' {
        Get-DzFat32Problem -Root $script:Root | Should -BeNullOrEmpty
        [System.IO.File]::WriteAllText((Join-Path $script:Root 'big.squashfs'), ('x' * 2000))
        InModuleScope Linux {
            $script:Fat32MaxFile = 1000
            try { Get-DzFat32Problem -Root $args[0] | Should -Match 'big\.squashfs' } finally { $script:Fat32MaxFile = 4294967295 }
        } -ArgumentList $script:Root
    }
}

Describe 'Linux kit (kit\linux)' {
    It 'lists only Flathub ids that were checked' {
        $verified = @(Get-Content -LiteralPath (Join-Path $script:Repo 'tests/data/flatpak-ids-verified.txt') | Where-Object { $_ -and -not $_.StartsWith('#') })
        $apps = (Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:Repo 'kit/linux/apps.json') | ConvertFrom-Json)
        foreach ($a in $apps.apps) {
            if ($a.PSObject.Properties['flatpak']) {
                $verified | Should -Contain $a.flatpak
                $a.flatpak | Should -Match '^[A-Za-z][A-Za-z0-9_-]*(\.[A-Za-z0-9_-]+){2,}$'
            }
        }
    }
    It 'uses unique ids, known categories and known modes' {
        $apps = (Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:Repo 'kit/linux/apps.json') | ConvertFrom-Json)
        $modes = @((Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:Repo 'kit/config/modes.json') | ConvertFrom-Json).modes | ForEach-Object { $_.id })
        $cats = @($apps.categories | ForEach-Object { $_.id })
        $ids = @($apps.apps | ForEach-Object { $_.id })
        ($ids | Select-Object -Unique).Count | Should -Be $ids.Count
        foreach ($a in $apps.apps) {
            $cats | Should -Contain $a.category
            foreach ($m in @($a.modes)) { $modes | Should -Contain $m }
            @($a.PSObject.Properties.Name | Where-Object { $_ -match '(?i)cmd|command|script|exec' }) | Should -BeNullOrEmpty
        }
    }
    It 'passes its Python tests' {
        $py = Get-Command python3 -ErrorAction SilentlyContinue
        if (-not $py) { Set-ItResult -Skipped -Because 'python3 is not installed here'; return }
        $out = & $py.Source -m unittest discover -s (Join-Path $script:Repo 'tests/linux') 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($out -join "`n")
    }
    It 'has a Russian text for everything the setup shows' {
        $ru = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $script:Repo 'kit/lang/ru.json') | ConvertFrom-Json
        $have = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        foreach ($p in $ru.strings) { [void]$have.Add([string]$p[0]) }
        $code = Get-Content -Raw -LiteralPath (Join-Path $script:Repo 'kit/linux/dayzero.py')
        $texts = @([regex]::Matches($code, '\bT\("((?:[^"\\]|\\.)+)"') | ForEach-Object { $_.Groups[1].Value }) +
            @([regex]::Matches($code, '"title": "((?:[^"\\]|\\.)+)"') | ForEach-Object { $_.Groups[1].Value })
        $texts.Count | Should -BeGreaterThan 15
        $missing = @($texts | Where-Object { -not $have.Contains($_) } | Select-Object -Unique)
        $missing | Should -BeNullOrEmpty
    }
}

Describe 'Finding the newest ISO of each distro (Resolve-DzLinuxIsoSource)' {
    BeforeAll {
        $h = '0123456789abcdef' * 4
        $script:Pages = @{
            'https://dl.fedoraproject.org/pub/fedora/linux/releases/' = '<a href="43/">43/</a><a href="44/">44/</a><a href="45/">45/</a><a href="9/">9/</a>'
            'https://dl.fedoraproject.org/pub/fedora/linux/releases/45/Workstation/x86_64/iso/' = '<a href="Fedora-Workstation-45-1.4-x86_64-CHECKSUM">c</a><a href="Fedora-Workstation-Live-45-1.4.x86_64.iso">i</a>'
            'https://dl.fedoraproject.org/pub/fedora/linux/releases/45/Workstation/x86_64/iso/Fedora-Workstation-45-1.4-x86_64-CHECKSUM' = "SHA256 (Fedora-Workstation-Live-45-1.4.x86_64.iso) = $h"
            'https://cdimage.debian.org/debian-cd/current-live/amd64/iso-hybrid/SHA256SUMS' = "$h  debian-live-13.8.0-amd64-cinnamon.iso`n$h  debian-live-13.8.0-amd64-gnome.iso`n$h  debian-live-13.8.0-amd64-gnome.iso.contents"
            'https://mirrors.edge.kernel.org/linuxmint/stable/' = '<a href="../">..</a><a href="21.3/">21.3/</a><a href="22/">22/</a><a href="22.3/">22.3/</a>'
            'https://mirrors.edge.kernel.org/linuxmint/stable/22.3/sha256sum.txt' = "$h *linuxmint-22.3-cinnamon-64bit.iso`n$h *linuxmint-22.3-mate-64bit.iso"
            'https://cachyos.org/download/' = 'x https://iso.cachyos.org/desktop/260809/cachyos-desktop-linux-260809.iso y https://iso.cachyos.org/handheld/260628/cachyos-handheld-linux-260628.iso'
            'https://mirror.cachyos.org/ISO/desktop/260809/cachyos-desktop-linux-260809.iso.sha256' = "$h  cachyos-desktop-linux-260809.iso"
        }
        $pages = $script:Pages
        $script:Fetch = { param($u) if (-not $pages.ContainsKey($u)) { throw "not in the test pages: $u" }; $pages[$u] }.GetNewClosure()
        $script:Resolve = { param($id) Resolve-DzLinuxIsoSource -Distro (Get-DzLinuxDistro -Id $id) -AllowedHosts $script:Catalog.AllowedHosts -Fetch $script:Fetch }
    }
    It 'Fedora: the highest release folder, its CHECKSUM file, the Workstation live ISO' {
        $r = & $script:Resolve 'fedora-workstation'
        $r.Url | Should -Be 'https://dl.fedoraproject.org/pub/fedora/linux/releases/45/Workstation/x86_64/iso/Fedora-Workstation-Live-45-1.4.x86_64.iso'
        $r.Version | Should -Be '45'
        $r.Sha256 | Should -Match '^[0-9a-f]{64}$'
    }
    It 'Debian: the GNOME live ISO from the current release' {
        (& $script:Resolve 'debian-gnome').Url | Should -Be 'https://cdimage.debian.org/debian-cd/current-live/amd64/iso-hybrid/debian-live-13.8.0-amd64-gnome.iso'
    }
    It 'Linux Mint: the newest release folder and its Cinnamon ISO' {
        (& $script:Resolve 'linuxmint-cinnamon').Url | Should -Be 'https://mirrors.edge.kernel.org/linuxmint/stable/22.3/linuxmint-22.3-cinnamon-64bit.iso'
    }
    It 'CachyOS: the release cachyos.org names, not just the newest folder on the mirror' {
        $r = & $script:Resolve 'cachyos-desktop'
        $r.Url | Should -Be 'https://mirror.cachyos.org/ISO/desktop/260809/cachyos-desktop-linux-260809.iso'
        $r.SumsUrl | Should -Be 'https://mirror.cachyos.org/ISO/desktop/260809/cachyos-desktop-linux-260809.iso.sha256'
    }
    It 'refuses addresses that are not on the allowed hosts' {
        $d = (Get-DzLinuxDistro -Id 'debian-gnome').PSObject.Copy()
        $d.baseUrl = 'https://evil.example/debian/'
        { Resolve-DzLinuxIsoSource -Distro $d -AllowedHosts $script:Catalog.AllowedHosts -Fetch $script:Fetch } | Should -Throw '*not an allowed*'
    }
    It 'refuses a release name that could leave the folder' {
        $pages = @{ 'https://cachyos.org/download/' = 'desktop/../../x/cachyos-desktop-linux-x.iso' }
        $f = { param($u) $pages[$u] }.GetNewClosure()
        { Resolve-DzLinuxIsoSource -Distro (Get-DzLinuxDistro -Id 'cachyos-desktop') -AllowedHosts $script:Catalog.AllowedHosts -Fetch $f } | Should -Throw
    }
    It 'says so when nothing matches' {
        $pages = @{ 'https://cdimage.debian.org/debian-cd/current-live/amd64/iso-hybrid/SHA256SUMS' = '' }
        $f = { param($u) $pages[$u] }.GetNewClosure()
        { Resolve-DzLinuxIsoSource -Distro (Get-DzLinuxDistro -Id 'debian-gnome') -AllowedHosts $script:Catalog.AllowedHosts -Fetch $f } | Should -Throw '*No Debian*'
    }
}
