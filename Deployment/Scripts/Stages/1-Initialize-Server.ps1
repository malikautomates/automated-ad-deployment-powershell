#Requires -Version 5.1
<#
.SYNOPSIS
    Stage 1 - server identity, addressing and role binaries.

.DESCRIPTION
    Everything that has to be true before a server can become a domain
    controller, and nothing that depends on Active Directory existing yet:

      1. Resolve and record the addressing plan.
      2. Apply it, so the address can never move again.
      3. Install EVERY Windows role the whole deployment needs - not just AD DS.
      4. Rename the computer.

    Step 3 covers roles that later stages use (IIS, FTP, Windows Server Backup)
    on purpose. Component payload failures (0x800f081f) are common on
    evaluation images, and they are far cheaper to fix here - interactively,
    before the first reboot - than at Stage 3 or 4, which run unattended as
    SYSTEM with no window on screen. Later stages find the roles present and
    skip their own installs.

    The rename is here, before promotion, on purpose. Renaming a member server
    is routine. Renaming a domain controller means reissuing service principal
    names and rewriting DNS records, and Microsoft's supported path for it is a
    different tool entirely. Getting the name right first avoids all of that.

    The restart at the end of this stage covers both the rename and the role
    installation.
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

Initialize-DeploymentLog -LogFolder $Config.Paths.Logs -StageName 'Stage1-InitializeServer' | Out-Null

try {
    Assert-Administrator

    # ----------------------------------------------------------------------
    #  Decide the addressing, and write the decision down before acting on it.
    #
    #  Under PinCurrentLease the address is read from the live DHCP lease. That
    #  information only exists right now - once the interface is static there is
    #  no lease left to consult - so later stages and the validation report read
    #  it back from the state file rather than trying to recompute it.
    # ----------------------------------------------------------------------
    Invoke-DeploymentStep -Force:$Force -Description 'Resolve and record the addressing plan' -Action {
        $adapter = Get-TargetAdapter -InterfaceAlias (Get-ConfigValue $Config.Network 'InterfaceAlias' '')
        $plan = Resolve-NetworkPlan -Config $Config -Adapter $adapter

        Write-DeploymentLog -Message $plan.Summary

        Set-DeploymentFact -Name 'InterfaceAlias' -Value $plan.InterfaceAlias
        Set-DeploymentFact -Name 'IPAddress' -Value ([string]$plan.IPAddress)
        Set-DeploymentFact -Name 'PrefixLength' -Value ([string]$plan.PrefixLength)
        Set-DeploymentFact -Name 'DefaultGateway' -Value ([string]$plan.DefaultGateway)
        Set-DeploymentFact -Name 'UpstreamDns' -Value (@($plan.UpstreamDns) -join ',')
        Set-DeploymentFact -Name 'AddressingMode' -Value $plan.Mode

        if ($plan.IPAddress -and $plan.PrefixLength) {
            $networkId = ConvertTo-NetworkId -IPAddress $plan.IPAddress -PrefixLength ([int]$plan.PrefixLength)
            Set-DeploymentFact -Name 'NetworkId' -Value $networkId
            # in-addr.arpa zone name for the reverse lookup zone created in Stage 4.
            $octets = ($plan.IPAddress -split '\.')
            # Deliberately if/elseif, NOT switch. A PowerShell switch evaluates
            # EVERY matching condition unless each branch breaks, so a /24 would
            # satisfy both "-ge 24" and "-ge 16" and emit two strings - turning
            # this fact into an array and breaking every consumer downstream.
            $prefix = [int]$plan.PrefixLength
            $zoneName = if ($prefix -ge 24) {
                "$($octets[2]).$($octets[1]).$($octets[0]).in-addr.arpa"
            }
            elseif ($prefix -ge 16) {
                "$($octets[1]).$($octets[0]).in-addr.arpa"
            }
            else {
                "$($octets[0]).in-addr.arpa"
            }
            Set-DeploymentFact -Name 'ReverseZoneName' -Value ([string]$zoneName)
        }
    }

    Invoke-DeploymentStep -Force:$Force -Description 'Apply static addressing' -Action {
        $adapter = Get-TargetAdapter -InterfaceAlias (Get-ConfigValue $Config.Network 'InterfaceAlias' '')
        $plan = Resolve-NetworkPlan -Config $Config -Adapter $adapter `
            -UpstreamDnsOverride (@((Get-DeploymentFact -Name 'UpstreamDns' '') -split ',' | Where-Object { $_ }))

        # Under PinCurrentLease, re-resolving here would read the address that is
        # about to be replaced. Use the recorded decision instead.
        $recordedIp = Get-DeploymentFact -Name 'IPAddress'
        if ($recordedIp) {
            $plan.IPAddress = $recordedIp
            $plan.PrefixLength = [int](Get-DeploymentFact -Name 'PrefixLength')
            $plan.DefaultGateway = Get-DeploymentFact -Name 'DefaultGateway'
        }

        Set-DeploymentNetwork -Plan $plan
    }

    # ----------------------------------------------------------------------
    #  Role binaries. Installing them now means the restart at the end of this
    #  stage covers the role install and the rename together, rather than
    #  costing a third reboot later.
    # ----------------------------------------------------------------------
    Invoke-DeploymentStep -Force:$Force -Description 'Install every Windows role the deployment needs' -Action {
        $required = @(Get-ConfigValue $Config.Features 'Required' @('AD-Domain-Services', 'RSAT-AD-PowerShell'))
        if ($required.Count -eq 0) {
            Write-DeploymentLog -Level WARN -Message 'Features.Required is empty - nothing to install. Later stages will fail if the roles are not already present.'
            return
        }

        Write-DeploymentLog -Message "Installing $($required.Count) role(s) up front: $($required -join ', ')"
        Write-DeploymentLog -Message 'Doing this here, rather than one role per stage, keeps any payload problem in front of an operator instead of surfacing unattended after a reboot.'

        # A single call: Install-DeploymentFeature skips whatever is already
        # present, and on a missing-payload error (0x800f081f) finds the
        # Windows installation media and retries by itself.
        Install-DeploymentFeature -Name $required -IncludeManagementTools `
            -SourcePath (Get-ConfigValue $Config.Features 'SourcePath' '')

        $missing = @($required | Where-Object { -not (Get-WindowsFeature -Name $_ -ErrorAction SilentlyContinue).Installed })
        if ($missing.Count -gt 0) {
            throw "These roles are still not installed after the attempt: $($missing -join ', '). The deployment cannot continue without them."
        }
        Write-DeploymentLog -Level SUCCESS -Message 'All required roles are present. Later stages will find them installed and skip their own checks.'
    }

    # ----------------------------------------------------------------------
    #  Identity
    # ----------------------------------------------------------------------
    Invoke-DeploymentStep -Force:$Force -Description "Rename computer to $($Config.Server.ComputerName)" -Action {
        $target = $Config.Server.ComputerName
        if ($env:COMPUTERNAME -eq $target) {
            Write-DeploymentLog -Level SKIP -Message "Computer is already named '$target'."
            return
        }
        Rename-Computer -NewName $target -Force -ErrorAction Stop
        Write-DeploymentLog -Message "Computer will be '$target' after the restart (currently '$env:COMPUTERNAME')."
    }

    Complete-DeploymentLog
}
catch {
    Complete-DeploymentLog -Outcome 'ABORTED'
    throw
}
