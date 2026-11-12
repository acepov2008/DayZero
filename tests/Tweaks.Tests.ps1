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
            $a.type | Should -BeIn @('registry', 'powerPlan', 'startupDisable')
            if ($a.type -eq 'registry') {
                $a.path | Should -Match '^HK(CU|LM):\\'
                $a.kind | Should -BeIn @('DWord', 'QWord', 'String', 'ExpandString', 'Binary', 'MultiString')
                Test-DzProtectedRegistryPath -Path $a.path | Should -BeFalse -Because 'Windows Update and Defender are off limits'
            }
        }
    }
    It 'has no service changes and never disables Windows Update or Defender' {
        $text = Get-Content -Raw (Join-Path $script:SourceKit 'config/tweaks.json')
        $text | Should -Not -Match '"type"\s*:\s*"service"'
        $text | Should -Not -Match 'wuauserv|WinDefend|DisableAntiSpyware|NoAutoUpdate|DisableRealtimeMonitoring'
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
    It 'gives every gaming tweak the user asked for' {
        $g = Get-DzMode -Config $script:Config -Id 'gaming'
        foreach ($id in 'game-mode', 'gpu-scheduling', 'mouse-accel-off', 'background-apps-off', 'startup-trim', 'bing-search-off', 'widgets-off', 'copilot-off', 'telemetry-min', 'power-plan', 'memory-integrity-off', 'game-bar-off') {
            @($g.tweaks) | Should -Contain $id
        }
    }
    It 'uses the lowest telemetry level per edition (Required on Home/Pro, off on Enterprise/Education)' {
        $a = @((Get-Tweak 'telemetry-min').actions)[0]
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
        [void](Invoke-DzTweak -Tweak (Get-Tweak 'telemetry-min') -Context $script:ctx)
        $u = Undo-DzTweak
        $u.Failed | Should -Be 0
        $u.Restored | Should -Be 4
        $script:Reg['HKCU:\Control Panel\Mouse|MouseSpeed'].Value | Should -Be '1'
        $script:Reg.ContainsKey('HKCU:\Control Panel\Mouse|MouseThreshold1') | Should -BeFalse
        $script:Reg.ContainsKey('HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection|AllowTelemetry') | Should -BeFalse
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
        $evil2 = [pscustomobject]@{ id = 'evil2'; title = 'Evil'; actions = @([pscustomobject]@{ type = 'service'; name = 'wuauserv' }) }
        { Invoke-DzTweak -Tweak $evil2 -Context $script:ctx } | Should -Throw '*unknown action type*'
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
    It '<Name> is never on the keep list' -ForEach $script:DebloatItems {
        $keep = Get-DzKeepPattern -DebloatConfig $script:Config.debloat
        Test-DzKeptPackage -Name $Name -Keep $keep | Should -BeFalse
        $Item.title | Should -Not -BeNullOrEmpty
        @($Item.profiles | Where-Object { $_ -notin @('light', 'full') }).Count | Should -Be 0
    }
    It 'always keeps the Store, Calculator, Photos and winget' {
        $keep = Get-DzKeepPattern -DebloatConfig $null
        foreach ($n in 'Microsoft.WindowsStore', 'Microsoft.WindowsCalculator', 'Microsoft.Windows.Photos', 'Microsoft.DesktopAppInstaller', 'Microsoft.SecHealthUI') {
            Test-DzKeptPackage -Name $n -Keep $keep | Should -BeTrue
        }
    }
    It 'refuses a JSON entry that would remove a kept app' {
        $bad = '{"packages":[{"name":"Microsoft.WindowsStore","title":"Store","profiles":["full"]},{"name":"Microsoft.Windows.*","title":"All","profiles":["full"]},{"name":"Clipchamp.Clipchamp","title":"Clipchamp","profiles":["full"]}]}' | ConvertFrom-Json
        @(Get-DzDebloatTarget -DebloatConfig $bad -Profile 'full' | ForEach-Object { $_.name }) | Should -Be @('Clipchamp.Clipchamp')
    }
    It 'makes the light profile a subset of the full one' {
        $light = @(Get-DzDebloatTarget -DebloatConfig $script:Config.debloat -Profile 'light' | ForEach-Object { $_.name })
        $full = @(Get-DzDebloatTarget -DebloatConfig $script:Config.debloat -Profile 'full' | ForEach-Object { $_.name })
        $light.Count | Should -BeLessThan $full.Count
        foreach ($l in $light) { $full | Should -Contain $l }
    }
    It 'removes the Copilot app in the full profile' {
        @(Get-DzDebloatTarget -DebloatConfig $script:Config.debloat -Profile 'full' | ForEach-Object { $_.name }) | Should -Contain 'Microsoft.Copilot'
    }
    It 'offers OneDrive removal as an unticked option' {
        $o = @($script:Config.debloat.optionalRemovals | Where-Object { $_.id -eq 'onedrive' })[0]
        $o.default | Should -BeFalse
        $o.winget | Should -Be 'Microsoft.OneDrive'
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
