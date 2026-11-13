#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Tests for the wizard core: state file, step engine (resume, restarts, retries, dry run,
# requirements), the background runspace, config loading, plan building and PC detection.

BeforeAll {
    $repo = Split-Path -Parent $PSScriptRoot
    $script:SourceKit = Join-Path $repo 'kit'
    $lib = Join-Path $script:SourceKit 'lib'
    foreach ($m in (& (Join-Path $lib 'Modules.ps1'))) { Import-Module (Join-Path $lib $m) -Force -DisableNameChecking }

    function New-TestKit {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath $script:SourceKit -Destination $dir -Recurse
        Set-DzKitRoot -Path $dir
        return $dir
    }
    function New-TestStep {
        param([string]$Id, [string]$Type = 'test', [hashtable]$StepArgs = @{}, [string[]]$Requires = @())
        return [ordered]@{ id = $Id; title = "Step $Id"; type = $Type; group = 'Test'; args = $StepArgs; requires = $Requires }
    }
    # Behaviour of the fake step is chosen by its "mode" argument.
    function global:Invoke-DzTestStep {
        param([hashtable]$Context)
        $mode = Get-DzStepArg -Context $Context -Name 'mode' -Default 'done'
        $Context.Cache['calls'] = 1 + [int]$(if ($Context.Cache.ContainsKey('calls')) { $Context.Cache['calls'] } else { 0 })
        switch ($mode) {
            'done' { New-DzStepResult -Status Done -Message 'fine' }
            'warn' { New-DzStepResult -Status Warn -Message 'careful' }
            'fail' { New-DzStepResult -Status Failed -Message 'broken' }
            'throw' { throw 'exploded' }
            'noisy' { 'stray output'; 42; New-DzStepResult -Status Done -Message 'last wins' }
            'rebootOnce' {
                if ($Context.Cache.ContainsKey('rebooted')) { New-DzStepResult -Status Done -Message 'after restart' }
                else { $Context.Cache['rebooted'] = $true; New-DzStepResult -Status Reboot -Message 'restart please' }
            }
            'rebootAlways' { New-DzStepResult -Status Reboot -Message 'again' }
        }
    }
    Register-DzStepType -Type 'test' -Command 'Invoke-DzTestStep'
}

Describe 'State file' {
    BeforeEach { $script:kit = New-TestKit; $script:path = Join-Path $script:kit 'state.json' }

    It 'round-trips through state.json' {
        $s = New-DzState -Mode 'gaming' -Steps @((New-TestStep 'a'), (New-TestStep 'b')) -Options @{ apps = @('chrome') } -BuildId '0a1b2c3d'
        Save-DzState -State $s -Path $script:path
        $r = Read-DzState -Path $script:path
        $r.mode | Should -Be 'gaming'
        @($r.steps).Count | Should -Be 2
        $r.steps[1].id | Should -Be 'b'
        @($r.options.apps) | Should -Be @('chrome')
        $r.buildId | Should -Be '0a1b2c3d'
    }
    It 'keeps a single step as a list' {
        $s = New-DzState -Mode 'office' -Steps @((New-TestStep 'only'))
        Save-DzState -State $s -Path $script:path
        @((Read-DzState -Path $script:path).steps).Count | Should -Be 1
    }
    It 'overwrites an existing file atomically and leaves no temp file' {
        $s = New-DzState -Mode 'office' -Steps @((New-TestStep 'x'))
        Save-DzState -State $s -Path $script:path
        $s.mode = 'gaming'
        Save-DzState -State $s -Path $script:path
        (Read-DzState -Path $script:path).mode | Should -Be 'gaming'
        Test-Path "$($script:path).tmp" | Should -BeFalse
    }
    It 'sets a damaged file aside and returns nothing' {
        Set-Content -LiteralPath $script:path -Value '{ not json'
        Read-DzState -Path $script:path | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $script:kit -Filter 'state.json.damaged-*').Count | Should -Be 1
    }
    It 'resets only failed steps for a retry' {
        $s = New-DzState -Mode 'gaming' -Steps @((New-TestStep 'a'), (New-TestStep 'b'), (New-TestStep 'c'))
        $s.steps[0].status = 'done'; $s.steps[1].status = 'failed'; $s.steps[2].status = 'skipped'
        Reset-DzFailedStep -State $s | Should -Be 1
        @($s.steps | ForEach-Object { $_.status }) | Should -Be @('done', 'pending', 'skipped')
    }
    It 'counts statuses' {
        $s = New-DzState -Mode 'gaming' -Steps @((New-TestStep 'a'), (New-TestStep 'b'))
        $s.steps[0].status = 'done'
        $c = Get-DzStateCount -State $s
        $c.done | Should -Be 1; $c.pending | Should -Be 1; $c.total | Should -Be 2
    }
}

Describe 'Engine run' {
    BeforeEach {
        $script:kit = New-TestKit
        $script:path = Join-Path $script:kit 'state.json'
        $script:events = New-Object System.Collections.Generic.List[object]
        $script:sink = { param($e) $script:events.Add($e) }
    }
    BeforeAll {
        function Invoke-TestRun {
            param([object]$State, [hashtable]$Context, [scriptblock]$Stop = { $false }, [int]$MaxReboots = 6)
            if (-not $Context) { $Context = New-DzContext -State $State -KitRoot $script:kit }
            return Invoke-DzRun -State $State -StatePath $script:path -Context $Context -Sink $script:sink -ShouldStop $Stop -MaxReboots $MaxReboots
        }
    }

    It 'runs every step in order and ends on the summary' {
        $s = New-DzState -Mode 'gaming' -Steps @((New-TestStep 'a'), (New-TestStep 'b' -StepArgs @{ mode = 'warn' }), (New-TestStep 'c' -StepArgs @{ mode = 'fail' }))
        Invoke-TestRun -State $s | Should -Be 'finished'
        $saved = Read-DzState -Path $script:path
        $saved.phase | Should -Be 'summary'
        @($saved.steps | ForEach-Object { $_.status }) | Should -Be @('done', 'warn', 'failed')
        $saved.steps[2].message | Should -Be 'broken'
        @($script:events | Where-Object { $_.type -eq 'finished' }).Count | Should -Be 1
    }
    It 'turns an exception into a failed step and keeps going' {
        $s = New-DzState -Mode 'gaming' -Steps @((New-TestStep 'a' -StepArgs @{ mode = 'throw' }), (New-TestStep 'b'))
        [void](Invoke-TestRun -State $s)
        $saved = Read-DzState -Path $script:path
        $saved.steps[0].status | Should -Be 'failed'
        $saved.steps[0].message | Should -Match 'exploded'
        $saved.steps[1].status | Should -Be 'done'
    }
    It 'uses the last result when a step writes stray output' {
        $s = New-DzState -Mode 'gaming' -Steps @((New-TestStep 'a' -StepArgs @{ mode = 'noisy' }))
        [void](Invoke-TestRun -State $s)
        (Read-DzState -Path $script:path).steps[0].message | Should -Be 'last wins'
    }
    It 'skips unknown step types instead of failing' {
        $s = New-DzState -Mode 'gaming' -Steps @((New-TestStep 'a' -Type 'nonexistent'))
        [void](Invoke-TestRun -State $s)
        (Read-DzState -Path $script:path).steps[0].status | Should -Be 'skipped'
    }
    It 'never runs a finished step again' {
        $s = New-DzState -Mode 'gaming' -Steps @((New-TestStep 'a'), (New-TestStep 'b'))
        $ctx = New-DzContext -State $s -KitRoot $script:kit
        [void](Invoke-TestRun -State $s -Context $ctx)
        [void](Invoke-TestRun -State (Read-DzState -Path $script:path) -Context $ctx)
        $ctx.Cache['calls'] | Should -Be 2
    }
    It 'stops for a restart, then continues with the same step' {
        $s = New-DzState -Mode 'gaming' -Steps @((New-TestStep 'a'), (New-TestStep 'b' -StepArgs @{ mode = 'rebootOnce' }), (New-TestStep 'c'))
        $ctx = New-DzContext -State $s -KitRoot $script:kit
        Invoke-TestRun -State $s -Context $ctx | Should -Be 'reboot'
        $mid = Read-DzState -Path $script:path
        $mid.phase | Should -Be 'reboot'
        $mid.rebootCount | Should -Be 1
        @($mid.steps | ForEach-Object { $_.status }) | Should -Be @('done', 'reboot', 'pending')
        @($script:events | Where-Object { $_.type -eq 'reboot' }).Count | Should -Be 1

        Invoke-TestRun -State $mid -Context $ctx | Should -Be 'finished'
        @((Read-DzState -Path $script:path).steps | ForEach-Object { $_.status }) | Should -Be @('done', 'done', 'done')
    }
    It 'gives up after the maximum number of restarts' {
        $s = New-DzState -Mode 'gaming' -Steps @((New-TestStep 'a' -StepArgs @{ mode = 'rebootAlways' }))
        $s.rebootCount = 2
        Invoke-TestRun -State $s -MaxReboots 2 | Should -Be 'finished'
        $step = (Read-DzState -Path $script:path).steps[0]
        $step.status | Should -Be 'failed'
        $step.message | Should -Match 'already restarted 2 times'
    }
    It 'never restarts in dry-run mode' {
        $s = New-DzState -Mode 'gaming' -Steps @((New-TestStep 'a' -StepArgs @{ mode = 'rebootAlways' }))
        $ctx = New-DzContext -State $s -KitRoot $script:kit -DryRun $true
        Invoke-TestRun -State $s -Context $ctx | Should -Be 'finished'
        (Read-DzState -Path $script:path).steps[0].message | Should -Match 'DRY-RUN'
    }
    It 'marks a step failed when it keeps getting interrupted (crash loop protection)' {
        $s = New-DzState -Mode 'gaming' -Steps @((New-TestStep 'a'))
        $s.steps[0].status = 'running'; $s.steps[0].attempts = 3
        [void](Invoke-TestRun -State $s)
        $step = (Read-DzState -Path $script:path).steps[0]
        $step.status | Should -Be 'failed'
        $step.message | Should -Match 'attempts'
    }
    It 're-runs a step that was interrupted once' {
        $s = New-DzState -Mode 'gaming' -Steps @((New-TestStep 'a'))
        $s.steps[0].status = 'running'; $s.steps[0].attempts = 1
        [void](Invoke-TestRun -State $s)
        (Read-DzState -Path $script:path).steps[0].status | Should -Be 'done'
    }
    It 'pauses before the next step when asked' {
        $s = New-DzState -Mode 'gaming' -Steps @((New-TestStep 'a'), (New-TestStep 'b'))
        Invoke-TestRun -State $s -Stop { $true } | Should -Be 'stopped'
        @((Read-DzState -Path $script:path).steps | ForEach-Object { $_.status }) | Should -Be @('pending', 'pending')
    }
    It 'fails a step whose requirement is not met, with the reason' {
        Register-DzRequirement -Name 'testNeed' -Check { param($ctx) if ($ctx.Flags['ok']) { $null } else { 'Need is missing.' } }
        $s = New-DzState -Mode 'gaming' -Steps @((New-TestStep 'a' -Requires @('testNeed')))
        [void](Invoke-TestRun -State $s)
        $step = (Read-DzState -Path $script:path).steps[0]
        $step.status | Should -Be 'failed'
        $step.message | Should -Be 'Need is missing.'
    }
    It 'sends step and progress events for the GUI' {
        $s = New-DzState -Mode 'gaming' -Steps @((New-TestStep 'a'))
        [void](Invoke-TestRun -State $s)
        @($script:events | Where-Object { $_.type -eq 'step' } | ForEach-Object { $_.status }) | Should -Be @('running', 'done')
        $last = @($script:events | Where-Object { $_.type -eq 'progress' })[-1]
        $last.done | Should -Be 1; $last.total | Should -Be 1
    }
}

Describe 'Background runspace' {
    It 'runs the plan off the GUI thread and reports through the queue' {
        $kit = New-TestKit
        $path = Join-Path $kit 'state.json'
        # A real step type that needs no network: preflight with a fake system object.
        $s = New-DzState -Mode 'gaming' -Steps @((New-TestStep 'pf' -Type 'preflight'))
        Save-DzState -State $s -Path $path
        $sys = [pscustomobject]@{ Caption = 'Windows 11 Pro'; DisplayVersion = '25H2'; Build = 26200; Ubr = 1; IsVirtualMachine = $true; IsLaptop = $false; GpuVendors = @(); GpuNames = @(); Brand = 'Other'; FreeDiskGB = 100; Architecture = 'amd64' }
        $sync = New-DzSync -System $sys
        $job = Start-DzRunAsync -KitRoot $kit -StatePath $path -Sync $sync -DryRun $true
        $deadline = (Get-Date).AddSeconds(90)
        while (-not (Test-DzRunAsyncCompleted -Job $job) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
        Complete-DzRunAsync -Job $job
        $msgs = New-Object System.Collections.Generic.List[object]
        $m = $null
        while ($sync.Queue.TryDequeue([ref]$m)) { $msgs.Add($m) }
        $types = @($msgs | ForEach-Object { $_.type })
        $types | Should -Contain 'step'
        $types | Should -Contain 'log'
        $types[-1] | Should -Be 'done'
        ($msgs | Where-Object { $_.type -eq 'done' }).outcome | Should -Be 'finished'
        (Read-DzState -Path $path).steps[0].status | Should -Be 'done'
        @(Get-ChildItem -LiteralPath (Join-Path $kit 'Logs') -Filter 'engine-*.log').Count | Should -Be 1
    }
}

Describe 'Shipped configuration' {
    BeforeAll { $script:cfg = Get-DzConfig -KitRoot $script:SourceKit }
    It 'has no broken references' {
        $problems = Test-DzConfig -Config $script:cfg
        @($problems).Count | Should -Be 0 -Because ($problems -join '; ')
    }
    It 'offers gaming, office, everything and custom, defaulting to gaming' {
        @(Get-DzModeList -Config $script:cfg | ForEach-Object { $_.id }) | Should -Be @('gaming', 'office', 'everything', 'custom')
        $script:cfg.modes.defaultMode | Should -Be 'gaming'
    }
    It 'builds Everything from Gaming + Office + its own extras' {
        $e = Get-DzMode -Config $script:cfg -Id 'everything'
        $g = Get-DzMode -Config $script:cfg -Id 'gaming'
        $o = Get-DzMode -Config $script:cfg -Id 'office'
        foreach ($a in @($g.apps + $o.apps)) { @($e.apps) | Should -Contain $a }
        @($e.apps) | Should -Contain 'powertoys'
        $e.office | Should -BeTrue
        $e.debloat | Should -Be 'standard' -Because 'the most thorough level of its parts'
        @($e.modeIds) | Should -Be @('everything', 'gaming', 'office')
        @($e.apps | Group-Object | Where-Object { $_.Count -gt 1 }).Count | Should -Be 0
    }
    It 'keeps Office simple: Minimal clean-up suggested and no gaming tweaks' {
        $o = Get-DzMode -Config $script:cfg -Id 'office'
        $o.debloat | Should -Be 'minimal'
        @($o.tweaks) | Should -Not -Contain 'game-mode'
    }
    It 'reports a mode that lists an unknown app' {
        $bad = @{ modes = ('{"modes":[{"id":"x","apps":["nope"],"tweaks":[],"debloat":"none"}]}' | ConvertFrom-Json); apps = ('{"apps":[{"id":"chrome","name":"Chrome"}]}' | ConvertFrom-Json); tweaks = $null; debloat = $null; drivers = $null; office = $null }
        (Test-DzConfig -Config $bad) -join ' ' | Should -Match "unknown app 'nope'"
    }
}

Describe 'Plan building' {
    BeforeAll {
        foreach ($t in @('preflight', 'driversFolder', 'network', 'activation', 'restorePoint', 'winget', 'windowsUpdate', 'gpuApp', 'oemTool', 'debloat', 'removal', 'tweak', 'app', 'office')) {
            if (-not (Test-DzStepType -Type $t)) { Register-DzStepType -Type $t -Command 'Invoke-DzTestStep' }
        }
        $script:cfg = @{
            modes   = ('{"defaultMode":"g","modes":[{"id":"g","debloat":"full","apps":["a1"],"tweaks":["t-early","t-late","t-opt","t-desk"]},{"id":"o","debloat":"light","office":true,"apps":["a2"],"tweaks":[]}]}' | ConvertFrom-Json)
            apps    = ('{"apps":[{"id":"a1","name":"App One","category":"Games"},{"id":"a2","name":"App Two"},{"id":"x1","name":"Extra","optional":true,"modes":["o"]},{"id":"w10","name":"Win10 only","optional":true,"modes":["g"],"appliesTo":{"windows":[10]}}]}' | ConvertFrom-Json)
            tweaks  = ('{"tweaks":[{"id":"t-early","title":"Early"},{"id":"t-late","title":"Late","phase":"late"},{"id":"t-opt","title":"Optional","optional":true,"default":true,"defaultLaptop":false,"laptopWarning":"battery!"},{"id":"t-desk","title":"Desktop only","appliesTo":{"formFactor":"desktop"}}]}' | ConvertFrom-Json)
            # Old level names in modes ("full", "light") must still work.
            debloat = ('{"levels":[{"id":"clear"},{"id":"minimal"},{"id":"standard"}],"packages":[],"optionalRemovals":[{"id":"onedrive","title":"Remove OneDrive","modes":["g"]}]}' | ConvertFrom-Json)
            drivers = ('{"gpuApps":[{"vendor":"NVIDIA","name":"NVIDIA App"}],"oemTools":[{"brand":"Dell","name":"Dell Command Update"}]}' | ConvertFrom-Json)
            office  = $null
        }
        $script:desktop = [pscustomobject]@{ WindowsVersion = 11; Build = 26200; IsLaptop = $false; IsVirtualMachine = $false; GpuVendors = @('NVIDIA'); Brand = 'Dell'; Architecture = 'amd64'; EditionId = 'Professional' }
        $script:laptop = [pscustomobject]@{ WindowsVersion = 11; Build = 26200; IsLaptop = $true; IsVirtualMachine = $false; GpuVendors = @('Intel'); Brand = 'Other'; Architecture = 'amd64'; EditionId = 'Core' }
        $script:vm = [pscustomobject]@{ WindowsVersion = 11; Build = 26200; IsLaptop = $false; IsVirtualMachine = $true; GpuVendors = @('NVIDIA'); Brand = 'Dell'; Architecture = 'amd64'; EditionId = 'Professional' }
    }

    It 'orders steps: USB drivers before internet, tweaks before apps, late tweaks and final update last' {
        $mode = Get-DzMode -Config $script:cfg -Id 'g'
        $plan = New-DzPlan -Mode $mode -Options @{ apps = @('a1'); tweaks = @('t-opt'); oemTool = $true; removals = @('onedrive') } -System $script:desktop -Config $script:cfg
        $ids = @($plan | ForEach-Object { $_.id })
        $ids[0] | Should -Be 'preflight'
        [array]::IndexOf($ids, 'drivers-usb') | Should -BeLessThan ([array]::IndexOf($ids, 'network'))
        [array]::IndexOf($ids, 'restore-point') | Should -BeLessThan ([array]::IndexOf($ids, 'debloat'))
        [array]::IndexOf($ids, 'tweak:t-early') | Should -BeLessThan ([array]::IndexOf($ids, 'app:a1'))
        [array]::IndexOf($ids, 'app:a1') | Should -BeLessThan ([array]::IndexOf($ids, 'tweak:t-late'))
        $ids[-1] | Should -Be 'windows-update-final'
        $ids | Should -Contain 'gpu-nvidia'
        $ids | Should -Contain 'oem-tool'
        $ids | Should -Contain 'remove:onedrive'
        $ids | Should -Contain 'tweak:t-opt'
        $ids | Should -Contain 'tweak:t-desk'
    }
    It 'adds optional tweaks only when chosen, and skips desktop-only tweaks on laptops' {
        $mode = Get-DzMode -Config $script:cfg -Id 'g'
        $ids = @(New-DzPlan -Mode $mode -Options @{ apps = @(); tweaks = @() } -System $script:laptop -Config $script:cfg | ForEach-Object { $_.id })
        $ids | Should -Not -Contain 'tweak:t-opt'
        $ids | Should -Not -Contain 'tweak:t-desk'
        $ids | Should -Not -Contain 'oem-tool'
    }
    It 'skips the GPU app and PC-brand tool in a virtual machine' {
        $mode = Get-DzMode -Config $script:cfg -Id 'g'
        $ids = @(New-DzPlan -Mode $mode -Options @{ apps = @(); oemTool = $true } -System $script:vm -Config $script:cfg | ForEach-Object { $_.id })
        $ids | Should -Not -Contain 'gpu-nvidia'
        $ids | Should -Not -Contain 'oem-tool'
    }
    It 'adds Microsoft 365 for office modes and marks downloads as needing internet + winget' {
        $mode = Get-DzMode -Config $script:cfg -Id 'o'
        $plan = New-DzPlan -Mode $mode -Options @{ apps = @('a2') } -System $script:desktop -Config $script:cfg
        $office = $plan | Where-Object { $_.id -eq 'office' }
        $office | Should -Not -BeNullOrEmpty
        @($office.requires) | Should -Contain 'internet'
        @(($plan | Where-Object { $_.id -eq 'app:a2' }).requires) | Should -Be @('internet', 'winget')
        ($plan | Where-Object { $_.id -eq 'debloat' }).args.level | Should -Be 'minimal'
        @(($plan | Where-Object { $_.id -eq 'debloat' }).args.keepApps) | Should -Be @('a2')
    }
    It 'leaves out steps whose type is not available yet' {
        $mode = Get-DzMode -Config $script:cfg -Id 'g'
        $plan = New-DzPlan -Mode $mode -Options @{ apps = @('a1') } -System $script:desktop -Config $script:cfg
        @($plan | Where-Object { -not (Test-DzStepType -Type $_.type) }).Count | Should -Be 0
    }

    Context 'Review screen model' {
        It 'ticks mode apps, leaves extras unticked, hides apps for other Windows versions' {
            $mode = Get-DzMode -Config $script:cfg -Id 'o'
            $r = Get-DzReviewModel -Mode $mode -System $script:desktop -Config $script:cfg
            ($r.Apps | Where-Object { $_.Id -eq 'a2' }).Checked | Should -BeTrue
            ($r.Apps | Where-Object { $_.Id -eq 'x1' }).Checked | Should -BeFalse
            $g = Get-DzReviewModel -Mode (Get-DzMode -Config $script:cfg -Id 'g') -System $script:desktop -Config $script:cfg
            @($g.Apps | ForEach-Object { $_.Id }) | Should -Not -Contain 'w10'
        }
        It 'turns battery-hungry options off on laptops and shows the laptop warning' {
            $mode = Get-DzMode -Config $script:cfg -Id 'g'
            $desk = (Get-DzReviewModel -Mode $mode -System $script:desktop -Config $script:cfg).Options | Where-Object { $_.Id -eq 't-opt' }
            $lap = (Get-DzReviewModel -Mode $mode -System $script:laptop -Config $script:cfg).Options | Where-Object { $_.Id -eq 't-opt' }
            $desk.Checked | Should -BeTrue
            $lap.Checked | Should -BeFalse
            $lap.Warning | Should -Be 'battery!'
        }
        It 'offers the PC-brand tool only for a known brand' {
            $mode = Get-DzMode -Config $script:cfg -Id 'g'
            @((Get-DzReviewModel -Mode $mode -System $script:desktop -Config $script:cfg).Options | ForEach-Object { $_.Kind }) | Should -Contain 'oemTool'
            @((Get-DzReviewModel -Mode $mode -System $script:laptop -Config $script:cfg).Options | ForEach-Object { $_.Kind }) | Should -Not -Contain 'oemTool'
        }
        It 'converts ticked boxes into plan options' {
            $o = ConvertTo-DzPlanOption -Apps @([pscustomobject]@{ Id = 'a'; Checked = $true }, [pscustomobject]@{ Id = 'b'; Checked = $false }) -Options @(
                [pscustomobject]@{ Id = 't'; Kind = 'tweak'; Checked = $true }, [pscustomobject]@{ Id = 'oemTool'; Kind = 'oemTool'; Checked = $true },
                [pscustomobject]@{ Id = 'r'; Kind = 'removal'; Checked = $false })
            @($o.apps) | Should -Be @('a')
            @($o.tweaks) | Should -Be @('t')
            @($o.removals).Count | Should -Be 0
            $o.oemTool | Should -BeTrue
        }
    }
}

Describe 'PC detection helpers' {
    It 'brand <In> -> <Out>' -ForEach @(
        @{ In = 'Dell Inc.'; Out = 'Dell' }, @{ In = 'Alienware'; Out = 'Dell' }, @{ In = 'LENOVO'; Out = 'Lenovo' },
        @{ In = 'HP'; Out = 'HP' }, @{ In = 'Hewlett-Packard'; Out = 'HP' }, @{ In = 'ASUSTeK COMPUTER INC.'; Out = 'ASUS' },
        @{ In = 'Micro-Star International Co., Ltd.'; Out = 'Other' }, @{ In = ''; Out = 'Other' }
    ) { ConvertTo-DzBrand -Manufacturer $In | Should -Be $Out }
    It 'GPU vendor from PNP id <In> -> <Out>' -ForEach @(
        @{ In = 'PCI\VEN_10DE&DEV_2786&SUBSYS'; Out = 'NVIDIA' }, @{ In = 'PCI\VEN_1002&DEV_744C'; Out = 'AMD' },
        @{ In = 'PCI\VEN_8086&DEV_A780'; Out = 'Intel' }, @{ In = 'ROOT\BasicDisplay'; Out = $null }
    ) { ConvertTo-DzGpuVendor -PnpDeviceId $In | Should -Be $Out }
    It 'detects laptops by chassis or battery' {
        Test-DzLaptopChassis -ChassisTypes @(3) | Should -BeFalse
        Test-DzLaptopChassis -ChassisTypes @(10) | Should -BeTrue
        Test-DzLaptopChassis -ChassisTypes @(31) | Should -BeTrue
        Test-DzLaptopChassis -ChassisTypes @(3) -HasBattery $true | Should -BeTrue
    }
    It 'detects virtual machines' {
        Test-DzVirtualMachine -Manufacturer 'Microsoft Corporation' -Model 'Virtual Machine' | Should -BeTrue
        Test-DzVirtualMachine -Manufacturer 'innotek GmbH' -Model 'VirtualBox' | Should -BeTrue
        Test-DzVirtualMachine -Manufacturer 'Dell Inc.' -Model 'XPS 8960' | Should -BeFalse
    }
    It 'maps build numbers to Windows 10/11' {
        ConvertTo-DzWindowsMajor -Build 19045 | Should -Be 10
        ConvertTo-DzWindowsMajor -Build 26200 | Should -Be 11
    }
    It 'applies appliesTo rules' {
        $pc = [pscustomobject]@{ WindowsVersion = 10; Build = 19045; IsLaptop = $true; IsVirtualMachine = $false; GpuVendors = @('AMD'); Architecture = 'amd64'; EditionId = 'Core' }
        Test-DzApplicable -Item ([pscustomobject]@{ appliesTo = [pscustomobject]@{ windows = @(11) } }) -System $pc | Should -Match 'Windows 11'
        Test-DzApplicable -Item ([pscustomobject]@{ appliesTo = [pscustomobject]@{ formFactor = 'desktop' } }) -System $pc | Should -Match 'Desktop'
        Test-DzApplicable -Item ([pscustomobject]@{ appliesTo = [pscustomobject]@{ gpuVendors = @('NVIDIA') } }) -System $pc | Should -Match 'NVIDIA'
        Test-DzApplicable -Item ([pscustomobject]@{ appliesTo = [pscustomobject]@{ windows = @(10); gpuVendors = @('AMD') } }) -System $pc | Should -BeNullOrEmpty
        Test-DzApplicable -Item ([pscustomobject]@{ name = 'no rules' }) -System $pc | Should -BeNullOrEmpty
    }
}
