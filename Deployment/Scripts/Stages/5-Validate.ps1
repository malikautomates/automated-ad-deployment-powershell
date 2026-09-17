#Requires -Version 5.1
<#
.SYNOPSIS
    Stage 5 - prove the deployment did what it claimed.

.DESCRIPTION
    Asks the server what it actually looks like and compares that against the
    configuration, one assertion at a time. This is the difference between "the
    script finished" and "the build is correct" - the original kit only ever
    established the former.

    Writes a CSV and a self-contained HTML report, prints a summary, and exits
    non-zero if anything failed so the run is machine-checkable.

    Safe and useful to run at any time afterwards as a health check:

        Invoke-Deployment.ps1 -Only 5
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [hashtable] $Config,
    [string] $DeploymentRoot,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'

if (-not $DeploymentRoot) { $DeploymentRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent }
if (-not (Get-Module Vortex.Deployment)) {
    Import-Module (Join-Path $DeploymentRoot 'Modules\Vortex.Deployment\Vortex.Deployment.psd1') -Force -ErrorAction Stop
}
if (-not $Config) {
    $Config = Import-DeploymentConfig -Path (Join-Path $DeploymentRoot 'Config\DeploymentConfig.psd1') -DeploymentRoot $DeploymentRoot
}
if (-not (Get-DeploymentState)) { Initialize-DeploymentState -Path $Config.Paths.StateFile | Out-Null }

Initialize-DeploymentLog -LogFolder $Config.Paths.Logs -StageName 'Stage5-Validate' | Out-Null

try {
    Invoke-DeploymentStep -Force -Description 'Wait for Active Directory to become available' -Action {
        Wait-ForActiveDirectory -TimeoutMinutes 10 | Out-Null
    }

    Import-Module ActiveDirectory -ErrorAction Stop

    $results = Get-DeploymentValidationResult -Config $Config

    # Console summary, grouped so a long report stays readable.
    foreach ($group in ($results | Group-Object Category)) {
        Write-Host ''
        Write-Host "  $($group.Name)" -ForegroundColor Cyan
        foreach ($item in $group.Group) {
            $colour = switch ($item.Status) {
                'PASS' { 'Green' }
                'FAIL' { 'Red' }
                default { 'Yellow' }
            }
            $line = '    {0,-5} {1}' -f $item.Status, $item.Check
            if ($item.Status -ne 'PASS' -and $item.Actual) {
                $line += "  (expected '$($item.Expected)', found '$($item.Actual)')"
            }
            Write-Host $line -ForegroundColor $colour
        }
    }

    $report = Export-DeploymentValidationReport -Result $results -ReportFolder $Config.Paths.Reports `
        -Title "Vortex AI deployment validation - $($Config.Domain.DnsName)"

    Write-Host ''
    Write-DeploymentLog -Message "Validation complete: $($report.Passed) passed, $($report.Failed) failed, $($report.Warnings) warning(s)."
    Write-DeploymentLog -Message "CSV report : $($report.CsvPath)"
    Write-DeploymentLog -Message "HTML report: $($report.HtmlPath)"

    foreach ($failure in @($results | Where-Object Status -eq 'FAIL')) {
        Write-DeploymentLog -Level ERROR -Message "FAILED CHECK - $($failure.Category) / $($failure.Check): expected '$($failure.Expected)', found '$($failure.Actual)'. $($failure.Detail)"
    }
    foreach ($warning in @($results | Where-Object Status -eq 'WARN')) {
        Write-DeploymentLog -Level WARN -Message "$($warning.Category) / $($warning.Check): $($warning.Detail)"
    }

    if ($report.Failed -gt 0) {
        # Throwing rather than returning quietly: the stage stays marked
        # incomplete, so re-running the deployment re-validates instead of
        # declaring victory over a build that does not match its configuration.
        Write-DeploymentLog -Level ERROR -Message "$($report.Failed) check(s) failed. The deployment is NOT complete - see the report."
        Complete-DeploymentLog -Outcome "complete with $($report.Failed) failure(s)"
        throw "Validation failed $($report.Failed) check(s). Full detail: $($report.HtmlPath)"
    }

    Write-DeploymentLog -Level SUCCESS -Message 'Every check passed.'
    Complete-DeploymentLog
}
catch {
    Complete-DeploymentLog -Outcome 'ABORTED'
    throw
}
