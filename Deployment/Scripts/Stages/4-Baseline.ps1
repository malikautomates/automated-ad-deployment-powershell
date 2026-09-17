#Requires -Version 5.1
<#
.SYNOPSIS
    Stage 4 - the security and operational baseline.

.DESCRIPTION
    Everything in this stage is something a real domain gets on day one and a
    lab build usually never gets at all. None of it is required to make the
    directory "work", and all of it is required to make it survivable:

      AD Recycle Bin   Without it a deleted object loses its attributes and its
                       group memberships, and restoring it means an authoritative
                       restore from backup. It can only be enabled, never
                       disabled, so it is done immediately.
      DNS forwarders   Once the DC resolves through itself it can no longer
                       reach public names without these. Windows Update and
                       module installs fail in confusing ways otherwise.
      Reverse zone     Most diagnostic tooling assumes IP-to-name works.
      Time             The forest root PDC emulator is the clock the entire
                       domain follows. Past five minutes of drift, Kerberos
                       starts refusing tickets and the errors mention neither
                       time nor Kerberos.
      Password policy  Applied after account creation so the generated
                       passwords are not evaluated against a stricter rule.
      Auditing         The events an investigation actually needs, enabled
                       before there is an incident rather than after.

    Individual steps are non-critical where a failure is survivable, so one
    unavailable subsystem does not cost the rest of the baseline. Anything that
    did not apply shows up in the Stage 5 report.
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

Initialize-DeploymentLog -LogFolder $Config.Paths.Logs -StageName 'Stage4-Baseline' | Out-Null

try {
    Assert-Administrator

    Invoke-DeploymentStep -Force -Description 'Wait for Active Directory to become available' -Action {
        Wait-ForActiveDirectory -TimeoutMinutes 15 | Out-Null
    }

    Import-Module ActiveDirectory -ErrorAction Stop
    $security = Get-ConfigValue $Config 'Security' @{}
    $dnsConfig = Get-ConfigValue $Config 'Dns' @{}
    $timeConfig = Get-ConfigValue $Config 'Time' @{}

    # ----------------------------------------------------------------------
    #  Directory hygiene
    # ----------------------------------------------------------------------
    Invoke-DeploymentStep -Force:$Force -ContinueOnError -Description 'Enable the Active Directory Recycle Bin' -Action {
        if (-not (Get-ConfigValue $security 'EnableAdRecycleBin' $true)) {
            Write-DeploymentLog -Level SKIP -Message 'Disabled by configuration.'
            return
        }

        $feature = Get-ADOptionalFeature -Filter "Name -eq 'Recycle Bin Feature'" -ErrorAction Stop
        if (@($feature.EnabledScopes).Count -gt 0) {
            Write-DeploymentLog -Level SKIP -Message 'AD Recycle Bin is already enabled.'
            return
        }

        $forest = Get-ADForest
        Enable-ADOptionalFeature -Identity $feature.DistinguishedName `
            -Scope ForestOrConfigurationSet -Target $forest.Name -Confirm:$false -ErrorAction Stop

        Write-DeploymentLog -Level SUCCESS -Message 'AD Recycle Bin enabled. This is irreversible, which is why it is done at build time.'
    }

    # ----------------------------------------------------------------------
    #  DNS
    # ----------------------------------------------------------------------
    Invoke-DeploymentStep -Force:$Force -ContinueOnError -Description 'Configure DNS forwarders' -Action {
        $recorded = @((Get-DeploymentFact -Name 'UpstreamDns' '') -split ',' | Where-Object { $_ })
        $configured = @(Get-ConfigValue $Config.Network 'Forwarders' @())
        $forwarders = if ($configured.Count -gt 0) { $configured } else { $recorded }

        # Never forward to ourselves - that is a resolution loop.
        $ownAddresses = @((Get-NetIPAddress -AddressFamily IPv4).IPAddress) + '127.0.0.1'
        $forwarders = @($forwarders | Where-Object { $_ -notin $ownAddresses })

        if ($forwarders.Count -eq 0) {
            Write-DeploymentLog -Level WARN -Message 'No usable forwarder could be determined. The DC will fall back to root hints, which usually works but is slower. Set Network.Forwarders in the configuration to fix this.'
            return
        }

        Set-DnsServerForwarder -IPAddress $forwarders -UseRootHint $true -ErrorAction Stop
        Write-DeploymentLog -Level SUCCESS -Message "DNS forwarders set to $($forwarders -join ', ')."
    }

    Invoke-DeploymentStep -Force:$Force -ContinueOnError -Description 'Create the DNS reverse lookup zone' -Action {
        if (-not (Get-ConfigValue $dnsConfig 'CreateReverseLookupZone' $true)) {
            Write-DeploymentLog -Level SKIP -Message 'Disabled by configuration.'
            return
        }

        $networkId = @(Get-DeploymentFact -Name 'NetworkId') | Select-Object -First 1
        # Select-Object -First 1 defends against a state file written by an older
        # build, where this fact could be an array. Harmless for a plain string.
        $zoneName = @(Get-DeploymentFact -Name 'ReverseZoneName') | Select-Object -First 1
        if (-not $networkId -or -not $zoneName) {
            Write-DeploymentLog -Level WARN -Message 'No network id recorded in the state file - cannot create a reverse zone.'
            return
        }

        if (Get-DnsServerZone -Name $zoneName -ErrorAction SilentlyContinue) {
            Write-DeploymentLog -Level SKIP -Message "Reverse zone '$zoneName' already exists."
            return
        }

        Add-DnsServerPrimaryZone -NetworkId $networkId -ReplicationScope 'Domain' -DynamicUpdate 'Secure' -ErrorAction Stop
        Write-DeploymentLog -Level SUCCESS -Message "Created reverse lookup zone '$zoneName' for $networkId."
    }

    Invoke-DeploymentStep -Force:$Force -ContinueOnError -Description 'Enable DNS scavenging' -Action {
        if (-not (Get-ConfigValue $dnsConfig 'EnableScavenging' $true)) {
            Write-DeploymentLog -Level SKIP -Message 'Disabled by configuration.'
            return
        }

        $days = [int](Get-ConfigValue $dnsConfig 'ScavengingIntervalDays' 7)
        $interval = New-TimeSpan -Days $days

        Set-DnsServerScavenging -ScavengingState $true -ScavengingInterval $interval `
            -RefreshInterval $interval -NoRefreshInterval $interval -ApplyOnAllZones -ErrorAction Stop | Out-Null

        Write-DeploymentLog -Level SUCCESS -Message "DNS scavenging enabled on all zones with a $days-day interval, so stale records do not accumulate forever."
    }

    # ----------------------------------------------------------------------
    #  Time
    # ----------------------------------------------------------------------
    Invoke-DeploymentStep -Force:$Force -ContinueOnError -Description 'Disable VMware Tools host time synchronisation' -Action {
        if (-not (Get-ConfigValue $timeConfig 'DisableVMwareToolsSync' $true)) {
            Write-DeploymentLog -Level SKIP -Message 'Disabled by configuration.'
            return
        }

        $toolbox = Join-Path $env:ProgramFiles 'VMware\VMware Tools\VMwareToolboxCmd.exe'
        if (-not (Test-Path -LiteralPath $toolbox)) {
            Write-DeploymentLog -Level SKIP -Message 'VMware Tools is not installed - nothing to disable.'
            return
        }

        & $toolbox timesync disable | Out-Null
        Write-DeploymentLog -Level SUCCESS -Message 'VMware Tools time synchronisation disabled. The Windows Time service is now the only thing setting this clock, which is what a domain controller requires.'
    }

    Invoke-DeploymentStep -Force:$Force -ContinueOnError -Description 'Configure the PDC emulator as the authoritative time source' -Action {
        if (-not (Get-ConfigValue $timeConfig 'ConfigurePdcTimeSource' $true)) {
            Write-DeploymentLog -Level SKIP -Message 'Disabled by configuration.'
            return
        }

        $domain = Get-ADDomain
        $thisHost = "$env:COMPUTERNAME.$($domain.DNSRoot)"
        if ($domain.PDCEmulator -ne $thisHost) {
            Write-DeploymentLog -Level SKIP -Message "This server ($thisHost) does not hold the PDC emulator role ($($domain.PDCEmulator)) - external time configuration belongs on that one."
            return
        }

        $peers = @(Get-ConfigValue $timeConfig 'NtpServers' @('time.windows.com'))
        # 0x8 requests the client send mode, which is what works through NAT.
        $peerList = ($peers | ForEach-Object { "$_,0x8" }) -join ' '

        & w32tm.exe /config "/manualpeerlist:$peerList" /syncfromflags:manual /reliable:yes /update | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "w32tm /config returned exit code $LASTEXITCODE." }

        Restart-Service -Name w32time -Force -ErrorAction Stop
        Wait-ForService -Name w32time -Status Running -TimeoutSeconds 60 | Out-Null
        & w32tm.exe /resync /rediscover | Out-Null

        Write-DeploymentLog -Level SUCCESS -Message "PDC emulator time source set to $($peers -join ', '). Every other machine in the domain follows this clock."
    }

    # ----------------------------------------------------------------------
    #  Policy
    # ----------------------------------------------------------------------
    Invoke-DeploymentStep -Force:$Force -ContinueOnError -Description 'Apply the default domain password and lockout policy' -Action {
        $policy = Get-ConfigValue $Config 'PasswordPolicy' @{}
        if (-not (Get-ConfigValue $policy 'Apply' $true)) {
            Write-DeploymentLog -Level SKIP -Message 'Disabled by configuration.'
            return
        }

        $domain = Get-ADDomain
        Set-ADDefaultDomainPasswordPolicy -Identity $domain.DNSRoot `
            -MinPasswordLength ([int](Get-ConfigValue $policy 'MinPasswordLength' 14)) `
            -ComplexityEnabled ([bool](Get-ConfigValue $policy 'ComplexityEnabled' $true)) `
            -MaxPasswordAge (New-TimeSpan -Days ([int](Get-ConfigValue $policy 'MaxPasswordAgeDays' 365))) `
            -MinPasswordAge (New-TimeSpan -Days ([int](Get-ConfigValue $policy 'MinPasswordAgeDays' 1))) `
            -PasswordHistoryCount ([int](Get-ConfigValue $policy 'PasswordHistoryCount' 24)) `
            -LockoutThreshold ([int](Get-ConfigValue $policy 'LockoutThreshold' 10)) `
            -LockoutDuration (New-TimeSpan -Minutes ([int](Get-ConfigValue $policy 'LockoutDurationMinutes' 15))) `
            -LockoutObservationWindow (New-TimeSpan -Minutes ([int](Get-ConfigValue $policy 'LockoutWindowMinutes' 15))) `
            -ErrorAction Stop

        Write-DeploymentLog -Level SUCCESS -Message 'Default domain password and lockout policy applied.'
    }

    Invoke-DeploymentStep -Force:$Force -ContinueOnError -Description 'Enable advanced audit policy subcategories' -Action {
        foreach ($entry in @(Get-ConfigValue $security 'AuditSubcategories' @())) {
            $name = $entry.Name
            $successFlag = if (Get-ConfigValue $entry 'Success' $true) { 'enable' } else { 'disable' }
            $failureFlag = if (Get-ConfigValue $entry 'Failure' $true) { 'enable' } else { 'disable' }

            & auditpol.exe /set /subcategory:"$name" /success:$successFlag /failure:$failureFlag | Out-Null
            if ($LASTEXITCODE -ne 0) {
                # Subcategory names are localised; on a non-English server these
                # will not match. Worth a warning, not worth failing over.
                Write-DeploymentLog -Level WARN -Message "auditpol could not set '$name' (exit code $LASTEXITCODE). Subcategory names are language-specific."
                continue
            }
            Write-DeploymentLog -Message "Auditing for '$name': success=$successFlag, failure=$failureFlag."
        }
    }

    # ----------------------------------------------------------------------
    #  Host hardening and access
    # ----------------------------------------------------------------------
    Invoke-DeploymentStep -Force:$Force -ContinueOnError -Description 'Confirm SMBv1 is disabled' -Action {
        if (-not (Get-ConfigValue $security 'DisableSmb1' $true)) { return }

        $smb = Get-SmbServerConfiguration
        if (-not $smb.EnableSMB1Protocol) {
            Write-DeploymentLog -Level SKIP -Message 'SMBv1 is already disabled.'
            return
        }
        Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force -ErrorAction Stop
        Write-DeploymentLog -Level SUCCESS -Message 'SMBv1 disabled.'
    }

    Invoke-DeploymentStep -Force:$Force -ContinueOnError -Description 'Enable Remote Desktop' -Action {
        if (-not (Get-ConfigValue $security 'EnableRdp' $true)) {
            Write-DeploymentLog -Level SKIP -Message 'Disabled by configuration.'
            return
        }

        Set-ItemProperty -LiteralPath 'HKLM:\System\CurrentControlSet\Control\Terminal Server' `
            -Name 'fDenyTSConnections' -Value 0 -ErrorAction Stop

        # Network Level Authentication on: it forces authentication before a
        # session is created, which removes a whole class of pre-auth attacks.
        Set-ItemProperty -LiteralPath 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' `
            -Name 'UserAuthentication' -Value 1 -ErrorAction SilentlyContinue

        Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue
        Write-DeploymentLog -Level SUCCESS -Message 'Remote Desktop enabled with Network Level Authentication.'
    }

    # ----------------------------------------------------------------------
    #  Backup
    # ----------------------------------------------------------------------
    Invoke-DeploymentStep -Force:$Force -ContinueOnError -Description 'Install Windows Server Backup and stage the system state job' -Action {
        $backup = Get-ConfigValue $Config 'Backup' @{}

        Install-DeploymentFeature -Name 'Windows-Server-Backup' `
            -SourcePath (Get-ConfigValue $Config.Features 'SourcePath' '') | Out-Null

        $target = [string](Get-ConfigValue $backup 'TargetPath' '')
        $enabled = [bool](Get-ConfigValue $backup 'Enabled' $false)
        $taskName = 'Vortex-SystemStateBackup'
        $time = [string](Get-ConfigValue $backup 'DailyAt' '02:00')

        if (-not $enabled -or -not $target) {
            Write-DeploymentLog -Level WARN -Message 'No backup target configured, so no backup job was created. wbadmin cannot write a system state backup to the volume it is backing up, so a single-disk server has nowhere valid to put one. Add a second disk or a UNC path, set Backup.TargetPath and Backup.Enabled in the configuration, then re-run this stage. A domain controller with no system state backup has no recovery path.'
            return
        }

        $action = New-ScheduledTaskAction -Execute 'wbadmin.exe' `
            -Argument "start systemstatebackup -backupTarget:$target -quiet"
        $trigger = New-ScheduledTaskTrigger -Daily -At $time
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal `
            -Description "Nightly Active Directory system state backup to $target" -ErrorAction Stop | Out-Null

        Write-DeploymentLog -Level SUCCESS -Message "Nightly system state backup scheduled at $time to $target."
    }

    Complete-DeploymentLog
}
catch {
    Complete-DeploymentLog -Outcome 'ABORTED'
    throw
}
