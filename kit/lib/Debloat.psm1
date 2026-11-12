#Requires -Version 5.1
<#
    DayZero - removes preinstalled apps listed in config\debloat.json and the optional
    removals (OneDrive). Every removal is recorded in <kit>\backup\apps.json so
    'DayZero.cmd -Undo' can reinstall it.

    The keep-list below is enforced in code: the Store, Calculator, Photos, App Installer
    (winget), Windows Security and the app frameworks can never be removed by DayZero,
    whatever the JSON says.
#>

Set-StrictMode -Version 2.0

$script:HardKeep = @(
    'Microsoft.WindowsStore', 'Microsoft.StorePurchaseApp', 'Microsoft.WindowsCalculator', 'Microsoft.Windows.Photos',
    'Microsoft.DesktopAppInstaller', 'Microsoft.SecHealthUI', 'Microsoft.VCLibs*', 'Microsoft.UI.Xaml*', 'Microsoft.NET.*',
    'Microsoft.WindowsAppRuntime*', 'Microsoft.Services.Store.Engagement', 'Microsoft.AAD.BrokerPlugin', 'Microsoft.AccountsControl',
    'Microsoft.LockApp', 'Microsoft.Windows.*', 'MicrosoftWindows.*', 'windows.*', 'Microsoft.*Extension*', 'Microsoft.HEVCVideoExtension',
    'Microsoft.XboxIdentityProvider', 'Microsoft.Xbox.TCUI', 'Microsoft.WindowsTerminal', 'Microsoft.WindowsNotepad', 'Microsoft.Paint'
)
# Explicit exceptions to the Microsoft.Windows.* safety net: removable apps whose names start that way.
$script:KeepExceptions = @('Microsoft.Windows.DevHome')

function Get-DzKeepPattern {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowNull()][object]$DebloatConfig)
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($k in $script:HardKeep) { $list.Add($k) }
    foreach ($k in @(Get-DzProperty $DebloatConfig 'keep' @())) { if ($k) { $list.Add([string]$k) } }
    return , $list.ToArray()
}

function Test-DzKeptPackage {
    <#
        True when a package name (or a removal pattern) would touch something on the keep list.
        A pattern is refused if it matches a kept name, or a kept pattern matches it.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][string[]]$Keep)
    if ($script:KeepExceptions -contains $Name) { return $false }
    foreach ($k in $Keep) {
        if ($Name -like $k -or $k -like $Name) { return $true }
    }
    return $false
}

function Get-DzDebloatTarget {
    <# The packages of one profile ('light' or 'full'), keep-list violations removed (and reported). #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$DebloatConfig, [Parameter(Mandatory = $true)][string]$Profile)
    $keep = Get-DzKeepPattern -DebloatConfig $DebloatConfig
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($p in @(Get-DzProperty $DebloatConfig 'packages' @())) {
        if (@($p.profiles) -notcontains $Profile) { continue }
        if (Test-DzKeptPackage -Name ([string]$p.name) -Keep $keep) {
            Write-DzLog -Level Warn -Message ("debloat.json lists '{0}', which is on the keep list; not removing it." -f $p.name)
            continue
        }
        $out.Add($p)
    }
    return $out.ToArray()
}

function Remove-DzBloatware {
    <# Removes one debloat profile. Returns a step result. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context, [Parameter(Mandatory = $true)][string]$Profile)
    $cfg = $Context.Config.debloat
    if ($null -eq $cfg) { return (New-DzStepResult -Status Skipped -Message 'config\debloat.json is missing.') }
    $targets = Get-DzDebloatTarget -DebloatConfig $cfg -Profile $Profile
    if ($Context.Progress) { & $Context.Progress 'Looking for preinstalled apps...' }
    $provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)
    $removed = New-Object System.Collections.Generic.List[object]
    $failed = New-Object System.Collections.Generic.List[string]
    foreach ($t in $targets) {
        $name = [string]$t.name
        $user = @(Get-AppxPackage -Name $name -ErrorAction SilentlyContinue)
        $prov = @($provisioned | Where-Object { $_.DisplayName -like $name })
        if ($user.Count -eq 0 -and $prov.Count -eq 0) { continue }
        $names = @(@($user | ForEach-Object { $_.Name }) + @($prov | ForEach-Object { $_.DisplayName }) | Sort-Object -Unique)
        try {
            Invoke-DzAction -Description ("Remove {0} ({1})" -f $t.title, ($names -join ', ')) -Action {
                foreach ($u in $user) { Remove-AppxPackage -Package $u.PackageFullName -ErrorAction Stop }
                foreach ($p in $prov) { [void](Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction Stop) }
            } | Out-Null
            $removed.Add([ordered]@{ type = 'appx'; pattern = $name; packages = $names; title = [string]$t.title })
        }
        catch { $failed.Add(("{0}: {1}" -f $t.title, $_.Exception.Message)) }
    }
    if ($removed.Count -gt 0 -and -not (Test-DzDryRun)) {
        Add-DzBackupEntry -Name 'apps' -Entry ([ordered]@{ step = "debloat-$Profile"; removedAt = (Get-Date).ToString('o'); removed = $removed.ToArray() })
    }
    $titles = @($removed | ForEach-Object { $_.title })
    $msg = if ($titles.Count -gt 0) { ('{0}{1} app(s): {2}.' -f $(if (Test-DzDryRun) { '[DRY-RUN] would remove ' } else { 'Removed ' }), $titles.Count, ($titles -join ', ')) } else { 'Nothing to remove; the PC is already clean.' }
    if ($failed.Count -gt 0) { return (New-DzStepResult -Status Warn -Message ($msg + ' Could not remove: ' + ($failed -join '; '))) }
    return (New-DzStepResult -Status Done -Message $msg)
}

function Remove-DzOptionalItem {
    <# Optional removals from debloat.json (OneDrive). Returns a step result. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context, [Parameter(Mandatory = $true)][string]$Id)
    $item = @(Get-DzProperty $Context.Config.debloat 'optionalRemovals' @()) | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    if ($null -eq $item) { return (New-DzStepResult -Status Failed -Message "Unknown removal '$Id'.") }
    if ([string](Get-DzProperty $item 'type' '') -ne 'winget') { return (New-DzStepResult -Status Failed -Message "Unsupported removal type for '$Id'.") }
    $pkg = [string]$item.winget
    $winget = $Context.Flags['WingetPath']
    if (-not $winget) { $winget = Find-DzWinget }
    if (-not $winget) {
        if (Test-DzDryRun) { return (New-DzStepResult -Status Done -Message "[DRY-RUN] would uninstall $pkg.") }
        return (New-DzStepResult -Status Failed -Message 'winget is not available.')
    }
    if (-not (Test-DzWingetPackageInstalled -WingetPath $winget -Id $pkg)) {
        return (New-DzStepResult -Status Done -Message 'Not installed; nothing to remove.')
    }
    $uninstallArgs = @('uninstall', '--id', $pkg, '--exact', '--silent', '--accept-source-agreements', '--disable-interactivity')
    $r = Invoke-DzAction -Description ("Uninstall {0} ({1}) as the signed-in user" -f $item.title, $pkg) -Action {
        Invoke-DzAsUser -FilePath $winget -Arguments $uninstallArgs -TimeoutSec 900
    }
    if (Test-DzDryRun) { return (New-DzStepResult -Status Done -Message "[DRY-RUN] would uninstall $pkg.") }
    $info = Get-DzWingetExitInfo -Code $r.ExitCode
    if ($info.Outcome -in @('ok', 'notFound', 'rebootLater')) {
        Add-DzBackupEntry -Name 'apps' -Entry ([ordered]@{ step = "remove-$Id"; removedAt = (Get-Date).ToString('o'); removed = @([ordered]@{ type = 'winget'; id = $pkg; title = [string]$item.title }) })
        return (New-DzStepResult -Status Done -Message 'Uninstalled.')
    }
    return (New-DzStepResult -Status Failed -Message ("Uninstall failed: {0} [{1}]" -f $info.Text, $info.Hex))
}

function Restore-DzRemovedApp {
    <#
        Undo for removals: winget packages are reinstalled by id; Store apps by their exact
        Store name ('winget install --name <title> --source msstore --exact'). Returns
        @{ Restored; Failed; Messages }.
    #>
    [CmdletBinding()]
    param()
    $entries = @(Read-DzBackup -Name 'apps')
    $winget = Find-DzWinget
    $ok = 0; $bad = 0
    $messages = New-Object System.Collections.Generic.List[string]
    foreach ($e in $entries) {
        foreach ($r in @($e.removed)) {
            if (-not $winget) { $bad++; $messages.Add("$($r.title): winget not available, reinstall it from the Microsoft Store."); continue }
            if ($r.type -eq 'winget') { $wingetArgs = @('install', '--id', [string]$r.id, '--exact', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity') }
            else { $wingetArgs = @('install', '--name', ([string]$r.title -replace '\s*\(.*\)$', ''), '--exact', '--source', 'msstore', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity') }
            $res = Invoke-DzAction -Description ("Reinstall {0}" -f $r.title) -Action { Invoke-DzAsUser -FilePath $winget -Arguments $wingetArgs -TimeoutSec 1800 }
            if (Test-DzDryRun) { continue }
            $info = Get-DzWingetExitInfo -Code $res.ExitCode
            if ($info.Outcome -in @('ok', 'installed', 'rebootLater')) { $ok++ }
            else { $bad++; $messages.Add(("{0}: {1} Search the Microsoft Store for it." -f $r.title, $info.Text)) }
        }
    }
    if ($bad -eq 0 -and $entries.Count -gt 0 -and -not (Test-DzDryRun)) { Close-DzBackup -Name 'apps' }
    return [pscustomobject]@{ Restored = $ok; Failed = $bad; Messages = $messages.ToArray() }
}

Export-ModuleMember -Function @('Get-DzKeepPattern', 'Test-DzKeptPackage', 'Get-DzDebloatTarget', 'Remove-DzBloatware', 'Remove-DzOptionalItem', 'Restore-DzRemovedApp')
