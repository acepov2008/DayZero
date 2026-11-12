#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Tests for drivers and Windows Update: Drivers\ folder (pnputil), GPU / PC-brand apps,
# and the Windows Update loop (COM replaced by mocks).

BeforeAll {
    $repo = Split-Path -Parent $PSScriptRoot
    $script:SourceKit = Join-Path $repo 'kit'
    $lib = Join-Path $script:SourceKit 'lib'
    foreach ($m in (& (Join-Path $lib 'Modules.ps1'))) { Import-Module (Join-Path $lib $m) -Force -DisableNameChecking }
    $script:Config = Get-DzConfig -KitRoot $script:SourceKit
    function New-Ctx {
        param([string]$KitRoot = $script:SourceKit)
        $state = New-DzState -Mode 'gaming' -Steps @([ordered]@{ id = 'x'; title = 'X'; type = 'gpuApp'; group = 'D'; args = @{}; requires = @() })
        $c = New-DzContext -State $state -Config $script:Config -KitRoot $KitRoot -Settings ([pscustomobject]@{ buildId = $null })
        $c.Flags['WingetPath'] = 'C:\fake\winget.exe'
        return $c
    }
}

Describe 'drivers.json' {
    It 'covers NVIDIA, AMD and Intel graphics' {
        @($script:Config.drivers.gpuApps | ForEach-Object { $_.vendor }) | Should -Be @('NVIDIA', 'AMD', 'Intel')
    }
    It 'covers Dell, Lenovo, HP and ASUS' {
        @($script:Config.drivers.oemTools | ForEach-Object { $_.brand }) | Should -Be @('Dell', 'Lenovo', 'HP', 'ASUS')
    }
    It 'gives every entry a winget id, Store id or official https page on the vendor''s own site' {
        foreach ($i in @($script:Config.drivers.gpuApps) + @($script:Config.drivers.oemTools)) {
            $w = Get-DzProperty $i 'winget' ''; $m = Get-DzProperty $i 'msstore' ''; $p = Get-DzProperty $i 'page' ''
            ([bool]$w -or [bool]$m -or [bool]$p) | Should -BeTrue -Because $i.name
            if ($p) { $p | Should -Match '^https://(www\.)?(nvidia|amd|intel|dell|lenovo|hp|asus)\.com/' }
            if ($m) { $m | Should -Match '^[0-9A-Z]{12}$' }
        }
    }
}

Describe 'GPU and PC-brand apps' {
    BeforeEach { Mock -ModuleName Drivers Install-DzWingetPackage { New-DzStepResult -Status Done -Message "installed $Id from $Source" } }

    It 'installs the Intel app with winget' {
        $ctx = New-Ctx
        $ctx.Step = [pscustomobject]@{ args = [pscustomobject]@{ vendor = 'Intel' } }
        $r = Invoke-DzStepGpuApp -Context $ctx
        $r.Message | Should -Be 'installed Intel.IntelDriverAndSupportAssistant from winget'
    }
    It 'links to the official NVIDIA page instead of guessing a download' {
        $ctx = New-Ctx
        $ctx.Step = [pscustomobject]@{ args = [pscustomobject]@{ vendor = 'NVIDIA' } }
        $r = Invoke-DzStepGpuApp -Context $ctx
        $r.Status | Should -Be 'Warn'
        $r.Message | Should -Match 'nvidia\.com'
        @($ctx.State.followUps).Count | Should -Be 1
        $ctx.State.followUps[0].url | Should -Be 'https://www.nvidia.com/en-us/software/nvidia-app/'
        Should -Invoke -ModuleName Drivers Install-DzWingetPackage -Times 0
    }
    It 'does not add the same link twice (retry)' {
        $ctx = New-Ctx
        $ctx.Step = [pscustomobject]@{ args = [pscustomobject]@{ vendor = 'AMD' } }
        [void](Invoke-DzStepGpuApp -Context $ctx)
        [void](Invoke-DzStepGpuApp -Context $ctx)
        @($ctx.State.followUps).Count | Should -Be 1
    }
    It 'installs Lenovo Vantage from the Microsoft Store' {
        $ctx = New-Ctx
        $ctx.Step = [pscustomobject]@{ args = [pscustomobject]@{ brand = 'Lenovo' } }
        (Invoke-DzStepOemTool -Context $ctx).Message | Should -Be 'installed 9WZDNCRFJ4MV from msstore'
    }
    It 'installs Dell Command Update with winget' {
        $ctx = New-Ctx
        $ctx.Step = [pscustomobject]@{ args = [pscustomobject]@{ brand = 'Dell' } }
        (Invoke-DzStepOemTool -Context $ctx).Message | Should -Be 'installed Dell.CommandUpdate.Universal from winget'
    }
}

Describe 'Drivers folder (pnputil)' {
    BeforeEach {
        Set-DzDryRun -Enabled $false
        $script:kit = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path (Join-Path $script:kit 'Drivers'))
    }
    AfterAll { Set-DzDryRun -Enabled $false }
    It 'maps exit codes' {
        (Get-DzPnputilOutcome -ExitCode 0).Status | Should -Be 'Done'
        (Get-DzPnputilOutcome -ExitCode 3010).Status | Should -Be 'Warn'
        (Get-DzPnputilOutcome -ExitCode 259).Status | Should -Be 'Done'
        (Get-DzPnputilOutcome -ExitCode 5).Status | Should -Be 'Failed'
    }
    It 'skips quietly when the folder has no drivers' {
        (Install-DzDriverFolder -Context (New-Ctx -KitRoot $script:kit)).Status | Should -Be 'Skipped'
    }
    It 'runs pnputil /add-driver (folder)\*.inf /subdirs /install and reports a needed restart' {
        Set-Content -LiteralPath (Join-Path $script:kit 'Drivers/wifi.inf') -Value '[Version]'
        Mock -ModuleName Drivers Invoke-DzProcess { [pscustomobject]@{ ExitCode = 3010; Output = @('Added driver packages: 1'); TimedOut = $false } }
        $ctx = New-Ctx -KitRoot $script:kit
        $r = Install-DzDriverFolder -Context $ctx
        $r.Status | Should -Be 'Warn'
        $ctx.Flags['RestartRecommended'] | Should -BeTrue
        Should -Invoke -ModuleName Drivers Invoke-DzProcess -Times 1 -ParameterFilter {
            $FilePath -match 'pnputil' -and $Arguments[0] -eq '/add-driver' -and $Arguments[1] -like '*.inf' -and ($Arguments -contains '/subdirs') -and ($Arguments -contains '/install')
        }
    }
    It 'only counts the drivers in dry-run mode' {
        Set-Content -LiteralPath (Join-Path $script:kit 'Drivers/a.inf') -Value '[Version]'
        Set-DzDryRun -Enabled $true
        Mock -ModuleName Drivers Invoke-DzProcess { throw 'must not run' }
        (Install-DzDriverFolder -Context (New-Ctx -KitRoot $script:kit)).Message | Should -Match 'DRY-RUN.*1 driver'
    }
}

Describe 'Windows Update' {
    BeforeAll {
        function New-FakeUpdate { param([string]$Title) [pscustomobject]@{ Title = $Title; MaxDownloadSize = 50MB } }
    }
    BeforeEach {
        Set-DzDryRun -Enabled $false
        $script:round = 0
        Mock -ModuleName WindowsUpdate Test-DzRebootPending { $false }
        Mock -ModuleName WindowsUpdate New-DzUpdateSession { [pscustomobject]@{ fake = $true } }
        Mock -ModuleName WindowsUpdate Find-DzUpdate {
            $script:round++
            if ($script:round -eq 1) { @((New-FakeUpdate 'Cumulative Update'), (New-FakeUpdate 'NVIDIA - Display driver')) } else { @() }
        }
    }
    AfterAll { Set-DzDryRun -Enabled $false }

    It 'searches only what Windows would install by itself: software + drivers, no optional updates' {
        $crit = Get-DzUpdateCriteria
        @($crit | ForEach-Object { $_.Kind }) | Should -Be @('software', 'driver')
        foreach ($c in $crit) { $c.Text | Should -Match 'BrowseOnly=0'; $c.Text | Should -Match 'IsInstalled=0' }
    }
    It 'installs what it finds and searches again until nothing is left' {
        Mock -ModuleName WindowsUpdate Install-DzUpdate { [pscustomobject]@{ RebootRequired = $false; Results = @([pscustomobject]@{ Title = 'a'; ResultCode = 2; HResult = '0x0' }, [pscustomobject]@{ Title = 'b'; ResultCode = 2; HResult = '0x0' }) } }
        $r = Invoke-DzWindowsUpdate -Context (New-Ctx)
        $r.Status | Should -Be 'Done'
        $r.Message | Should -Match 'Installed 2'
        Should -Invoke -ModuleName WindowsUpdate Find-DzUpdate -Times 2
    }
    It 'asks for a restart and runs again afterwards (first pass)' {
        Mock -ModuleName WindowsUpdate Install-DzUpdate { [pscustomobject]@{ RebootRequired = $true; Results = @([pscustomobject]@{ Title = 'a'; ResultCode = 2; HResult = '0x0' }) } }
        (Invoke-DzWindowsUpdate -Context (New-Ctx)).Status | Should -Be 'Reboot'
    }
    It 'never forces a restart in the final check, only recommends one' {
        Mock -ModuleName WindowsUpdate Install-DzUpdate { [pscustomobject]@{ RebootRequired = $true; Results = @([pscustomobject]@{ Title = 'a'; ResultCode = 2; HResult = '0x0' }) } }
        $ctx = New-Ctx
        (Invoke-DzWindowsUpdate -Context $ctx -Final $true).Status | Should -Be 'Warn'
        $ctx.Flags['RestartRecommended'] | Should -BeTrue
    }
    It 'restarts first when Windows is already waiting for one' {
        Mock -ModuleName WindowsUpdate Test-DzRebootPending { $true }
        (Invoke-DzWindowsUpdate -Context (New-Ctx)).Status | Should -Be 'Reboot'
        Should -Invoke -ModuleName WindowsUpdate Find-DzUpdate -Times 0
    }
    It 'reports failed updates without looping forever' {
        Mock -ModuleName WindowsUpdate Find-DzUpdate { @((New-FakeUpdate 'Broken update')) }
        Mock -ModuleName WindowsUpdate Install-DzUpdate { [pscustomobject]@{ RebootRequired = $false; Results = @([pscustomobject]@{ Title = 'Broken update'; ResultCode = 4; HResult = '0x80240022' }) } }
        $r = Invoke-DzWindowsUpdate -Context (New-Ctx)
        $r.Status | Should -Be 'Warn'
        $r.Message | Should -Match 'Broken update'
        Should -Invoke -ModuleName WindowsUpdate Find-DzUpdate -Times 1
    }
    It 'only lists updates in dry-run mode' {
        Set-DzDryRun -Enabled $true
        Mock -ModuleName WindowsUpdate Install-DzUpdate { throw 'must not install' }
        (Invoke-DzWindowsUpdate -Context (New-Ctx)).Message | Should -Match 'DRY-RUN.*2 update'
    }
    It 'explains common Windows Update errors' {
        Mock -ModuleName WindowsUpdate Find-DzUpdate { throw 'Exception from HRESULT: 0x8024402C' }
        (Invoke-DzWindowsUpdate -Context (New-Ctx)).Message | Should -Match 'No connection to Windows Update'
        ConvertTo-DzHResult -Value -2145124322 | Should -Be '0x8024001E'
    }
}

Describe 'Engine keeps the restart recommendation for the summary' {
    It 'writes restartRecommended into state.json' {
        $kit = Join-Path $TestDrive 'rr'
        [void](New-Item -ItemType Directory -Path $kit)
        function global:Invoke-DzTestRestartFlag { param($Context) $Context.Flags['RestartRecommended'] = $true; New-DzStepResult -Status Done }
        Register-DzStepType -Type 'flagTest' -Command 'Invoke-DzTestRestartFlag'
        $s = New-DzState -Mode 'gaming' -Steps @([ordered]@{ id = 'f'; title = 'F'; type = 'flagTest'; group = 'T'; args = @{}; requires = @() })
        $path = Join-Path $kit 'state.json'
        [void](Invoke-DzRun -State $s -StatePath $path -Context (New-DzContext -State $s -KitRoot $kit))
        (Read-DzState -Path $path).restartRecommended | Should -BeTrue
    }
}
