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
