#Requires -Version 5.1
<#
.SYNOPSIS
    DayZero setup wizard - STAGE 1 PLACEHOLDER.
.DESCRIPTION
    Stage 1 ships the USB builder and the install-time bootstrap. This placeholder proves
    the whole chain on a freshly installed PC:
        answer file -> toolkit copied to C:\DayZero -> first sign-in -> scheduled task -> this window
    It logs to C:\DayZero\Logs (and the USB stick's DayZero\Logs when plugged in).
    "Finish" runs the real end-of-setup cleanup (auto-start task, automatic sign-in,
    cached answer files, temporary password). The full wizard replaces this in stage 2.
.PARAMETER Resume
    Started by the scheduled task at sign-in.
.PARAMETER DryRun
    Only log what would be done.
#>
[CmdletBinding()]
param(
    [switch]$Resume,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$kit = $PSScriptRoot

try {
    Import-Module (Join-Path $kit 'lib\Core.psm1') -Force
    Import-Module (Join-Path $kit 'lib\Session.psm1') -Force
    Import-Module (Join-Path $kit 'lib\Ui.psm1') -Force

    $settings = Get-DzSettings
    Set-DzDryRun -Enabled ([bool]$DryRun -or [bool]$settings.dryRun)
    $logPath = Initialize-DzLog -Name 'wizard' -BuildId $settings.buildId
    Write-DzLog -Level Step -Message ("DayZero {0} placeholder wizard started (resume: {1}, dry run: {2})." -f (Get-DzVersion), [bool]$Resume, (Test-DzDryRun))

    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $details = @(
        ('Windows    : {0} (build {1})' -f $os.Caption, $os.BuildNumber),
        ('Computer   : {0}' -f $env:COMPUTERNAME),
        ('User       : {0}' -f $env:USERNAME),
        ('Mode       : {0}{1}' -f $settings.defaultMode, $(if (Test-DzDryRun) { '   (DRY RUN)' } else { '' })),
        ('Build id   : {0}' -f $settings.buildId),
        ('Toolkit    : {0}' -f $kit),
        ('Log        : {0}' -f $logPath)
    )
    foreach ($d in $details) { Write-DzLog -Message $d }

    [void](Initialize-DzTheme -ThemePath (Join-Path $kit 'ui\Theme.xaml'))
    $xamlPath = Join-Path $kit 'ui\Placeholder.xaml'
    $window = Import-DzXaml -Path $xamlPath
    $ui = Get-DzNamedElement -Root $window -XamlPath $xamlPath
    $ui.SubtitleText.Text = "SETUP WIZARD  $([char]0x00B7)  v$(Get-DzVersion)  $([char]0x00B7)  stage 1 preview"
    $ui.DetailsText.Text = ($details -join [Environment]::NewLine)

    $ui.LaterButton.Add_Click({
            Write-DzLog -Message 'User chose "ask again next sign-in".'
            $window.Close()
        })
    $ui.FinishButton.Add_Click({
            $ui.FinishButton.IsEnabled = $false
            Write-DzLog -Level Step -Message 'Finishing: cleaning up the temporary setup helpers.'
            $ok = Complete-DzSetup -Settings $settings
            if ($ok) {
                $ui.StatusText.Text = 'All cleaned up. You can close this window.'
                $ui.StatusText.Foreground = $window.FindResource('DzGreen')
            }
            else {
                $ui.StatusText.Text = "Some cleanup steps failed. See $logPath"
                $ui.StatusText.Foreground = $window.FindResource('DzRed')
                $ui.FinishButton.IsEnabled = $true
            }
            $ui.LaterButton.Content = '_Close'
        })

    [void]$window.ShowDialog()
    Write-DzLog -Message 'Placeholder wizard closed.'
}
catch {
    $msg = $_.Exception.Message
    try { Write-DzLog -Level Error -Message ($msg + ' ' + $_.ScriptStackTrace) } catch { Write-Verbose 'Logging failed.' }
    try {
        Add-Type -AssemblyName PresentationFramework
        [void][System.Windows.MessageBox]::Show("DayZero hit an error:`n`n$msg`n`nLogs: $kit\Logs", 'DayZero', 'OK', 'Error')
    }
    catch { Write-Error $msg }
    exit 1
}
