#Requires -Version 5.1
<#
.SYNOPSIS
    Validates the configuration and user feed BEFORE any server is touched.

.DESCRIPTION
    Pure static analysis. No Active Directory, no elevation, no server - this
    runs on a laptop, and it is the cheapest possible place to catch a mistake.

    It answers "is what I am asking for coherent?", not "did the deployment
    work". Stage 5 answers the second question, against a real domain
    controller, and neither replaces the other.

    What it catches that would otherwise surface mid-deployment:
      - an OU whose parent is declared after it (creation is sequential)
      - a user pointed at an OU that does not exist
      - a global group sitting on an ACL, which defeats AGDLP
      - a sAMAccountName over the 20-character limit
      - an ACL identity prefixed with the wrong NetBIOS domain
      - an account expiry date already in the past
      - role groups nobody is in, resource groups on no ACL

    Exits non-zero if anything failed, so it can gate a commit or a build.

.EXAMPLE
    .\Scripts\Test-DeploymentDesign.ps1

.EXAMPLE
    .\Scripts\Test-DeploymentDesign.ps1 -ReportFolder C:\Temp
    Writes the HTML and CSV somewhere other than Output\Reports.
#>

[CmdletBinding()]
param(
    [string] $DeploymentRoot,
    [string] $ConfigPath,
    [string] $ReportFolder,
    [switch] $Quiet
)

$ErrorActionPreference = 'Stop'

if (-not $DeploymentRoot) { $DeploymentRoot = Split-Path -Path $PSScriptRoot -Parent }
if (-not $ConfigPath) { $ConfigPath = Join-Path $DeploymentRoot 'Config\DeploymentConfig.psd1' }

Import-Module (Join-Path $DeploymentRoot 'Modules\Vortex.Deployment\Vortex.Deployment.psd1') -Force -ErrorAction Stop

$Config = Import-DeploymentConfig -Path $ConfigPath -DeploymentRoot $DeploymentRoot
if (-not $ReportFolder) { $ReportFolder = $Config.Paths.Reports }

$results = Get-DeploymentDesignValidationResult -Config $Config

if (-not $Quiet) {
    foreach ($group in ($results | Group-Object Category)) {
        $failed = @($group.Group | Where-Object Status -eq 'FAIL').Count
        $warned = @($group.Group | Where-Object Status -eq 'WARN').Count
        $passed = @($group.Group | Where-Object Status -eq 'PASS').Count

        Write-Host ''
        Write-Host ("  {0}  ({1} passed, {2} failed, {3} warnings)" -f $group.Name, $passed, $failed, $warned) -ForegroundColor Cyan

        # Passing checks are counted, not listed - a clean run should be short.
        foreach ($item in ($group.Group | Where-Object Status -ne 'PASS')) {
            $colour = if ($item.Status -eq 'FAIL') { 'Red' } else { 'Yellow' }
            Write-Host ("    {0,-5} {1}" -f $item.Status, $item.Check) -ForegroundColor $colour
            if ($item.Actual) {
                Write-Host ("          expected '{0}', found '{1}'" -f $item.Expected, $item.Actual) -ForegroundColor DarkGray
            }
            if ($item.Detail) {
                Write-Host ("          {0}" -f $item.Detail) -ForegroundColor DarkGray
            }
        }
    }
}

$report = Export-DeploymentValidationReport -Result $results -ReportFolder $ReportFolder `
    -Title "Vortex AI deployment - design validation ($($Config.Domain.DnsName))"

Write-Host ''
Write-Host ("  {0} passed   {1} failed   {2} warnings" -f $report.Passed, $report.Failed, $report.Warnings) -ForegroundColor $(
    if ($report.Failed -gt 0) { 'Red' } elseif ($report.Warnings -gt 0) { 'Yellow' } else { 'Green' })
Write-Host "  HTML : $($report.HtmlPath)"
Write-Host "  CSV  : $($report.CsvPath)"
Write-Host ''

if ($report.Failed -gt 0) {
    Write-Host '  Design validation FAILED. Fix the configuration before deploying.' -ForegroundColor Red
    Write-Host ''
    exit 1
}

Write-Host '  Design is coherent. This does not prove the deployment worked - run stage 5 on the server for that.' -ForegroundColor Green
Write-Host ''
