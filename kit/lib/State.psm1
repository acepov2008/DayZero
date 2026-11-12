#Requires -Version 5.1
<#
    DayZero - the wizard's progress file (C:\DayZero\state.json).

    It records the chosen mode and options, the planned steps and each step's status, so
    the wizard can stop at any point (restart, crash, closed window) and continue where
    it left off. Steps that are already done are never run again.

    Step status values:
      pending   not started yet
      running   started; if the wizard finds this after a restart, the step is re-run
      done      finished
      warn      finished, but with something worth reading
      failed    did not work (can be retried from the summary screen)
      skipped   not needed on this PC
      reboot    needs a restart, then runs again (e.g. Windows Update)
#>

Set-StrictMode -Version 2.0

$script:FinalStatuses = @('done', 'warn', 'skipped')

function ConvertTo-DzStateObject {
    param([Parameter(Mandatory = $true)][object]$Data)
    return ($Data | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
}

function New-DzState {
    <# Creates a fresh state for a planned run (not yet saved). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Mode,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Steps,
        [System.Collections.IDictionary]$Options = @{},
        [AllowNull()][object]$System = $null,
        [AllowNull()][string]$BuildId = $null,
        [bool]$DryRun = $false
    )
    $now = (Get-Date).ToString('o')
    $stepList = New-Object System.Collections.Generic.List[object]
    foreach ($s in $Steps) {
        $stepList.Add([ordered]@{
                id         = [string]$s.id
                title      = [string]$s.title
                type       = [string]$s.type
                group      = [string]$s.group
                args       = $(if ($s.Contains('args') -and $null -ne $s.args) { $s.args } else { @{} })
                requires   = @($(if ($s.Contains('requires')) { $s.requires } else { @() }))
                status     = 'pending'
                attempts   = 0
                message    = ''
                startedAt  = $null
                finishedAt = $null
            })
    }
    $data = [ordered]@{
        schemaVersion = 1
        buildId       = $BuildId
        phase         = 'running'
        mode          = $Mode
        options       = $Options
        dryRun        = $DryRun
        createdAt     = $now
        updatedAt     = $now
        rebootCount   = 0
        system        = $System
        steps         = $stepList.ToArray()
    }
    $state = ConvertTo-DzStateObject -Data $data
    # ConvertFrom-Json turns a one-step list into a single object on some versions; keep it a list.
    $state.steps = @($state.steps | Where-Object { $null -ne $_ })
    return $state
}

function Save-DzState {
    <# Writes the state atomically (temp file, then replace) so a power cut can't leave half a file. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $State.updatedAt = (Get-Date).ToString('o')
    $json = $State | ConvertTo-Json -Depth 12
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $Path) {
        # [NullString]::Value: PowerShell would otherwise pass "" instead of null for the backup path.
        [System.IO.File]::Replace($tmp, $Path, [NullString]::Value)
    }
    else {
        [System.IO.File]::Move($tmp, $Path)
    }
}

function Read-DzState {
    <# Returns the saved state, or $null if there is none. A damaged file is set aside. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        $state = $text | ConvertFrom-Json
        if ($null -eq $state -or -not $state.PSObject.Properties['steps']) { throw 'no steps' }
        $state.steps = @($state.steps | Where-Object { $null -ne $_ })
        return $state
    }
    catch {
        $bad = "$Path.damaged-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
        try { Move-Item -LiteralPath $Path -Destination $bad -Force } catch { Write-Verbose 'Could not move the damaged state file.' }
        return $null
    }
}

function Set-DzStepStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][int]$Index,
        [Parameter(Mandatory = $true)][ValidateSet('pending', 'running', 'done', 'warn', 'failed', 'skipped', 'reboot')][string]$Status,
        [AllowEmptyString()][string]$Message = ''
    )
    $step = $State.steps[$Index]
    $step.status = $Status
    $step.message = $Message
    $now = (Get-Date).ToString('o')
    if ($Status -eq 'running') { $step.startedAt = $now; $step.attempts = [int]$step.attempts + 1 }
    elseif ($Status -ne 'pending') { $step.finishedAt = $now }
}

function Test-DzStepFinal {
    <# True when a step needs no more work (done, warn or skipped). #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][object]$Step)
    return ($script:FinalStatuses -contains [string]$Step.status)
}

function Reset-DzFailedStep {
    <# Marks failed steps as pending again so the next run retries them. Returns how many. #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory = $true)][object]$State)
    $n = 0
    foreach ($s in $State.steps) {
        if ($s.status -eq 'failed') {
            $s.status = 'pending'; $s.attempts = 0; $s.message = ''
            $n++
        }
    }
    if ($n -gt 0) { $State.phase = 'running' }
    return $n
}

function Get-DzStateCount {
    <# Counts steps per status: @{ done=..; warn=..; failed=..; ... ; total=.. }. #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory = $true)][object]$State)
    $c = @{ pending = 0; running = 0; done = 0; warn = 0; failed = 0; skipped = 0; reboot = 0; total = 0 }
    foreach ($s in $State.steps) {
        $c.total++
        $k = [string]$s.status
        if ($c.ContainsKey($k)) { $c[$k]++ }
    }
    return $c
}

Export-ModuleMember -Function @('New-DzState', 'Save-DzState', 'Read-DzState', 'Set-DzStepStatus', 'Test-DzStepFinal', 'Reset-DzFailedStep', 'Get-DzStateCount')
