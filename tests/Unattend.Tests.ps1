#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Tests for builder\lib\Unattend.psm1 - the autounattend.xml generator.
# Run with tools\Invoke-DzChecks.ps1 (works on Windows PowerShell 5.1 and PowerShell 7).

BeforeAll {
    $repo = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repo 'builder/lib/Unattend.psm1') -Force

    function New-TestOption {
        param([hashtable]$Override = @{})
        $o = @{
            UILanguage = 'en-US'; UserLocale = 'fi-FI'; InputLocale = '040b:0000040b'
            TimeZone = 'FLE Standard Time'; Edition = 'auto'; UserName = 'Gamer'
            Password = 'S3cret!pw'; ComputerName = 'RIG-01'; BuildId = '0a1b2c3d'; GeneratorVersion = 'test'
        }
        foreach ($k in $Override.Keys) { $o[$k] = $Override[$k] }
        return $o
    }
    function Get-TestDoc {
        param([string]$Xml)
        $doc = New-Object System.Xml.XmlDocument
        $doc.LoadXml($Xml)
        $ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
        $ns.AddNamespace('u', 'urn:schemas-microsoft-com:unattend')
        $ns.AddNamespace('wcm', 'http://schemas.microsoft.com/WMIConfig/2002/State')
        return @{ Doc = $doc; Ns = $ns }
    }
    function Get-Node {
        param([hashtable]$T, [string]$XPath)
        return $T.Doc.SelectNodes($XPath, $T.Ns)
    }
}

Describe 'Disk safety' {
    It 'never writes disk or image-install settings (edition <_>)' -ForEach @('auto', 'home', 'pro', 'key') {
        $opts = New-TestOption -Override @{ Edition = $_; ProductKey = 'ABCDE-FGHIJ-KLMNO-PQRST-UVWXY' }
        $t = Get-TestDoc (New-DzUnattendXml -Options $opts)
        foreach ($name in (Get-DzForbiddenUnattendElement)) {
            $t.Doc.GetElementsByTagName($name, 'urn:schemas-microsoft-com:unattend').Count | Should -Be 0 -Because "<$name> could wipe or pick a disk"
        }
    }
    It 'tells the reader that disk selection stays manual' {
        New-DzUnattendXml -Options (New-TestOption) | Should -Match 'disk selection stays manual'
    }
}

Describe 'No OOBE hacks' {
    It 'uses only documented settings (no BypassNRO, LabConfig, ms-cxh, registry edits)' {
        $xml = New-DzUnattendXml -Options (New-TestOption)
        $xml | Should -Not -Match 'BypassNRO|LabConfig|ms-cxh|reg(\.exe)? add|HKLM\\SYSTEM\\Setup'
    }
}

Describe 'Passwords' {
    It 'never stores the password as plain text' {
        $xml = New-DzUnattendXml -Options (New-TestOption)
        $xml | Should -Not -Match ([regex]::Escape('S3cret!pw'))
        $t = Get-TestDoc $xml
        @(Get-Node $t '//u:Password/u:PlainText') | ForEach-Object { $_.InnerText | Should -Be 'false' }
        @(Get-Node $t '//u:Password').Count | Should -Be 2   # LocalAccount + AutoLogon
    }
    It 'encodes like Windows Setup: base64(UTF-16LE(password + "Password"))' {
        ConvertTo-DzUnattendSecret -Value 'abc' | Should -BeExactly 'YQBiAGMAUABhAHMAcwB3AG8AcgBkAA=='
        $t = Get-TestDoc (New-DzUnattendXml -Options (New-TestOption))
        foreach ($v in @(Get-Node $t '//u:Password/u:Value')) {
            [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($v.InnerText)) | Should -BeExactly 'S3cret!pwPassword'
        }
    }
    It 'masks password values in the on-screen preview' {
        $preview = Get-DzUnattendPreview -Xml (New-DzUnattendXml -Options (New-TestOption))
        $preview | Should -Not -Match ([regex]::Escape((ConvertTo-DzUnattendSecret -Value 'S3cret!pw')))
        $preview | Should -Match 'hidden in preview'
    }
}

Describe 'Edition selection' {
    It 'AUTO writes no product key at all, so Setup can use the firmware key' {
        $t = Get-TestDoc (New-DzUnattendXml -Options (New-TestOption -Override @{ Edition = 'auto' }))
        @(Get-Node $t '//u:ProductKey').Count | Should -Be 0
        @(Get-Node $t '//u:UserData/u:AcceptEula')[0].InnerText | Should -Be 'true'
    }
    It 'HOME uses the Home generic install key' {
        $t = Get-TestDoc (New-DzUnattendXml -Options (New-TestOption -Override @{ Edition = 'home' }))
        @(Get-Node $t '//u:ProductKey/u:Key')[0].InnerText | Should -Be 'YTMG3-N6DKC-DKB77-7M9GH-8HVX7'
    }
    It 'PRO uses the Pro generic install key' {
        $t = Get-TestDoc (New-DzUnattendXml -Options (New-TestOption -Override @{ Edition = 'pro' }))
        @(Get-Node $t '//u:ProductKey/u:Key')[0].InnerText | Should -Be 'VK7JG-NPHTM-C97JM-9MPGT-3V66T'
        @(Get-Node $t '//u:ProductKey/u:WillShowUI')[0].InnerText | Should -Be 'OnError'
    }
    It 'KEY uses the typed key, upper-cased' {
        $t = Get-TestDoc (New-DzUnattendXml -Options (New-TestOption -Override @{ Edition = 'key'; ProductKey = ' abcde-fghij-klmno-pqrst-uvwxy ' }))
        @(Get-Node $t '//u:ProductKey/u:Key')[0].InnerText | Should -Be 'ABCDE-FGHIJ-KLMNO-PQRST-UVWXY'
    }
    It 'KEY with a malformed key is refused' {
        { New-DzUnattendXml -Options (New-TestOption -Override @{ Edition = 'key'; ProductKey = '12345' }) } | Should -Throw '*product key*'
    }
}

Describe 'Account and OOBE screens' {
    BeforeAll {
        $script:t = Get-TestDoc (New-DzUnattendXml -Options (New-TestOption))
    }
    It 'creates one local administrator account' {
        $accounts = @(Get-Node $script:t '//u:LocalAccounts/u:LocalAccount')
        $accounts.Count | Should -Be 1
        $accounts[0].SelectSingleNode('u:Name', $script:t.Ns).InnerText | Should -Be 'Gamer'
        $accounts[0].SelectSingleNode('u:Group', $script:t.Ns).InnerText | Should -Be 'Administrators'
        $accounts[0].GetAttribute('action', 'http://schemas.microsoft.com/WMIConfig/2002/State') | Should -Be 'add'
    }
    It 'hides the <_> page' -ForEach @('HideEULAPage', 'HideOEMRegistrationScreen', 'HideOnlineAccountScreens', 'HideWirelessSetupInOOBE') {
        @(Get-Node $script:t "//u:OOBE/u:$_")[0].InnerText | Should -Be 'true'
    }
    It 'answers the privacy page with Express settings off (ProtectYourPC = 3)' {
        @(Get-Node $script:t '//u:OOBE/u:ProtectYourPC')[0].InnerText | Should -Be '3'
    }
    It 'signs in automatically a limited number of times' {
        @(Get-Node $script:t '//u:AutoLogon/u:Enabled')[0].InnerText | Should -Be 'true'
        @(Get-Node $script:t '//u:AutoLogon/u:LogonCount')[0].InnerText | Should -Be '10'
        @(Get-Node $script:t '//u:AutoLogon/u:Username')[0].InnerText | Should -Be 'Gamer'
    }
    It 'leaves out AutoLogon when it is switched off' {
        $t2 = Get-TestDoc (New-DzUnattendXml -Options (New-TestOption -Override @{ AutoLogon = $false }))
        @(Get-Node $t2 '//u:AutoLogon').Count | Should -Be 0
    }
    It 'uses * (random name) when no computer name is given' {
        $t2 = Get-TestDoc (New-DzUnattendXml -Options (New-TestOption -Override @{ ComputerName = '' }))
        @(Get-Node $t2 '//u:ComputerName')[0].InnerText | Should -Be '*'
    }
    It 'handles non-ASCII user names and stays valid UTF-8 XML' {
        $name = 'J' + [char]0x00FC + 'ri ' + [char]0x00D5 + 'un'   # non-ASCII, kept as escapes so this file stays ASCII
        $xml = New-DzUnattendXml -Options (New-TestOption -Override @{ UserName = $name })
        $xml | Should -Match '^<\?xml version="1.0" encoding="utf-8"\?>'
        $t2 = Get-TestDoc $xml
        @(Get-Node $t2 '//u:LocalAccount/u:Name')[0].InnerText | Should -BeExactly $name
    }
}

Describe 'Passes, components and regional settings' {
    It 'has the windowsPE, specialize and oobeSystem passes' {
        $t = Get-TestDoc (New-DzUnattendXml -Options (New-TestOption))
        @(Get-Node $t '/u:unattend/u:settings' | ForEach-Object { $_.GetAttribute('pass') }) |
            Should -Be @('windowsPE', 'specialize', 'oobeSystem')
    }
    It 'marks every component for <_>' -ForEach @('amd64', 'arm64') {
        $t = Get-TestDoc (New-DzUnattendXml -Options (New-TestOption -Override @{ Architecture = $_ }))
        $arch = $_
        @(Get-Node $t '//u:component') | ForEach-Object {
            $_.GetAttribute('processorArchitecture') | Should -Be $arch
            $_.GetAttribute('publicKeyToken') | Should -Be '31bf3856ad364e35'
        }
    }
    It 'writes language, region, keyboard and time zone' {
        $t = Get-TestDoc (New-DzUnattendXml -Options (New-TestOption))
        @(Get-Node $t '//u:SetupUILanguage/u:UILanguage')[0].InnerText | Should -Be 'en-US'
        @(Get-Node $t "//u:component[@name='Microsoft-Windows-International-Core']/u:UserLocale")[0].InnerText | Should -Be 'fi-FI'
        @(Get-Node $t "//u:component[@name='Microsoft-Windows-International-Core']/u:SystemLocale")[0].InnerText | Should -Be 'fi-FI'
        @(Get-Node $t "//u:component[@name='Microsoft-Windows-International-Core']/u:InputLocale")[0].InnerText | Should -Be '040b:0000040b'
        @(Get-Node $t '//u:TimeZone')[0].InnerText | Should -Be 'FLE Standard Time'
    }
}

Describe 'Bootstrap commands' {
    It 'specialize copies the kit from the drive that has this build marker (never C:)' {
        $c = Get-DzKitSearchCommand -BuildId '0a1b2c3d'
        $c.Specialize | Should -Match 'DayZero\\build-0a1b2c3d\.marker'
        $c.Specialize | Should -Match 'CopyKit\.cmd %d: 0a1b2c3d'
        $c.Specialize | Should -Match '\(D E F'
        $c.Specialize | Should -Not -Match '\(C '
    }
    It 'first logon prefers the copy on C: and passes the build id' {
        $c = Get-DzKitSearchCommand -BuildId '0a1b2c3d'
        $c.FirstLogon | Should -Match '\(C D E'
        $c.FirstLogon | Should -Match 'FirstLogon\.cmd 0a1b2c3d'
    }
    It 'puts both commands into the answer file' {
        $t = Get-TestDoc (New-DzUnattendXml -Options (New-TestOption))
        @(Get-Node $t '//u:RunSynchronousCommand/u:Path')[0].InnerText | Should -Match 'CopyKit\.cmd'
        @(Get-Node $t '//u:FirstLogonCommands/u:SynchronousCommand/u:CommandLine')[0].InnerText | Should -Match 'FirstLogon\.cmd'
    }
    It 'makes 8-character hex build ids' {
        1..20 | ForEach-Object { New-DzBuildId | Should -Match '^[0-9a-f]{8}$' }
    }
}

Describe 'Input validation' {
    It 'computer name <Name> -> valid: <Valid>' -ForEach @(
        @{ Name = ''; Valid = $true }, @{ Name = 'RIG-01'; Valid = $true }, @{ Name = 'ABCDEFGHIJKLMNO'; Valid = $true },
        @{ Name = 'ABCDEFGHIJKLMNOP'; Valid = $false }, @{ Name = '12345'; Valid = $false }, @{ Name = 'my pc'; Valid = $false },
        @{ Name = '-rig'; Valid = $false }, @{ Name = 'rig_1'; Valid = $false }
    ) {
        ($null -eq (Test-DzComputerName -Name $Name)) | Should -Be $Valid
    }
    It 'user name <Name> -> valid: <Valid>' -ForEach @(
        @{ Name = 'Gamer'; Valid = $true }, @{ Name = 'Mari Maasikas'; Valid = $true }, @{ Name = ''; Valid = $false },
        @{ Name = 'Administrator'; Valid = $false }, @{ Name = 'guest'; Valid = $false }, @{ Name = 'a/b'; Valid = $false },
        @{ Name = 'Tom & Jerry'; Valid = $false }, @{ Name = 'x' * 21; Valid = $false }, @{ Name = '...'; Valid = $false },
        @{ Name = ' padded'; Valid = $false }
    ) {
        ($null -eq (Test-DzUserName -Name $Name)) | Should -Be $Valid
    }
    It 'rejects a user name equal to the computer name' {
        Test-DzUserName -Name 'RIG' -ComputerName 'rig' | Should -Not -BeNullOrEmpty
    }
    It 'keyboard <Value> -> valid: <Valid>' -ForEach @(
        @{ Value = '0409:00000409'; Valid = $true }, @{ Value = '040b:0000040b;0409:00000409'; Valid = $true },
        @{ Value = '0411:{03B5835F-F03C-411B-9CE2-AA23E1171E36}{A76C93D9-5523-4E90-AAFA-4DB112F9AC76}'; Valid = $true },
        @{ Value = 'en-US'; Valid = $false }, @{ Value = ''; Valid = $false }
    ) {
        ($null -eq (Test-DzInputLocale -Value $Value)) | Should -Be $Valid
    }
    It 'refuses to build with <Case>' -ForEach @(
        @{ Case = 'an empty password'; Override = @{ Password = '' } },
        @{ Case = 'a bad build id'; Override = @{ BuildId = 'XYZ' } },
        @{ Case = 'a bad locale'; Override = @{ UserLocale = 'not a locale' } },
        @{ Case = 'an unknown edition'; Override = @{ Edition = 'ultimate' } },
        @{ Case = 'an x86 architecture'; Override = @{ Architecture = 'x86' } },
        @{ Case = 'a reserved user name'; Override = @{ UserName = 'Administrator' } }
    ) {
        { New-DzUnattendXml -Options (New-TestOption -Override $Override) } | Should -Throw
    }
}
