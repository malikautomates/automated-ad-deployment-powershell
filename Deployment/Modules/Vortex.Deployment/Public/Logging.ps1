<#
    Logging and the single unit-of-work wrapper every deployment action runs
    through. Keeping all error policy in one place is what makes the difference
    between "the script printed some red text and kept going" and "the pipeline
    stopped before it could half-build a domain controller".
#>

function Initialize-DeploymentLog {
    <#
    .SYNOPSIS
        Opens a timestamped transcript and prepares logging for one stage.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $LogFolder,
        [Parameter(Mandatory)] [string] $StageName
    )

    if (-not (Test-Path -LiteralPath $LogFolder)) {
        New-Item -Path $LogFolder -ItemType Directory -Force | Out-Null
    }

    $script:DeploymentStageName = $StageName
    $script:DeploymentLogFile = Join-Path $LogFolder ("{0}-{1}.log" -f $StageName, (Get-Date -Format 'yyyyMMdd-HHmmss'))

    # Transcript failure must not abort a stage: a stage running as SYSTEM at
    # startup may briefly contend for the file, and losing the transcript is far
    # less bad than losing the deployment.
    $script:DeploymentTranscriptActive = $false
    try {
        Start-Transcript -Path $script:DeploymentLogFile -Append -ErrorAction Stop | Out-Null
        $script:DeploymentTranscriptActive = $true
    }
    catch {
        Write-Warning "Could not start transcript at $script:DeploymentLogFile - $($_.Exception.Message)"
    }

    Write-DeploymentLog -Message ("===== Stage '{0}' starting on {1} as {2} =====" -f `
            $StageName, $env:COMPUTERNAME, [Security.Principal.WindowsIdentity]::GetCurrent().Name)
    Write-DeploymentEventLog -EntryType Information -EventId 1000 -Message "Stage '$StageName' starting."
    return $script:DeploymentLogFile
}

function Write-DeploymentLog {
    <#
    .SYNOPSIS
        Writes one structured, timestamped line to console, transcript and (for
        warnings and errors) the Windows Application event log.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)] [string] $Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS', 'WHATIF', 'SKIP')] [string] $Level = 'INFO'
    )
    process {
        $stage = if ($script:DeploymentStageName) { $script:DeploymentStageName } else { 'VortexAI' }
        $line = "[{0}] [{1,-7}] [{2}] {3}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $stage, $Message

        switch ($Level) {
            'ERROR' { Write-Host $line -ForegroundColor Red }
            'WARN' { Write-Host $line -ForegroundColor Yellow }
            'SUCCESS' { Write-Host $line -ForegroundColor Green }
            'WHATIF' { Write-Host $line -ForegroundColor Magenta }
            'SKIP' { Write-Host $line -ForegroundColor DarkGray }
            default { Write-Host $line }
        }

        switch ($Level) {
            'ERROR' { Write-DeploymentEventLog -EntryType Error -EventId 1003 -Message $line }
            'WARN' { Write-DeploymentEventLog -EntryType Warning -EventId 1002 -Message $line }
        }
    }
}

function Complete-DeploymentLog {
    <#
    .SYNOPSIS
        Closes the transcript for the current stage.
    #>
    [CmdletBinding()]
    param([string] $Outcome = 'complete')

    Write-DeploymentLog -Message "===== Stage '$script:DeploymentStageName' $Outcome ====="
    Write-DeploymentEventLog -EntryType Information -EventId 1001 -Message "Stage '$script:DeploymentStageName' $Outcome."
    if ($script:DeploymentTranscriptActive) {
        try { Stop-Transcript | Out-Null } catch { }
        $script:DeploymentTranscriptActive = $false
    }
}

function Get-DeploymentLogPath {
    <#
    .SYNOPSIS
        Returns the transcript path for the stage currently running.
    #>
    [CmdletBinding()]
    param()
    return $script:DeploymentLogFile
}

function Invoke-DeploymentStep {
    <#
    .SYNOPSIS
        Runs one unit of deployment work under a single consistent policy.

    .DESCRIPTION
        Every action in every stage goes through this function, which gives the
        whole pipeline uniform behaviour for:

        - Logging      start / success / failure with timings.
        - Idempotence  a step already recorded complete in the state file is
                       skipped, so a resumed run does not redo finished work.
        - WhatIf       under -WhatIf the action is described, never executed.
        - Error policy a failure aborts the stage by default. Genuinely
                       optional work passes -ContinueOnError.

        The abort-by-default choice is deliberate. The failure mode this
        replaces is a script that logs an error and then keeps configuring a
        server whose earlier assumptions no longer hold.

    .PARAMETER Description
        Human-readable name for the step. Also its identity in the state file,
        so keep it stable across edits or resumed runs will redo the step.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Description,
        [Parameter(Mandatory)] [scriptblock] $Action,
        [switch] $ContinueOnError,
        [switch] $Force
    )

    $stepKey = "{0}::{1}" -f $script:DeploymentStageName, $Description

    if (-not $Force -and (Test-DeploymentStepComplete -StepKey $stepKey)) {
        Write-DeploymentLog -Level SKIP -Message "Already completed on a previous run: $Description"
        return
    }

    if ($WhatIfPreference) {
        Write-DeploymentLog -Level WHATIF -Message "Would run: $Description"
        return
    }

    Write-DeploymentLog -Message "Starting: $Description"
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        & $Action
        $stopwatch.Stop()
        Set-DeploymentStepComplete -StepKey $stepKey
        Write-DeploymentLog -Level SUCCESS -Message ("Completed: {0} ({1:n1}s)" -f $Description, $stopwatch.Elapsed.TotalSeconds)
    }
    catch {
        $stopwatch.Stop()
        $detail = $_.Exception.Message
        Write-DeploymentLog -Level ERROR -Message "FAILED: $Description -- $detail"
        Write-DeploymentLog -Level ERROR -Message "  at $($_.InvocationInfo.PositionMessage -replace '\r?\n', ' ')"

        if ($ContinueOnError) {
            Write-DeploymentLog -Level WARN -Message 'Step is marked non-critical - continuing.'
            return
        }

        Complete-DeploymentLog -Outcome 'ABORTED'
        throw "Deployment aborted: step '$Description' failed. $detail (see $script:DeploymentLogFile)"
    }
}
