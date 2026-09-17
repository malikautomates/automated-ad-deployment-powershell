#Requires -Version 5.1
<#
.SYNOPSIS
    Stage 2 - promote this server to the first domain controller in a new forest.

.DESCRIPTION
    Runs unattended, as SYSTEM, from the startup task registered before the
    previous restart.

    The Directory Services Restore Mode password is generated here rather than
    typed. It is a break-glass credential used to boot a domain controller into
    a repair mode where Active Directory is offline - it is needed rarely, and
    when it is needed it matters enormously. A generated 24-character value
    written to the protected handover file is safer than a memorable one reused
    from the administrator account, which is what the original scripts did.

    It is written to disk BEFORE promotion starts, so a promotion that succeeds
    can never leave the domain with a DSRM password nobody recorded.
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

Initialize-DeploymentLog -LogFolder $Config.Paths.Logs -StageName 'Stage2-InstallADForest' | Out-Null

try {
    Assert-Administrator

    Invoke-DeploymentStep -Force:$Force -Description 'Confirm the rename from Stage 1 took effect' -Action {
        $expected = $Config.Server.ComputerName
        if ($env:COMPUTERNAME -ne $expected) {
            throw "Computer is named '$env:COMPUTERNAME' but should be '$expected'. Promotion is being stopped: renaming a domain controller after the fact is far harder than renaming a member server. Check that Stage 1's rename succeeded and that the server restarted."
        }
        Write-DeploymentLog -Message "Computer name confirmed as '$expected'."
    }

    Invoke-DeploymentStep -Force:$Force -Description 'Generate and record the DSRM password' -Action {
        $existing = Get-DeploymentFact -Name 'DsrmSecretFile'
        if ($existing -and (Test-Path -LiteralPath $existing)) {
            Write-DeploymentLog -Level SKIP -Message 'A DSRM password has already been generated and stored for this deployment.'
            return
        }

        $dsrmPassword = New-RandomPassword -Length 24
        $securePath = Join-Path $Config.Paths.Secrets 'dsrm.secret'

        # Machine-scoped DPAPI: written here by SYSTEM, and readable by any
        # administrator on THIS machine only. Copied elsewhere it is just noise.
        Protect-DeploymentSecret -Secret (ConvertTo-SecureString $dsrmPassword -AsPlainText -Force) -Path $securePath
        Set-DeploymentFact -Name 'DsrmSecretFile' -Value $securePath

        Export-DeploymentSecretReport -SecretsFolder $Config.Paths.Secrets -FileName 'DSRM-password.csv' -Entry @(
            [pscustomobject]@{
                Account = "DSRM ($($Config.Domain.DnsName))"
                Secret  = $dsrmPassword
                Purpose = 'Directory Services Restore Mode. Break-glass only. Move this into your password manager and delete this file.'
            }
        ) | Out-Null

        Write-DeploymentLog -Level WARN -Message 'DSRM password generated. It is NOT single-use - store it somewhere durable before deleting the handover file.'
    }

    Invoke-DeploymentStep -Force:$Force -Description "Promote to first domain controller in '$($Config.Domain.DnsName)'" -Action {
        # Test for the database file rather than the NTDS service. Installing
        # the AD DS role registers that service whether or not a forest was ever
        # created, so a service-existence check would report "already promoted"
        # on a server that never was, and silently skip the only step that
        # matters.
        $ntdsDatabase = Join-Path $env:SystemRoot 'NTDS\ntds.dit'
        if (Test-Path -LiteralPath $ntdsDatabase) {
            Write-DeploymentLog -Level SKIP -Message "Active Directory database already present at $ntdsDatabase - this server is already promoted."
            return
        }

        Import-Module ADDSDeployment -ErrorAction Stop

        $dsrmSecure = Unprotect-DeploymentSecret -Path (Get-DeploymentFact -Name 'DsrmSecretFile')

        $parameters = @{
            DomainName                    = $Config.Domain.DnsName
            DomainNetbiosName             = $Config.Domain.NetBiosName
            SafeModeAdministratorPassword = $dsrmSecure
            InstallDns                    = $true
            NoRebootOnCompletion          = $true
            Force                         = $true
            ErrorAction                   = 'Stop'
        }

        $domainMode = Get-ConfigValue $Config.Domain 'DomainMode' ''
        $forestMode = Get-ConfigValue $Config.Domain 'ForestMode' ''
        if ($domainMode) { $parameters['DomainMode'] = $domainMode }
        if ($forestMode) { $parameters['ForestMode'] = $forestMode }

        Write-DeploymentLog -Message 'Starting forest promotion. This takes several minutes and produces no output until it finishes.'
        $result = Install-ADDSForest @parameters

        Write-DeploymentLog -Level SUCCESS -Message "Promotion finished with status '$($result.Status)'. A restart is required before Active Directory is usable."
    }

    Complete-DeploymentLog
}
catch {
    Complete-DeploymentLog -Outcome 'ABORTED'
    throw
}
