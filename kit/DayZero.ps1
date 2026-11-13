#Requires -Version 5.1
<#
.SYNOPSIS
    DayZero setup wizard.
.DESCRIPTION
    Pick a mode, review the apps and options, then DayZero works through its plan with a
    live step list and log. It survives restarts (the \DayZero\DayZero scheduled task
    starts it again at sign-in), and ends with a summary that can retry failed steps.

    Start it with DayZero.cmd (asks for admin rights). The first sign-in after Windows
    Setup starts it automatically.
.PARAMETER Resume
    Started by the scheduled task at sign-in: continue where it stopped.
.PARAMETER DryRun
    Only log what would be done; change nothing.
.PARAMETER Mode
    Pre-select a mode id from config\modes.json (gaming, office, everything).
.PARAMETER Reset
    Forget previous progress and start again at the mode picker.
.PARAMETER Undo
    Revert DayZero's tweaks (see TESTING.md).
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'WPF event handler parameters are used inside the Invoke-DzSafe blocks, which the analyzer cannot follow.')]
[CmdletBinding()]
param(
    [switch]$Resume,
    [switch]$DryRun,
    [string]$Mode,
    [switch]$Reset,
    [switch]$Undo
)

$ErrorActionPreference = 'Stop'
$script:Kit = $PSScriptRoot
$script:Cli = @{ Resume = [bool]$Resume; DryRun = [bool]$DryRun; Mode = [string]$Mode; Reset = [bool]$Reset; Undo = [bool]$Undo }

# Status icons (kept as code points so this file stays ASCII for PowerShell 5.1).
$script:Icons = @{
    pending = [string][char]0x25CB   # white circle
    running = [string][char]0x25D4   # circle with upper-right quadrant
    done    = [string][char]0x2713   # check mark
    warn    = [string][char]0x26A0   # warning sign (Segoe UI Symbol draws it in one colour)
    failed  = [string][char]0x2715   # multiplication x
    skipped = [string][char]0x2192   # arrow
    reboot  = [string][char]0x21BB   # clockwise open circle arrow
}
$script:Arrow = [string][char]0x25B6
$script:Bullet = [string][char]0x2022

$script:ui = $null
$script:Window = $null
$script:Page = ''
$script:State = $null
$script:SelectedMode = $null
$script:ModeCards = @()
$script:ReviewControls = @()
$script:StepItems = $null
$script:Sync = $null
$script:Job = $null
$script:Timer = $null
$script:RebootTimer = $null
$script:RebootSeconds = 0
$script:WaitingForRestart = $false
$script:CloseWhenStopped = $false
$script:Paused = $false
$script:LastError = $null

# ------------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------------

function Invoke-DzSafe {
    <# Runs a GUI action; an error is logged and shown instead of crashing the window. #>
    param([Parameter(Mandatory = $true)][scriptblock]$Action)
    try { & $Action }
    catch {
        $msg = $_.Exception.Message
        try { Write-DzLog -Level Error -Message ("GUI: $msg " + $_.ScriptStackTrace) } catch { Write-Verbose $msg }
        [void](Show-DzMessage -Text "Something went wrong:`n`n$msg" -Kind Error -Owner $script:Window)
    }
}

function Get-DzBrush {
    param([Parameter(Mandatory = $true)][string]$Key)
    return $script:Window.FindResource($Key)
}

function New-DzTextBlock {
    param([string]$Text, [double]$Size = 13, [string]$Brush = '', [switch]$Bold, [switch]$Wrap, [switch]$Emoji, [double]$Top = 0)
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Text
    $tb.FontSize = $Size
    if ($Bold) { $tb.FontWeight = [System.Windows.FontWeights]::Bold }
    if ($Wrap) { $tb.TextWrapping = [System.Windows.TextWrapping]::Wrap }
    if ($Emoji) { $tb.FontFamily = Get-DzBrush 'DzEmoji' }
    if ($Brush) { $tb.Foreground = Get-DzBrush $Brush }
    if ($Top -ne 0) { $tb.Margin = New-Object System.Windows.Thickness(0, $Top, 0, 0) }
    return $tb
}

function Set-DzVisible {
    param([Parameter(Mandatory = $true)][object]$Element, [bool]$Visible)
    $Element.Visibility = if ($Visible) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
}

function New-DzStepView {
    param([int]$Index, [object]$Step, [string]$Status, [string]$Message)
    if (-not $Status) { $Status = [string]$Step.status }
    if ($null -eq $Message) { $Message = [string]$Step.message }
    $icon = $script:Icons['pending']
    if ($script:Icons.ContainsKey($Status)) { $icon = $script:Icons[$Status] }
    return [pscustomobject]@{ Index = $Index; Id = [string]$Step.id; Title = [string]$Step.title; Status = $Status; Icon = $icon; Message = [string]$Message }
}

# ------------------------------------------------------------------------------------
# Pages
# ------------------------------------------------------------------------------------

function Invoke-DzPageAnimation {
    <# Fades a page in while it slides up a little. #>
    param([Parameter(Mandatory = $true)][object]$Element)
    if (-not ($Element.RenderTransform -is [System.Windows.Media.TranslateTransform])) {
        $Element.RenderTransform = New-Object System.Windows.Media.TranslateTransform
    }
    $duration = New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(280))
    $ease = New-Object System.Windows.Media.Animation.CubicEase
    $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
    $fade = New-Object System.Windows.Media.Animation.DoubleAnimation(0.0, 1.0, $duration)
    $fade.EasingFunction = $ease
    $slide = New-Object System.Windows.Media.Animation.DoubleAnimation(16.0, 0.0, $duration)
    $slide.EasingFunction = $ease
    $Element.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
    $Element.RenderTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $slide)
}

function Set-DzPage {
    param([Parameter(Mandatory = $true)][ValidateSet('Mode', 'Review', 'Progress', 'Summary', 'Esu')][string]$Name)
    $ui = $script:ui
    $changed = ($script:Page -ne $Name)
    $script:Page = $Name
    Set-DzVisible $ui.ModePage ($Name -eq 'Mode')
    Set-DzVisible $ui.ReviewPage ($Name -eq 'Review')
    Set-DzVisible $ui.ProgressPage ($Name -eq 'Progress')
    Set-DzVisible $ui.SummaryPage ($Name -eq 'Summary')
    Set-DzVisible $ui.EsuPage ($Name -eq 'Esu')
    if ($changed) {
        $pageElement = @{ Mode = $ui.ModePage; Review = $ui.ReviewPage; Progress = $ui.ProgressPage; Summary = $ui.SummaryPage; Esu = $ui.EsuPage }[$Name]
        try { Invoke-DzPageAnimation -Element $pageElement } catch { Write-Verbose 'Page animation skipped.' }
    }

    Set-DzVisible $ui.BackButton ($Name -eq 'Review')
    Set-DzVisible $ui.StopButton ($Name -eq 'Progress' -and -not $script:WaitingForRestart)
    Set-DzVisible $ui.OpenLogsButton ($Name -in @('Progress', 'Summary'))
    Set-DzVisible $ui.RetryButton $false
    Set-DzVisible $ui.OpenLinksButton $false
    Set-DzVisible $ui.NextButton ($Name -ne 'Progress')
    $ui.NextButton.IsEnabled = $true
    switch ($Name) {
        'Mode' {
            $ui.NextButton.Content = "_NEXT  $($script:Arrow)"
            $ui.HintText.Text = 'Arrow keys or 1 - 4 pick a mode  |  Enter continues'
        }
        'Review' {
            $ui.NextButton.Content = "_START  $($script:Arrow)"
            $ui.HintText.Text = 'Space ticks a box  |  Enter starts  |  Esc goes back'
        }
        'Progress' {
            $ui.HintText.Text = 'L shows the live log  |  You can keep using the PC; restarts are announced first'
        }
        'Summary' {
            $ui.NextButton.Content = if ($script:Paused) { "_CONTINUE  $($script:Arrow)" } else { "_FINISH  $($script:Arrow)" }
            $ui.HintText.Text = 'Finish turns off automatic sign-in and cleans up the setup helpers'
        }
        'Esu' {
            $ui.NextButton.Content = '_CLOSE'
            $ui.HintText.Text = ''
        }
    }
}

function Initialize-DzModeCards {
    $ui = $script:ui
    $ui.ModeCardsPanel.Children.Clear()
    $cards = New-Object System.Collections.Generic.List[object]
    $style = Get-DzBrush 'DzModeCard'
    foreach ($m in @(Get-DzModeList -Config $script:Config)) {
        $rb = New-Object System.Windows.Controls.RadioButton
        $rb.GroupName = 'Mode'
        $rb.Style = $style
        $rb.Tag = [string]$m.id
        $rb.MinHeight = 270
        $rb.Margin = New-Object System.Windows.Thickness(8)
        $panel = New-Object System.Windows.Controls.StackPanel
        $glyph = [string](Get-DzProperty $m 'icon' '')
        if ($glyph) {
            $iconBlock = New-DzTextBlock -Text $glyph -Size 34 -Brush 'DzText' -Top 4
            $iconBlock.FontFamily = Get-DzBrush 'DzIconFont'
            $panel.Children.Add($iconBlock) | Out-Null
        }
        else { $panel.Children.Add((New-DzTextBlock -Text ([string](Get-DzProperty $m 'emoji' '')) -Size 52 -Emoji)) | Out-Null }
        $panel.Children[0].HorizontalAlignment = 'Center'
        $title = New-DzTextBlock -Text ([string](Get-DzProperty $m 'title' $m.id)) -Size 18 -Bold -Top 10
        $title.HorizontalAlignment = 'Center'
        $panel.Children.Add($title) | Out-Null
        $tag = New-DzTextBlock -Text ([string](Get-DzProperty $m 'tagline' '')) -Size 13 -Brush 'DzMuted' -Top 2
        $tag.HorizontalAlignment = 'Center'
        $panel.Children.Add($tag) | Out-Null
        if ([string]$m.id -eq [string]$script:Settings.defaultMode) {
            $def = New-DzTextBlock -Text 'BUILDER DEFAULT' -Size 10 -Bold -Brush 'DzCyan' -Top 6
            $def.HorizontalAlignment = 'Center'
            $panel.Children.Add($def) | Out-Null
        }
        $first = $true
        foreach ($h in @(Get-DzProperty $m 'highlights' @())) {
            $top = if ($first) { 14 } else { 4 }
            $first = $false
            $panel.Children.Add((New-DzTextBlock -Text ("{0} {1}" -f $script:Bullet, $h) -Size 12 -Brush 'DzMuted' -Wrap -Top $top)) | Out-Null
        }
        $rb.Content = $panel
        [System.Windows.Automation.AutomationProperties]::SetName($rb, ('{0} mode: {1}' -f (Get-DzProperty $m 'title' $m.id), (Get-DzProperty $m 'tagline' '')))
        $rb.Add_Checked({ param($src, $evt) Invoke-DzSafe { Select-DzMode -Id ([string]$src.Tag) } })
        $ui.ModeCardsPanel.Children.Add($rb) | Out-Null
        $cards.Add($rb)
    }
    $script:ModeCards = $cards.ToArray()
}

function Select-DzMode {
    param([Parameter(Mandatory = $true)][string]$Id)
    $script:SelectedMode = $Id
    foreach ($c in $script:ModeCards) { if ([string]$c.Tag -eq $Id -and -not $c.IsChecked) { $c.IsChecked = $true } }
    $m = @(Get-DzModeList -Config $script:Config) | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    if ($m) { $script:ui.ModeDescriptionText.Text = [string](Get-DzProperty $m 'description' '') }
}

function Move-DzModeSelection {
    param([int]$Delta)
    $ids = @($script:ModeCards | ForEach-Object { [string]$_.Tag })
    if ($ids.Count -eq 0) { return }
    $i = [array]::IndexOf($ids, [string]$script:SelectedMode)
    $i = ($i + $Delta + $ids.Count) % $ids.Count
    Select-DzMode -Id $ids[$i]
    $script:ModeCards[$i].Focus() | Out-Null
}

function Show-DzReview {
    $ui = $script:ui
    $mode = Get-DzMode -Config $script:Config -Id $script:SelectedMode
    $preselect = $null
    if ($mode.custom -and $script:Settings.PSObject.Properties['customSelection']) { $preselect = $script:Settings.customSelection }
    # The clean-up level picked in the USB builder (separate from the mode); the mode's suggestion otherwise.
    $level = if ($script:Settings.PSObject.Properties['debloatLevel']) { [string]$script:Settings.debloatLevel } else { $null }
    $review = Get-DzReviewModel -Mode $mode -System $script:System -Config $script:Config -Preselect $preselect -DebloatLevel $level
    $ui.ReviewTitleText.Text = ("YOUR PC  {0}  {1} MODE" -f $script:Bullet, $mode.title)

    $sys = $script:System
    if ($sys) {
        $form = if ($sys.IsVirtualMachine) { 'Virtual machine' } elseif ($sys.IsLaptop) { 'Laptop' } else { 'Desktop' }
        $lines = @(
            ('Windows    {0} {1} (build {2}.{3})' -f ($sys.Caption -replace '^Microsoft ', ''), $sys.DisplayVersion, $sys.Build, $sys.Ubr),
            ('Type       {0} - {1} {2}' -f $form, $sys.Manufacturer, $sys.Model),
            ('Graphics   {0}' -f $(if (@($sys.GpuNames).Count) { @($sys.GpuNames) -join ', ' } else { 'not detected' })),
            ('Memory     {0} GB    Free disk {1} GB' -f $sys.MemoryGB, $sys.FreeDiskGB)
        )
        $ui.SystemInfoText.Text = ($lines -join [Environment]::NewLine)
        Set-DzVisible $ui.LaptopNotice ([bool]$sys.IsLaptop)
    }
    else {
        $ui.SystemInfoText.Text = 'Could not read the PC details (see the log).'
    }

    $ui.OptionsPanel.Children.Clear()
    $ui.AppsPanel.Children.Clear()
    $controls = New-Object System.Collections.Generic.List[object]
    foreach ($c in @(Add-DzChoiceGroup -Panel $ui.OptionsPanel -Items @($review.Options) -RadioPrefix 'opt')) { $controls.Add($c) }
    foreach ($c in @(Add-DzChoiceGroup -Panel $ui.AppsPanel -Items @($review.Apps) -GroupWidth 215 -RadioPrefix 'app')) { $controls.Add($c) }
    $script:ReviewControls = $controls.ToArray()
    Enable-DzLevelPreset -Controls $script:ReviewControls
    Set-DzVisible $ui.NoOptionsText (@($review.Options).Count -eq 0)
    Set-DzVisible $ui.NoAppsText (@($review.Apps).Count -eq 0)
    $script:Review = $review
    Set-DzPage Review
}

function Start-DzFromReview {
    Update-DzChoiceItem -Controls $script:ReviewControls
    $mode = Get-DzMode -Config $script:Config -Id $script:SelectedMode
    $options = ConvertTo-DzPlanOption -Apps @($script:Review.Apps) -Options @($script:Review.Options)
    $plan = New-DzPlan -Mode $mode -Options $options -System $script:System -Config $script:Config
    Write-DzLog -Level Step -Message ("Mode '{0}' chosen: {1} steps planned, {2} apps." -f $mode.id, @($plan).Count, @($options.apps).Count)
    $script:State = New-DzState -Mode $mode.id -Steps $plan -Options $options -System $script:System -BuildId $script:Settings.buildId -DryRun (Test-DzDryRun)
    Save-DzState -State $script:State -Path $script:StatePath
    Start-DzEngine
}

# ------------------------------------------------------------------------------------
# Running the engine
# ------------------------------------------------------------------------------------

function Initialize-DzStepItems {
    $script:StepItems.Clear()
    $i = 0
    foreach ($s in @($script:State.steps)) { $script:StepItems.Add((New-DzStepView -Index $i -Step $s)); $i++ }
}

function Start-DzEngine {
    if ($script:Job) { return }
    $script:Paused = $false
    $script:WaitingForRestart = $false
    Set-DzPage Progress
    Initialize-DzStepItems
    $ui = $script:ui
    $ui.CurrentStepText.Text = 'Starting...'
    $ui.ProgressDetailText.Text = ''
    $ui.StopButton.IsEnabled = $true
    $ui.StopButton.Content = '_Pause after this step'
    $script:Sync = New-DzSync -System $script:System
    $script:Job = Start-DzRunAsync -KitRoot $script:Kit -StatePath $script:StatePath -Sync $script:Sync -DryRun (Test-DzDryRun)
    $script:Timer.Start()
}

function Add-DzLiveLog {
    param([string]$Line)
    $box = $script:ui.LogText
    $box.AppendText($Line + [Environment]::NewLine)
    if ($box.LineCount -gt 5000) { $box.Text = (($box.Text -split "`r?`n") | Select-Object -Last 3000) -join [Environment]::NewLine }
    $box.ScrollToEnd()
}

function Update-DzFromQueue {
    $ui = $script:ui
    if ($null -eq $script:Sync) { return }
    $msg = $null
    $n = 0
    while ($n -lt 400 -and $script:Sync.Queue.TryDequeue([ref]$msg)) {
        $n++
        switch ([string]$msg.type) {
            'log' { Add-DzLiveLog -Line ([string]$msg.line) }
            'step' {
                $i = [int]$msg.index
                if ($i -lt $script:StepItems.Count) {
                    $old = $script:StepItems[$i]
                    $script:StepItems[$i] = [pscustomobject]@{ Index = $i; Id = $old.Id; Title = $old.Title; Status = [string]$msg.status; Icon = $(if ($script:Icons.ContainsKey([string]$msg.status)) { $script:Icons[[string]$msg.status] } else { $old.Icon }); Message = [string]$msg.message }
                    if ($msg.status -eq 'running') {
                        $ui.CurrentStepText.Text = [string]$msg.title
                        $ui.ProgressDetailText.Text = ''
                        $container = $ui.StepList.ItemContainerGenerator.ContainerFromIndex($i)
                        if ($container) { $container.BringIntoView() }
                    }
                }
            }
            'detail' {
                $i = [int]$msg.index
                if ($i -lt $script:StepItems.Count) {
                    $old = $script:StepItems[$i]
                    $script:StepItems[$i] = [pscustomobject]@{ Index = $i; Id = $old.Id; Title = $old.Title; Status = $old.Status; Icon = $old.Icon; Message = [string]$msg.message }
                }
                $ui.ProgressDetailText.Text = [string]$msg.message
            }
            'progress' {
                $ui.OverallProgress.Maximum = [Math]::Max(1, [int]$msg.total)
                $ui.OverallProgress.Value = [int]$msg.done
                $ui.ProgressCountText.Text = ('{0} / {1}' -f $msg.done, $msg.total)
            }
            'reboot' { Show-DzReboot -Reason ([string]$msg.reason) }
            'done' { Complete-DzEngine -Outcome ([string]$msg.outcome); return }
            'crash' {
                $script:LastError = [string]$msg.message
                Write-DzLog -Level Error -Message ("Engine stopped: {0} {1}" -f $msg.message, $msg.stack)
                Add-DzLiveLog -Line ("ENGINE ERROR: " + $msg.message)
                Complete-DzEngine -Outcome 'crash'
                return
            }
        }
    }
    if ($script:Job -and (Test-DzRunAsyncCompleted -Job $script:Job) -and $script:Sync.Queue.IsEmpty) {
        $script:LastError = 'The background engine stopped without reporting back.'
        Complete-DzEngine -Outcome 'crash'
    }
}

function Complete-DzEngine {
    param([Parameter(Mandatory = $true)][string]$Outcome)
    if ($script:Job) { Complete-DzRunAsync -Job $script:Job; $script:Job = $null }
    $script:State = Read-DzState -Path $script:StatePath
    $script:Timer.Stop()
    if ($script:CloseWhenStopped) { $script:Window.Close(); return }
    switch ($Outcome) {
        'reboot' { Write-DzLog -Message 'Waiting for the restart.' }
        'stopped' { $script:Paused = $true; Show-DzSummary }
        default { Show-DzSummary }
    }
}

function Show-DzReboot {
    param([string]$Reason)
    $ui = $script:ui
    $script:WaitingForRestart = $true
    $ui.RebootReasonText.Text = $Reason
    $script:RebootSeconds = 60
    $ui.RebootCountdownText.Text = "Restarting in $($script:RebootSeconds) seconds..."
    Set-DzVisible $ui.StopButton $false
    Set-DzVisible $ui.RebootOverlay $true
    $ui.RestartNowButton.Focus() | Out-Null
    $script:RebootTimer.Start()
}

function Invoke-DzRestartNow {
    $script:RebootTimer.Stop()
    $script:ui.RestartNowButton.IsEnabled = $false
    $script:ui.RestartLaterButton.IsEnabled = $false
    $script:ui.RebootCountdownText.Text = 'Restarting now...'
    Write-DzLog -Level Step -Message 'Restarting to continue setup.'
    Invoke-DzRestart -Reason 'continue DayZero setup'
}

function Stop-DzRestartCountdown {
    $script:RebootTimer.Stop()
    Set-DzVisible $script:ui.RebootOverlay $false
    $script:ui.NextButton.Content = "_RESTART NOW  $($script:Arrow)"
    Set-DzVisible $script:ui.NextButton $true
    $script:ui.HintText.Text = 'DayZero continues automatically after the next restart.'
    Write-DzLog -Message 'Restart postponed by the user.'
}

# ------------------------------------------------------------------------------------
# Summary, finish, Windows 10 reminder
# ------------------------------------------------------------------------------------

function Show-DzSummary {
    $ui = $script:ui
    if ($null -eq $script:State) { $script:State = Read-DzState -Path $script:StatePath }
    $counts = Get-DzStateCount -State $script:State
    $list = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
    $i = 0
    foreach ($s in @($script:State.steps)) { $list.Add((New-DzStepView -Index $i -Step $s)); $i++ }
    $ui.SummaryList.ItemsSource = $list

    if ($script:Paused) { $ui.SummaryTitleText.Text = 'PAUSED' }
    elseif ($counts.failed -gt 0 -or $script:LastError) { $ui.SummaryTitleText.Text = ('DONE, WITH {0} PROBLEM{1}' -f $counts.failed, $(if ($counts.failed -eq 1) { '' } else { 'S' })) }
    else { $ui.SummaryTitleText.Text = ('ALL DONE ' + $script:Icons['done']) }
    $ui.SummaryCountsText.Text = ('{0} done  |  {1} with notes  |  {2} failed  |  {3} skipped  |  {4} not started{5}' -f $counts.done, $counts.warn, $counts.failed, $counts.skipped, ($counts.pending + $counts.reboot + $counts.running), $(if (Test-DzDryRun) { '   (DRY RUN: nothing was changed)' } else { '' }))

    # Activation (read-only)
    $act = Get-DzActivationStatus
    if ($act.Error) {
        $ui.ActivationText.Text = 'Could not read the activation status.'
        $ui.ActivationDetailText.Text = $act.Error
    }
    else {
        $ui.ActivationText.Text = if ($act.Activated) { "$($script:Icons['done']) Windows is activated" } else { "$($script:Icons['failed']) $($act.StatusText)" }
        $ui.ActivationText.Foreground = Get-DzBrush $(if ($act.Activated) { 'DzGreen' } else { 'DzRed' })
        $detail = @()
        if ($act.Edition) { $detail += $act.Edition }
        if ($act.Channel) { $detail += "Licence channel: $($act.Channel)" }
        if ($act.FirmwareKeyPresent) { $detail += "Key in this PC's firmware: $($act.FirmwareEdition)" }
        if (-not $act.Activated) { $detail += 'Settings > System > Activation shows why. A digital licence often kicks in within an hour of being online.' }
        $ui.ActivationDetailText.Text = ($detail -join [Environment]::NewLine)
    }

    $notes = New-Object System.Collections.Generic.List[string]
    if ($script:Paused) { $notes.Add('DayZero is paused. Press CONTINUE to carry on with the remaining steps.') }
    if ($script:LastError) { $notes.Add("The engine stopped with an error: $($script:LastError)") }
    if ($counts.failed -gt 0) { $notes.Add("Press 'Retry failed steps'. Many failures (downloads, Store apps) work on a second try, especially after Windows Update.") }
    $office = @($script:State.steps | Where-Object { $_.type -eq 'office' -and $_.status -in @('done', 'warn') })
    if ($office.Count -gt 0) { $notes.Add('Open Word or Excel and sign in with your Microsoft account to activate Microsoft 365.') }
    if (@($script:State.steps | Where-Object { $_.type -eq 'tweak' -and $_.status -eq 'done' }).Count -gt 0) {
        $notes.Add('Some tweaks (GPU scheduling, Memory Integrity, mouse) take effect after the next restart.')
        $notes.Add(('Changed your mind? Run {0} -Undo to put every tweak back and reinstall removed apps.' -f (Join-Path $script:Kit 'DayZero.cmd')))
    }
    foreach ($f in @(Get-DzFollowUpList)) { $notes.Add(("{0}: {1}" -f $f.title, $f.url)) }
    if ($script:State.PSObject.Properties['restartRecommended'] -and $script:State.restartRecommended) { $notes.Add('Restart the PC once you are done, to finish drivers and updates.') }
    if ($script:Settings.temporaryPassword) { $notes.Add('You set a temporary password: Windows asks for a new one at your next sign-in.') }
    if (Test-DzDryRun) { $notes.Add('This was a DRY RUN. Open the logs to see everything DayZero would have done.') }
    if (-not $script:Paused) { $notes.Add('Press FINISH to switch off automatic sign-in and remove the setup helpers.') }
    $ui.NextStepsText.Text = (($notes | ForEach-Object { "$($script:Bullet) $_" }) -join [Environment]::NewLine)

    Set-DzPage Summary
    Set-DzVisible $ui.RetryButton ($counts.failed -gt 0)
    Set-DzVisible $ui.OpenLinksButton (@(Get-DzFollowUpList).Count -gt 0)
}

function Get-DzFollowUpList {
    if ($null -eq $script:State -or -not $script:State.PSObject.Properties['followUps']) { return @() }
    return @($script:State.followUps | Where-Object { $_ -and $_.url })
}

function Open-DzFollowUp {
    # explorer.exe hands the link to the signed-in user's normal (not elevated) browser.
    foreach ($f in @(Get-DzFollowUpList)) {
        if ([string]$f.url -match '^https://') {
            Write-DzLog -Message ("Opening {0}" -f $f.url)
            Start-Process -FilePath 'explorer.exe' -ArgumentList ([string]$f.url)
        }
    }
}

function Invoke-DzRetry {
    $n = Reset-DzFailedStep -State $script:State
    Save-DzState -State $script:State -Path $script:StatePath
    Write-DzLog -Level Step -Message "Retrying $n failed step(s)."
    $script:LastError = $null
    Start-DzEngine
}

function Complete-DzWizard {
    $script:ui.NextButton.IsEnabled = $false
    Write-DzLog -Level Step -Message 'Finishing: removing setup helpers.'
    $ok = Complete-DzSetup -Settings $script:Settings
    $script:State.phase = 'finished'
    Save-DzState -State $script:State -Path $script:StatePath
    if (-not $ok) {
        [void](Show-DzMessage -Text 'Some cleanup steps failed (see the log). You can re-run DayZero.cmd later to try again.' -Kind Warning -Owner $script:Window)
    }
    if ($script:System -and [int]$script:System.WindowsVersion -eq 10) { Show-DzEsu; return }
    $script:Window.Close()
}

function Show-DzEsu {
    $nl = [Environment]::NewLine
    $script:ui.EsuText.Text = @(
        'Windows 10 support ended on October 14, 2025. Microsoft''s Extended Security Updates (ESU) program keeps sending security fixes to Windows 10 PCs until October 12, 2027.',
        '',
        'How to enroll:  Settings > Update & Security > Windows Update > "Enroll now".',
        '',
        "$($script:Bullet) Free if you sync your PC settings with Windows Backup, or 1,000 Microsoft Rewards points, or a one-time purchase (US`$30).",
        "$($script:Bullet) Needs Windows 10 version 22H2 with the latest updates installed.",
        "$($script:Bullet) Enrolling needs a Microsoft account. DayZero created a local account; you can sign in to a Microsoft account during enrollment.",
        "$($script:Bullet) If this PC meets the Windows 11 requirements, upgrading is free and needs no ESU."
    ) -join $nl
    Write-DzLog -Message 'Showed the Windows 10 ESU reminder.'
    Set-DzPage Esu
}

# ------------------------------------------------------------------------------------
# Buttons and keys
# ------------------------------------------------------------------------------------

function Invoke-DzNext {
    switch ($script:Page) {
        'Mode' { if ($script:SelectedMode) { Show-DzReview } }
        'Review' { Start-DzFromReview }
        'Progress' { if ($script:WaitingForRestart) { Invoke-DzRestartNow } }
        'Summary' { if ($script:Paused) { Start-DzEngine } else { Complete-DzWizard } }
        'Esu' { $script:Window.Close() }
    }
}

function Invoke-DzKey {
    param([object]$KeyArgs)
    $key = $KeyArgs.Key
    $focused = [System.Windows.Input.Keyboard]::FocusedElement
    if ($focused -is [System.Windows.Controls.TextBox] -and -not $focused.IsReadOnly) { return }
    $K = [System.Windows.Input.Key]
    if ($script:Page -eq 'Mode') {
        $digits = @($K::D1, $K::D2, $K::D3, $K::D4, $K::D5, $K::NumPad1, $K::NumPad2, $K::NumPad3, $K::NumPad4, $K::NumPad5)
        $pos = [array]::IndexOf($digits, $key)
        if ($pos -ge 0) {
            $n = $pos % 5
            if ($n -lt $script:ModeCards.Count) { Select-DzMode -Id ([string]$script:ModeCards[$n].Tag); $script:ModeCards[$n].Focus() | Out-Null }
            $KeyArgs.Handled = $true; return
        }
        if ($key -eq $K::Left -or $key -eq $K::Up) { Move-DzModeSelection -Delta -1; $KeyArgs.Handled = $true; return }
        if ($key -eq $K::Right -or $key -eq $K::Down) { Move-DzModeSelection -Delta 1; $KeyArgs.Handled = $true; return }
        if ($key -eq $K::Enter) { Invoke-DzNext; $KeyArgs.Handled = $true; return }
    }
    elseif ($script:Page -eq 'Review') {
        if ($key -eq $K::Escape) { Set-DzPage Mode; $KeyArgs.Handled = $true; return }
        if ($key -eq $K::Enter) { Invoke-DzNext; $KeyArgs.Handled = $true; return }
    }
    elseif ($script:Page -eq 'Progress') {
        if ($key -eq $K::L) { $script:ui.LogExpander.IsExpanded = -not $script:ui.LogExpander.IsExpanded; $KeyArgs.Handled = $true; return }
    }
}

function Confirm-DzClose {
    param([object]$CloseArgs)
    if ($null -eq $script:Job) { return }
    if ($script:CloseWhenStopped) { return }    # second attempt: let it close
    $answer = Show-DzMessage -Kind Question -Owner $script:Window -Text ("DayZero is still working on:`n  {0}`n`nPause after this step and close? It continues at your next sign-in." -f $script:ui.CurrentStepText.Text)
    $CloseArgs.Cancel = $true
    if ($answer -eq 'Yes') {
        $script:CloseWhenStopped = $true
        $script:Sync.Cancel = $true
        $script:ui.StopButton.IsEnabled = $false
        $script:ui.StopButton.Content = 'Pausing...'
        Write-DzLog -Message 'Closing requested: pausing after the current step.'
    }
}

# ------------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------------

function Start-DzWizard {
    $lib = Join-Path $script:Kit 'lib'
    foreach ($m in (& (Join-Path $lib 'Modules.ps1'))) { Import-Module (Join-Path $lib $m) -Force -DisableNameChecking }
    Import-Module (Join-Path $lib 'Ui.psm1') -Force

    $script:Settings = Get-DzSettings
    $script:StatePath = Get-DzStatePath
    if ($script:Cli.Reset -and (Test-Path -LiteralPath $script:StatePath)) {
        Move-Item -LiteralPath $script:StatePath -Destination ($script:StatePath + '.reset-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) -Force
    }
    $script:State = Read-DzState -Path $script:StatePath
    $dry = $script:Cli.DryRun -or [bool]$script:Settings.dryRun
    if ($script:State -and $script:State.PSObject.Properties['dryRun']) { $dry = $dry -or [bool]$script:State.dryRun }
    Set-DzDryRun -Enabled $dry
    [void](Initialize-DzLog -Name 'wizard' -BuildId $script:Settings.buildId)
    Write-DzLog -Level Step -Message ("DayZero {0} wizard started (resume: {1}, dry run: {2}, state: {3})." -f (Get-DzVersion), $script:Cli.Resume, $dry, $(if ($script:State) { $script:State.phase } else { 'none' }))

    if ($script:Cli.Resume -and $script:State -and $script:State.phase -eq 'finished') {
        # The task is DayZero's own helper, so it is removed even after a dry run.
        Write-DzLog -Message 'Setup already finished; removing the auto-start task.'
        Set-DzDryRun -Enabled $false
        Unregister-DzResumeTask
        return
    }
    if ($script:Cli.Undo) {
        if (Get-Command -Name 'Invoke-DzUndo' -ErrorAction SilentlyContinue) { Invoke-DzUndo; return }
        throw 'Undo is not available in this DayZero version.'
    }

    $script:Config = Get-DzConfig -KitRoot $script:Kit
    foreach ($p in @(Test-DzConfig -Config $script:Config)) { Write-DzLog -Level Warn -Message "Config: $p" }
    try { $script:System = Get-DzSystemInfo; Write-DzLog -Message ('This PC: ' + (Format-DzSystemSummary -System $script:System)) }
    catch { $script:System = $null; Write-DzLog -Level Warn -Message ('Could not read PC details: ' + $_.Exception.Message) }

    [void](Initialize-DzTheme -ThemePath (Join-Path $script:Kit 'ui\Theme.xaml'))
    $xamlPath = Join-Path $script:Kit 'ui\Wizard.xaml'
    $script:Window = Import-DzXaml -Path $xamlPath
    $script:ui = Get-DzNamedElement -Root $script:Window -XamlPath $xamlPath
    $ui = $script:ui

    $ui.SubtitleText.Text = ("SETUP WIZARD  {0}  v{1}" -f [char]0x00B7, (Get-DzVersion))
    Set-DzVisible $ui.DryRunBadge $dry
    if ($script:System) { $ui.SystemChipText.Text = Format-DzSystemSummary -System $script:System }
    $script:StepItems = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
    $ui.StepList.ItemsSource = $script:StepItems

    $script:Timer = New-Object System.Windows.Threading.DispatcherTimer
    $script:Timer.Interval = [TimeSpan]::FromMilliseconds(150)
    $script:Timer.Add_Tick({ Invoke-DzSafe { Update-DzFromQueue } })
    $script:RebootTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:RebootTimer.Interval = [TimeSpan]::FromSeconds(1)
    $script:RebootTimer.Add_Tick({
            Invoke-DzSafe {
                $script:RebootSeconds--
                $script:ui.RebootCountdownText.Text = "Restarting in $($script:RebootSeconds) seconds..."
                if ($script:RebootSeconds -le 0) { Invoke-DzRestartNow }
            }
        })

    $ui.NextButton.Add_Click({ Invoke-DzSafe { Invoke-DzNext } })
    $ui.BackButton.Add_Click({ Invoke-DzSafe { Set-DzPage Mode } })
    $ui.RetryButton.Add_Click({ Invoke-DzSafe { Invoke-DzRetry } })
    $ui.OpenLinksButton.Add_Click({ Invoke-DzSafe { Open-DzFollowUp } })
    $ui.StopButton.Add_Click({
            Invoke-DzSafe {
                if ($script:Sync) { $script:Sync.Cancel = $true }
                $script:ui.StopButton.IsEnabled = $false
                $script:ui.StopButton.Content = 'Pausing after this step...'
                Write-DzLog -Message 'Pause requested.'
            }
        })
    $ui.OpenLogsButton.Add_Click({ Invoke-DzSafe { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + (Join-Path $script:Kit 'Logs') + '"') } })
    $ui.RestartNowButton.Add_Click({ Invoke-DzSafe { Invoke-DzRestartNow } })
    $ui.RestartLaterButton.Add_Click({ Invoke-DzSafe { Stop-DzRestartCountdown } })
    $ui.OpenWindowsUpdateButton.Add_Click({ Invoke-DzSafe { Start-Process -FilePath 'ms-settings:windowsupdate' } })
    $script:Window.Add_PreviewKeyDown({ param($src, $keyArgs) Invoke-DzSafe { Invoke-DzKey -KeyArgs $keyArgs } })
    $script:Window.Add_Closing({ param($src, $closeArgs) Invoke-DzSafe { Confirm-DzClose -CloseArgs $closeArgs } })

    Initialize-DzModeCards
    $wanted = @($script:Cli.Mode, [string]$script:Settings.defaultMode, [string](Get-DzProperty $script:Config.modes 'defaultMode' ''), 'gaming') |
        Where-Object { $_ -and (@($script:ModeCards | ForEach-Object { [string]$_.Tag }) -contains $_) } | Select-Object -First 1
    if ($wanted) { Select-DzMode -Id $wanted }

    $phase = if ($script:State) { [string]$script:State.phase } else { 'select' }
    $script:Window.Add_ContentRendered({
            Invoke-DzSafe {
                switch ($phase) {
                    { $_ -in @('running', 'reboot') } { Start-DzEngine }
                    { $_ -in @('summary', 'finished') } { Show-DzSummary }
                    default {
                        Set-DzPage Mode
                        $sel = @($script:ModeCards | Where-Object { $_.IsChecked }) | Select-Object -First 1
                        if ($sel) { $sel.Focus() | Out-Null }
                    }
                }
            }
        })
    Set-DzPage Mode
    [void]$script:Window.ShowDialog()
    Write-DzLog -Message 'Wizard window closed.'
}

try {
    Start-DzWizard
}
catch {
    $msg = $_.Exception.Message
    try { Write-DzLog -Level Error -Message ($msg + ' ' + $_.ScriptStackTrace) } catch { Write-Verbose $msg }
    try {
        Add-Type -AssemblyName PresentationFramework
        [void][System.Windows.MessageBox]::Show("DayZero hit an error:`n`n$msg`n`nLogs: $script:Kit\Logs", 'DayZero', 'OK', 'Error')
    }
    catch { Write-Error $msg }
    exit 1
}
