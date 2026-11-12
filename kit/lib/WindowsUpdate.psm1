#Requires -Version 5.1
<#
    DayZero - Windows Update through the Windows Update Agent API that is built into Windows
    (Microsoft.Update.Session COM object). No extra modules.

    One step call: search software + driver updates that Windows would install automatically
    (BrowseOnly=0, i.e. not the "optional" ones), accept their licence terms, download,
    install, and search again (up to 3 rounds) because some updates only appear after others.
    If an update needs a restart, the step asks the engine for one and runs again afterwards,
    until nothing is left. The final check never forces a restart; it just recommends one.

    DayZero never changes Windows Update settings or pauses updates.
#>

Set-StrictMode -Version 2.0

$script:Criteria = @(
    @{ Kind = 'software'; Text = "IsInstalled=0 and IsHidden=0 and BrowseOnly=0 and Type='Software'" },
    @{ Kind = 'driver'; Text = "IsInstalled=0 and IsHidden=0 and BrowseOnly=0 and Type='Driver'" }
)
# OperationResultCode
$script:ResultCodes = @{ 0 = 'not started'; 1 = 'in progress'; 2 = 'succeeded'; 3 = 'succeeded with errors'; 4 = 'failed'; 5 = 'aborted' }
$script:KnownErrors = @{
    '0x8024402C' = 'No connection to Windows Update (proxy or DNS problem).'
    '0x80072EE2' = 'The connection to Windows Update timed out.'
    '0x80072EFD' = 'Could not reach Windows Update.'
    '0x8024001E' = 'Windows Update is shutting down; restart and retry.'
    '0x80240022' = 'All updates failed to install.'
    '0x80070070' = 'Not enough disk space.'
}

function Get-DzUpdateCriteria {
    [CmdletBinding()]
    param()
    return , $script:Criteria
}

function ConvertTo-DzHResult {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][int64]$Value)
    if ($Value -lt 0) { $Value += 4294967296 }
    return ('0x{0:X8}' -f $Value)
}

function Get-DzUpdateErrorText {
    <# Friendly text for a Windows Update error (exception message or HRESULT). #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Message)
    foreach ($k in $script:KnownErrors.Keys) { if ($Message -match $k) { return "$($script:KnownErrors[$k]) ($k)" } }
    return $Message
}

function Test-DzRebootPending {
    <# True when Windows is waiting for a restart to finish earlier updates. #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { return $true }
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { return $true }
    try { return [bool](New-Object -ComObject Microsoft.Update.SystemInfo).RebootRequired } catch { return $false }
}

function New-DzUpdateSession {
    [CmdletBinding()]
    param()
    $s = New-Object -ComObject Microsoft.Update.Session
    $s.ClientApplicationID = 'DayZero'
    return $s
}

function Find-DzUpdate {
    <# Updates Windows would install automatically, skipping any that need user input. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Session)
    $searcher = $Session.CreateUpdateSearcher()
    $list = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($c in $script:Criteria) {
        $result = $searcher.Search($c.Text)
        foreach ($u in @($result.Updates)) {
            $id = [string]$u.Identity.UpdateID
            if ($seen.ContainsKey($id)) { continue }
            $seen[$id] = $true
            if ($u.InstallationBehavior.CanRequestUserInput) { Write-DzLog -Level Warn -Message "Skipping (needs user input): $($u.Title)"; continue }
            $list.Add($u)
        }
    }
    return $list.ToArray()
}

function Install-DzUpdate {
    <# Downloads and installs a set of updates. Returns RebootRequired + one result per update. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Session, [Parameter(Mandatory = $true)][object[]]$Updates)
    $coll = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $Updates) {
        if (-not $u.EulaAccepted) { $u.AcceptEula() }
        [void]$coll.Add($u)
    }
    $downloader = $Session.CreateUpdateDownloader()
    $downloader.Updates = $coll
    [void]$downloader.Download()

    $ready = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $Updates) { if ($u.IsDownloaded) { [void]$ready.Add($u) } }
    $results = New-Object System.Collections.Generic.List[object]
    $reboot = $false
    if ($ready.Count -gt 0) {
        $installer = $Session.CreateUpdateInstaller()
        $installer.Updates = $ready
        $r = $installer.Install()
        $reboot = [bool]$r.RebootRequired
        for ($i = 0; $i -lt $ready.Count; $i++) {
            $ur = $r.GetUpdateResult($i)
            $results.Add([pscustomobject]@{ Title = [string]$ready.Item($i).Title; ResultCode = [int]$ur.ResultCode; HResult = (ConvertTo-DzHResult -Value ([int64]$ur.HResult)) })
        }
    }
    foreach ($u in $Updates) {
        if (-not $u.IsDownloaded) { $results.Add([pscustomobject]@{ Title = [string]$u.Title; ResultCode = 4; HResult = 'download failed' }) }
    }
    return [pscustomobject]@{ RebootRequired = $reboot; Results = $results.ToArray() }
}

function Invoke-DzWindowsUpdate {
    <# The Windows Update step body. Returns a step result. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context, [bool]$Final = $false)
    $say = { param($t) Write-DzLog -Message $t; if ($Context.Progress) { & $Context.Progress $t } }
    if (-not (Test-DzDryRun) -and (Test-DzRebootPending)) {
        if ($Final) {
            $Context.Flags['RestartRecommended'] = $true
            return (New-DzStepResult -Status Warn -Message 'Windows is waiting for a restart to finish updates. Restart when you are done.')
        }
        return (New-DzStepResult -Status Reboot -Message 'Earlier updates need a restart first.')
    }
    $installed = 0
    $failed = New-Object System.Collections.Generic.List[string]
    try {
        $session = New-DzUpdateSession
        for ($round = 1; $round -le 3; $round++) {
            & $say ("Searching for updates (round {0})... this can take several minutes." -f $round)
            $updates = @(Find-DzUpdate -Session $session)
            if ($updates.Count -eq 0) { break }
            $mb = 0
            foreach ($u in $updates) {
                try { $mb += [double]$u.MaxDownloadSize / 1MB } catch { Write-Verbose 'Unknown size.' }
                Write-DzLog -Message ("  found: {0}" -f $u.Title)
            }
            if (Test-DzDryRun) {
                return (New-DzStepResult -Status Done -Message ("[DRY-RUN] would install {0} update(s), about {1:N0} MB." -f $updates.Count, $mb))
            }
            & $say ("Downloading and installing {0} update(s), about {1:N0} MB..." -f $updates.Count, $mb)
            $r = Invoke-DzAction -Description ("Install {0} Windows update(s)" -f $updates.Count) -Action { Install-DzUpdate -Session $session -Updates $updates }
            foreach ($res in @($r.Results)) {
                $txt = if ($script:ResultCodes.ContainsKey([int]$res.ResultCode)) { $script:ResultCodes[[int]$res.ResultCode] } else { [string]$res.ResultCode }
                Write-DzLog -Level $(if ($res.ResultCode -in 2, 3) { 'Ok' } else { 'Warn' }) -Message ("  {0}: {1} {2}" -f $txt, $res.Title, $(if ($res.ResultCode -in 2, 3) { '' } else { $res.HResult }))
                if ($res.ResultCode -in 2, 3) { $installed++ } else { $failed.Add([string]$res.Title) }
            }
            if ($r.RebootRequired) {
                if ($Final) {
                    $Context.Flags['RestartRecommended'] = $true
                    return (New-DzStepResult -Status Warn -Message "Installed $installed update(s). Restart to finish.")
                }
                return (New-DzStepResult -Status Reboot -Message "Installed $installed update(s); a restart is needed to continue.")
            }
            if (@($r.Results | Where-Object { $_.ResultCode -in 2, 3 }).Count -eq 0) { break }   # nothing worked: don't loop
        }
    }
    catch {
        return (New-DzStepResult -Status Failed -Message (Get-DzUpdateErrorText -Message $_.Exception.Message))
    }
    if ($failed.Count -gt 0) {
        return (New-DzStepResult -Status Warn -Message ("Installed {0}; {1} failed: {2}. Windows Update will retry them on its own." -f $installed, $failed.Count, ($failed -join '; ')))
    }
    if ($installed -eq 0) { return (New-DzStepResult -Status Done -Message 'Windows is up to date.') }
    return (New-DzStepResult -Status Done -Message "Installed $installed update(s). Up to date.")
}

Export-ModuleMember -Function @('Get-DzUpdateCriteria', 'ConvertTo-DzHResult', 'Get-DzUpdateErrorText', 'Test-DzRebootPending', 'New-DzUpdateSession', 'Find-DzUpdate', 'Install-DzUpdate', 'Invoke-DzWindowsUpdate')
