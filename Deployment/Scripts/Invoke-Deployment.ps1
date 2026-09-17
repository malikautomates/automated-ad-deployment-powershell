#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Runs the Vortex AI Active Directory deployment from end to end.

.DESCRIPTION
    This is the only script that needs to be started by hand. It owns the stage
    list, tracks progress in a state file, and re-launches itself after each
    reboot until the deployment is finished.

    Two restarts are unavoidable and each one is placed deliberately:

      Stage 1  applies addressing, installs EVERY role the deployment needs,
               and renames the server, then restarts. The rename happens BEFORE
               promotion because renaming a domain controller afterwards means
               rebuilding service principal names and DNS records.
      Stage 2  promotes the forest, then restarts.
      Stage 3  builds the directory contents.
      Stage 4  applies the security and operational baseline.
      Stage 5  validates everything and writes the report.

    Restarts are survived with a scheduled task that runs as NT AUTHORITY\SYSTEM.
    No credential is stored on disk and Windows auto-logon is never touched.

    Every stage records what it completed, so a run interrupted by a failure
    resumes from the first incomplete step rather than starting over.

.PARAMETER Resume
    Used by the scheduled task after a restart. Continues from the recorded
    state rather than starting a new deployment.

.PARAMETER StartFrom
    Begin at this stage number, ignoring earlier stages.

.PARAMETER Only
    Run just these stage numbers. Useful for re-running validation on its own.

.PARAMETER Force
    Re-run steps already recorded as complete.

.PARAMETER Reset
    Discard recorded progress and start again. This forgets what the pipeline
    believes it has done; it does not undo anything on the server.

.EXAMPLE
    C:\ADDeployment\Scripts\Invoke-Deployment.ps1
    Normal first run, from the VM console.

.EXAMPLE
    C:\ADDeployment\Scripts\Invoke-Deployment.ps1 -WhatIf
    Shows every action the deployment would take, changing nothing.

.EXAMPLE
    C:\ADDeployment\Scripts\Invoke-Deployment.ps1 -Only 5
    Re-runs validation and writes a fresh report.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $DeploymentRoot,
    [string] $ConfigPath,
    [switch] $Resume,
    [int] $StartFrom,
    [int[]] $Only,
    [switch] $Force,
    [switch] $Reset,
    [switch] $SkipPreflight
)

$ErrorActionPreference = 'Stop'

if (-not $DeploymentRoot) { $DeploymentRoot = Split-Path -Path $PSScriptRoot -Parent }
if (-not $ConfigPath) { $ConfigPath = Join-Path $DeploymentRoot 'Config\DeploymentConfig.psd1' }

$ResumeTaskName = 'Vortex-Deployment-Resume'

# --------------------------------------------------------------------------
#  Load the engine and the configuration
# --------------------------------------------------------------------------
$modulePath = Join-Path $DeploymentRoot 'Modules\Vortex.Deployment\Vortex.Deployment.psd1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "Cannot find the Vortex.Deployment module at '$modulePath'. Is -DeploymentRoot correct? It is currently '$DeploymentRoot'."
}
Import-Module $modulePath -Force -ErrorAction Stop

$Config = Import-DeploymentConfig -Path $ConfigPath -DeploymentRoot $DeploymentRoot
Initialize-DeploymentState -Path $Config.Paths.StateFile | Out-Null

if ($Reset) {
    Reset-DeploymentState -Confirm:$false
    Write-Host 'Recorded deployment progress has been cleared. Nothing on the server was changed.' -ForegroundColor Yellow
}

# --------------------------------------------------------------------------
#  Stage list
#
#  RebootAfter marks the stages that cannot complete their work without a
#  restart. Everything else runs straight through in a single pass.
# --------------------------------------------------------------------------
$Stages = @(
    @{ Number = 0; Name = 'Preflight'; File = '0-Preflight.ps1'; RebootAfter = $false; Description = 'Read-only environment checks' }
    @{ Number = 1; Name = 'Initialize-Server'; File = '1-Initialize-Server.ps1'; RebootAfter = $true; Description = 'Addressing, computer name, all role binaries' }
    @{ Number = 2; Name = 'Install-ADForest'; File = '2-Install-ADForest.ps1'; RebootAfter = $true; Description = 'Forest promotion' }
    @{ Number = 3; Name = 'Configure-ADEnvironment'; File = '3-Configure-ADEnvironment.ps1'; RebootAfter = $false; Description = 'OUs, users, groups, folders, shares, FTP' }
    @{ Number = 4; Name = 'Baseline'; File = '4-Baseline.ps1'; RebootAfter = $false; Description = 'DNS, time, password policy, auditing, recycle bin' }
    @{ Number = 5; Name = 'Validate'; File = '5-Validate.ps1'; RebootAfter = $false; Description = 'Post-deployment validation report' }
)

$selected = $Stages
if ($Only) {
    $selected = @($Stages | Where-Object { $Only -contains $_.Number })
    if ($selected.Count -eq 0) { throw "No stage matches -Only $($Only -join ', '). Valid stage numbers are $(($Stages.Number) -join ', ')." }
}
elseif ($PSBoundParameters.ContainsKey('StartFrom')) {
    $selected = @($Stages | Where-Object { $_.Number -ge $StartFrom })
}
elseif ($SkipPreflight) {
    $selected = @($Stages | Where-Object { $_.Number -ne 0 })
}

# --------------------------------------------------------------------------
#  Housekeeping: prune old transcripts so repeated runs cannot fill the disk
# --------------------------------------------------------------------------
$retentionDays = [int](Get-ConfigValue (Get-ConfigValue $Config 'Logging' @{}) 'RetentionDays' 30)
if ($retentionDays -gt 0 -and (Test-Path -LiteralPath $Config.Paths.Logs)) {
    Get-ChildItem -LiteralPath $Config.Paths.Logs -Filter '*.log' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$retentionDays) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

# --------------------------------------------------------------------------
#  Banner
# --------------------------------------------------------------------------
$state = Get-DeploymentState
Write-Host ''
Write-Host '  Vortex AI Active Directory deployment' -ForegroundColor Cyan
Write-Host "  Deployment id : $($state.DeploymentId)"
Write-Host "  Root          : $DeploymentRoot"
Write-Host "  Target domain : $($Config.Domain.DnsName) ($($Config.Domain.NetBiosName))"
Write-Host "  Target name   : $($Config.Server.ComputerName)   (currently $env:COMPUTERNAME)"
Write-Host "  Mode          : $(if ($Resume) { 'resuming after restart' } else { 'interactive' })$(if ($WhatIfPreference) { '  [WhatIf - nothing will be changed]' })"
Write-Host "  Logs          : $($Config.Paths.Logs)"
Write-Host ''

# --------------------------------------------------------------------------
#  Run the stages
# --------------------------------------------------------------------------
foreach ($stage in $selected) {
    $stageKey = "{0}-{1}" -f $stage.Number, $stage.Name

    if (-not $Force -and -not $Only -and (Test-DeploymentStageComplete -StageName $stageKey)) {
        Write-Host "  [skip] Stage $($stage.Number) $($stage.Name) - already completed." -ForegroundColor DarkGray
        continue
    }

    $stagePath = Join-Path (Join-Path $Config.Paths.Scripts 'Stages') $stage.File
    if (-not (Test-Path -LiteralPath $stagePath)) {
        throw "Stage script not found: $stagePath"
    }

    Write-Host ''
    Write-Host "  >>> Stage $($stage.Number): $($stage.Name) - $($stage.Description)" -ForegroundColor Cyan

    try {
        & $stagePath -Config $Config -DeploymentRoot $DeploymentRoot -Force:$Force
    }
    catch {
        Write-Host ''
        Write-Host "  Stage $($stage.Number) ($($stage.Name)) FAILED." -ForegroundColor Red
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ''
        Write-Host "  Nothing further will run and the server will NOT restart." -ForegroundColor Yellow
        Write-Host "  Read the transcript in $($Config.Paths.Logs), fix the cause, then run:" -ForegroundColor Yellow
        Write-Host "    $PSCommandPath" -ForegroundColor Yellow
        Write-Host "  Completed steps are remembered, so it will carry on from where it stopped." -ForegroundColor Yellow
        throw
    }

    if (-not $WhatIfPreference) {
        Set-DeploymentStageComplete -StageName $stageKey
    }

    if ($stage.RebootAfter) {
        if ($WhatIfPreference) {
            Write-Host "  [WhatIf] Would register '$ResumeTaskName' and restart here." -ForegroundColor Magenta
            continue
        }

        Register-DeploymentResumeTask -TaskName $ResumeTaskName -ScriptPath $PSCommandPath -Arguments "-Resume -DeploymentRoot `"$DeploymentRoot`""
        Request-DeploymentRestart -ResumeTaskName $ResumeTaskName -Reason "to complete stage $($stage.Number) ($($stage.Name))"
        return   # Request-DeploymentRestart does not come back.
    }

    # The resume task exists for one reason: to survive a restart. Once no
    # remaining stage needs one, it is spent scaffolding - so retire it here
    # rather than after the loop.
    #
    # That ordering matters. Stage 5 asserts the scaffolding is gone; leaving
    # removal until after every stage completed meant the assertion ran while
    # the task was necessarily still registered, and could never pass.
    if (-not $WhatIfPreference) {
        $rebootsRemaining = @($selected | Where-Object { $_.Number -gt $stage.Number -and $_.RebootAfter }).Count
        if ($rebootsRemaining -eq 0) {
            Unregister-DeploymentResumeTask -TaskName $ResumeTaskName
        }
    }
}

# --------------------------------------------------------------------------
#  Finished: remove the automation scaffolding
# --------------------------------------------------------------------------
$allDone = @($Stages | Where-Object { $_.Number -gt 0 } | Where-Object {
        -not (Test-DeploymentStageComplete -StageName ("{0}-{1}" -f $_.Number, $_.Name))
    }).Count -eq 0

if ($allDone -and -not $WhatIfPreference) {
    Unregister-DeploymentResumeTask -TaskName $ResumeTaskName

    Write-Host ''
    Write-Host '  Deployment complete.' -ForegroundColor Green
    Write-Host "  Validation report : $($Config.Paths.Reports)"
    Write-Host "  Transcripts       : $($Config.Paths.Logs)"
    Write-Host "  Credentials       : $($Config.Paths.Secrets)  <- distribute, then delete" -ForegroundColor Yellow
    Write-Host ''
}
elseif ($WhatIfPreference) {
    Write-Host ''
    Write-Host '  WhatIf pass complete. No changes were made.' -ForegroundColor Magenta
    Write-Host ''
}
