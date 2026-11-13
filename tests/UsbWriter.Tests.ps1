#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Tests for builder\lib\UsbWriter.psm1, using a temporary folder as the "USB stick".

BeforeAll {
    $repo = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repo 'builder/lib/UsbWriter.psm1') -Force
    Import-Module (Join-Path $repo 'builder/lib/Unattend.psm1') -Force
    $script:KitSource = Join-Path $repo 'kit'

    function New-TestSetting {
        param([string]$BuildId = '0a1b2c3d')
        return [ordered]@{
            schemaVersion = 1; buildId = $BuildId; builtAt = '2026-11-12T12:00:00Z'; builderVersion = 'test'
            windowsVersion = 11; edition = 'auto'; userName = 'Gamer'; temporaryPassword = $true; defaultMode = 'gaming'; dryRun = $false
        }
    }
    function Invoke-TestWrite {
        param([string]$Root, [string]$BuildId = '0a1b2c3d')
        $xml = New-DzUnattendXml -Options @{
            UILanguage = 'en-US'; UserLocale = 'en-US'; InputLocale = '0409:00000409'; TimeZone = 'UTC'
            UserName = 'Gamer'; Password = 'pw-123456'; BuildId = $BuildId
        }
        return Write-DzKitToTarget -TargetRoot $Root -KitSource $script:KitSource -UnattendXml $xml -Settings (New-TestSetting -BuildId $BuildId)
    }
}

Describe 'Write-DzKitToTarget' {
    BeforeEach {
        $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $script:root)
    }

    It 'calls the tick callback while copying, so the builder window can stay responsive' {
        $xml = New-DzUnattendXml -Options @{
            UILanguage = 'en-US'; UserLocale = 'en-US'; InputLocale = '0409:00000409'; TimeZone = 'UTC'
            UserName = 'Gamer'; Password = 'pw-123456'; BuildId = '0a1b2c3d'
        }
        $count = @{ n = 0 }
        [void](Write-DzKitToTarget -TargetRoot $script:root -KitSource $script:KitSource -UnattendXml $xml -Settings (New-TestSetting) -Tick { $count.n++ })
        $count.n | Should -BeGreaterThan 3
    }

    It 'writes the answer file, toolkit, settings, marker and README' {
        $r = Invoke-TestWrite -Root $script:root
        Test-Path (Join-Path $script:root 'autounattend.xml') | Should -BeTrue
        Test-Path (Join-Path $script:root 'DayZero-README.txt') | Should -BeTrue
        Test-Path (Join-Path $script:root 'DayZero/DayZero.cmd') | Should -BeTrue
        Test-Path (Join-Path $script:root 'DayZero/bootstrap/CopyKit.cmd') | Should -BeTrue
        Test-Path (Join-Path $script:root 'DayZero/build-0a1b2c3d.marker') | Should -BeTrue
        $r.Backup | Should -BeNullOrEmpty
    }

    It 'writes the answer file as UTF-8 without a byte order mark' {
        [void](Invoke-TestWrite -Root $script:root)
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $script:root 'autounattend.xml'))
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) | Should -BeFalse
        [System.Text.Encoding]::UTF8.GetString($bytes) | Should -Match '^<\?xml'
    }

    It 'never puts the password into settings.json' {
        [void](Invoke-TestWrite -Root $script:root)
        $json = Get-Content -Raw (Join-Path $script:root 'DayZero/config/settings.json')
        $json | Should -Not -Match 'pw-123456'
        ($json | ConvertFrom-Json).buildId | Should -Be '0a1b2c3d'
    }

    It 'backs up an existing autounattend.xml instead of deleting it' {
        Set-Content -LiteralPath (Join-Path $script:root 'autounattend.xml') -Value '<old/>'
        $r = Invoke-TestWrite -Root $script:root
        $r.Backup | Should -Not -BeNullOrEmpty
        Get-Content -Raw $r.Backup | Should -Match '<old/>'
    }

    It 'keeps the user''s Drivers and Logs folders when rebuilding' {
        [void](Invoke-TestWrite -Root $script:root -BuildId '11111111')
        Set-Content -LiteralPath (Join-Path $script:root 'DayZero/Drivers/my-wifi.inf') -Value 'driver'
        Set-Content -LiteralPath (Join-Path $script:root 'DayZero/Logs/old.log') -Value 'log'
        [void](Invoke-TestWrite -Root $script:root -BuildId '22222222')
        Test-Path (Join-Path $script:root 'DayZero/Drivers/my-wifi.inf') | Should -BeTrue
        Test-Path (Join-Path $script:root 'DayZero/Logs/old.log') | Should -BeTrue
    }

    It 'keeps scripts already on the stick and copies the kit''s Scripts folder' {
        [void](Invoke-TestWrite -Root $script:root -BuildId '11111111')
        Test-Path (Join-Path $script:root 'DayZero/Scripts/README.txt') | Should -BeTrue
        Set-Content -LiteralPath (Join-Path $script:root 'DayZero/Scripts/on-stick.cmd') -Value 'echo stick'
        Set-Content -LiteralPath (Join-Path $script:root 'DayZero/Scripts/README.txt') -Value 'old readme'
        [void](Invoke-TestWrite -Root $script:root -BuildId '22222222')
        Test-Path (Join-Path $script:root 'DayZero/Scripts/on-stick.cmd') | Should -BeTrue
        Get-Content -Raw (Join-Path $script:root 'DayZero/Scripts/README.txt') | Should -Match 'YOUR OWN SCRIPTS' -Because 'kit files replace same-named ones'
    }
    It 'leaves exactly one build marker after a rebuild' {
        [void](Invoke-TestWrite -Root $script:root -BuildId '11111111')
        [void](Invoke-TestWrite -Root $script:root -BuildId '22222222')
        $markers = @(Get-ChildItem -LiteralPath (Join-Path $script:root 'DayZero') -Filter 'build-*.marker')
        $markers.Count | Should -Be 1
        $markers[0].Name | Should -Be 'build-22222222.marker'
    }

    It 'refuses a bad build id' {
        $s = New-TestSetting -BuildId 'nothex!!'
        { Write-DzKitToTarget -TargetRoot $script:root -KitSource $script:KitSource -UnattendXml '<x/>' -Settings $s } | Should -Throw
    }
}

Describe 'Test-DzUsbStick' {
    BeforeEach {
        $script:stick = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $script:stick)
        [void](Invoke-TestWrite -Root $script:stick)
        foreach ($f in 'setup.exe', 'bootmgr', 'sources/boot.wim', 'sources/install.swm', 'sources/install2.swm', 'efi/boot/bootx64.efi') {
            $p = Join-Path $script:stick $f
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $p) -Force)
            Set-Content -LiteralPath $p -Value 'x'
        }
        function Get-Check { param([object[]]$Checks, [string]$Name) return @($Checks | Where-Object { $_.Name -eq $Name }) | Select-Object -First 1 }
    }

    It 'passes a complete stick' {
        $c = @(Test-DzUsbStick -Root $script:stick -FileSystem 'FAT32')
        @($c | Where-Object { -not $_.Ok }) | Should -BeNullOrEmpty
        ($c | ForEach-Object { $_.Name }) | Should -Contain 'Answer file finds the toolkit'
        (Get-Check $c 'Your settings').Detail | Should -Match 'Mode gaming'
    }
    It 'changes nothing on the stick' {
        $before = @(Get-ChildItem -LiteralPath $script:stick -Recurse -File | ForEach-Object { $_.FullName + '|' + $_.Length + '|' + $_.LastWriteTimeUtc.Ticks })
        [void](Test-DzUsbStick -Root $script:stick -FileSystem 'FAT32')
        $after = @(Get-ChildItem -LiteralPath $script:stick -Recurse -File | ForEach-Object { $_.FullName + '|' + $_.Length + '|' + $_.LastWriteTimeUtc.Ticks })
        $after | Should -Be $before
    }
    It 'reports a missing Windows Setup file, boot file and image' {
        Remove-Item -LiteralPath (Join-Path $script:stick 'setup.exe')
        Remove-Item -LiteralPath (Join-Path $script:stick 'efi/boot/bootx64.efi')
        Remove-Item -LiteralPath (Join-Path $script:stick 'sources/install.swm'), (Join-Path $script:stick 'sources/install2.swm')
        $c = @(Test-DzUsbStick -Root $script:stick)
        (Get-Check $c 'Windows Setup files').Ok | Should -BeFalse
        (Get-Check $c 'Windows Setup files').Detail | Should -Match 'setup\.exe'
        (Get-Check $c 'Boot files').Ok | Should -BeFalse
        (Get-Check $c 'Windows image').Ok | Should -BeFalse
    }
    It 'notices a missing part of a split image' {
        Remove-Item -LiteralPath (Join-Path $script:stick 'sources/install2.swm')
        Set-Content -LiteralPath (Join-Path $script:stick 'sources/install3.swm') -Value 'x'
        $c = Get-Check @(Test-DzUsbStick -Root $script:stick) 'Windows image'
        $c.Ok | Should -BeFalse
        $c.Detail | Should -Match 'install2\.swm'
    }
    It 'fails an answer file that contains disk settings' {
        $answer = Join-Path $script:stick 'autounattend.xml'
        $xml = (Get-Content -Raw -LiteralPath $answer) -replace '</unattend>', '<settings pass="windowsPE"><DiskConfiguration><WipeDisk>true</WipeDisk></DiskConfiguration></settings></unattend>'
        Set-Content -LiteralPath $answer -Value $xml
        $c = Get-Check @(Test-DzUsbStick -Root $script:stick) 'Answer file'
        $c.Ok | Should -BeFalse
        $c.Detail | Should -Match 'DiskConfiguration'
    }
    It 'fails a missing, broken or foreign answer file' {
        $answer = Join-Path $script:stick 'autounattend.xml'
        Set-Content -LiteralPath $answer -Value '<unattend><oops>'
        (Get-Check @(Test-DzUsbStick -Root $script:stick) 'Answer file').Ok | Should -BeFalse
        Set-Content -LiteralPath $answer -Value '<unattend xmlns="urn:schemas-microsoft-com:unattend"/>'
        (Get-Check @(Test-DzUsbStick -Root $script:stick) 'Answer file').Detail | Should -Match 'not made by DayZero'
        Remove-Item -LiteralPath $answer
        (Get-Check @(Test-DzUsbStick -Root $script:stick) 'Answer file').Detail | Should -Match 'Missing'
    }
    It 'fails when the marker the answer file looks for is gone' {
        Get-ChildItem -LiteralPath (Join-Path $script:stick 'DayZero') -Filter 'build-*.marker' | Remove-Item
        (Get-Check @(Test-DzUsbStick -Root $script:stick) 'Answer file finds the toolkit').Ok | Should -BeFalse
    }
    It 'fails an incomplete toolkit and settings from another build' {
        Remove-Item -LiteralPath (Join-Path $script:stick 'DayZero/DayZero.ps1')
        $settings = Join-Path $script:stick 'DayZero/config/settings.json'
        Set-Content -LiteralPath $settings -Value ((Get-Content -Raw -LiteralPath $settings) -replace '0a1b2c3d', 'ffffffff')
        $c = @(Test-DzUsbStick -Root $script:stick)
        (Get-Check $c 'DayZero toolkit').Detail | Should -Match 'DayZero\.ps1'
        (Get-Check $c 'Your settings').Ok | Should -BeFalse
    }
    It 'uses what Windows reports about the image and the file system' {
        $info = [pscustomobject]@{ Error = $null; WindowsVersion = 11; Build = 26100; Editions = @([pscustomobject]@{ Index = 1; Name = 'Windows 11 Home' }, [pscustomobject]@{ Index = 2; Name = 'Windows 11 Pro' }) }
        (Get-Check @(Test-DzUsbStick -Root $script:stick -ImageInfo $info -FileSystem 'FAT32') 'Windows image opens').Detail | Should -Be 'Windows 11 build 26100: Home, Pro'
        $bad = [pscustomobject]@{ Error = 'The file is corrupt.' }
        (Get-Check @(Test-DzUsbStick -Root $script:stick -ImageInfo $bad) 'Windows image opens').Ok | Should -BeFalse
        (Get-Check @(Test-DzUsbStick -Root $script:stick -FileSystem 'NTFS') 'File system').Detail | Should -Match '^NTFS: made by another tool'
    }
    It 'checks only the answer file and toolkit of an export folder' {
        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $folder)
        [void](Invoke-TestWrite -Root $folder)
        $c = @(Test-DzUsbStick -Root $folder -ToolkitOnly)
        @($c | Where-Object { -not $_.Ok }) | Should -BeNullOrEmpty
        ($c | ForEach-Object { $_.Name }) | Should -Not -Contain 'Windows Setup files'
    }
}

Describe 'Copy-DzKit leaves this PC''s leftovers behind' {
    It 'does not copy state.json, backup or the language choice from the kit folder' {
        $kit = Join-Path $TestDrive 'kitcopy'
        Copy-Item -LiteralPath $script:KitSource -Destination $kit -Recurse
        Set-Content -LiteralPath (Join-Path $kit 'state.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path $kit 'state.json.reset-1') -Value '{}'
        Set-Content -LiteralPath (Join-Path $kit 'language.txt') -Value 'ru'
        [void](New-Item -ItemType Directory -Path (Join-Path $kit 'backup'))
        $dest = Join-Path $TestDrive 'kitdest'
        Copy-DzKit -KitSource $kit -Destination $dest
        Test-Path (Join-Path $dest 'DayZero.ps1') | Should -BeTrue
        Test-Path (Join-Path $dest 'lang/ru.json') | Should -BeTrue
        foreach ($n in 'state.json', 'state.json.reset-1', 'language.txt', 'backup') { Test-Path (Join-Path $dest $n) | Should -BeFalse }
    }
}
