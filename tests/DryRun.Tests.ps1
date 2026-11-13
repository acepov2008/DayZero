#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# End-to-end dry run of every mode: the real plan from the real config, run through the
# real engine, with every function that could change the PC replaced by one that THROWS.
# Passing means: in dry-run mode DayZero walks the whole plan and changes nothing.

BeforeDiscovery {
    # Custom mode arrives with the builder's picks (settings.json customSelection).
    # Level = the clean-up level picked in the builder ($null: the mode's suggestion).
    $script:Modes = @(
        @{ Mode = 'gaming'; Form = 'desktop'; Pre = $null; Level = $null }, @{ Mode = 'gaming'; Form = 'laptop'; Pre = $null; Level = 'advanced' },
        @{ Mode = 'office'; Form = 'desktop'; Pre = $null; Level = 'clear' }, @{ Mode = 'everything'; Form = 'desktop'; Pre = $null; Level = $null },
        @{ Mode = 'custom'; Form = 'desktop'; Pre = @{ apps = @('chrome', 'telegram', 'whatsapp', 'claude', 'winrar'); office = $true; tweaks = @() }; Level = 'minimal' }
    )
}

BeforeAll {
    $repo = Split-Path -Parent $PSScriptRoot
    $script:SourceKit = Join-Path $repo 'kit'
    $lib = Join-Path $script:SourceKit 'lib'
    # Windows-only commands DayZero calls; stubs so they can be mocked on any OS.
    foreach ($name in 'Get-AppxPackage', 'Get-AppxProvisionedPackage', 'Remove-AppxPackage', 'Remove-AppxProvisionedPackage', 'Add-AppxPackage',
        'Checkpoint-Computer', 'Enable-ComputerRestore', 'Get-ComputerRestorePoint', 'Restart-Computer', 'Register-ScheduledTask', 'Unregister-ScheduledTask') {
        if (-not (Get-Command $name -ErrorAction SilentlyContinue)) { Set-Item -Path "function:global:$name" -Value { throw "stub called: $($MyInvocation.MyCommand.Name)" } }
    }
    foreach ($m in (& (Join-Path $lib 'Modules.ps1'))) { Import-Module (Join-Path $lib $m) -Force -DisableNameChecking }
    $script:Config = Get-DzConfig -KitRoot $script:SourceKit
}

Describe 'Dry run of <Mode> on a <Form> (clean-up level: <Level>)' -ForEach $script:Modes {
    BeforeAll {
        $script:kit = Join-Path $TestDrive "$Mode-$Form"
        [void](New-Item -ItemType Directory -Path (Join-Path $script:kit 'Drivers') -Force)
        Set-Content -LiteralPath (Join-Path $script:kit 'Drivers/net.inf') -Value '[Version]'
        Set-DzKitRoot -Path $script:kit
        Set-DzDryRun -Enabled $true

        # Read-only lookups return a believable PC...
        Mock -ModuleName Steps.Base Test-DzInternet { $true }
        Mock -ModuleName Steps.Windows Get-DzActivationStatus { [pscustomobject]@{ Activated = $false; StatusText = 'Not activated'; Channel = ''; Edition = ''; PartialKey = ''; FirmwareKeyPresent = $true; FirmwareEdition = '[4.0] Professional OEM:DM'; Error = $null } }
        Mock -ModuleName WindowsUpdate New-DzUpdateSession { [pscustomobject]@{ fake = $true } }
        Mock -ModuleName WindowsUpdate Find-DzUpdate { @([pscustomobject]@{ Title = '2026-11 Cumulative Update'; MaxDownloadSize = 900MB }) }
        Mock -ModuleName Debloat Get-AppxPackage { if ($Name -eq 'Clipchamp.Clipchamp') { [pscustomobject]@{ Name = $Name; PackageFullName = "$Name_1.0_x64" } } }
        Mock -ModuleName Debloat Get-AppxProvisionedPackage { @() }
        foreach ($mod in 'Winget', 'Steps.Apps', 'Office', 'Debloat') { Mock -ModuleName $mod Find-DzWinget { $null } }

        # ...and anything that would change it throws.
        foreach ($mod in 'Tweaks', 'Steps.Windows') {
            Mock -ModuleName $mod Set-DzRegistryValue { throw "REAL CHANGE: registry $Path\$Name" }
            Mock -ModuleName $mod Remove-DzRegistryValue { throw "REAL CHANGE: registry delete $Path\$Name" }
        }
        foreach ($mod in 'Winget', 'Office', 'Drivers', 'Debloat') {
            Mock -ModuleName $mod Invoke-DzProcess { throw "REAL CHANGE: process $FilePath $Arguments" }
            Mock -ModuleName $mod Invoke-DzAsUser { throw "REAL CHANGE: user process $FilePath" }
        }
        Mock -ModuleName WindowsUpdate Install-DzUpdate { throw 'REAL CHANGE: Windows Update install' }
        Mock -ModuleName Debloat Remove-AppxPackage { throw 'REAL CHANGE: Remove-AppxPackage' }
        Mock -ModuleName Debloat Remove-AppxProvisionedPackage { throw 'REAL CHANGE: Remove-AppxProvisionedPackage' }
        Mock -ModuleName Tweaks Get-DzServiceStart { 'Automatic' }
        Mock -ModuleName Tweaks Get-DzMachineEnvironment { $null }
        Mock -ModuleName Tweaks Test-DzRegistryKey { $false }
        Mock -ModuleName Tweaks Set-DzServiceStart { throw "REAL CHANGE: service $Name" }
        Mock -ModuleName Tweaks Set-DzMachineEnvironment { throw "REAL CHANGE: environment $Name" }
        Mock -ModuleName Tweaks New-DzRegistryKey { throw "REAL CHANGE: registry key $Path" }
        Mock -ModuleName Tweaks Remove-DzRegistryKey { throw "REAL CHANGE: registry key delete $Path" }
        Mock -ModuleName Tweaks Clear-DzTempFolder { throw 'REAL CHANGE: temp files' }
        Mock -ModuleName Tweaks Invoke-DzProcess { throw "REAL CHANGE: process $FilePath" }
        Mock -ModuleName Steps.Windows Checkpoint-Computer { throw 'REAL CHANGE: restore point' }
        Mock -ModuleName Steps.Windows Enable-ComputerRestore { throw 'REAL CHANGE: system protection' }
        Mock -ModuleName Winget Add-AppxPackage { throw 'REAL CHANGE: Add-AppxPackage' }
        Mock -ModuleName Session Restart-Computer { throw 'REAL CHANGE: restart' }

        $script:sys = [pscustomobject]@{
            WindowsVersion = 11; Build = 26200; Ubr = 7000; DisplayVersion = '25H2'; EditionId = 'Professional'; Caption = 'Windows 11 Pro'
            Architecture = 'amd64'; Manufacturer = 'Dell Inc.'; Model = 'XPS'; Brand = 'Dell'; IsVirtualMachine = $false
            IsLaptop = ($Form -eq 'laptop'); GpuVendors = @('NVIDIA', 'Intel'); GpuNames = @('RTX', 'UHD'); MemoryGB = 32; FreeDiskGB = 400
        }
        $modeObj = Get-DzMode -Config $script:Config -Id $Mode   # not $mode: PowerShell names ignore case
        $review = Get-DzReviewModel -Mode $modeObj -System $script:sys -Config $script:Config -Preselect $Pre -DebloatLevel $Level
        $script:review = $review
        $options = ConvertTo-DzPlanOption -Apps @($review.Apps) -Options @($review.Options)
        $plan = New-DzPlan -Mode $modeObj -Options $options -System $script:sys -Config $script:Config
        $script:plan = $plan
        $state = New-DzState -Mode $Mode -Steps $plan -Options $options -System $script:sys -DryRun $true
        $script:statePath = Join-Path $script:kit 'state.json'
        $script:log = New-Object System.Collections.Generic.List[string]
        Add-DzLogListener -Listener { param($level, $line) $script:log.Add($line) }
        $ctx = New-DzContext -Settings ([pscustomobject]@{ buildId = $null; officePlan = 'personal' }) -State $state -System $script:sys -Config $script:Config -KitRoot $script:kit -DryRun $true
        $script:outcome = Invoke-DzRun -State $state -StatePath $script:statePath -Context $ctx -Sink { param($e) }
        $script:final = Read-DzState -Path $script:statePath
    }
    AfterAll {
        Set-DzDryRun -Enabled $false
        Set-DzKitRoot -Path $script:SourceKit
    }

    It 'finishes the whole plan without restarting' {
        $script:outcome | Should -Be 'finished'
        $script:final.phase | Should -Be 'summary'
        $script:final.rebootCount | Should -Be 0
    }
    It 'has no failed or unfinished steps' {
        $bad = @($script:final.steps | Where-Object { $_.status -notin @('done', 'warn', 'skipped') })
        ($bad | ForEach-Object { "$($_.id)=$($_.status): $($_.message)" }) -join '; ' | Should -BeNullOrEmpty
    }
    It 'logs what it would do instead of doing it' {
        @($script:log | Where-Object { $_ -match '\[DRY-RUN\]' }).Count | Should -BeGreaterThan 5
        @($script:log | Where-Object { $_ -match 'REAL CHANGE' }).Count | Should -Be 0
    }
    It 'writes no backup files (nothing was changed)' {
        Test-Path (Join-Path $script:kit 'backup') | Should -BeFalse
    }
    It 'plans the right big steps' {
        $ids = @($script:final.steps | ForEach-Object { $_.id })
        foreach ($must in 'preflight', 'drivers-usb', 'network', 'activation', 'restore-point', 'winget', 'windows-update', 'windows-update-final') { $ids | Should -Contain $must }
        if ($Level -eq 'clear') { $ids | Should -Not -Contain 'debloat'; @($ids | Where-Object { $_ -in 'tweak:telemetry-off', 'tweak:temp-files-clean' }).Count | Should -Be 0 }
        else { $ids | Should -Contain 'debloat'; $ids | Should -Contain 'tweak:telemetry-off' }
        if ($Level -in $null, 'advanced' -and $Mode -ne 'office') { $ids | Should -Contain 'tweak:disk-cleanup'; $ids | Should -Contain 'tweak:location-off' }
        if ($Level -eq 'advanced') { $ids | Should -Contain 'tweak:classic-context-menu'; $ids | Should -Contain 'remove:onedrive' }
        $ids | Should -Contain 'gpu-nvidia'
        $ids | Should -Contain 'gpu-intel'
        $ids | Should -Contain 'oem-tool'
        $ids | Should -Contain 'app:chrome'
        if ($Mode -eq 'gaming') { $ids | Should -Contain 'app:steam'; $ids | Should -Not -Contain 'office' }
        if ($Mode -ne 'gaming') { $ids | Should -Contain 'office' }
        if ($Mode -eq 'office') { $ids | Should -Not -Contain 'tweak:game-mode' }
        if ($Mode -eq 'custom') {
            foreach ($id in 'app:telegram', 'app:whatsapp', 'app:claude', 'app:winrar') { $ids | Should -Contain $id }
            $ids | Should -Not -Contain 'app:steam'
            $ids | Should -Not -Contain 'app:7zip'
            @($ids | Where-Object { $_ -in 'tweak:game-mode', 'tweak:power-plan' }).Count | Should -Be 0
            $ids | Should -Not -Contain 'tweak:location-off' -Because 'Minimal level'
        }
    }
    It 'adds the performance power plan on desktops only (laptops: unticked)' {
        $ids = @($script:final.steps | ForEach-Object { $_.id })
        if ($Mode -in 'office', 'custom') { $ids | Should -Not -Contain 'tweak:power-plan' }
        elseif ($Form -eq 'laptop') { $ids | Should -Not -Contain 'tweak:power-plan' }
        else { $ids | Should -Contain 'tweak:power-plan' }
    }
    It 'never plans the security trade-offs unless ticked' {
        $ids = @($script:final.steps | ForEach-Object { $_.id })
        $ids | Should -Not -Contain 'tweak:memory-integrity-off'
        $ids | Should -Not -Contain 'tweak:game-bar-off'
        if ($Level -ne 'advanced') { $ids | Should -Not -Contain 'remove:onedrive' }
    }
    It 'leaves the NVIDIA app as a link on the summary' {
        @($script:final.followUps | ForEach-Object { $_.url }) | Should -Contain 'https://www.nvidia.com/en-us/software/nvidia-app/'
    }
}
