#Requires -Version 5.1
<#
.SYNOPSIS
    Optional - finish onboarding the new users into Microsoft 365.

.DESCRIPTION
    NOT part of the automatic stage pipeline, and deliberately so. Hybrid
    identity sync runs on a schedule this machine does not control, so a step
    that waits on it does not belong inside a reboot chain. Run this by hand,
    or from its own scheduled task, once sync is known to be working.

    For each user in Data\Users.csv it:
      - confirms the account has synced into Entra ID,
      - adds them to the Microsoft Team mapped to their AD group,
      - reports their licence state (or assigns it, if you have opted out of
        native group-based licensing).

.NOTES
    Prerequisites, none of which this script can do for you:

    1. Real hybrid identity. A verified public domain (vortexai.local can never be
       one), that suffix applied as the users' UPN, and Entra Connect installed
       and syncing.

    2. An Entra app registration with APPLICATION permissions - User.Read.All,
       GroupMember.Read.All, TeamMember.ReadWrite.All, Organization.Read.All -
       with admin consent granted by a Global Administrator, authenticating
       with a certificate whose private key is in this server's
       Cert:\LocalMachine\My store.

    3. Install-Module Microsoft.Graph -Scope AllUsers
       (or the sub-modules: Authentication, Users, Users.Actions, Teams)

    4. The Microsoft365 section of DeploymentConfig.psd1 filled in, including
       GroupTeamMap.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $DeploymentRoot
)

$ErrorActionPreference = 'Stop'

if (-not $DeploymentRoot) { $DeploymentRoot = Split-Path -Path $PSScriptRoot -Parent }

Import-Module (Join-Path $DeploymentRoot 'Modules\Vortex.Deployment\Vortex.Deployment.psd1') -Force -ErrorAction Stop
Import-Module (Join-Path $DeploymentRoot 'Modules\Vortex.Microsoft365\Vortex.Microsoft365.psm1') -Force -ErrorAction Stop

$Config = Import-DeploymentConfig -Path (Join-Path $DeploymentRoot 'Config\DeploymentConfig.psd1') -DeploymentRoot $DeploymentRoot
Initialize-DeploymentState -Path $Config.Paths.StateFile | Out-Null

$m365 = Get-ConfigValue $Config 'Microsoft365' @{}
if (-not (Get-ConfigValue $m365 'Enabled' $false)) {
    Write-Host 'Microsoft365.Enabled is false in the configuration. Nothing to do.' -ForegroundColor Yellow
    Write-Host 'This stage is optional and requires hybrid identity to already be working - see the README.' -ForegroundColor Yellow
    return
}

# Microsoft.Graph.Users.Actions carries Set-MgUserLicense. Despite the name
# it is NOT in Microsoft.Graph.Users, and omitting it fails only at the
# moment a licence is assigned.
Import-Module Microsoft.Graph.Authentication, Microsoft.Graph.Users,
Microsoft.Graph.Users.Actions, Microsoft.Graph.Teams -ErrorAction Stop

Initialize-DeploymentLog -LogFolder $Config.Paths.Logs -StageName 'Stage9-OnboardMicrosoft365' | Out-Null

try {
    $verifiedDomain = [string](Get-ConfigValue $m365 'VerifiedDomain' '')
    if ($verifiedDomain -like '*.local') {
        throw "Microsoft365.VerifiedDomain is '$verifiedDomain'. A .local domain cannot be verified in a Microsoft 365 tenant, so no account with that UPN suffix will ever sync. Use a domain you own and have verified in the tenant."
    }

    $syncServer = [string](Get-ConfigValue $m365 'EntraConnectServer' '')
    if ($syncServer) {
        Invoke-DeploymentStep -ContinueOnError -Description "Trigger a delta sync on $syncServer" -Action {
            Invoke-EntraConnectDeltaSync -EntraConnectServer $syncServer
        }
    }
    else {
        Write-DeploymentLog -Message 'No EntraConnectServer configured - relying on the normal sync schedule (30 minutes by default).'
    }

    Invoke-DeploymentStep -Force -Description 'Connect to Microsoft Graph (application, certificate auth)' -Action {
        Connect-VortexGraph -TenantId $m365.TenantId -AppId $m365.AppId -CertificateThumbprint $m365.CertificateThumbprint
    }

    $synced = @{}
    $rows = @(Import-Csv -LiteralPath $Config.Paths.UsersCsv)

    foreach ($row in $rows) {
        $sam = ([string]$row.SamAccountName).Trim()
        if (-not $sam) { continue }
        $upn = "$sam@$verifiedDomain"

        Invoke-DeploymentStep -Force -ContinueOnError -Description "Confirm '$upn' has synced to Entra ID" -Action {
            $synced[$sam] = Wait-ForEntraUser -UserPrincipalName $upn `
                -TimeoutMinutes ([int](Get-ConfigValue $m365 'SyncWaitMinutes' 15))
            Write-DeploymentLog -Message "'$upn' is present in Entra ID."
        }
    }

    Invoke-DeploymentStep -Force -ContinueOnError -Description 'Add users to their mapped Microsoft Teams' -Action {
        $teamMap = Get-ConfigValue $m365 'GroupTeamMap' @{}
        if ($teamMap.Count -eq 0) {
            Write-DeploymentLog -Level WARN -Message 'GroupTeamMap is empty - no Teams membership to apply.'
            return
        }

        foreach ($row in $rows) {
            $sam = ([string]$row.SamAccountName).Trim()
            $user = $synced[$sam]
            if (-not $user) {
                Write-DeploymentLog -Level WARN -Message "'$sam' never confirmed as synced - skipping Teams membership."
                continue
            }

            foreach ($groupName in (([string]$row.Groups) -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
                if (-not $teamMap.ContainsKey($groupName)) { continue }
                Add-EntraTeamMember -TeamId $teamMap[$groupName] -UserId $user.Id -DisplayNameForLog $sam
            }
        }
    }

    Invoke-DeploymentStep -Force -ContinueOnError -Description 'Report or assign licences' -Action {
        if (Get-ConfigValue $m365 'UseGroupBasedLicensing' $true) {
            Write-DeploymentLog -Message 'Group-based licensing is in use. Entra ID assigns and revokes automatically; this is a report only.'
            foreach ($sam in $synced.Keys) {
                $skus = @(Get-MgUserLicenseDetail -UserId $synced[$sam].Id -ErrorAction SilentlyContinue).SkuPartNumber
                if ($skus) {
                    Write-DeploymentLog -Message "  $sam : $($skus -join ', ')"
                }
                else {
                    Write-DeploymentLog -Level WARN -Message "  $sam : NO LICENCE. Check the Licenses blade on their group in the Entra admin center."
                }
            }
            return
        }

        $licenseMap = Get-ConfigValue $m365 'GroupLicenseMap' @{}
        foreach ($row in $rows) {
            $sam = ([string]$row.SamAccountName).Trim()
            $user = $synced[$sam]
            if (-not $user) { continue }
            foreach ($groupName in (([string]$row.Groups) -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
                if (-not $licenseMap.ContainsKey($groupName)) { continue }
                Set-EntraUserLicense -UserId $user.Id -SkuId $licenseMap[$groupName] -DisplayNameForLog $sam
            }
        }
    }

    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    Complete-DeploymentLog
}
catch {
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    Complete-DeploymentLog -Outcome 'ABORTED'
    throw
}
