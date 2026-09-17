#Requires -Version 5.1
<#
    Microsoft Graph helpers for the optional hybrid-identity follow-through.

    Kept as a SEPARATE module from Vortex.Deployment on purpose. The deployment
    engine must import cleanly on a bare Windows Server with no internet access
    and no modules installed; this one depends on Microsoft.Graph, which is
    neither present nor installable in that situation. Loading them together
    would make an optional extra a hard prerequisite of the core build.

    What is native to Entra ID and needs no script at all:

      Cloud account creation   Entra Connect does this automatically once the
                               on-premises account exists and syncs.
      Licence assignment       Group-based licensing (Entra admin center ->
                               Groups -> Licenses) assigns and, critically,
                               REVOKES as membership changes. Microsoft
                               reconciles it continuously. No script can match
                               that, which is why the default here only reports.

    What genuinely needs scripting: Teams membership. A Team is backed by a
    cloud-native Microsoft 365 Group, not by a synced on-premises security
    group, and nothing native puts someone in a Team because of an AD group
    membership. That gap is what this module bridges.
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Connect-VortexGraph {
    <#
    .SYNOPSIS
        Signs in to Microsoft Graph as an application, using a certificate.

    .DESCRIPTION
        Certificate authentication rather than a client secret: a secret is a
        password that has to be stored in a config file and rotated before it
        expires, and everyone who can read the file holds it. The certificate's
        private key stays in the machine's certificate store and is never a
        value anybody can copy out of a text file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $TenantId,
        [Parameter(Mandatory)] [string] $AppId,
        [Parameter(Mandatory)] [string] $CertificateThumbprint
    )

    foreach ($placeholder in $TenantId, $AppId, $CertificateThumbprint) {
        if ($placeholder -like '<*>') {
            throw 'The Microsoft365 section of DeploymentConfig.psd1 still contains placeholder values. Fill in TenantId, AppId and CertificateThumbprint first - see the README.'
        }
    }

    $certificate = Get-Item -Path "Cert:\LocalMachine\My\$CertificateThumbprint" -ErrorAction SilentlyContinue
    if (-not $certificate) {
        throw "No certificate with thumbprint '$CertificateThumbprint' in Cert:\LocalMachine\My. Import the private key on this server, or correct the thumbprint in the configuration."
    }

    Connect-MgGraph -TenantId $TenantId -ClientId $AppId -CertificateThumbprint $CertificateThumbprint -NoWelcome
}

function Invoke-EntraConnectDeltaSync {
    <#
    .SYNOPSIS
        Asks the Entra Connect server for an immediate delta sync.

    .DESCRIPTION
        Entra Connect syncs on its own schedule, every 30 minutes by default.
        Triggering a delta cycle avoids waiting for it. Needs PowerShell
        remoting to that server; if it is unavailable the caller should simply
        wait for the normal cycle instead.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $EntraConnectServer)

    Invoke-Command -ComputerName $EntraConnectServer -ScriptBlock {
        Import-Module ADSync
        Start-ADSyncSyncCycle -PolicyType Delta
    }
}

function Wait-ForEntraUser {
    <#
    .SYNOPSIS
        Waits for an on-premises account to appear in Entra ID.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $UserPrincipalName,
        [int] $TimeoutMinutes = 15,
        [int] $PollSeconds = 30
    )

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        $user = Get-MgUser -Filter "userPrincipalName eq '$UserPrincipalName'" -ErrorAction SilentlyContinue
        if ($user) { return $user }
        Start-Sleep -Seconds $PollSeconds
    }
    throw "'$UserPrincipalName' did not appear in Entra ID within $TimeoutMinutes minute(s). Check the sync status on the Entra Connect server, and that the account's UPN suffix is a domain verified in the tenant - a .local suffix will never sync."
}

function Add-EntraTeamMember {
    <#
    .SYNOPSIS
        Adds a user to a Microsoft Team, if they are not already in it.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $TeamId,
        [Parameter(Mandatory)] [string] $UserId,
        [string] $DisplayNameForLog
    )

    if (-not $DisplayNameForLog) { $DisplayNameForLog = $UserId }

    $existing = Get-MgTeamMember -TeamId $TeamId -All -ErrorAction SilentlyContinue |
        Where-Object { $_.AdditionalProperties.userId -eq $UserId }
    if ($existing) {
        Write-DeploymentLog -Level SKIP -Message "'$DisplayNameForLog' is already a member of team $TeamId."
        return
    }

    if (-not $PSCmdlet.ShouldProcess($DisplayNameForLog, "Add to team $TeamId")) { return }

    $body = @{
        '@odata.type'     = '#microsoft.graph.aadUserConversationMember'
        roles             = @()
        'user@odata.bind' = "https://graph.microsoft.com/v1.0/users('$UserId')"
    }
    New-MgTeamMember -TeamId $TeamId -BodyParameter $body | Out-Null
    Write-DeploymentLog -Message "Added '$DisplayNameForLog' to team $TeamId."
}

function Set-EntraUserLicense {
    <#
    .SYNOPSIS
        Assigns a licence directly. Fallback for when group-based licensing is
        deliberately not used.

    .DESCRIPTION
        Worth stating plainly: this does NOT revoke. Removing someone from a
        group will not take their licence back, so an organisation using this
        path has to build its own offboarding. Group-based licensing does not
        have that problem, which is why it is the default.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $UserId,
        [Parameter(Mandatory)] [string] $SkuId,
        [string] $DisplayNameForLog
    )

    if (-not $DisplayNameForLog) { $DisplayNameForLog = $UserId }

    $current = Get-MgUserLicenseDetail -UserId $UserId -ErrorAction SilentlyContinue
    if ($current -and ($current.SkuId -contains $SkuId)) {
        Write-DeploymentLog -Level SKIP -Message "'$DisplayNameForLog' already holds SKU $SkuId."
        return
    }

    if (-not $PSCmdlet.ShouldProcess($DisplayNameForLog, "Assign licence SKU $SkuId")) { return }

    Set-MgUserLicense -UserId $UserId -AddLicenses @(@{ SkuId = $SkuId }) -RemoveLicenses @() | Out-Null
    Write-DeploymentLog -Level WARN -Message "Assigned SKU $SkuId to '$DisplayNameForLog'. This will not be revoked automatically if they leave the group."
}

Export-ModuleMember -Function Connect-VortexGraph, Invoke-EntraConnectDeltaSync, Wait-ForEntraUser, Add-EntraTeamMember, Set-EntraUserLicense
