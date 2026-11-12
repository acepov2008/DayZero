#Requires -Version 5.1
<#
    DayZero - the step engine.

    * Step types are registered by the step modules (Register-DzStepType). A plan is an
      ordered list of steps; each step has a type, arguments and optional requirements
      ('internet', 'winget', 'restorePoint', ...).
    * Invoke-DzRun works through the plan in order, saving state.json after every change,
      so it can resume after a restart. It never re-runs a finished step.
    * Results: Done, Warn, Failed, Skipped, Reboot. "Reboot" means: restart, then run this
      step again (Windows Update keeps going until nothing is left).
    * The GUI runs Invoke-DzRun in a background runspace (Start-DzRunAsync) and receives
      events through a thread-safe queue, so the window never freezes.
#>

Set-StrictMode -Version 2.0

$script:StepTypes = @{}
$script:Requirements = @{}

function Register-DzStepType {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Type,
        [Parameter(Mandatory = $true)][string]$Command
    )
    $script:StepTypes[$Type] = $Command
}

function Test-DzStepType {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][string]$Type)
    return $script:StepTypes.ContainsKey($Type)
}

function Get-DzStepType {
    [CmdletBinding()]
    param()
    return @($script:StepTypes.Keys)
}

function Register-DzRequirement {
    <#
        A requirement check gets the run context and returns $null when satisfied, or a
        short explanation shown on the failed step (e.g. "No internet connection").
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Check
    )
    $script:Requirements[$Name] = $Check
}

function New-DzStepResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Done', 'Warn', 'Failed', 'Skipped', 'Reboot')][string]$Status,
        [AllowEmptyString()][string]$Message = ''
    )
    return [pscustomobject]@{ PSTypeName = 'DayZero.StepResult'; Status = $Status; Message = $Message }
}

function New-DzContext {
    <# Everything a step gets to work with. Flags/Cache are shared by all steps of one run. #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()][object]$Settings,
        [AllowNull()][object]$State,
        [AllowNull()][object]$System,
        [AllowNull()][hashtable]$Config,
        [AllowNull()][string]$KitRoot,
        [bool]$DryRun = $false
    )
    return @{
        Settings = $Settings
        State    = $State
        System   = $System
        Config   = $Config
        KitRoot  = $KitRoot
        DryRun   = $DryRun
        Step     = $null
        Flags    = @{}
        Cache    = @{}
        Progress = $null    # scriptblock(text) set by Invoke-DzRun: shows sub-progress on the step
    }
}

function Get-DzStepArg {
    <# Reads an argument of the current step (works for JSON objects and hashtables). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$Default = $null
    )
    $a = $Context.Step.args
    if ($null -eq $a) { return $Default }
    if ($a -is [System.Collections.IDictionary]) { if ($a.Contains($Name)) { return $a[$Name] } else { return $Default } }
    $p = $a.PSObject.Properties[$Name]
    if ($null -eq $p) { return $Default }
    return $p.Value
}

function Invoke-DzStepEntry {
    <# Runs one step and always returns a step result (exceptions become Failed). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Step,
        [Parameter(Mandatory = $true)][hashtable]$Context
    )
    $command = $null
    if ($script:StepTypes.ContainsKey([string]$Step.type)) { $command = $script:StepTypes[[string]$Step.type] }
    if (-not $command) { return (New-DzStepResult -Status Skipped -Message 'Not available in this DayZero version.') }

    foreach ($req in @($Step.requires)) {
        if (-not $req) { continue }
        if ($script:Requirements.ContainsKey([string]$req)) {
            $problem = & $script:Requirements[[string]$req] $Context
            if ($problem) { return (New-DzStepResult -Status Failed -Message ([string]$problem)) }
        }
    }

    $Context.Step = $Step
    try {
        $output = @(& $command -Context $Context)
        # Steps may accidentally write other objects; the last step result wins.
        $result = $output | Where-Object { $null -ne $_ -and $_.PSObject.Properties['Status'] -and $_.PSObject.Properties['Message'] } | Select-Object -Last 1
        if ($null -eq $result) { return (New-DzStepResult -Status Done) }
        return $result
    }
    catch {
        return (New-DzStepResult -Status Failed -Message $_.Exception.Message)
    }
    finally {
        $Context.Step = $null
    }
}

function Invoke-DzRun {
    <#
    .SYNOPSIS
        Runs every unfinished step of the plan in order.
    .PARAMETER Sink
        Called with an event hashtable: @{ type='step'|'progress'|'reboot'|'finished'|'detail'; ... }.
    .PARAMETER ShouldStop
        Returns $true to stop before the next step (state stays resumable).
    .OUTPUTS
        'finished', 'reboot' or 'stopped'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [scriptblock]$Sink = { param($e) Write-Verbose ($e | Out-String) },
        [scriptblock]$ShouldStop = { $false },
        [int]$MaxReboots = 6,
        [int]$MaxAttempts = 3
    )
    $Context.State = $State
    $State.phase = 'running'
    Save-DzState -State $State -Path $StatePath
    $steps = @($State.steps)
    $total = $steps.Count

    $emitStep = {
        param([int]$i)
        $s = $steps[$i]
        & $Sink @{ type = 'step'; index = $i; id = [string]$s.id; title = [string]$s.title; status = [string]$s.status; message = [string]$s.message }
        $finished = @($steps | Where-Object { Test-DzStepFinal -Step $_ }).Count
        & $Sink @{ type = 'progress'; done = $finished; total = $total; current = [string]$s.title }
    }

    for ($i = 0; $i -lt $total; $i++) {
        $step = $steps[$i]
        if (Test-DzStepFinal -Step $step) { continue }
        if ($step.status -eq 'failed') { continue }

        if ($step.status -eq 'running' -and [int]$step.attempts -ge $MaxAttempts) {
            Set-DzStepStatus -State $State -Index $i -Status failed -Message "Stopped after $MaxAttempts attempts: the PC may have restarted or crashed during this step."
            Save-DzState -State $State -Path $StatePath
            & $emitStep $i
            continue
        }
        if (& $ShouldStop) {
            Write-DzLog -Level Warn -Message 'Stop requested: pausing before the next step.'
            Save-DzState -State $State -Path $StatePath
            return 'stopped'
        }

        Set-DzStepStatus -State $State -Index $i -Status running
        Save-DzState -State $State -Path $StatePath
        & $emitStep $i
        Write-DzLog -Level Step -Message ("[{0}/{1}] {2}" -f ($i + 1), $total, $step.title)

        $index = $i
        $Context.Progress = { param([string]$Text) & $Sink @{ type = 'detail'; index = $index; message = $Text } }.GetNewClosure()
        $result = Invoke-DzStepEntry -Step $step -Context $Context
        $Context.Progress = $null

        $status = ([string]$result.Status).ToLowerInvariant()
        $message = [string]$result.Message
        if ($status -eq 'reboot') {
            if ($Context.DryRun) {
                $status = 'done'
                $message = ('[DRY-RUN] would restart and run this step again. ' + $message).Trim()
            }
            elseif ([int]$State.rebootCount -ge $MaxReboots) {
                $status = 'failed'
                $message = "Needed another restart, but DayZero already restarted $MaxReboots times. Restart yourself, then retry. $message".Trim()
            }
            else {
                Set-DzStepStatus -State $State -Index $i -Status reboot -Message $message
                $State.rebootCount = [int]$State.rebootCount + 1
                $State.phase = 'reboot'
                Save-DzState -State $State -Path $StatePath
                & $emitStep $i
                Write-DzLog -Level Warn -Message ("Restart needed: {0} {1}" -f $step.title, $message)
                & $Sink @{ type = 'reboot'; index = $i; reason = ("{0}: {1}" -f $step.title, $message) }
                return 'reboot'
            }
        }
        Set-DzStepStatus -State $State -Index $i -Status $status -Message $message
        Save-DzState -State $State -Path $StatePath
        & $emitStep $i
        $level = switch ($status) { 'failed' { 'Error' } 'warn' { 'Warn' } default { 'Ok' } }
        Write-DzLog -Level $level -Message ("{0}: {1} {2}" -f $step.title, $status.ToUpperInvariant(), $message)
    }

    if ($Context.Flags['RestartRecommended']) {
        if ($State.PSObject.Properties['restartRecommended']) { $State.restartRecommended = $true }
        else { $State | Add-Member -NotePropertyName restartRecommended -NotePropertyValue $true }
    }
    $State.phase = 'summary'
    Save-DzState -State $State -Path $StatePath
    & $Sink @{ type = 'finished' }
    return 'finished'
}

# ---------------------------------------------------------------------------------------
# Background runspace (used by the GUI)
# ---------------------------------------------------------------------------------------

$script:RunnerScript = {
    param([string]$KitRoot, [string]$StatePath, [bool]$DryRun, [object]$Sync)
    $ErrorActionPreference = 'Stop'
    try {
        $libDir = [System.IO.Path]::Combine($KitRoot, 'lib')
        foreach ($m in (& ([System.IO.Path]::Combine($libDir, 'Modules.ps1')))) {
            Import-Module ([System.IO.Path]::Combine($libDir, $m)) -Force -DisableNameChecking
        }
        Set-DzKitRoot -Path $KitRoot
        $settings = Get-DzSettings
        Set-DzDryRun -Enabled $DryRun
        [void](Initialize-DzLog -Name 'engine' -BuildId $settings.buildId)
        Add-DzLogListener -Listener { param($level, $line) $Sync.Queue.Enqueue(@{ type = 'log'; level = $level; line = $line }) }.GetNewClosure()

        $state = Read-DzState -Path $StatePath
        if ($null -eq $state) { throw "No state file at $StatePath." }
        $config = Get-DzConfig -KitRoot $KitRoot
        $system = $null
        if ($Sync.ContainsKey('System') -and $null -ne $Sync.System) { $system = $Sync.System }
        elseif (Get-Command Get-DzSystemInfo -ErrorAction SilentlyContinue) { $system = Get-DzSystemInfo }
        $context = New-DzContext -Settings $settings -State $state -System $system -Config $config -KitRoot $KitRoot -DryRun $DryRun

        $sink = { param($e) $Sync.Queue.Enqueue($e) }.GetNewClosure()
        $stop = { [bool]$Sync.Cancel }.GetNewClosure()
        $outcome = Invoke-DzRun -State $state -StatePath $StatePath -Context $context -Sink $sink -ShouldStop $stop
        $Sync.Queue.Enqueue(@{ type = 'done'; outcome = $outcome })
    }
    catch {
        $Sync.Queue.Enqueue(@{ type = 'crash'; message = $_.Exception.Message; stack = [string]$_.ScriptStackTrace })
    }
}

function New-DzSync {
    <# Shared object between the GUI thread and the engine runspace. #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowNull()][object]$System = $null)
    $sync = [hashtable]::Synchronized(@{})
    $sync.Queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $sync.Cancel = $false
    $sync.System = $System
    return $sync
}

function Start-DzRunAsync {
    <# Starts Invoke-DzRun in a background runspace. Returns a handle for Test-DzRunAsync/Stop. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$KitRoot,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][hashtable]$Sync,
        [bool]$DryRun = $false
    )
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    # Execution policy exists only on Windows (setting it elsewhere breaks Open()).
    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        $iss.ExecutionPolicy = [Microsoft.PowerShell.ExecutionPolicy]::Bypass
    }
    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($iss)
    $runspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $runspace.Open()
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $runspace
    [void]$ps.AddScript($script:RunnerScript.ToString())
    [void]$ps.AddArgument($KitRoot).AddArgument($StatePath).AddArgument($DryRun).AddArgument($Sync)
    $handle = $ps.BeginInvoke()
    return [pscustomobject]@{ PowerShell = $ps; Handle = $handle; Runspace = $runspace }
}

function Test-DzRunAsyncCompleted {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][object]$Job)
    return [bool]$Job.Handle.IsCompleted
}

function Complete-DzRunAsync {
    <# Cleans up a finished background run. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Job)
    try { [void]$Job.PowerShell.EndInvoke($Job.Handle) } catch { Write-Verbose $_.Exception.Message }
    $Job.PowerShell.Dispose()
    $Job.Runspace.Dispose()
}

Export-ModuleMember -Function @(
    'Register-DzStepType', 'Test-DzStepType', 'Get-DzStepType', 'Register-DzRequirement', 'New-DzStepResult',
    'New-DzContext', 'Get-DzStepArg', 'Invoke-DzStepEntry', 'Invoke-DzRun',
    'New-DzSync', 'Start-DzRunAsync', 'Test-DzRunAsyncCompleted', 'Complete-DzRunAsync'
)
