#Requires -Version 5.1
<#
    DayZero - basic steps: "Check this PC" and "Connect to the internet", plus the
    'internet' requirement used by every step that downloads something.
#>

Set-StrictMode -Version 2.0

function Invoke-DzStepPreflight {
    <# Read-only: logs what this PC is and warns about things worth fixing first. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $sys = $Context.System
    if ($null -eq $sys) { $sys = Get-DzSystemInfo; $Context.System = $sys }
    $summary = Format-DzSystemSummary -System $sys
    Write-DzLog -Message "This PC: $summary"
    if (@($sys.GpuNames).Count -gt 0) { Write-DzLog -Message ("Graphics: " + (@($sys.GpuNames) -join ', ')) }
    if ($null -ne $Context.State) {
        try { $Context.State.system = $sys } catch { Write-Verbose 'State has no system field.' }
    }

    $warnings = New-Object System.Collections.Generic.List[string]
    if ($null -ne $sys.FreeDiskGB -and [double]$sys.FreeDiskGB -lt 20) {
        $warnings.Add(("Only {0} GB free on {1}; installs may fail." -f $sys.FreeDiskGB, $env:SystemDrive))
    }
    if ($sys.Architecture -eq 'arm64') { $warnings.Add('ARM64 PC: some apps and drivers are x64-only and will be skipped or fail.') }
    if ($sys.IsLaptop) {
        try {
            $onBattery = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop | Where-Object { $_.BatteryStatus -eq 1 }).Count -gt 0
            if ($onBattery) { $warnings.Add('Running on battery: plug in the charger, updates can take a while.') }
        }
        catch { Write-Verbose 'Battery status unavailable.' }
    }
    if ($warnings.Count -gt 0) { return (New-DzStepResult -Status Warn -Message ($summary + '. ' + ($warnings -join ' '))) }
    return (New-DzStepResult -Status Done -Message $summary)
}

function Invoke-DzStepNetwork {
    <# Waits for a working internet connection (default up to 10 minutes). Read-only. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    $timeout = [int](Get-DzStepArg -Context $Context -Name 'timeoutSec' -Default 600)
    $interval = [int](Get-DzStepArg -Context $Context -Name 'intervalSec' -Default 10)
    $deadline = (Get-Date).AddSeconds($timeout)
    $told = $false
    while ($true) {
        if (Test-DzInternet) {
            $Context.Cache['internetOk'] = $true
            $Context.Cache['internetCheckedAt'] = Get-Date
            return (New-DzStepResult -Status Done -Message 'Online.')
        }
        if ((Get-Date) -ge $deadline) {
            $Context.Cache['internetOk'] = $false
            $Context.Cache['internetCheckedAt'] = Get-Date
            return (New-DzStepResult -Status Failed -Message ("No internet after {0} minutes. Plug in a network cable or pick a Wi-Fi network from the taskbar, then press 'Retry failed steps'. Steps that need the internet are waiting for this." -f [math]::Round($timeout / 60, 1)))
        }
        if (-not $told) {
            $told = $true
            Write-DzLog -Level Warn -Message 'Waiting for an internet connection...'
            if ($Context.Progress) { & $Context.Progress 'Waiting for internet: plug in a cable or join Wi-Fi from the taskbar.' }
        }
        Start-Sleep -Seconds $interval
    }
}

Register-DzStepType -Type 'preflight' -Command 'Invoke-DzStepPreflight'
Register-DzStepType -Type 'network' -Command 'Invoke-DzStepNetwork'

Register-DzRequirement -Name 'internet' -Check {
    param($Context)
    $cache = $Context.Cache
    $fresh = $cache.ContainsKey('internetCheckedAt') -and (((Get-Date) - $cache['internetCheckedAt']).TotalSeconds -lt 60)
    if (-not $fresh) {
        $cache['internetOk'] = [bool](Test-DzInternet)
        $cache['internetCheckedAt'] = Get-Date
    }
    if ($cache['internetOk']) { return $null }
    return 'No internet connection. Connect, then press Retry failed steps.'
}

Export-ModuleMember -Function @('Invoke-DzStepPreflight', 'Invoke-DzStepNetwork')
