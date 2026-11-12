#Requires -Version 5.1
<#
    DayZero - winget (Windows Package Manager).

    Getting winget ready on a fresh install (Initialize-DzWinget), in this order:
      1. already working?                       -> done
      2. re-register App Installer               (Add-AppxPackage -RegisterByFamilyName)
      3. wait for the Store to finish updating it (first minutes after sign-in)
      4. install the copy the builder put on the stick (DayZero\bundled\winget)
      5. download it from Microsoft's winget-cli GitHub release
    Installing a package (Install-DzWingetPackage):
      - already installed ('winget list')        -> done, nothing to do
      - id still exists ('winget show')          -> otherwise 'winget search' by name and log the hits
      - 'winget install --exact --silent ...'    -> exit codes mapped below
      - installers that refuse admin rights run as the signed-in user via a one-off scheduled task
#>

Set-StrictMode -Version 2.0

$script:AppInstallerFamily = 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe'
$script:WingetBundleUrl = 'https://github.com/microsoft/winget-cli/releases/latest/download/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'
$script:WingetDepsUrl = 'https://github.com/microsoft/winget-cli/releases/latest/download/DesktopAppInstaller_Dependencies.zip'
$script:CommonArgs = @('--accept-source-agreements', '--disable-interactivity')

# winget return codes (doc/windows/package-manager/winget/returnCodes.md in microsoft/winget-cli).
# Outcome: ok | installed | rebootLater | rebootNow | nonElevated | busy | notFound | failed
$script:ExitCodes = @{
    0             = @{ Name = 'OK'; Outcome = 'ok'; Text = 'Installed.' }
    3010          = @{ Name = 'ERROR_SUCCESS_REBOOT_REQUIRED'; Outcome = 'rebootLater'; Text = 'Installed; finishes after a restart.' }
    1641          = @{ Name = 'ERROR_SUCCESS_REBOOT_INITIATED'; Outcome = 'rebootNow'; Text = 'The installer wants to restart the PC.' }
    (-1978335212) = @{ Name = 'APPINSTALLER_CLI_ERROR_NO_APPLICATIONS_FOUND'; Outcome = 'notFound'; Text = 'No package found with that id.' }
    (-1978335189) = @{ Name = 'APPINSTALLER_CLI_ERROR_UPDATE_NOT_APPLICABLE'; Outcome = 'installed'; Text = 'Already installed and up to date.' }
    (-1978335146) = @{ Name = 'APPINSTALLER_CLI_ERROR_INSTALLER_PROHIBITS_ELEVATION'; Outcome = 'nonElevated'; Text = 'The installer refuses to run as administrator.' }
    (-1978335135) = @{ Name = 'APPINSTALLER_CLI_ERROR_PACKAGE_ALREADY_INSTALLED'; Outcome = 'installed'; Text = 'Already installed.' }
    (-1978334975) = @{ Name = 'APPINSTALLER_CLI_ERROR_INSTALL_PACKAGE_IN_USE'; Outcome = 'failed'; Text = 'The app is running. Close it and retry.' }
    (-1978334974) = @{ Name = 'APPINSTALLER_CLI_ERROR_INSTALL_INSTALL_IN_PROGRESS'; Outcome = 'busy'; Text = 'Another installation is in progress.' }
    (-1978334973) = @{ Name = 'APPINSTALLER_CLI_ERROR_INSTALL_FILE_IN_USE'; Outcome = 'failed'; Text = 'A file is in use. Close running apps and retry.' }
    (-1978334972) = @{ Name = 'APPINSTALLER_CLI_ERROR_INSTALL_MISSING_DEPENDENCY'; Outcome = 'failed'; Text = 'A dependency is missing.' }
    (-1978334971) = @{ Name = 'APPINSTALLER_CLI_ERROR_INSTALL_DISK_FULL'; Outcome = 'failed'; Text = 'The disk is full.' }
    (-1978334969) = @{ Name = 'APPINSTALLER_CLI_ERROR_INSTALL_NO_NETWORK'; Outcome = 'failed'; Text = 'No internet connection.' }
    (-1978334967) = @{ Name = 'APPINSTALLER_CLI_ERROR_INSTALL_REBOOT_REQUIRED_TO_FINISH'; Outcome = 'rebootLater'; Text = 'Installed; finishes after a restart.' }
    (-1978334966) = @{ Name = 'APPINSTALLER_CLI_ERROR_INSTALL_REBOOT_REQUIRED_FOR_INSTALL'; Outcome = 'rebootNow'; Text = 'Needs a restart before it can install.' }
    (-1978334965) = @{ Name = 'APPINSTALLER_CLI_ERROR_INSTALL_REBOOT_INITIATED'; Outcome = 'rebootNow'; Text = 'The installer is restarting the PC.' }
    (-1978334963) = @{ Name = 'APPINSTALLER_CLI_ERROR_INSTALL_ALREADY_INSTALLED'; Outcome = 'installed'; Text = 'Another version is already installed.' }
    (-1978334962) = @{ Name = 'APPINSTALLER_CLI_ERROR_INSTALL_DOWNGRADE'; Outcome = 'installed'; Text = 'A newer version is already installed.' }
    (-1978334961) = @{ Name = 'APPINSTALLER_CLI_ERROR_INSTALL_BLOCKED_BY_POLICY'; Outcome = 'failed'; Text = 'Blocked by a policy on this PC.' }
}

function Get-DzWingetExitInfo {
    <# Explains a winget / installer exit code. Accepts signed or unsigned (scheduled task) values. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int64]$Code)
    if ($Code -gt [int32]::MaxValue) { $Code = $Code - 4294967296 }
    $key = [int]$Code
    if ($script:ExitCodes.ContainsKey($key)) {
        $e = $script:ExitCodes[$key]
        return [pscustomobject]@{ Code = $key; Hex = ('0x{0:X8}' -f $key); Name = $e.Name; Outcome = $e.Outcome; Text = $e.Text }
    }
    return [pscustomobject]@{ Code = $key; Hex = ('0x{0:X8}' -f $key); Name = 'UNKNOWN'; Outcome = 'failed'; Text = ('Exit code {0} (0x{0:X8}).' -f $key) }
}

function ConvertTo-DzArgumentString {
    <# Quotes arguments the way Windows programs parse them (CommandLineToArgvW rules). #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyCollection()][string[]]$Arguments = @())
    $parts = foreach ($a in $Arguments) {
        if ($a -eq '') { '""' }
        elseif ($a -notmatch '[\s"]') { $a }
        else {
            $escaped = [regex]::Replace($a, '(\\*)"', { param($m) ($m.Groups[1].Value * 2) + '\"' })
            $escaped = [regex]::Replace($escaped, '(\\+)$', { param($m) $m.Groups[1].Value * 2 })
            '"' + $escaped + '"'
        }
    }
    return ($parts -join ' ')
}

function ConvertFrom-DzToolOutput {
    <# Splits tool output into readable lines, dropping progress bars and spinners. #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if (-not $Text) { return @() }
    $lines = foreach ($raw in ($Text -split "`r`n|`n|`r")) {
        $l = $raw.Trim()
        if (-not $l) { continue }
        if ($l -match '^[\s\-\\|/]+$') { continue }                       # spinner
        if ($l -match '[\u2580-\u259F]') { continue }                     # block-character progress bars
        if ($l -match '^\d+(\.\d+)?\s*(KB|MB|GB)\s*/\s*\d') { continue }  # "12.3 MB / 50 MB"
        if ($l -match '^\d{1,3}%$') { continue }
        $l
    }
    return @($lines)
}

function Invoke-DzProcess {
    <# Runs a program hidden, captures its output, enforces a timeout. Returns ExitCode, Output, TimedOut. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [AllowEmptyCollection()][string[]]$Arguments = @(),
        [int]$TimeoutSec = 3600
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = ConvertTo-DzArgumentString -Arguments $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $timedOut = -not $p.WaitForExit([Math]::Max(1, $TimeoutSec) * 1000)
    if ($timedOut) {
        try { $p.Kill() } catch { Write-Verbose 'Process already gone.' }
    }
    $p.WaitForExit()
    $text = [string]$outTask.Result + [Environment]::NewLine + [string]$errTask.Result
    $code = if ($timedOut) { -1 } else { $p.ExitCode }
    $p.Dispose()
    return [pscustomobject]@{ ExitCode = $code; Output = (ConvertFrom-DzToolOutput -Text $text); TimedOut = $timedOut }
}

function Find-DzWinget {
    <# Path to winget.exe, or $null. #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $cmd = Get-Command -Name 'winget.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    if ($env:LOCALAPPDATA) {
        $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
        if (Test-Path -LiteralPath $alias) { return $alias }
    }
    if ($env:ProgramFiles) {
        $direct = Get-ChildItem -Path (Join-Path $env:ProgramFiles 'WindowsApps') -Filter 'Microsoft.DesktopAppInstaller_*_8wekyb3d8bbwe' -Directory -ErrorAction SilentlyContinue |
            Sort-Object -Property Name -Descending | ForEach-Object { Join-Path $_.FullName 'winget.exe' } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if ($direct) { return $direct }
    }
    return $null
}

function Get-DzWingetVersion {
    <# 'v1.29.380' style string, or $null when winget does not run. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$WingetPath = (Find-DzWinget))
    if (-not $WingetPath) { return $null }
    try {
        $r = Invoke-DzProcess -FilePath $WingetPath -Arguments @('--version') -TimeoutSec 60
        $v = @($r.Output | Where-Object { $_ -match '^v?\d+\.\d+' }) | Select-Object -First 1
        if ($r.ExitCode -eq 0 -and $v) { return $v }
    }
    catch { Write-Verbose $_.Exception.Message }
    return $null
}

function Install-DzAppxBundle {
    <# Installs the App Installer bundle plus its dependency packages for this CPU. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$BundlePath,
        [AllowNull()][string]$DependencyFolder,
        [string]$Architecture = 'amd64'
    )
    $archFolder = if ($Architecture -eq 'arm64') { 'arm64' } else { 'x64' }
    $deps = @()
    if ($DependencyFolder -and (Test-Path -LiteralPath $DependencyFolder)) {
        $deps = @(Get-ChildItem -LiteralPath $DependencyFolder -Recurse -File -Include '*.appx', '*.msix' |
                Where-Object { $_.FullName -match ('[\\/]' + $archFolder + '[\\/]') -or $_.Name -match ('_' + $archFolder + '[._]') } |
                ForEach-Object { $_.FullName })
    }
    Invoke-DzAction -Description ("Install App Installer (winget) from {0}" -f $BundlePath) -Action {
        if ($deps.Count -gt 0) { Add-AppxPackage -Path $BundlePath -DependencyPath $deps -ForceApplicationShutdown -ErrorAction Stop }
        else { Add-AppxPackage -Path $BundlePath -ForceApplicationShutdown -ErrorAction Stop }
    }.GetNewClosure() | Out-Null
}

function Wait-DzWinget {
    param([int]$Seconds, [int]$IntervalSec = 10)
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        $v = Get-DzWingetVersion
        if ($v) { return $v }
        Start-Sleep -Seconds $IntervalSec
    } while ((Get-Date) -lt $deadline)
    return $null
}

function Initialize-DzWinget {
    <#
        Makes winget usable. Returns @{ Ok; Version; Path; Message }. Sets Context.Flags.WingetPath.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $say = { param($t) Write-DzLog -Message $t; if ($Context.Progress) { & $Context.Progress $t } }
    $finish = {
        param([string]$Version, [string]$How)
        $path = Find-DzWinget
        $Context.Flags['WingetPath'] = $path
        Write-DzLog -Level Ok -Message "winget $Version ready ($How)."
        if (-not (Test-DzDryRun)) {
            # Accept the source agreements once and refresh the package index.
            [void](Invoke-DzProcess -FilePath $path -Arguments @('source', 'update') -TimeoutSec 300)
        }
        return [pscustomobject]@{ Ok = $true; Version = $Version; Path = $path; Message = "winget $Version ($How)" }
    }

    $v = Get-DzWingetVersion
    if ($v) { return (& $finish $v 'already installed') }

    & $say 'winget is not ready yet: re-registering App Installer...'
    try {
        Invoke-DzAction -Description "Re-register App Installer ($script:AppInstallerFamily)" -Action {
            Add-AppxPackage -RegisterByFamilyName -MainPackage $script:AppInstallerFamily -ErrorAction Stop
        } | Out-Null
    }
    catch { Write-DzLog -Level Warn -Message ('Re-register failed: ' + $_.Exception.Message) }
    if (Test-DzDryRun) {
        $Context.Flags['WingetDry'] = $true
        return [pscustomobject]@{ Ok = $true; Version = ''; Path = $null; Message = '[DRY-RUN] winget is not installed here; would register or install App Installer.' }
    }
    $v = Wait-DzWinget -Seconds 30
    if ($v) { return (& $finish $v 're-registered') }

    & $say 'Waiting for the Microsoft Store to finish setting up App Installer (up to 3 minutes)...'
    $v = Wait-DzWinget -Seconds 180 -IntervalSec 15
    if ($v) { return (& $finish $v 'after waiting for the Store') }

    $arch = if ($Context.System) { [string]$Context.System.Architecture } else { 'amd64' }
    $bundled = [System.IO.Path]::Combine($Context.KitRoot, 'bundled', 'winget')
    $bundle = Join-Path $bundled 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'
    if (Test-Path -LiteralPath $bundle) {
        & $say 'Installing the App Installer copy from the USB stick...'
        try {
            Install-DzAppxBundle -BundlePath $bundle -DependencyFolder (Join-Path $bundled 'deps') -Architecture $arch
            $v = Wait-DzWinget -Seconds 60 -IntervalSec 5
            if ($v) { return (& $finish $v 'from the USB stick') }
        }
        catch { Write-DzLog -Level Warn -Message ('Bundled App Installer failed: ' + $_.Exception.Message) }
    }

    & $say 'Downloading App Installer from Microsoft (winget-cli on GitHub)...'
    try {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) 'DayZero-winget'
        $b = Save-DzDownload -Url $script:WingetBundleUrl -Path (Join-Path $tmp 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle')
        $z = Save-DzDownload -Url $script:WingetDepsUrl -Path (Join-Path $tmp 'DesktopAppInstaller_Dependencies.zip')
        $depsDir = Join-Path $tmp 'deps'
        if (Test-Path -LiteralPath $depsDir) { Remove-Item -LiteralPath $depsDir -Recurse -Force }
        Expand-Archive -LiteralPath $z -DestinationPath $depsDir -Force
        Install-DzAppxBundle -BundlePath $b -DependencyFolder $depsDir -Architecture $arch
        $v = Wait-DzWinget -Seconds 60 -IntervalSec 5
        if ($v) { return (& $finish $v 'downloaded from Microsoft') }
    }
    catch { Write-DzLog -Level Warn -Message ('Download fallback failed: ' + $_.Exception.Message) }

    return [pscustomobject]@{ Ok = $false; Version = ''; Path = $null; Message = 'winget could not be set up. Open the Microsoft Store, update "App Installer", then press Retry failed steps.' }
}

function Invoke-DzAsUser {
    <#
        Runs a program as the signed-in user WITHOUT admin rights (some installers refuse to
        run elevated) through a one-off scheduled task, waits for it, returns ExitCode + Output.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [AllowEmptyCollection()][string[]]$Arguments = @(),
        [int]$TimeoutSec = 3600
    )
    $id = 'DayZero-AsUser-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $work = Join-Path ([System.IO.Path]::GetTempPath()) $id
    [void](New-Item -ItemType Directory -Path $work -Force)
    $outFile = Join-Path $work 'output.txt'
    $q = { param($s) "'" + ($s -replace "'", "''") + "'" }
    $argList = ($Arguments | ForEach-Object { & $q $_ }) -join ', '
    $script = @(
        '$ErrorActionPreference = ''Continue''',
        ('$o = & ' + (& $q $FilePath) + ' @(' + $argList + ') 2>&1 | Out-String'),
        ('Set-Content -LiteralPath ' + (& $q $outFile) + ' -Value $o -Encoding UTF8'),
        'exit $LASTEXITCODE'
    ) -join "`r`n"
    $scriptFile = Join-Path $work 'run.ps1'
    # UTF-8 with BOM so Windows PowerShell 5.1 reads non-ASCII paths correctly.
    [System.IO.File]::WriteAllText($scriptFile, $script, (New-Object System.Text.UTF8Encoding($true)))

    $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action = New-ScheduledTaskAction -Execute $ps -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $scriptFile)
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::FromSeconds($TimeoutSec + 60))
    [void](Register-ScheduledTask -TaskName $id -TaskPath '\DayZero\' -Action $action -Principal $principal -Settings $settings -Force)
    try {
        $started = Get-Date
        Start-ScheduledTask -TaskName $id -TaskPath '\DayZero\'
        $deadline = $started.AddSeconds($TimeoutSec)
        $code = $null
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 2
            $info = Get-ScheduledTaskInfo -TaskName $id -TaskPath '\DayZero\'
            $state = (Get-ScheduledTask -TaskName $id -TaskPath '\DayZero\').State
            $last = [int64]$info.LastTaskResult
            # 267009 = still running, 267011 = has not run yet
            if ([string]$state -ne 'Running' -and $last -ne 267009 -and $last -ne 267011 -and $info.LastRunTime -ge $started.AddSeconds(-5)) { $code = $last; break }
        }
        if ($null -eq $code) {
            Stop-ScheduledTask -TaskName $id -TaskPath '\DayZero\' -ErrorAction SilentlyContinue
            return [pscustomobject]@{ ExitCode = -1; Output = @('Timed out.'); TimedOut = $true }
        }
        if ($code -gt [int32]::MaxValue) { $code = $code - 4294967296 }
        $text = if (Test-Path -LiteralPath $outFile) { [System.IO.File]::ReadAllText($outFile) } else { '' }
        return [pscustomobject]@{ ExitCode = [int]$code; Output = (ConvertFrom-DzToolOutput -Text $text); TimedOut = $false }
    }
    finally {
        Unregister-ScheduledTask -TaskName $id -TaskPath '\DayZero\' -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-DzWingetPackageInstalled {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][string]$WingetPath, [Parameter(Mandatory = $true)][string]$Id, [string]$Source = 'winget')
    $r = Invoke-DzProcess -FilePath $WingetPath -Arguments (@('list', '--id', $Id, '--exact', '--source', $Source) + $script:CommonArgs) -TimeoutSec 180
    return ($r.ExitCode -eq 0 -and (@($r.Output | Where-Object { $_ -match [regex]::Escape($Id) }).Count -gt 0))
}

function Test-DzWingetPackageExists {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][string]$WingetPath, [Parameter(Mandatory = $true)][string]$Id, [string]$Source = 'winget')
    $r = Invoke-DzProcess -FilePath $WingetPath -Arguments (@('show', '--id', $Id, '--exact', '--source', $Source) + $script:CommonArgs) -TimeoutSec 180
    return ($r.ExitCode -eq 0)
}

function Search-DzWingetPackage {
    <# 'winget search' by name; returns the result table lines (header included) for the log. #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory = $true)][string]$WingetPath, [Parameter(Mandatory = $true)][string]$Name, [string]$Source = 'winget')
    $r = Invoke-DzProcess -FilePath $WingetPath -Arguments (@('search', '--name', $Name, '--source', $Source) + $script:CommonArgs) -TimeoutSec 180
    return , @($r.Output | Select-Object -First 8)
}

function Install-DzWingetPackage {
    <#
        Installs one package and returns a step result. Read-only checks run even in dry-run
        mode (so a dry run also proves the ids are right); only the install itself is skipped.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter(Mandatory = $true)][string]$Id,
        [string]$Name = '',
        [string]$Source = 'winget',
        [bool]$Elevated = $true,
        [string]$Scope = ''
    )
    if (-not $Name) { $Name = $Id }
    $winget = $Context.Flags['WingetPath']
    if (-not $winget) { $winget = Find-DzWinget }
    if (-not $winget) {
        if (Test-DzDryRun) { return (New-DzStepResult -Status Done -Message "[DRY-RUN] would install $Name ($Id) with winget.") }
        return (New-DzStepResult -Status Failed -Message 'winget is not available.')
    }

    if (Test-DzWingetPackageInstalled -WingetPath $winget -Id $Id -Source $Source) {
        return (New-DzStepResult -Status Done -Message 'Already installed.')
    }
    if (-not (Test-DzWingetPackageExists -WingetPath $winget -Id $Id -Source $Source)) {
        $hits = Search-DzWingetPackage -WingetPath $winget -Name $Name -Source $Source
        foreach ($h in $hits) { Write-DzLog -Level Warn -Message "  search '$Name': $h" }
        return (New-DzStepResult -Status Failed -Message ("Package id '{0}' was not found in {1}. 'winget search' results are in the log; fix the id in config\apps.json." -f $Id, $Source))
    }

    $installArgs = @('install', '--id', $Id, '--exact', '--source', $Source, '--silent', '--accept-package-agreements') + $script:CommonArgs
    if ($Scope) { $installArgs += @('--scope', $Scope) }
    if ($Context.Progress) { & $Context.Progress "Downloading and installing $Name..." }

    $run = {
        param([bool]$AsAdmin)
        if ($AsAdmin) { return (Invoke-DzProcess -FilePath $winget -Arguments $installArgs -TimeoutSec 3600) }
        $userWinget = $winget
        if ($env:LOCALAPPDATA) {
            $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
            if (Test-Path -LiteralPath $alias) { $userWinget = $alias }
        }
        return (Invoke-DzAsUser -FilePath $userWinget -Arguments $installArgs -TimeoutSec 3600)
    }
    $how = if ($Elevated) { 'as administrator' } else { 'as the signed-in user (no admin rights)' }
    $result = Invoke-DzAction -Description ("Install {0} ({1}) {2}" -f $Name, $Id, $how) -Action { & $run $Elevated }.GetNewClosure()
    if (Test-DzDryRun) { return (New-DzStepResult -Status Done -Message "[DRY-RUN] id checked; would install $Name.") }

    for ($attempt = 1; $attempt -le 4; $attempt++) {
        $info = Get-DzWingetExitInfo -Code $result.ExitCode
        foreach ($line in @($result.Output | Select-Object -Last 6)) { Write-DzLog -Message "  winget: $line" }
        switch ($info.Outcome) {
            'ok' { return (New-DzStepResult -Status Done -Message $info.Text) }
            'installed' { return (New-DzStepResult -Status Done -Message $info.Text) }
            'rebootLater' { $Context.Flags['RestartRecommended'] = $true; return (New-DzStepResult -Status Warn -Message $info.Text) }
            'rebootNow' { return (New-DzStepResult -Status Reboot -Message $info.Text) }
            'nonElevated' {
                if (-not $Elevated) { return (New-DzStepResult -Status Failed -Message $info.Text) }
                Write-DzLog -Message "$Name refuses admin rights; installing it as the signed-in user instead."
                $Elevated = $false
                $result = & $run $false
            }
            'busy' {
                Write-DzLog -Message 'Another installation is running; waiting 30 seconds.'
                Start-Sleep -Seconds 30
                $result = & $run $Elevated
            }
            default {
                $detail = if ($result.TimedOut) { 'Timed out after 60 minutes.' } else { "$($info.Text) [$($info.Hex)]" }
                return (New-DzStepResult -Status Failed -Message $detail)
            }
        }
    }
    return (New-DzStepResult -Status Failed -Message 'Gave up after several attempts (see the log).')
}

Export-ModuleMember -Function @(
    'Get-DzWingetExitInfo', 'ConvertTo-DzArgumentString', 'ConvertFrom-DzToolOutput', 'Invoke-DzProcess',
    'Find-DzWinget', 'Get-DzWingetVersion', 'Install-DzAppxBundle', 'Initialize-DzWinget', 'Invoke-DzAsUser',
    'Test-DzWingetPackageInstalled', 'Test-DzWingetPackageExists', 'Search-DzWingetPackage', 'Install-DzWingetPackage'
)
