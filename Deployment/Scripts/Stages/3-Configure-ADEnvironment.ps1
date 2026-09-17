#Requires -Version 5.1
<#
.SYNOPSIS
    Stage 3 - build the contents of the directory and the file resources.

.DESCRIPTION
    Runs unattended, as SYSTEM, after the promotion restart.

    Order matters here and is not arbitrary:

      OUs first   - users and groups need somewhere to live.
      Groups next - the ACLs later in the stage grant to them by name, so they
                    have to resolve.
      Users then  - each is created into its OU and added to its groups.
      Folders     - NTFS permissions referencing the groups above.
      Shares      - because NTFS permissions on a folder nobody can reach over
                    the network are decoration.
      FTP last    - it is the least important thing here and the most likely to
                    be slow.

    Every step is idempotent. A stage that failed halfway can simply be run
    again.
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

Initialize-DeploymentLog -LogFolder $Config.Paths.Logs -StageName 'Stage3-ConfigureADEnvironment' | Out-Null

try {
    Assert-Administrator

    # ----------------------------------------------------------------------
    #  Wait for the directory to actually answer.
    #
    #  The startup trigger fires when Task Scheduler starts, which on a freshly
    #  promoted DC is minutes before Active Directory Web Services is ready to
    #  serve the AD PowerShell module. Everything below depends on it.
    # ----------------------------------------------------------------------
    Invoke-DeploymentStep -Force -Description 'Wait for Active Directory to become available' -Action {
        Wait-ForActiveDirectory -TimeoutMinutes 15 | Out-Null
    }

    Import-Module ActiveDirectory -ErrorAction Stop
    $domainDn = Get-DeploymentDomainDn -DnsName $Config.Domain.DnsName

    Invoke-DeploymentStep -Force:$Force -Description 'Point the DNS client at this domain controller' -Action {
        Set-DomainControllerDnsClient `
            -InterfaceAlias (Get-DeploymentFact -Name 'InterfaceAlias') `
            -SelfAddress (Get-DeploymentFact -Name 'IPAddress')
    }

    # ----------------------------------------------------------------------
    #  Directory objects
    # ----------------------------------------------------------------------
    Invoke-DeploymentStep -Force:$Force -Description 'Create the organizational unit structure' -Action {
        New-DeploymentOuTree -Config $Config -DomainDn $domainDn
    }

    Invoke-DeploymentStep -Force:$Force -Description 'Create security groups and AGDLP nesting' -Action {
        New-DeploymentGroupModel -Config $Config -DomainDn $domainDn
    }

    Invoke-DeploymentStep -Force:$Force -Description 'Create user accounts from the CSV feed' -Action {
        # @() because a function returning a single-element array unrolls it to
        # a scalar on the way out - so adding ONE user would otherwise crash here
        # while adding fifteen worked fine.
        $credentials = @(Import-DeploymentUser -Config $Config -DomainDn $domainDn)

        if ($credentials.Count -gt 0) {
            Export-DeploymentSecretReport -Entry $credentials `
                -SecretsFolder $Config.Paths.Secrets `
                -FileName 'InitialUserPasswords.csv' | Out-Null
        }
        else {
            Write-DeploymentLog -Message 'No new accounts were created, so no credential file was written.'
        }
    }

    # ----------------------------------------------------------------------
    #  File resources
    # ----------------------------------------------------------------------
    Invoke-DeploymentStep -Force:$Force -Description 'Create folders and apply NTFS permissions' -Action {
        foreach ($folder in @(Get-ConfigValue $Config 'FolderStructure' @())) {
            Set-DeploymentFolderAcl -Path $folder.Path -Permissions @(Get-ConfigValue $folder 'Permissions' @())
        }
    }

    Invoke-DeploymentStep -Force:$Force -Description 'Publish SMB shares' -Action {
        foreach ($folder in @(Get-ConfigValue $Config 'FolderStructure' @())) {
            $shareName = Get-ConfigValue $folder 'ShareName' ''
            if (-not $shareName) { continue }

            New-DeploymentShare -Name $shareName -Path $folder.Path `
                -Description (Get-ConfigValue $folder 'ShareDescription' '')
        }
    }

    # ----------------------------------------------------------------------
    #  FTP - required to exist, required to be off.
    #
    #  Marked non-critical: it is the only part of this build that is not load
    #  bearing, and a slow or partial IIS install should not cost the whole
    #  deployment. If it fails the validation report will say so plainly.
    # ----------------------------------------------------------------------
    Invoke-DeploymentStep -Force:$Force -ContinueOnError -Description 'Install the FTP role and leave it disabled' -Action {
        if (-not (Get-ConfigValue $Config.Features 'InstallFtp' $false)) {
            Write-DeploymentLog -Level SKIP -Message 'Features.InstallFtp is false - skipping.'
            return
        }

        Install-DeploymentFeature -Name 'Web-Server', 'Web-FTP-Server' -IncludeManagementTools `
            -SourcePath (Get-ConfigValue $Config.Features 'SourcePath' '') | Out-Null

        $serviceName = Get-ConfigValue $Config.Features 'FtpServiceName' 'FTPSVC'
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if (-not $service) {
            throw "Feature installed but the '$serviceName' service is not present yet. Re-run this stage once the role has settled."
        }

        if ($service.Status -ne 'Stopped') {
            Stop-Service -Name $serviceName -Force -ErrorAction Stop
        }
        Set-Service -Name $serviceName -StartupType Disabled -ErrorAction Stop

        Write-DeploymentLog -Level SUCCESS -Message "FTP is installed, stopped and set to Disabled. Note: running IIS/FTP on a domain controller is not a production-appropriate design - see the comment in DeploymentConfig.psd1."
    }

    Complete-DeploymentLog
}
catch {
    Complete-DeploymentLog -Outcome 'ABORTED'
    throw
}
