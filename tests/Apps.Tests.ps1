#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Tests for the app engine: winget exit codes, argument quoting, output cleaning, process
# runner, the install flow (with winget mocked), Microsoft 365 configuration, and the
# shipped app catalog.

BeforeDiscovery {
    # Every winget id in the kit config, read straight from the JSON (modules are not loaded yet).
    $cfgDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'kit/config'
    $script:WingetIds = New-Object System.Collections.Generic.List[string]
    $apps = Get-Content -Raw (Join-Path $cfgDir 'apps.json') | ConvertFrom-Json
    foreach ($a in $apps.apps) { if ($a.PSObject.Properties['winget']) { $script:WingetIds.Add($a.winget) } }
    $drivers = Join-Path $cfgDir 'drivers.json'
    if (Test-Path $drivers) {
        $d = Get-Content -Raw $drivers | ConvertFrom-Json
        foreach ($t in @($d.gpuApps) + @($d.oemTools)) { if ($t -and $t.PSObject.Properties['winget'] -and $t.winget) { $script:WingetIds.Add($t.winget) } }
    }
    $office = Get-Content -Raw (Join-Path $cfgDir 'office.json') | ConvertFrom-Json
    $script:WingetIds.Add($office.odt.wingetId)
}

BeforeAll {
    $repo = Split-Path -Parent $PSScriptRoot
    $script:Kit = Join-Path $repo 'kit'
    $lib = Join-Path $script:Kit 'lib'
    foreach ($m in (& (Join-Path $lib 'Modules.ps1'))) { Import-Module (Join-Path $lib $m) -Force -DisableNameChecking }
    Import-Module (Join-Path $repo 'builder/lib/Bundles.psm1') -Force
    $script:Config = Get-DzConfig -KitRoot $script:Kit
    $script:Verified = @(Get-Content (Join-Path $PSScriptRoot 'data/winget-ids-verified.txt') | Where-Object { $_ -and -not $_.StartsWith('#') })
}

Describe 'winget exit codes' {
    It '<Code> -> <Outcome>' -ForEach @(
        @{ Code = 0; Outcome = 'ok' },
        @{ Code = -1978335189; Outcome = 'installed' },      # 0x8A15002B no applicable update
        @{ Code = -1978335135; Outcome = 'installed' },      # 0x8A150061 already installed
        @{ Code = -1978335146; Outcome = 'nonElevated' },    # 0x8A150056 installer prohibits elevation
        @{ Code = -1978334974; Outcome = 'busy' },           # 0x8A150102 install in progress
        @{ Code = -1978334967; Outcome = 'rebootLater' },    # 0x8A150109 reboot to finish
        @{ Code = -1978334966; Outcome = 'rebootNow' },      # 0x8A15010A reboot required for install
        @{ Code = -1978335212; Outcome = 'notFound' },       # 0x8A150014 no packages found
        @{ Code = 3010; Outcome = 'rebootLater' },
        @{ Code = 12345; Outcome = 'failed' }
    ) {
        (Get-DzWingetExitInfo -Code $Code).Outcome | Should -Be $Outcome
    }
    It 'understands the unsigned value a scheduled task reports' {
        (Get-DzWingetExitInfo -Code 2316632150).Name | Should -Be 'APPINSTALLER_CLI_ERROR_INSTALLER_PROHIBITS_ELEVATION'
        (Get-DzWingetExitInfo -Code -1978335146).Hex | Should -Be '0x8A150056'
    }
}

Describe 'Command lines and output' {
    It 'quotes arguments like Windows expects' {
        ConvertTo-DzArgumentString -Arguments @('install', '--id', 'Notepad++.Notepad++') | Should -Be 'install --id Notepad++.Notepad++'
        ConvertTo-DzArgumentString -Arguments @('/configure', 'C:\Users\Jo Doe\config.xml') | Should -Be '/configure "C:\Users\Jo Doe\config.xml"'
        ConvertTo-DzArgumentString -Arguments @('say "hi"') | Should -Be '"say \"hi\""'
        ConvertTo-DzArgumentString -Arguments @('C:\dir with space\') | Should -Be '"C:\dir with space\\"'
        ConvertTo-DzArgumentString -Arguments @('') | Should -Be '""'
    }
    It 'drops spinners and progress bars from tool output' {
        $bar = [string][char]0x2588 * 10 + [string][char]0x2592 * 5 + '  12.0 MB / 40.0 MB'
        $text = "Found Steam [Valve.Steam]`r`n  -`r`n  \`r`n$bar`r`n45%`r`n12.3 MB / 50 MB`r`nSuccessfully installed`n"
        @(ConvertFrom-DzToolOutput -Text $text) | Should -Be @('Found Steam [Valve.Steam]', 'Successfully installed')
    }
    It 'runs a process, captures output and the exit code' -Skip:([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        $r = Invoke-DzProcess -FilePath '/bin/sh' -Arguments @('-c', 'echo hello; echo oops 1>&2; exit 3') -TimeoutSec 20
        $r.ExitCode | Should -Be 3
        $r.Output | Should -Contain 'hello'
        $r.Output | Should -Contain 'oops'
        $r.TimedOut | Should -BeFalse
    }
    It 'kills a process that runs too long' -Skip:([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        $r = Invoke-DzProcess -FilePath '/bin/sh' -Arguments @('-c', 'sleep 30') -TimeoutSec 1
        $r.TimedOut | Should -BeTrue
        $r.ExitCode | Should -Be -1
    }
}

Describe 'Install-DzWingetPackage (winget mocked)' {
    BeforeAll {
        function New-Ctx { $c = New-DzContext -KitRoot $script:Kit; $c.Flags['WingetPath'] = 'C:\fake\winget.exe'; return $c }
        function New-Out { param([int]$Code, [string[]]$Lines = @()) [pscustomobject]@{ ExitCode = $Code; Output = $Lines; TimedOut = $false } }
    }
    BeforeEach {
        Set-DzDryRun -Enabled $false
        $script:installCalls = 0
        Mock -ModuleName Winget Start-Sleep { }
        Mock -ModuleName Winget Invoke-DzAsUser { New-Out 0 @('Successfully installed') }
    }
    AfterAll { Set-DzDryRun -Enabled $false }

    It 'does nothing when the package is already installed' {
        Mock -ModuleName Winget Invoke-DzProcess { if ($Arguments[0] -eq 'list') { New-Out 0 @('Name Id Version', 'Steam Valve.Steam 2.10') } else { $script:installCalls++; New-Out 0 } }
        $r = Install-DzWingetPackage -Context (New-Ctx) -Id 'Valve.Steam' -Name 'Steam'
        $r.Status | Should -Be 'Done'
        $r.Message | Should -Match 'Already installed'
        $script:installCalls | Should -Be 0
    }
    It 'searches by name and fails clearly when the id is gone' {
        Mock -ModuleName Winget Invoke-DzProcess {
            switch ($Arguments[0]) { 'list' { New-Out -1978335212 } 'show' { New-Out -1978335212 } 'search' { New-Out 0 @('Name Id', 'Steam Valve.SteamNew') } default { New-Out 0 } }
        }
        $r = Install-DzWingetPackage -Context (New-Ctx) -Id 'Valve.Steam' -Name 'Steam'
        $r.Status | Should -Be 'Failed'
        $r.Message | Should -Match "Package id 'Valve.Steam' was not found"
        Should -Invoke -ModuleName Winget Invoke-DzProcess -ParameterFilter { $Arguments[0] -eq 'search' } -Times 1
    }
    It 'installs silently with exact id and accepted agreements' {
        Mock -ModuleName Winget Invoke-DzProcess { switch ($Arguments[0]) { 'list' { New-Out -1978335212 } 'show' { New-Out 0 } default { New-Out 0 @('Successfully installed') } } }
        $r = Install-DzWingetPackage -Context (New-Ctx) -Id 'VideoLAN.VLC' -Name 'VLC' -Scope 'machine'
        $r.Status | Should -Be 'Done'
        Should -Invoke -ModuleName Winget Invoke-DzProcess -Times 1 -ParameterFilter {
            $Arguments[0] -eq 'install' -and ($Arguments -contains '--exact') -and ($Arguments -contains '--silent') -and
            ($Arguments -contains '--accept-package-agreements') -and ($Arguments -contains '--accept-source-agreements') -and
            ($Arguments -join ' ') -match '--scope machine'
        }
    }
    It 'retries without admin rights when the installer refuses elevation (Spotify)' {
        Mock -ModuleName Winget Invoke-DzProcess { switch ($Arguments[0]) { 'list' { New-Out -1978335212 } 'show' { New-Out 0 } default { New-Out -1978335146 } } }
        $r = Install-DzWingetPackage -Context (New-Ctx) -Id 'Spotify.Spotify' -Name 'Spotify'
        $r.Status | Should -Be 'Done'
        Should -Invoke -ModuleName Winget Invoke-DzAsUser -Times 1
    }
    It 'goes straight to the user context for apps marked elevated=false' {
        Mock -ModuleName Winget Invoke-DzProcess { switch ($Arguments[0]) { 'list' { New-Out -1978335212 } 'show' { New-Out 0 } default { throw 'should not install elevated' } } }
        $r = Install-DzWingetPackage -Context (New-Ctx) -Id 'Discord.Discord' -Name 'Discord' -Elevated $false
        $r.Status | Should -Be 'Done'
        Should -Invoke -ModuleName Winget Invoke-DzAsUser -Times 1
    }
    It 'waits and retries when another installation is running' {
        $script:n = 0
        Mock -ModuleName Winget Invoke-DzProcess {
            switch ($Arguments[0]) { 'list' { New-Out -1978335212 } 'show' { New-Out 0 } default { $script:n++; if ($script:n -lt 2) { New-Out -1978334974 } else { New-Out 0 } } }
        }
        (Install-DzWingetPackage -Context (New-Ctx) -Id 'X.Y' -Name 'XY').Status | Should -Be 'Done'
        Should -Invoke -ModuleName Winget Start-Sleep -Times 1
    }
    It 'asks for a restart when the installer needs one first' {
        Mock -ModuleName Winget Invoke-DzProcess { switch ($Arguments[0]) { 'list' { New-Out -1978335212 } 'show' { New-Out 0 } default { New-Out -1978334966 } } }
        (Install-DzWingetPackage -Context (New-Ctx) -Id 'X.Y' -Name 'XY').Status | Should -Be 'Reboot'
    }
    It 'reports a warning when the app finishes after a restart' {
        Mock -ModuleName Winget Invoke-DzProcess { switch ($Arguments[0]) { 'list' { New-Out -1978335212 } 'show' { New-Out 0 } default { New-Out 3010 } } }
        $ctx = New-Ctx
        (Install-DzWingetPackage -Context $ctx -Id 'X.Y' -Name 'XY').Status | Should -Be 'Warn'
        $ctx.Flags['RestartRecommended'] | Should -BeTrue
    }
    It 'checks the id but installs nothing in dry-run mode' {
        Set-DzDryRun -Enabled $true
        Mock -ModuleName Winget Invoke-DzProcess { switch ($Arguments[0]) { 'list' { New-Out -1978335212 } 'show' { New-Out 0 } default { $script:installCalls++; New-Out 0 } } }
        $r = Install-DzWingetPackage -Context (New-Ctx) -Id 'X.Y' -Name 'XY'
        $r.Message | Should -Match 'DRY-RUN'
        $script:installCalls | Should -Be 0
        Should -Invoke -ModuleName Winget Invoke-DzProcess -ParameterFilter { $Arguments[0] -eq 'show' } -Times 1
    }
}

Describe 'Microsoft 365 configuration' {
    BeforeAll { $script:office = $script:Config.office }
    It 'maps plans to the documented ODT product ids' {
        Get-DzOfficeProductId -OfficeConfig $script:office -Plan 'personal' | Should -Be 'O365HomePremRetail'
        Get-DzOfficeProductId -OfficeConfig $script:office -Plan 'business' | Should -Be 'O365BusinessRetail'
        Get-DzOfficeProductId -OfficeConfig $script:office -Plan 'enterprise' | Should -Be 'O365ProPlusRetail'
        Get-DzOfficeProductId -OfficeConfig $script:office -Plan '' | Should -Be 'O365HomePremRetail'
        { Get-DzOfficeProductId -OfficeConfig $script:office -Plan 'pirate' } | Should -Throw
    }
    It 'installs exactly Word, Excel, PowerPoint, Outlook and OneNote' {
        $doc = New-Object System.Xml.XmlDocument
        $doc.LoadXml((New-DzOfficeConfigXml -OfficeConfig $script:office -ProductId 'O365HomePremRetail'))
        $doc.SelectSingleNode('/Configuration/Add/Product').GetAttribute('ID') | Should -Be 'O365HomePremRetail'
        $excluded = @($doc.SelectNodes('//ExcludeApp') | ForEach-Object { $_.GetAttribute('ID') })
        foreach ($keep in 'Word', 'Excel', 'PowerPoint', 'Outlook', 'OneNote') { $excluded | Should -Not -Contain $keep }
        foreach ($drop in 'Access', 'Publisher', 'Teams', 'OneDrive', 'Groove', 'Lync', 'OutlookForWindows') { $excluded | Should -Contain $drop }
    }
    It 'is silent, 64-bit, current channel, language of Windows, no licensing tricks' {
        $xml = New-DzOfficeConfigXml -OfficeConfig $script:office -ProductId 'O365HomePremRetail'
        $doc = New-Object System.Xml.XmlDocument; $doc.LoadXml($xml)
        $add = $doc.SelectSingleNode('/Configuration/Add')
        $add.GetAttribute('OfficeClientEdition') | Should -Be '64'
        $add.GetAttribute('Channel') | Should -Be 'Current'
        $doc.SelectSingleNode('//Language').GetAttribute('ID') | Should -Be 'MatchOS'
        $doc.SelectSingleNode('/Configuration/Display').GetAttribute('Level') | Should -Be 'None'
        $doc.SelectSingleNode('/Configuration/Display').GetAttribute('AcceptEULA') | Should -Be 'TRUE'
        $xml | Should -Not -Match 'PIDKEY|AUTOACTIVATE|KMS'
    }
    It 'refuses an app that the ODT does not know' {
        $bad = $script:office | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        $bad.apps = @('Word', 'Paint')
        { New-DzOfficeConfigXml -OfficeConfig $bad -ProductId 'O365HomePremRetail' } | Should -Throw '*Paint*'
    }
}

Describe 'Shipped app catalog' {
    BeforeAll { $script:apps = @($script:Config.apps.apps) }
    It 'has unique ids and a winget or Store id for every app (Microsoft 365 uses the ODT)' {
        @($script:apps | Group-Object id | Where-Object { $_.Count -gt 1 }).Count | Should -Be 0
        foreach ($a in $script:apps) {
            if ((Get-DzProperty $a 'kind' '') -eq 'office') { continue }
            $has = [bool](Get-DzProperty $a 'winget' '') -or [bool](Get-DzProperty $a 'msstore' '')
            $has | Should -BeTrue -Because "$($a.id) needs a package id"
        }
    }
    It 'puts every app in a known category, in the requested groups' {
        $cats = @($script:Config.apps.categories | ForEach-Object { $_.id })
        foreach ($a in $script:apps) { $cats | Should -Contain $a.category }
        foreach ($c in 'browsers', 'messaging', 'compression', 'utilities', 'ai') { $cats | Should -Contain $c }
        ($script:Config.apps.categories | Where-Object { $_.id -eq 'compression' }).pickOne | Should -BeTrue
    }
    It 'offers the requested apps: <_>' -ForEach @('chrome', 'opera', 'firefox', 'edge', 'brave', 'telegram', 'whatsapp', 'viber', 'teams', '7zip', 'winrar', 'wiztree', 'powertoys', 'claude', 'chatgpt', 'discord', 'steam', 'epic', 'microsoft-365', 'libreoffice') {
        @($script:apps | ForEach-Object { $_.id }) | Should -Contain $_
    }
    It 'installs per-user apps without admin rights (<_>)' -ForEach @('spotify', 'discord', 'telegram', 'claude') {
        $id = $_
        (Get-DzProperty ($script:apps | Where-Object { $_.id -eq $id }) 'elevated' $true) | Should -BeFalse
    }
    It 'gets WhatsApp from the Microsoft Store (it is not in winget)' {
        $w = $script:apps | Where-Object { $_.id -eq 'whatsapp' }
        $w.source | Should -Be 'msstore'
        $w.msstore | Should -Be '9NKSQGP7F2NH'
    }
    It 'only uses winget ids that were verified against winget-pkgs (<_>)' -ForEach $script:WingetIds {
        $script:Verified | Should -Contain $_
    }
    It 'installs Spotify and Discord without admin rights' {
        foreach ($id in 'spotify', 'discord') {
            (Get-DzProperty ($script:apps | Where-Object { $_.id -eq $id }) 'elevated' $true) | Should -BeFalse
        }
    }
    It 'keeps Steam and Epic in Gaming, leaves Zoom, ShareX, Teams and OneDrive out of every mode' {
        $g = Get-DzMode -Config $script:Config -Id 'gaming'
        @($g.apps) | Should -Contain 'steam'
        @($g.apps) | Should -Contain 'epic'
        foreach ($m in 'gaming', 'office', 'everything') {
            $apps = @((Get-DzMode -Config $script:Config -Id $m).apps)
            foreach ($gone in 'zoom', 'sharex', 'teams', 'onedrive') { $apps | Should -Not -Contain $gone }
        }
    }
    It 'offers LibreOffice as an unticked extra in Office mode' {
        $sys = [pscustomobject]@{ WindowsVersion = 11; Build = 26200; IsLaptop = $false; IsVirtualMachine = $false; GpuVendors = @(); Architecture = 'amd64'; EditionId = 'Core'; Brand = 'Other' }
        $r = Get-DzReviewModel -Mode (Get-DzMode -Config $script:Config -Id 'office') -System $sys -Config $script:Config
        ($r.Apps | Where-Object { $_.Id -eq 'libreoffice' }).Checked | Should -BeFalse
    }
    It 'only offers Windows Terminal on Windows 10' {
        $w11 = [pscustomobject]@{ WindowsVersion = 11; Build = 26200; IsLaptop = $false; IsVirtualMachine = $false; GpuVendors = @(); Architecture = 'amd64'; EditionId = 'Core'; Brand = 'Other' }
        $w10 = [pscustomobject]@{ WindowsVersion = 10; Build = 19045; IsLaptop = $false; IsVirtualMachine = $false; GpuVendors = @(); Architecture = 'amd64'; EditionId = 'Core'; Brand = 'Other' }
        $e = Get-DzMode -Config $script:Config -Id 'everything'
        @((Get-DzReviewModel -Mode $e -System $w11 -Config $script:Config).Apps | ForEach-Object { $_.Id }) | Should -Not -Contain 'windows-terminal'
        @((Get-DzReviewModel -Mode $e -System $w10 -Config $script:Config).Apps | ForEach-Object { $_.Id }) | Should -Contain 'windows-terminal'
    }
}

Describe 'Review screen: whole catalog, Custom mode and pick-one groups' {
    BeforeAll {
        $script:pc = [pscustomobject]@{ WindowsVersion = 11; Build = 26200; IsLaptop = $false; IsVirtualMachine = $false; GpuVendors = @('NVIDIA'); Architecture = 'amd64'; EditionId = 'Professional'; Brand = 'Other' }
        function Get-Review { param([string]$Mode, $Pre = $null) Get-DzReviewModel -Mode (Get-DzMode -Config $script:Config -Id $Mode) -System $script:pc -Config $script:Config -Preselect $Pre }
        function Get-Ticked { param($R) @($R.Apps | Where-Object { $_.Checked -and $_.Kind -ne 'none' } | ForEach-Object { $_.Id }) }
    }
    It 'shows the whole catalog in every mode, with only the mode''s apps ticked' {
        $r = Get-Review 'gaming'
        @($r.Apps | Where-Object { $_.Kind -eq 'app' }).Count | Should -BeGreaterThan 25
        $t = Get-Ticked $r
        $t | Should -Contain 'steam'
        $t | Should -Not -Contain 'telegram'
        $t | Should -Not -Contain 'microsoft-365'
    }
    It 'ticks Microsoft 365 for Office mode' {
        Get-Ticked (Get-Review 'office') | Should -Contain 'microsoft-365'
    }
    It 'makes compression a pick-one group: 7-Zip in Office, None in Gaming' {
        $o = @((Get-Review 'office').Apps | Where-Object { $_.GroupId -eq 'compression' })
        @($o | ForEach-Object { $_.Exclusive } | Select-Object -Unique) | Should -Be @($true)
        @($o | Where-Object { $_.Checked } | ForEach-Object { $_.Id }) | Should -Be @('7zip')
        $g = @((Get-Review 'gaming').Apps | Where-Object { $_.GroupId -eq 'compression' })
        @($g | Where-Object { $_.Checked } | ForEach-Object { $_.Id }) | Should -Be @('none:compression')
    }
    It 'never ticks two apps of a pick-one group' {
        $r = Get-Review 'custom' @{ apps = @('7zip', 'winrar') }
        @($r.Apps | Where-Object { $_.GroupId -eq 'compression' -and $_.Checked }).Count | Should -Be 1
    }
    It 'starts Custom with nothing ticked and no clean-up' {
        $r = Get-Review 'custom'
        @(Get-Ticked $r).Count | Should -Be 0
        @($r.Options | Where-Object { $_.Kind -eq 'tweak' -and $_.Checked }).Count | Should -Be 0
        (@($r.Options | Where-Object { $_.Kind -eq 'debloat' -and $_.Checked })[0]).Id | Should -Be 'none'
    }
    It 'pre-ticks the builder''s Custom picks and turns them into the right plan' {
        foreach ($t in @('preflight', 'app', 'office', 'tweak', 'debloat', 'winget')) { if (-not (Test-DzStepType -Type $t)) { throw "missing step type $t" } }
        $pre = @{ apps = @('chrome', 'telegram', 'whatsapp', 'claude', 'winrar'); office = $true; debloat = 'light'; tweaks = @('game-mode') }
        $r = Get-Review 'custom' $pre
        $t = Get-Ticked $r
        foreach ($id in 'chrome', 'telegram', 'whatsapp', 'claude', 'winrar', 'microsoft-365') { $t | Should -Contain $id }
        $opt = ConvertTo-DzPlanOption -Apps @($r.Apps) -Options @($r.Options)
        $opt.office | Should -BeTrue
        $opt.debloat | Should -Be 'light'
        $opt.explicitTweaks | Should -BeTrue
        $ids = @(New-DzPlan -Mode (Get-DzMode -Config $script:Config -Id 'custom') -Options $opt -System $script:pc -Config $script:Config | ForEach-Object { $_.id })
        foreach ($id in 'app:chrome', 'app:telegram', 'app:whatsapp', 'app:claude', 'app:winrar', 'office', 'tweak:game-mode', 'debloat') { $ids | Should -Contain $id }
        $ids | Should -Not -Contain 'app:microsoft-365'
        $ids | Should -Not -Contain 'app:steam'
        $ids | Should -Not -Contain 'tweak:telemetry-min'
    }
    It 'lets any mode drop its clean-up and tweaks on the review screen' {
        $r = Get-Review 'gaming'
        foreach ($o in $r.Options) { $o.Checked = ($o.Kind -eq 'debloat' -and $o.Id -eq 'none') }
        $opt = ConvertTo-DzPlanOption -Apps @($r.Apps) -Options @($r.Options)
        $ids = @(New-DzPlan -Mode (Get-DzMode -Config $script:Config -Id 'gaming') -Options $opt -System $script:pc -Config $script:Config | ForEach-Object { $_.id })
        $ids | Should -Not -Contain 'debloat'
        @($ids | Where-Object { $_ -like 'tweak:*' }).Count | Should -Be 0
    }
    It 'describes what each mode includes for the builder' {
        $g = Get-DzModeSummary -Mode (Get-DzMode -Config $script:Config -Id 'gaming') -Config $script:Config
        $g | Should -Match 'Steam'
        $g | Should -Match 'off on laptops'
        $g | Should -Match 'Memory Integrity'
        Get-DzModeSummary -Mode (Get-DzMode -Config $script:Config -Id 'custom') -Config $script:Config | Should -Match 'Nothing is ticked yet'
        Get-DzModeSummary -Mode (Get-DzMode -Config $script:Config -Id 'custom') -Config $script:Config -Preselect @{ apps = @('claude') } | Should -Match 'AI assistants: Claude'
    }
}

Describe 'Offline helpers for the stick' {
    It 'only downloads from Microsoft sources' {
        foreach ($b in Get-DzBundleList) { $b.Url | Should -Match '^https://(github\.com/microsoft/winget-cli/|officecdn\.microsoft\.com/)' }
    }
    It 'requires a Microsoft signature on the Office Deployment Tool' {
        (Get-DzBundleList | Where-Object { $_.Name -eq 'Office Deployment Tool' }).Signer | Should -Be 'Microsoft Corporation'
    }
    It 'recognises Microsoft as the signer and rejects look-alikes' {
        Test-DzSignerMatch -Subject 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US' -Publisher 'Microsoft Corporation' | Should -BeTrue
        Test-DzSignerMatch -Subject 'CN=Microsoft Corporation Fake Ltd, O=Evil' -Publisher 'Microsoft Corporation' | Should -BeFalse
        Test-DzSignerMatch -Subject '' -Publisher 'Microsoft Corporation' | Should -BeFalse
    }
}
