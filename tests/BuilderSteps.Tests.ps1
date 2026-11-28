#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# The builder's step-by-step pages (Back / Next, step line). WPF cannot run here, so the step
# functions are taken from Builder.ps1 / LinuxBuilder.ps1 and driven with stand-in controls.

BeforeAll {
    $script:Repo = Split-Path -Parent $PSScriptRoot
    $script:Load = {
        param([string]$File, [string[]]$Functions, [string[]]$Variables)
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Repo $File), [ref]$null, [ref]$null)
        foreach ($name in $Functions) {
            $f = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
            . ([scriptblock]::Create($f.Extent.Text))
        }
        foreach ($v in $Variables) {
            $a = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq "`$script:$v" }, $true)
            . ([scriptblock]::Create($a.Extent.Text))
        }
    }
    function Get-DzText { param([Parameter(Position = 0)]$Text) $Text }
    function New-Control { [pscustomobject]@{ Visibility = 'Visible'; IsEnabled = $true; Text = '' } }
    $script:XamlNames = {
        param([string]$File)
        $doc = New-Object System.Xml.XmlDocument
        $doc.Load((Join-Path $script:Repo $File))
        @($doc.SelectNodes('//*') | ForEach-Object { $_.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml') } | Where-Object { $_ })
    }
}

Describe 'Windows side: one step at a time' {
    BeforeAll {
        . $script:Load 'builder/Builder.ps1' @('Show-WinStep', 'Move-WinStep', 'Get-WinStepProblem') @('WinSteps', 'WinStep', 'WinReached')
    }
    BeforeEach {
        $script:ui = @{}
        foreach ($s in $script:WinSteps) { $script:ui[$s.Panel] = New-Control }
        foreach ($n in 'BackButton', 'NextButton', 'PreviewButton', 'WriteButton') { $script:ui[$n] = New-Control }
        $script:ui.WindowsBodyScroll = [pscustomobject]@{} | Add-Member -MemberType ScriptMethod -Name ScrollToTop -Value { } -PassThru
        $script:WinStep = 0; $script:WinReached = 0
        $script:Errors = @()
        $script:Bar = $null
        $script:Messages = @()
        function Update-StepBar { param($Steps, $Index, $Reached, $OnJump) $script:Bar = @{ Count = @($Steps).Count; Index = $Index; Reached = $Reached } }
        function Update-WinReview { $script:Reviewed = $true }
        function Get-BuilderInput { [pscustomobject]@{ Errors = $script:Errors } }
        function Show-DzMessage { param($Text, $Title, $Kind, $Owner) $script:Messages += $Text }
    }
    It 'has one page per step in the XAML, and the last step is the review' {
        $names = & $script:XamlNames 'builder/Builder.xaml'
        foreach ($s in $script:WinSteps) { $names | Should -Contain $s.Panel }
        @($names | Where-Object { $_ -like 'WinStep*' }).Count | Should -Be $script:WinSteps.Count
        $script:WinSteps[-1].Panel | Should -Be 'WinStepReview'
    }
    It 'starts on step 1 with Back off and Next on, and draws the step line' {
        Show-WinStep -Index 0
        $script:ui.WinStepTarget.Visibility | Should -Be 'Visible'
        $script:ui.WinStepWindows.Visibility | Should -Be 'Collapsed'
        $script:ui.BackButton.IsEnabled | Should -BeFalse
        $script:ui.NextButton.Visibility | Should -Be 'Visible'
        $script:ui.WriteButton.Visibility | Should -Be 'Collapsed'
        $script:Bar.Count | Should -Be 8
        $script:Bar.Index | Should -Be 0
    }
    It 'Next stops on a problem of this step and says it; other steps'' problems do not block' {
        Show-WinStep -Index 0
        $script:Errors = @('Pick the USB stick to make into a Windows installer (plug one in and press Refresh).')
        Move-WinStep -Delta 1
        $script:WinStep | Should -Be 0
        $script:Messages[0] | Should -Match 'Pick the USB stick'
        $script:Errors = @('Enter a password.')
        Move-WinStep -Delta 1
        $script:WinStep | Should -Be 1
        $script:ui.WinStepWindows.Visibility | Should -Be 'Visible'
        $script:ui.WinStepTarget.Visibility | Should -Be 'Collapsed'
    }
    It 'stops on the account step for a missing password' {
        Show-WinStep -Index 2
        $script:Errors = @('Enter a password.')
        Move-WinStep -Delta 1
        $script:WinStep | Should -Be 2
    }
    It 'Back always works, and the line remembers how far you got' {
        Show-WinStep -Index 4
        $script:Errors = @('Enter a password.')
        Move-WinStep -Delta -1
        $script:WinStep | Should -Be 3
        $script:Bar.Reached | Should -Be 4
        $script:ui.BackButton.IsEnabled | Should -BeTrue
    }
    It 'the last step shows the review with CREATE and Preview instead of Next' {
        Show-WinStep -Index 7
        $script:Reviewed | Should -BeTrue
        $script:ui.WinStepReview.Visibility | Should -Be 'Visible'
        $script:ui.NextButton.Visibility | Should -Be 'Collapsed'
        $script:ui.WriteButton.Visibility | Should -Be 'Visible'
        $script:ui.PreviewButton.Visibility | Should -Be 'Visible'
        Show-WinStep -Index 99
        $script:WinStep | Should -Be 7
    }
}

Describe 'Linux side: the steps follow what is picked' {
    BeforeAll {
        . $script:Load 'builder/LinuxBuilder.ps1' @('Get-LxSteps', 'Show-LxStep', 'Move-LxStep', 'Test-LxRawKind') @('LxStep', 'LxReached', 'LxAllPanels')
    }
    BeforeEach {
        $script:lx = @{}
        foreach ($p in $script:LxAllPanels) { $script:lx[$p] = New-Control }
        foreach ($n in 'LxBackButton', 'LxNextButton', 'LxPreviewButton', 'LxWriteButton') { $script:lx[$n] = New-Control }
        $script:lx.LxBodyScroll = [pscustomobject]@{} | Add-Member -MemberType ScriptMethod -Name ScrollToTop -Value { } -PassThru
        $script:LxStep = 0; $script:LxReached = 0; $script:LxBusy = $false
        $script:Kind = 'download'
        $script:Errors = @()
        function Get-LxSystem { [pscustomobject]@{ Kind = $script:Kind } }
        function Update-StepBar { param($Steps, $Index, $Reached, $OnJump) $script:Bar = @{ Count = @($Steps).Count; Index = $Index } }
        function Update-LxReview { }
        function Get-LxInput { [pscustomobject]@{ Errors = $script:Errors } }
        function Show-DzMessage { param($Text, $Title, $Kind, $Owner) }
    }
    It 'has every step page in the XAML' {
        $names = & $script:XamlNames 'builder/LinuxPanel.xaml'
        foreach ($p in $script:LxAllPanels) { $names | Should -Contain $p }
        @($names | Where-Object { $_ -like 'LxStep*' }).Count | Should -Be $script:LxAllPanels.Count
    }
    It 'Ubuntu with DayZero has 7 steps; an ISO written as it is has 3' {
        @(Get-LxSteps).Count | Should -Be 7
        foreach ($k in 'raw-iso', 'download-raw') {
            $script:Kind = $k
            @(Get-LxSteps | ForEach-Object { $_.Panel }) | Should -Be @('LxStepWhich', 'LxStepWhere', 'LxStepReview')
        }
    }
    It 'goes through the pages with Next and Back, CREATE on the last one' {
        Show-LxStep -Index 0
        Move-LxStep -Delta 1
        $script:lx.LxStepWhere.Visibility | Should -Be 'Visible'
        $script:Errors = @('Enter a password. Linux needs one (sudo asks for it).')
        Move-LxStep -Delta 1
        Move-LxStep -Delta 1
        $script:LxStep | Should -Be 2   # stopped on the account step
        Move-LxStep -Delta -1
        $script:LxStep | Should -Be 1
        Show-LxStep -Index 6
        $script:lx.LxWriteButton.Visibility | Should -Be 'Visible'
        $script:lx.LxNextButton.Visibility | Should -Be 'Collapsed'
        $script:lx.LxPreviewButton.Visibility | Should -Be 'Visible'
    }
    It 'an ISO written as it is goes straight from WHERE TO WRITE to CREATE, without a preview' {
        $script:Kind = 'download-raw'
        Show-LxStep -Index 1
        Move-LxStep -Delta 1
        $script:lx.LxStepReview.Visibility | Should -Be 'Visible'
        $script:lx.LxPreviewButton.Visibility | Should -Be 'Collapsed'
        $script:Bar.Count | Should -Be 3
    }
}
