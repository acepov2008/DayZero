#Requires -Version 5.1
<#
    DayZero - 'DayZero.cmd -Undo': puts back everything DayZero's tweaks changed (from
    backup\tweaks.json) and reinstalls the apps it removed (backup\apps.json). Apps that
    DayZero installed are not uninstalled (use Settings > Apps for that), and the restore
    point from before the tweaks is still available as a last resort.
#>

Set-StrictMode -Version 2.0

function Get-DzUndoSummary {
    [CmdletBinding()]
    param()
    $tweaks = @(Read-DzBackup -Name 'tweaks')
    $apps = @(Read-DzBackup -Name 'apps')
    $changeCount = 0
    foreach ($t in $tweaks) { $changeCount += @($t.changes).Count }
    $appTitles = @(foreach ($a in $apps) { foreach ($r in @($a.removed)) { [string]$r.title } })
    return [pscustomobject]@{
        TweakTitles = @($tweaks | ForEach-Object { [string]$_.title })
        ChangeCount = $changeCount
        AppTitles   = $appTitles
        Empty       = ($tweaks.Count -eq 0 -and $apps.Count -eq 0)
    }
}

function Invoke-DzUndo {
    <# Asks first (when there is a GUI), then restores. Returns $true when everything was put back. #>
    [CmdletBinding()]
    param([switch]$NoPrompt)
    $s = Get-DzUndoSummary
    Write-DzLog -Level Step -Message ("Undo requested: {0} setting(s) in {1} tweak(s), {2} removed app(s)." -f $s.ChangeCount, $s.TweakTitles.Count, $s.AppTitles.Count)
    if ($s.Empty) {
        if (-not $NoPrompt) { [void](Show-DzMessage -Text 'There is nothing to undo: DayZero has no recorded changes on this PC.' -Kind Info) }
        return $true
    }
    if (-not $NoPrompt) {
        $lines = @('DayZero will put back:', '')
        if ($s.TweakTitles.Count) { $lines += ($s.TweakTitles | ForEach-Object { "  - $_" }) }
        if ($s.AppTitles.Count) { $lines += ''; $lines += 'and reinstall from the Microsoft Store / winget:'; $lines += ($s.AppTitles | ForEach-Object { "  - $_" }) }
        $lines += ''; $lines += 'Continue?'
        if ((Show-DzMessage -Text ($lines -join "`n") -Kind Question) -ne 'Yes') { Write-DzLog -Message 'Undo cancelled.'; return $false }
    }
    $t = Undo-DzTweak
    $a = Restore-DzRemovedApp
    $problems = @($t.Messages) + @($a.Messages)
    foreach ($p in $problems) { Write-DzLog -Level Warn -Message "Undo: $p" }
    $text = "Restored $($t.Restored) setting(s) and reinstalled $($a.Restored) app(s)."
    if ($problems.Count -gt 0) { $text += "`n`nNot everything worked:`n - " + ($problems -join "`n - ") }
    $text += "`n`nRestart the PC so every setting takes effect."
    Write-DzLog -Level Step -Message ($text -replace "`n", ' ')
    if (-not $NoPrompt) { [void](Show-DzMessage -Text $text -Kind $(if ($problems.Count) { 'Warning' } else { 'Info' })) }
    return ($problems.Count -eq 0)
}

Export-ModuleMember -Function @('Get-DzUndoSummary', 'Invoke-DzUndo')
