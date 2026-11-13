#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Tests for your own scripts (kit\Scripts): finding them, the review switch, the plan step,
# running them (Start-DzUserScript is replaced, nothing is really started) and dry run.

BeforeAll {
    $repo = Split-Path -Parent $PSScriptRoot
    $script:SourceKit = Join-Path $repo 'kit'
    $lib = Join-Path $script:SourceKit 'lib'
    foreach ($m in (& (Join-Path $lib 'Modules.ps1'))) { Import-Module (Join-Path $lib $m) -Force -DisableNameChecking }
    $script:Config = Get-DzConfig -KitRoot $script:SourceKit
    $script:pc = [pscustomobject]@{ WindowsVersion = 11; Build = 26200; IsLaptop = $false; IsVirtualMachine = $false; GpuVendors = @(); Architecture = 'amd64'; EditionId = 'Professional'; Brand = 'Other' }

    function New-ScriptKit {
        param([string[]]$Files)
        $kit = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path (Join-Path $kit 'Scripts') -Force)
        foreach ($f in $Files) { Set-Content -LiteralPath (Join-Path $kit "Scripts/$f") -Value 'x' }
        return $kit
    }
}

Describe 'Finding your scripts' {
    It 'takes .cmd, .bat and .ps1 files in name order and ignores the rest' {
        $kit = New-ScriptKit -Files @('02-b.ps1', '01-a.cmd', 'README.txt', '03-c.bat', 'notes.md')
        @(Get-DzUserScript -Folder (Join-Path $kit 'Scripts') | ForEach-Object { $_.Name }) | Should -Be @('01-a.cmd', '02-b.ps1', '03-c.bat')
    }
    It 'returns nothing for a missing folder' {
        @(Get-DzUserScript -Folder (Join-Path $TestDrive 'nope')).Count | Should -Be 0
    }
    It 'ships an empty Scripts folder with only a README' {
        Test-Path (Join-Path $script:SourceKit 'Scripts/README.txt') | Should -BeTrue
    }
    It 'starts .ps1 with PowerShell (execution policy bypassed) and the rest with cmd' {
        $p = Get-DzScriptCommand -Path 'C:\DayZero\Scripts\a b.ps1'
        $p.FilePath | Should -Be 'powershell.exe'
        $p.Arguments | Should -Contain 'Bypass'
        $p.Arguments[-1] | Should -Be '"C:\DayZero\Scripts\a b.ps1"'
        $c = Get-DzScriptCommand -Path 'C:\DayZero\Scripts\x.cmd'
        $c.FilePath | Should -Be 'cmd.exe'
        $c.Arguments | Should -Be @('/c', '"C:\DayZero\Scripts\x.cmd"')
    }
}

Describe 'Review switch and plan step' {
    BeforeAll {
        foreach ($t in @('preflight', 'app', 'tweak', 'userScripts')) { if (-not (Test-DzStepType -Type $t)) { throw "missing step type $t" } }
        $script:mode = Get-DzMode -Config $script:Config -Id 'gaming'
    }
    It 'offers a ticked switch only when there are scripts' {
        @((Get-DzReviewModel -Mode $script:mode -System $script:pc -Config $script:Config).Options | Where-Object { $_.Kind -eq 'userScripts' }).Count | Should -Be 0
        $r = Get-DzReviewModel -Mode $script:mode -System $script:pc -Config $script:Config -UserScripts @('01-a.cmd', '02-b.ps1')
        $o = @($r.Options | Where-Object { $_.Kind -eq 'userScripts' })[0]
        $o.Checked | Should -BeTrue
        $o.Description | Should -Match '01-a.cmd, 02-b.ps1'
    }
    It 'runs the scripts after the apps and before the late clean-up' {
        $r = Get-DzReviewModel -Mode $script:mode -System $script:pc -Config $script:Config -UserScripts @('01-a.cmd') -DebloatLevel 'standard'
        $opt = ConvertTo-DzPlanOption -Apps @($r.Apps) -Options @($r.Options)
        $opt.userScripts | Should -BeTrue
        $ids = @(New-DzPlan -Mode $script:mode -Options $opt -System $script:pc -Config $script:Config | ForEach-Object { $_.id })
        [array]::IndexOf($ids, 'user-scripts') | Should -BeGreaterThan ([array]::IndexOf($ids, 'app:steam'))
        [array]::IndexOf($ids, 'user-scripts') | Should -BeLessThan ([array]::IndexOf($ids, 'tweak:temp-files-clean'))
    }
    It 'plans nothing when the switch is unticked' {
        $r = Get-DzReviewModel -Mode $script:mode -System $script:pc -Config $script:Config -UserScripts @('01-a.cmd')
        ($r.Options | Where-Object { $_.Kind -eq 'userScripts' }).Checked = $false
        $ids = @(New-DzPlan -Mode $script:mode -Options (ConvertTo-DzPlanOption -Apps @($r.Apps) -Options @($r.Options)) -System $script:pc -Config $script:Config | ForEach-Object { $_.id })
        $ids | Should -Not -Contain 'user-scripts'
    }
}

Describe 'Running your scripts' {
    BeforeEach {
        Set-DzDryRun -Enabled $false
        Mock -ModuleName Scripts Find-DzUsbKit { $null }
    }
    AfterAll { Set-DzDryRun -Enabled $false }

    It 'runs every script in order and carries on after a failure' {
        $kit = New-ScriptKit -Files @('01-a.cmd', '02-b.ps1', '03-c.bat')
        $script:ran = New-Object System.Collections.Generic.List[string]
        Mock -ModuleName Scripts Start-DzUserScript {
            $script:ran.Add((Split-Path -Leaf $Path))
            [pscustomobject]@{ ExitCode = $(if ($Path -like '*02-b.ps1') { 5 } else { 0 }); TimedOut = $false }
        }
        $r = Invoke-DzUserScripts -Context (New-DzContext -KitRoot $kit)
        @($script:ran) | Should -Be @('01-a.cmd', '02-b.ps1', '03-c.bat')
        $r.Status | Should -Be 'Warn'
        $r.Message | Should -Match '02-b.ps1: exit code 5'
    }
    It 'reports Done when every script succeeds' {
        $kit = New-ScriptKit -Files @('only.cmd')
        Mock -ModuleName Scripts Start-DzUserScript { [pscustomobject]@{ ExitCode = 0; TimedOut = $false } }
        (Invoke-DzUserScripts -Context (New-DzContext -KitRoot $kit)).Status | Should -Be 'Done'
    }
    It 'warns about a script that never finishes' {
        $kit = New-ScriptKit -Files @('hang.cmd')
        Mock -ModuleName Scripts Start-DzUserScript { [pscustomobject]@{ ExitCode = $null; TimedOut = $true } }
        (Invoke-DzUserScripts -Context (New-DzContext -KitRoot $kit)).Message | Should -Match 'still running'
    }
    It 'skips when there are no scripts' {
        (Invoke-DzUserScripts -Context (New-DzContext -KitRoot (New-ScriptKit -Files @()))).Status | Should -Be 'Skipped'
    }
    It 'starts nothing in dry-run mode' {
        Set-DzDryRun -Enabled $true
        Mock -ModuleName Scripts Start-DzUserScript { throw 'REAL CHANGE: script started' }
        $r = Invoke-DzUserScripts -Context (New-DzContext -KitRoot (New-ScriptKit -Files @('01-a.cmd')))
        $r.Status | Should -Be 'Done'
        $r.Message | Should -Match 'DRY-RUN'
    }
}
