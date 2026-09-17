#Requires -Version 5.1
<#
.SYNOPSIS
    Stage 0 - read-only preflight checks.

.DESCRIPTION
    Changes nothing. Its only job is to answer "will this deployment succeed?"
    before anything is modified, because the expensive failures in a build like
    this are the ones discovered halfway through, on a server that is already
    part-configured.

    A Fail stops the pipeline. A Warn is printed and the run continues.

    Normally invoked by Invoke-Deployment.ps1, but safe to run on its own at any
    time - including against a finished server.
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

Initialize-DeploymentLog -LogFolder $Config.Paths.Logs -StageName 'Stage0-Preflight' | Out-Null

try {
    $checks = Test-DeploymentPrerequisite -Config $Config

    Write-Host ''
    $checks | Format-Table -AutoSize -Property @(
        @{ Label = 'Check'; Expression = { $_.Name }; Width = 34 }
        @{ Label = 'Status'; Expression = { $_.Status }; Width = 7 }
        @{ Label = 'Detail'; Expression = { $_.Detail } }
    ) | Out-String -Width 200 | Write-Host

    foreach ($check in $checks) {
        $level = switch ($check.Status) {
            'Fail' { 'ERROR' }
            'Warn' { 'WARN' }
            default { 'INFO' }
        }
        Write-DeploymentLog -Level $level -Message ("{0}: {1} - {2}" -f $check.Status, $check.Name, $check.Detail)
    }

    $failures = @($checks | Where-Object Status -eq 'Fail')
    $warnings = @($checks | Where-Object Status -eq 'Warn')

    Write-DeploymentLog -Message ("Preflight summary: {0} passed, {1} warning(s), {2} failure(s)." -f `
        @($checks | Where-Object Status -eq 'Pass').Count, $warnings.Count, $failures.Count)

    if ($failures.Count -gt 0) {
        $detail = ($failures | ForEach-Object { "  - $($_.Name): $($_.Detail)" }) -join [Environment]::NewLine
        throw "Preflight failed $($failures.Count) check(s). Resolve these before deploying:$([Environment]::NewLine)$detail"
    }

    Complete-DeploymentLog
}
catch {
    Complete-DeploymentLog -Outcome 'ABORTED'
    throw
}
