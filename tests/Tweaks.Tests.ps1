#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Tests for tweaks, debloat, restore point gate, activation helpers and undo.
# The registry is replaced by an in-memory fake, so apply -> undo can be checked exactly.

BeforeDiscovery {
    $cfgDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'kit/config'
    $script:TweakItems = @((Get-Content -Raw (Join-Path $cfgDir 'tweaks.json') | ConvertFrom-Json).tweaks | ForEach-Object { @{ Id = $_.id; Tweak = $_ } })
    $script:DebloatItems = @((Get-Content -Raw (Join-Path $cfgDir 'debloat.json') | ConvertFrom-Json).packages | ForEach-Object { @{ Name = $_.name; Item = $_ } })
}

BeforeAll {
    $repo = Split-Path -Parent $PSScriptRoot
    $script:SourceKit = Join-Path $repo 'kit'
    $lib = Join-Path $script:SourceKit 'lib'
    foreach ($m in (& (Join-Path $lib 'Modules.ps1'))) { Import-Module (Join-Path $lib $m) -Force -DisableNameChecking }
    $script:Config = Get-DzConfig -KitRoot $script:SourceKit

    function Use-FakeRegistry {
        $script:Reg = @{}
        Mock -ModuleName Tweaks Get-DzRegistryValue {
            $k = "$Path|$Name"
            if ($script:Reg.ContainsKey($k)) { [pscustomobject]@{ Exists = $true; Value = $script:Reg[$k].Value; Kind = $script:Reg[$k].Kind } }
            else { [pscustomobject]@{ Exists = $false; Value = $null; Kind = $null } }
        }
        Mock -ModuleName Tweaks Set-DzRegistryValue {
            if (Test-DzProtectedRegistryPath -Path $Path) { throw 'protected' }
            $script:Reg["$Path|$Name"] = @{ Value = $Value; Kind = $Kind }
        }
        Mock -ModuleName Tweaks Remove-DzRegistryValue { [void]$script:Reg.Remove("$Path|$Name") }
        Mock -ModuleName Tweaks Get-DzRegistryValueName {
            @($script:Reg.Keys | Where-Object { $_.StartsWith("$Path|") } | ForEach-Object { $_.Substring($Path.Length + 1) })
        }
        # Services, machine environment variables and registry keys, in memory too.
        $script:Svc = @{ DiagTrack = 'Automatic'; WerSvc = 'Manual'; CscService = 'Manual'; MapsBroker = 'AutomaticDelayed'; StorSvc = 'Automatic'; lfsvc = 'Manual' }
        Mock -ModuleName Tweaks Get-DzServiceStart { if ($script:Svc.ContainsKey($Name)) { $script:Svc[$Name] } else { $null } }
        Mock -ModuleName Tweaks Set-DzServiceStart {
            if (Test-DzProtectedService -Name $Name) { throw 'protected service' }
            $script:Svc[$Name] = $Startup
        }
        $script:EnvVars = @{}
        Mock -ModuleName Tweaks Get-DzMachineEnvironment { if ($script:EnvVars.ContainsKey($Name)) { $script:EnvVars[$Name] } else { $null } }
        Mock -ModuleName Tweaks Set-DzMachineEnvironment { if ($null -eq $Value -or [string]$Value -eq '') { [void]$script:EnvVars.Remove($Name) } else { $script:EnvVars[$Name] = $Value } }
        $script:Keys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($k in 'HKCU:\Software', 'HKCU:\Software\Classes', 'HKCU:\Software\Classes\CLSID') { [void]$script:Keys.Add($k) }
        Mock -ModuleName Tweaks Test-DzRegistryKey { $script:Keys.Contains($Path) }
        Mock -ModuleName Tweaks New-DzRegistryKey {
            $p = $Path
            while ($p -and -not $p.EndsWith(':')) { [void]$script:Keys.Add($p); $i = $p.LastIndexOf('\'); $p = if ($i -gt 0) { $p.Substring(0, $i) } else { $null } }
            $script:Reg["$Path|(default)"] = @{ Value = $DefaultValue; Kind = 'String' }
        }
        Mock -ModuleName Tweaks Remove-DzRegistryKey {
            foreach ($k in @($script:Keys | Where-Object { $_ -eq $Path -or $_.StartsWith("$Path\") })) { [void]$script:Keys.Remove($k) }
            foreach ($k in @($script:Reg.Keys | Where-Object { $_.StartsWith("$Path\") -or $_.StartsWith("$Path|") })) { [void]$script:Reg.Remove($k) }
        }
    }
    function New-TestKitRoot {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $dir)
        Set-DzKitRoot -Path $dir
        return $dir
    }
    function Get-Tweak { param([string]$Id) Get-DzCatalogItem -Catalog $script:Config.tweaks -Collection 'tweaks' -Id $Id }
    $script:Pro = [pscustomobject]@{ WindowsVersion = 11; Build = 26200; EditionId = 'Professional'; IsLaptop = $false; IsVirtualMachine = $false; GpuVendors = @('NVIDIA'); Architecture = 'amd64' }
}

Describe 'tweaks.json is documented and safe' {
    It '<Id> says what it does and why, and uses known action types' -ForEach $script:TweakItems {
        $Tweak.title | Should -Not -BeNullOrEmpty
        $Tweak.what | Should -Not -BeNullOrEmpty
        $Tweak.why | Should -Not -BeNullOrEmpty
        @($Tweak.actions).Count | Should -BeGreaterThan 0
        foreach ($a in $Tweak.actions) {
            $a.type | Should -BeIn @('registry', 'registryKey', 'service', 'environment', 'powerPlan', 'startupDisable', 'cleanTemp', 'componentCleanup')
            if ($a.type -in @('registry', 'registryKey')) {
                $a.path | Should -Match '^HK(CU|LM):\\'
                Test-DzProtectedRegistryPath -Path $a.path | Should -BeFalse -Because 'Windows Update and Defender are off limits'
            }
            if ($a.type -eq 'registry') { $a.kind | Should -BeIn @('DWord', 'QWord', 'String', 'ExpandString', 'Binary', 'MultiString') }
            if ($a.type -eq 'service') {
                Test-DzProtectedService -Name $a.name | Should -BeFalse -Because 'Windows Update, Defender, firewall and Store services are off limits'
                $a.startup | Should -BeIn @('Manual', 'Disabled', 'Automatic', 'AutomaticDelayed')
            }
        }
    }
    It 'never disables Windows Update or Defender, or weakens Defender' {
        $text = Get-Content -Raw (Join-Path $script:SourceKit 'config/tweaks.json')
        $text | Should -Not -Match 'wuauserv|WinDefend|DisableAntiSpyware|NoAutoUpdate|DisableRealtimeMonitoring|SubmitSamplesConsent|Set-MpPreference|SpynetReporting'
    }
    It 'leaves Internet Connection Sharing alone (Mobile hotspot needs it)' {
        $services = @($script:Config.tweaks.tweaks | ForEach-Object { @($_.actions) } | Where-Object { $_.type -eq 'service' } | ForEach-Object { $_.name })
        $services | Should -Not -Contain 'SharedAccess'
        $services | Should -Contain 'DiagTrack'
    }
    It 'keeps the security trade-offs off by default, with a warning' {
        foreach ($id in 'memory-integrity-off', 'game-bar-off') {
            $t = Get-Tweak $id
            $t.optional | Should -BeTrue
            $t.default | Should -BeFalse
            $t.warning | Should -Not -BeNullOrEmpty
        }
        (Get-Tweak 'memory-integrity-off').warning | Should -Match 'SECURITY'
    }
    It 'asks first on laptops for the power plan, with a battery warning' {
        $t = Get-Tweak 'power-plan'
        $t.default | Should -BeTrue
        $t.defaultLaptop | Should -BeFalse
        $t.laptopWarning | Should -Match 'battery'
    }
    It 'gives every gaming tweak the user asked for (privacy ones through the clean-up level)' {
        $g = Get-DzMode -Config $script:Config -Id 'gaming'
        foreach ($id in 'game-mode', 'gpu-scheduling', 'mouse-accel-off', 'background-apps-off', 'startup-trim', 'power-plan', 'memory-integrity-off', 'game-bar-off') {
            @($g.tweaks) | Should -Contain $id
        }
        $g.debloat | Should -Be 'standard'
        @((Get-DzDebloatLevel -Config $script:Config -Id 'standard').tweaks) | Should -Contain 'telemetry-off'
        foreach ($id in 'bing-search-off', 'widgets-off', 'copilot-off') { @((Get-DzDebloatLevel -Config $script:Config -Id 'advanced').tweaks) | Should -Contain $id }
    }
    It 'uses the lowest telemetry level per edition (Required on Home/Pro, off on Enterprise/Education)' {
        $a = @((Get-Tweak 'telemetry-off').actions)[0]
        Get-DzTweakTargetValue -Action $a -System ([pscustomobject]@{ EditionId = 'Core' }) | Should -Be 1
        Get-DzTweakTargetValue -Action $a -System ([pscustomobject]@{ EditionId = 'Professional' }) | Should -Be 1
        Get-DzTweakTargetValue -Action $a -System ([pscustomobject]@{ EditionId = 'Enterprise' }) | Should -Be 0
        Get-DzTweakTargetValue -Action $a -System ([pscustomobject]@{ EditionId = 'Education' }) | Should -Be 0
    }
}

Describe 'Applying and undoing tweaks' {
    BeforeEach {
        Use-FakeRegistry
        New-TestKitRoot | Out-Null
        Set-DzDryRun -Enabled $false
        $script:ctx = New-DzContext -System $script:Pro -KitRoot (Get-DzKitRoot)
    }
    AfterAll { Set-DzKitRoot -Path $script:SourceKit; Set-DzDryRun -Enabled $false }

    It 'sets the values and records what was there before' {
        $script:Reg['HKCU:\Control Panel\Mouse|MouseSpeed'] = @{ Value = '1'; Kind = 'String' }
        $r = Invoke-DzTweak -Tweak (Get-Tweak 'mouse-accel-off') -Context $script:ctx
        $r.Status | Should -Be 'Done'
        $script:Reg['HKCU:\Control Panel\Mouse|MouseSpeed'].Value | Should -Be '0'
        $script:Reg['HKCU:\Control Panel\Mouse|MouseThreshold1'].Value | Should -Be '0'
        $backup = @(Read-DzBackup -Name 'tweaks')
        $backup.Count | Should -Be 1
        $first = @($backup[0].changes) | Where-Object { $_.name -eq 'MouseSpeed' }
        $first.existed | Should -BeTrue
        $first.value | Should -Be '1'
        (@($backup[0].changes) | Where-Object { $_.name -eq 'MouseThreshold1' }).existed | Should -BeFalse
    }
    It 'is idempotent: a second run changes nothing and records nothing' {
        [void](Invoke-DzTweak -Tweak (Get-Tweak 'game-mode') -Context $script:ctx)
        $r = Invoke-DzTweak -Tweak (Get-Tweak 'game-mode') -Context $script:ctx
        $r.Message | Should -Match 'Already set'
        @(Read-DzBackup -Name 'tweaks').Count | Should -Be 1
    }
    It 'undo restores old values and removes values that did not exist' {
        $script:Reg['HKCU:\Control Panel\Mouse|MouseSpeed'] = @{ Value = '1'; Kind = 'String' }
        [void](Invoke-DzTweak -Tweak (Get-Tweak 'mouse-accel-off') -Context $script:ctx)
        [void](Invoke-DzTweak -Tweak (Get-Tweak 'telemetry-off') -Context $script:ctx)
        $script:Svc['DiagTrack'] | Should -Be 'Disabled'
        $script:EnvVars['POWERSHELL_TELEMETRY_OPTOUT'] | Should -Be '1'
        $u = Undo-DzTweak
        $u.Failed | Should -Be 0
        $u.Restored | Should -Be 17 -Because '3 mouse values + 11 telemetry values, 2 services, 1 environment variable'
        $script:Reg['HKCU:\Control Panel\Mouse|MouseSpeed'].Value | Should -Be '1'
        $script:Reg.ContainsKey('HKCU:\Control Panel\Mouse|MouseThreshold1') | Should -BeFalse
        $script:Reg.ContainsKey('HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection|AllowTelemetry') | Should -BeFalse
        $script:Svc['DiagTrack'] | Should -Be 'Automatic'
        $script:Svc['WerSvc'] | Should -Be 'Manual'
        $script:EnvVars.ContainsKey('POWERSHELL_TELEMETRY_OPTOUT') | Should -BeFalse
        @(Read-DzBackup -Name 'tweaks').Count | Should -Be 0 -Because 'the used backup is renamed so it is not applied twice'
    }
    It 'turns off matching startup entries the way Task Manager does, and undo turns them back on' {
        $script:Reg['HKCU:\Software\Microsoft\Windows\CurrentVersion\Run|Steam'] = @{ Value = 'steam.exe -silent'; Kind = 'String' }
        $script:Reg['HKCU:\Software\Microsoft\Windows\CurrentVersion\Run|MicrosoftEdgeAutoLaunch_ABC123'] = @{ Value = 'msedge.exe'; Kind = 'String' }
        $script:Reg['HKCU:\Software\Microsoft\Windows\CurrentVersion\Run|SecurityHealth'] = @{ Value = 'x'; Kind = 'String' }
        $r = Invoke-DzTweak -Tweak (Get-Tweak 'startup-trim') -Context $script:ctx
        $r.Message | Should -Match 'Steam'
        $approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
        $script:Reg["$approved|Steam"].Value[0] | Should -Be 3
        $script:Reg["$approved|MicrosoftEdgeAutoLaunch_ABC123"].Kind | Should -Be 'Binary'
        $script:Reg.ContainsKey("$approved|SecurityHealth") | Should -BeFalse
        [void](Undo-DzTweak)
        $script:Reg.ContainsKey("$approved|Steam") | Should -BeFalse
    }
    It 'says so when no app has a startup entry yet' {
        (Invoke-DzTweak -Tweak (Get-Tweak 'startup-trim') -Context $script:ctx).Message | Should -Match 'no.*startup entry yet'
    }
    It 'changes nothing and records nothing in dry-run mode' {
        Set-DzDryRun -Enabled $true
        $r = Invoke-DzTweak -Tweak (Get-Tweak 'bing-search-off') -Context $script:ctx
        $r.Message | Should -Match 'DRY-RUN'
        $script:Reg.Count | Should -Be 0
        @(Read-DzBackup -Name 'tweaks').Count | Should -Be 0
    }
    It 'notes when a restart is needed' {
        $r = Invoke-DzTweak -Tweak (Get-Tweak 'gpu-scheduling') -Context $script:ctx
        $r.Message | Should -Match 'restart'
        $script:ctx.Flags['RestartRecommended'] | Should -BeTrue
    }
    It 'refuses a tweak that touches Windows Update, whatever the JSON says' {
        $evil = [pscustomobject]@{ id = 'evil'; title = 'Evil'; actions = @([pscustomobject]@{ type = 'registry'; path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'; name = 'NoAutoUpdate'; kind = 'DWord'; value = 1 }) }
        { Invoke-DzTweak -Tweak $evil -Context $script:ctx } | Should -Throw '*never touches Windows Update*'
        foreach ($svc in 'wuauserv', 'UsoSvc', 'WaaSMedicSvc', 'BITS', 'WinDefend', 'SecurityHealthService', 'mpssvc', 'InstallService') {
            $evil2 = [pscustomobject]@{ id = 'evil2'; title = 'Evil'; actions = @([pscustomobject]@{ type = 'service'; name = $svc; startup = 'Disabled' }) }
            { Invoke-DzTweak -Tweak $evil2 -Context $script:ctx } | Should -Throw '*never touches Windows Update*'
        }
        $evil3 = [pscustomobject]@{ id = 'evil3'; title = 'Evil'; actions = @([pscustomobject]@{ type = 'script'; command = 'Set-MpPreference' }) }
        { Invoke-DzTweak -Tweak $evil3 -Context $script:ctx } | Should -Throw '*unknown action type*'
        $evil4 = [pscustomobject]@{ id = 'evil4'; title = 'Evil'; actions = @([pscustomobject]@{ type = 'registryKey'; path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\X' }) }
        { Invoke-DzTweak -Tweak $evil4 -Context $script:ctx } | Should -Throw '*never touches Windows Update*'
    }
    It 'changes service start types and undo puts back the exact old ones (delayed start too)' {
        $r = Invoke-DzTweak -Tweak (Get-Tweak 'services-manual') -Context $script:ctx
        $r.Status | Should -Be 'Done'
        $r.Message | Should -Match 'restart'
        $script:Svc['DiagTrack'] | Should -Be 'Disabled'
        $script:Svc['CscService'] | Should -Be 'Disabled'
        $script:Svc['MapsBroker'] | Should -Be 'Manual'
        $script:Svc['StorSvc'] | Should -Be 'Manual'
        (Invoke-DzTweak -Tweak (Get-Tweak 'services-manual') -Context $script:ctx).Message | Should -Match 'Already set'
        [void](Undo-DzTweak)
        $script:Svc['DiagTrack'] | Should -Be 'Automatic'
        $script:Svc['CscService'] | Should -Be 'Manual'
        $script:Svc['MapsBroker'] | Should -Be 'AutomaticDelayed'
        $script:Svc['StorSvc'] | Should -Be 'Automatic'
    }
    It 'skips a service that is not on this PC' {
        [void]$script:Svc.Remove('CscService')
        $r = Invoke-DzTweak -Tweak (Get-Tweak 'services-manual') -Context $script:ctx
        $r.Status | Should -Be 'Done'
        $r.Message | Should -Match 'CscService is not on this PC'
    }
    It 'creates the classic right-click menu key and undo deletes only what it created' {
        $r = Invoke-DzTweak -Tweak (Get-Tweak 'classic-context-menu') -Context $script:ctx
        $r.Status | Should -Be 'Done'
        $key = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'
        $script:Keys.Contains($key) | Should -BeTrue
        $script:Reg["$key|(default)"].Value | Should -Be ''
        $change = @(@(Read-DzBackup -Name 'tweaks')[0].changes)[0]
        $change.type | Should -Be 'registryKey'
        $change.created | Should -Be 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}'
        (Invoke-DzTweak -Tweak (Get-Tweak 'classic-context-menu') -Context $script:ctx).Message | Should -Match 'Already set'
        [void](Undo-DzTweak)
        $script:Keys.Contains($key) | Should -BeFalse
        $script:Keys.Contains('HKCU:\Software\Classes\CLSID') | Should -BeTrue
    }
    It 'runs DISM component clean-up without /ResetBase, and warns instead of failing' {
        Mock -ModuleName Tweaks Invoke-DzProcess { $script:DismArgs = @($Arguments); [pscustomobject]@{ ExitCode = 0; Output = ''; TimedOut = $false } }
        $r = Invoke-DzTweak -Tweak (Get-Tweak 'disk-cleanup') -Context $script:ctx
        $r.Status | Should -Be 'Done'
        $script:DismArgs | Should -Contain '/StartComponentCleanup'
        ($script:DismArgs -join ' ') | Should -Not -Match 'ResetBase'
        Mock -ModuleName Tweaks Invoke-DzProcess { [pscustomobject]@{ ExitCode = -2146498554; Output = ''; TimedOut = $false } }
        (Invoke-DzTweak -Tweak (Get-Tweak 'disk-cleanup') -Context $script:ctx).Status | Should -Be 'Warn'
    }
    It 'cleans temp files but keeps DayZero folders and logs' {
        $tmp = Join-Path $TestDrive ('temp-' + [guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path (Join-Path $tmp 'DayZero-odt'), (Join-Path $tmp 'old-installer') -Force)
        Set-Content -LiteralPath (Join-Path $tmp 'junk.tmp') -Value ('x' * 2048)
        Set-Content -LiteralPath (Join-Path $tmp 'old-installer/setup.exe') -Value 'x'
        Set-Content -LiteralPath (Join-Path $tmp 'Office-setup.log') -Value 'log'
        Set-Content -LiteralPath (Join-Path $tmp 'DayZero-odt/setup.exe') -Value 'x'
        Mock -ModuleName Tweaks Get-DzTempFolder { , @($tmp) }
        $r = Invoke-DzTweak -Tweak (Get-Tweak 'temp-files-clean') -Context $script:ctx
        $r.Status | Should -Be 'Done'
        $r.Message | Should -Match 'freed'
        Test-Path (Join-Path $tmp 'junk.tmp') | Should -BeFalse
        Test-Path (Join-Path $tmp 'old-installer') | Should -BeFalse
        Test-Path (Join-Path $tmp 'Office-setup.log') | Should -BeTrue
        Test-Path (Join-Path $tmp 'DayZero-odt/setup.exe') | Should -BeTrue
        @(Read-DzBackup -Name 'tweaks').Count | Should -Be 0 -Because 'deleting temp files has nothing to undo'
    }
    It 'deletes nothing and starts no DISM in dry-run mode' {
        Set-DzDryRun -Enabled $true
        Mock -ModuleName Tweaks Clear-DzTempFolder { throw 'REAL CHANGE: temp' }
        Mock -ModuleName Tweaks Invoke-DzProcess { throw 'REAL CHANGE: dism' }
        (Invoke-DzTweak -Tweak (Get-Tweak 'temp-files-clean') -Context $script:ctx).Message | Should -Match 'DRY-RUN'
        (Invoke-DzTweak -Tweak (Get-Tweak 'disk-cleanup') -Context $script:ctx).Message | Should -Match 'DRY-RUN'
        (Invoke-DzTweak -Tweak (Get-Tweak 'services-manual') -Context $script:ctx).Message | Should -Match 'DRY-RUN'
        $script:Svc['DiagTrack'] | Should -Be 'Automatic'
    }
}

Describe 'Registry key and service helpers' {
    It 'finds the parent of a registry path' {
        Get-DzParentRegistryPath -Path 'HKCU:\Software\Classes\CLSID' | Should -Be 'HKCU:\Software\Classes'
        Get-DzParentRegistryPath -Path 'HKCU:\Software' | Should -BeNullOrEmpty
    }
    It 'protects Windows Update, Defender, firewall and Store services, not the others' {
        foreach ($n in 'wuauserv', 'WUAUSERV', 'UsoSvc', 'WaaSMedicSvc', 'BITS', 'DoSvc', 'WinDefend', 'WdNisSvc', 'Sense', 'SecurityHealthService', 'wscsvc', 'mpssvc', 'BFE', 'AppXSvc', 'ClipSVC', 'InstallService', 'TrustedInstaller') {
            Test-DzProtectedService -Name $n | Should -BeTrue -Because $n
        }
        foreach ($n in 'DiagTrack', 'WerSvc', 'CscService', 'MapsBroker', 'StorSvc', 'lfsvc') { Test-DzProtectedService -Name $n | Should -BeFalse -Because $n }
    }
    It 'refuses to set a protected service even when called directly' {
        { Set-DzServiceStart -Name 'wuauserv' -Startup 'Disabled' } | Should -Throw '*never touches Windows Update*'
    }
    It 'keeps DayZero temp folders and log files' {
        Test-DzKeptTempItem -Name 'DayZero-winget' | Should -BeTrue
        Test-DzKeptTempItem -Name 'PC-20261112-1200.log' | Should -BeTrue
        Test-DzKeptTempItem -Name 'setup.exe' | Should -BeFalse
    }
}

Describe 'Protected paths' {
    It 'blocks <_>' -ForEach @(
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU',
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender',
        'HKLM:\SYSTEM\CurrentControlSet\Services\WinDefend',
        'HKLM:\SYSTEM\CurrentControlSet\Services\wuauserv',
        'HKLM:\SYSTEM\CurrentControlSet\Services\WaaSMedicSvc'
    ) { Test-DzProtectedRegistryPath -Path $_ | Should -BeTrue }
    It 'allows normal settings' {
        Test-DzProtectedRegistryPath -Path 'HKCU:\Software\Microsoft\GameBar' | Should -BeFalse
        Test-DzProtectedRegistryPath -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' | Should -BeFalse
    }
}

Describe 'Power plan and startup helpers' {
    It 'reads GUIDs from powercfg output' {
        ConvertFrom-DzPowercfgGuid -Output 'Power Scheme GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  (Balanced)' | Should -Be '381b4222-f694-41f0-9685-ff5bb260df2e'
        ConvertFrom-DzPowercfgGuid -Output @('Power Scheme GUID: 1D2E3F4A-AAAA-BBBB-CCCC-123456789ABC  (Ultimate Performance)') | Should -Be '1d2e3f4a-aaaa-bbbb-cccc-123456789abc'
        ConvertFrom-DzPowercfgGuid -Output 'Unable to perform operation.' | Should -BeNullOrEmpty
    }
    It 'matches startup names with wildcards, case-insensitively' {
        @(Select-DzStartupName -ValueNames @('Steam', 'discord', 'MicrosoftEdgeAutoLaunch_1', 'OneDrive') -Patterns @('Steam', 'Discord', 'MicrosoftEdgeAutoLaunch_*')) |
            Should -Be @('Steam', 'discord', 'MicrosoftEdgeAutoLaunch_1')
    }
}

Describe 'Debloat list' {
    It '<Name> is never on the keep list and belongs to a level' -ForEach $script:DebloatItems {
        $keep = Get-DzKeepPattern -DebloatConfig $script:Config.debloat
        Test-DzKeptPackage -Name $Name -Keep $keep | Should -BeFalse
        $Item.title | Should -Not -BeNullOrEmpty
        $Item.level | Should -BeIn @('minimal', 'standard', 'advanced')
    }
    It 'always keeps the Store, Calculator, Photos and winget' {
        $keep = Get-DzKeepPattern -DebloatConfig $null
        foreach ($n in 'Microsoft.WindowsStore', 'Microsoft.WindowsCalculator', 'Microsoft.Windows.Photos', 'Microsoft.DesktopAppInstaller', 'Microsoft.SecHealthUI') {
            Test-DzKeptPackage -Name $n -Keep $keep | Should -BeTrue
        }
    }
    It 'keeps the small tools WinUtil''s default list removes (Clock, Sticky Notes, Sound Recorder, Quick Assist)' {
        $keep = Get-DzKeepPattern -DebloatConfig $script:Config.debloat
        foreach ($n in 'Microsoft.WindowsAlarms', 'Microsoft.MicrosoftStickyNotes', 'Microsoft.WindowsSoundRecorder', 'MicrosoftCorporationII.QuickAssist') {
            Test-DzKeptPackage -Name $n -Keep $keep | Should -BeTrue -Because $n
        }
    }
    It 'refuses a JSON entry that would remove a kept app' {
        $bad = '{"levels":[{"id":"clear"},{"id":"full"}],"packages":[{"name":"Microsoft.WindowsStore","title":"Store","level":"full"},{"name":"Microsoft.Windows.*","title":"All","level":"full"},{"name":"Clipchamp.Clipchamp","title":"Clipchamp","level":"full"}]}' | ConvertFrom-Json
        @(Get-DzDebloatTarget -DebloatConfig $bad -Level 'full' | ForEach-Object { $_.name }) | Should -Be @('Clipchamp.Clipchamp')
    }
    It 'removes more at each level: Clear nothing, Minimal < Standard < Advanced' {
        $cfg = $script:Config.debloat
        @(Get-DzDebloatTarget -DebloatConfig $cfg -Level 'clear').Count | Should -Be 0
        $min = @(Get-DzDebloatTarget -DebloatConfig $cfg -Level 'minimal' | ForEach-Object { $_.name })
        $std = @(Get-DzDebloatTarget -DebloatConfig $cfg -Level 'standard' | ForEach-Object { $_.name })
        $adv = @(Get-DzDebloatTarget -DebloatConfig $cfg -Level 'advanced' | ForEach-Object { $_.name })
        $min.Count | Should -BeGreaterThan 0
        $min.Count | Should -BeLessThan $std.Count
        $std.Count | Should -BeLessThan $adv.Count
        foreach ($n in $min) { $std | Should -Contain $n }
        foreach ($n in $std) { $adv | Should -Contain $n }
        $min | Should -Contain 'king.com.*'
        $min | Should -Not -Contain 'Clipchamp.Clipchamp'
    }
    It 'removes WinUtil''s default AppX selection at Standard (except the tools DayZero keeps)' {
        $std = @(Get-DzDebloatTarget -DebloatConfig $script:Config.debloat -Level 'standard' | ForEach-Object { $_.name })
        foreach ($n in 'Microsoft.WindowsFeedbackHub', 'Microsoft.GetHelp', 'Microsoft.MicrosoftOfficeHub', 'Clipchamp.Clipchamp', 'Microsoft.Todos', 'Microsoft.MicrosoftSolitaireCollection',
            'Microsoft.PowerAutomateDesktop', 'Microsoft.Windows.DevHome', 'Microsoft.BingWeather', 'Microsoft.StartExperiencesApp', 'Microsoft.BingNews', 'Microsoft.Copilot', 'Microsoft.BingSearch') {
            $std | Should -Contain $n
        }
        $std | Should -Not -Contain 'Microsoft.OutlookForWindows'
    }
    It 'accepts the old level names (light, full)' {
        @(Get-DzDebloatTarget -DebloatConfig $script:Config.debloat -Level 'light').Count | Should -Be @(Get-DzDebloatTarget -DebloatConfig $script:Config.debloat -Level 'minimal').Count
        @(Get-DzDebloatTarget -DebloatConfig $script:Config.debloat -Level 'full').Count | Should -Be @(Get-DzDebloatTarget -DebloatConfig $script:Config.debloat -Level 'standard').Count
    }
    It 'does not remove the preinstalled Teams when Teams is one of the apps being installed' {
        @(Get-DzDebloatTarget -DebloatConfig $script:Config.debloat -Level 'advanced' | ForEach-Object { $_.name }) | Should -Contain 'MSTeams'
        @(Get-DzDebloatTarget -DebloatConfig $script:Config.debloat -Level 'advanced' -KeepApps @('teams') | ForEach-Object { $_.name }) | Should -Not -Contain 'MSTeams'
    }
    It 'offers OneDrive removal: unticked unless the level is Advanced' {
        $o = @($script:Config.debloat.optionalRemovals | Where-Object { $_.id -eq 'onedrive' })[0]
        $o.default | Should -BeFalse
        $o.winget | Should -Be 'Microsoft.OneDrive'
        @((Get-DzDebloatLevel -Config $script:Config -Id 'standard').removals) | Should -Not -Contain 'onedrive'
        @((Get-DzDebloatLevel -Config $script:Config -Id 'advanced').removals) | Should -Contain 'onedrive'
    }
}

Describe 'Clean-up levels (WinUtil presets)' {
    It 'offers Clear, Minimal, Standard and Advanced, Standard by default' {
        @(Get-DzDebloatLevelList -Config $script:Config | ForEach-Object { $_.id }) | Should -Be @('clear', 'minimal', 'standard', 'advanced')
        Get-DzDefaultDebloatLevel -Config $script:Config | Should -Be 'standard'
    }
    It 'resolves level names, old names and nonsense' {
        Resolve-DzDebloatLevelId -Config $script:Config -Id 'STANDARD' | Should -Be 'standard'
        Resolve-DzDebloatLevelId -Config $script:Config -Id 'none' | Should -Be 'clear'
        Resolve-DzDebloatLevelId -Config $script:Config -Id 'light' | Should -Be 'minimal'
        Resolve-DzDebloatLevelId -Config $script:Config -Id 'full' | Should -Be 'standard'
        Resolve-DzDebloatLevelId -Config $script:Config -Id 'nuke-everything' | Should -BeNullOrEmpty
        Resolve-DzDebloatLevelId -Config $script:Config -Id '' | Should -BeNullOrEmpty
    }
    It 'maps WinUtil''s Minimal preset' {
        $l = Get-DzDebloatLevel -Config $script:Config -Id 'minimal'
        foreach ($t in 'telemetry-off', 'services-manual', 'wpbt-off', 'consumer-features-off', 'promoted-apps-off') { @($l.tweaks) | Should -Contain $t }
        @(Get-DzDebloatLevel -Config $script:Config -Id 'clear').tweaks.Count | Should -Be 0
    }
    It 'maps WinUtil''s Standard preset on top of Minimal' {
        $l = Get-DzDebloatLevel -Config $script:Config -Id 'standard'
        foreach ($t in 'telemetry-off', 'activity-history-off', 'location-off', 'delivery-optimization-off', 'folder-discovery-off', 'end-task-taskbar', 'temp-files-clean', 'disk-cleanup') { @($l.tweaks) | Should -Contain $t }
        @($l.tweaks) | Should -Not -Contain 'classic-context-menu'
    }
    It 'maps WinUtil''s Advanced preset on top of Standard' {
        $l = Get-DzDebloatLevel -Config $script:Config -Id 'advanced'
        foreach ($t in 'location-off', 'copilot-off', 'windows-ai-off', 'widgets-off', 'bing-search-off', 'classic-context-menu') { @($l.tweaks) | Should -Contain $t }
    }
    It 'documents every item of WinUtil''s presets and where DayZero differs' {
        $map = @($script:Config.debloat.winutil)
        foreach ($item in 'Telemetry - Disable', 'Services - Set to Manual', 'ConsumerFeatures - Disable', 'Windows Platform Binary Table (WPBT) - Disable',
            'Activity History - Disable', 'Location Tracking - Disable', 'Delivery Optimization - Disable', 'File Explorer Automatic Folder Discovery - Disable',
            'End Task With Right Click - Enable', 'Temporary Files - Remove', 'Disk Cleanup - Run', 'Restore Point - Create',
            'Windows AI - Disable And Remove', 'Widgets - Remove', 'Microsoft OneDrive - Remove', 'Right-Click Menu Previous Layout - Enable',
            'Microsoft Store Recommended Search Results - Disable', 'Start Menu Previous Layout - Enable') {
            @($map | Where-Object { $_.item -eq $item }).Count | Should -Be 1 -Because $item
        }
    }
    It 'reports no problems in the shipped configuration' {
        @(Test-DzConfig -Config $script:Config) | Should -BeNullOrEmpty
    }
    It 'reports a level that lists an unknown tweak' {
        $cfg = @{} + $script:Config
        $cfg.debloat = ('{"levels":[{"id":"clear"},{"id":"x","tweaks":["no-such-tweak"],"removals":["nope"]}],"packages":[{"name":"A.B","title":"AB","level":"y"}]}' | ConvertFrom-Json)
        $text = (Test-DzConfig -Config $cfg) -join ' '
        $text | Should -Match "unknown tweak 'no-such-tweak'"
        $text | Should -Match "unknown removal 'nope'"
        $text | Should -Match "unknown level 'y'"
    }
}

Describe 'Restore point gate' {
    BeforeAll {
        function New-GateContext {
            param([string]$Status, [bool]$Require = $true, [bool]$Dry = $false)
            $state = New-DzState -Mode 'gaming' -Steps @([ordered]@{ id = 'restore-point'; title = 'RP'; type = 'restorePoint'; group = 'S'; args = @{}; requires = @() }, [ordered]@{ id = 'tweak:x'; title = 'X'; type = 'tweak'; group = 'T'; args = @{ id = 'game-mode' }; requires = @('restorePoint') })
            $state.steps[0].status = $Status
            $tw = $script:Config.tweaks | ConvertTo-Json -Depth 10 | ConvertFrom-Json
            $tw.requireRestorePoint = $Require
            $cfg = @{ tweaks = $tw }
            $ctx = New-DzContext -State $state -Config $cfg -DryRun $Dry
            return @{ Ctx = $ctx; Step = $state.steps[1] }
        }
    }
    It 'blocks tweaks when the restore point failed' {
        $g = New-GateContext -Status 'failed'
        $r = Invoke-DzStepEntry -Step $g.Step -Context $g.Ctx
        $r.Status | Should -Be 'Failed'
        $r.Message | Should -Match 'restore point'
    }
    It 'lets tweaks run once the restore point exists' {
        Mock -ModuleName Steps.Windows Invoke-DzTweak { New-DzStepResult -Status Done -Message 'ok' }
        $g = New-GateContext -Status 'done'
        (Invoke-DzStepEntry -Step $g.Step -Context $g.Ctx).Status | Should -Be 'Done'
    }
    It 'can be switched off in tweaks.json' {
        Mock -ModuleName Steps.Windows Invoke-DzTweak { New-DzStepResult -Status Done -Message 'ok' }
        $g = New-GateContext -Status 'failed' -Require $false
        (Invoke-DzStepEntry -Step $g.Step -Context $g.Ctx).Status | Should -Be 'Done'
    }
}

Describe 'Activation helpers' {
    It 'reads the edition from the firmware key description' {
        ConvertFrom-DzFirmwareKeyDescription -Description '[4.0] Professional OEM:DM' | Should -Be 'Professional'
        ConvertFrom-DzFirmwareKeyDescription -Description '[4.0] Core OEM:DM' | Should -Be 'Core'
        ConvertFrom-DzFirmwareKeyDescription -Description '[4.0] CoreSingleLanguage OEM:DM' | Should -Be 'CoreSingleLanguage'
        ConvertFrom-DzFirmwareKeyDescription -Description '' | Should -BeNullOrEmpty
    }
    It 'never contains third-party activation tools' {
        $files = Get-ChildItem -Path $script:SourceKit -Recurse -File -Include '*.ps1', '*.psm1', '*.json', '*.cmd'
        foreach ($f in $files) {
            Get-Content -Raw -LiteralPath $f.FullName | Should -Not -Match '(?i)kms(pico|_vl_all|auto)|massgrave|\bMAS_AIO\b|HWIDGen|activat(e|ion)\.cmd|/skms\b'
        }
    }
}

Describe 'Undo summary' {
    BeforeEach { New-TestKitRoot | Out-Null }
    AfterAll { Set-DzKitRoot -Path $script:SourceKit }
    It 'reports nothing to undo on a clean PC' {
        (Get-DzUndoSummary).Empty | Should -BeTrue
    }
    It 'lists recorded tweaks and removed apps' {
        Add-DzBackupEntry -Name 'tweaks' -Entry ([ordered]@{ tweakId = 'game-mode'; title = 'Turn on Game Mode'; changes = @([ordered]@{ type = 'registry'; path = 'HKCU:\X'; name = 'Y'; existed = $false }) })
        Add-DzBackupEntry -Name 'apps' -Entry ([ordered]@{ step = 'debloat-full'; removed = @([ordered]@{ type = 'appx'; title = 'Clipchamp' }) })
        $s = Get-DzUndoSummary
        $s.Empty | Should -BeFalse
        $s.ChangeCount | Should -Be 1
        $s.TweakTitles | Should -Contain 'Turn on Game Mode'
        $s.AppTitles | Should -Contain 'Clipchamp'
    }
}
