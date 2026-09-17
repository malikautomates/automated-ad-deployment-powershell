<#
    Deployment state. The pipeline spans two reboots, so "where did we get to?"
    has to survive a restart. This is the same idea as an MDT/SCCM task sequence
    variable store, scaled down to a JSON file.

    Without this, a failure in the middle of the chain means starting over from
    a fresh VM. With it, the orchestrator resumes at the first incomplete stage.
#>

function Initialize-DeploymentState {
    <#
    .SYNOPSIS
        Loads the state file, creating it on first run.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    $script:DeploymentStatePath = $Path

    $folder = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $folder)) {
        New-Item -Path $folder -ItemType Directory -Force | Out-Null
    }

    if (Test-Path -LiteralPath $Path) {
        try {
            $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
            $script:DeploymentState = ConvertTo-HashtableDeep -InputObject ($raw | ConvertFrom-Json)
        }
        catch {
            # A corrupt state file must not wedge the deployment permanently.
            # Preserve it for diagnosis and start clean.
            $backup = "$Path.corrupt-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            Move-Item -LiteralPath $Path -Destination $backup -Force
            Write-Warning "State file was unreadable and has been moved to $backup. Starting from a fresh state."
            $script:DeploymentState = $null
        }
    }

    if (-not $script:DeploymentState) {
        $script:DeploymentState = @{
            DeploymentId    = [guid]::NewGuid().ToString()
            StartedUtc      = (Get-Date).ToUniversalTime().ToString('o')
            UpdatedUtc      = (Get-Date).ToUniversalTime().ToString('o')
            CompletedStages = @()
            CompletedSteps  = @{}
            Facts           = @{}
        }
        Save-DeploymentState
    }

    foreach ($key in 'CompletedStages', 'CompletedSteps', 'Facts') {
        if (-not $script:DeploymentState.ContainsKey($key)) {
            $script:DeploymentState[$key] = if ($key -eq 'CompletedStages') { @() } else { @{} }
        }
    }

    return $script:DeploymentState
}

function Save-DeploymentState {
    <#
    .SYNOPSIS
        Flushes state to disk. Called after every state change so an abrupt
        reboot cannot lose more than the step in flight.
    #>
    [CmdletBinding()]
    param()

    if (-not $script:DeploymentStatePath) { return }
    $script:DeploymentState['UpdatedUtc'] = (Get-Date).ToUniversalTime().ToString('o')
    $script:DeploymentState | ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $script:DeploymentStatePath -Encoding UTF8 -ErrorAction Stop
}

function Get-DeploymentState {
    <#
    .SYNOPSIS
        Returns the in-memory state hashtable.
    #>
    [CmdletBinding()]
    param()
    return $script:DeploymentState
}

function Test-DeploymentStepComplete {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $StepKey)

    if (-not $script:DeploymentState) { return $false }
    return $script:DeploymentState.CompletedSteps.ContainsKey($StepKey)
}

function Set-DeploymentStepComplete {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $StepKey)

    if (-not $script:DeploymentState) { return }
    $script:DeploymentState.CompletedSteps[$StepKey] = (Get-Date).ToUniversalTime().ToString('o')
    Save-DeploymentState
}

function Test-DeploymentStageComplete {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $StageName)

    if (-not $script:DeploymentState) { return $false }
    return @($script:DeploymentState.CompletedStages) -contains $StageName
}

function Set-DeploymentStageComplete {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $StageName)

    if (-not $script:DeploymentState) { return }
    if (@($script:DeploymentState.CompletedStages) -notcontains $StageName) {
        $script:DeploymentState.CompletedStages = @($script:DeploymentState.CompletedStages) + $StageName
    }
    Save-DeploymentState
}

function Set-DeploymentFact {
    <#
    .SYNOPSIS
        Records a value that later stages need to know.

    .DESCRIPTION
        Chiefly used for the resolved network plan. Under PinCurrentLease the
        address is discovered from DHCP once, at the very start - by the time
        Stage 3 runs there is no lease left to read, so the decision has to be
        written down rather than recomputed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [AllowEmptyString()] $Value
    )
    if (-not $script:DeploymentState) { return }
    $script:DeploymentState.Facts[$Name] = $Value
    Save-DeploymentState
}

function Get-DeploymentFact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Name,
        $Default = $null
    )
    if (-not $script:DeploymentState) { return $Default }
    if (-not $script:DeploymentState.Facts.ContainsKey($Name)) { return $Default }
    return $script:DeploymentState.Facts[$Name]
}

function Reset-DeploymentState {
    <#
    .SYNOPSIS
        Clears recorded progress so the next run starts from Stage 1.

    .DESCRIPTION
        This only forgets what the pipeline believes it has done - it does not
        undo anything on the server. Use it when re-running against a rebuilt VM
        or a restored snapshot.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param()

    if ($PSCmdlet.ShouldProcess($script:DeploymentStatePath, 'Delete recorded deployment progress')) {
        if ($script:DeploymentStatePath -and (Test-Path -LiteralPath $script:DeploymentStatePath)) {
            Remove-Item -LiteralPath $script:DeploymentStatePath -Force
        }
        $script:DeploymentState = $null
        Initialize-DeploymentState -Path $script:DeploymentStatePath | Out-Null
    }
}
