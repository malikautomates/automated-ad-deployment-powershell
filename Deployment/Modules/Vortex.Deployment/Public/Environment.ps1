<#
    Host environment checks and waits. Everything here is about refusing to
    start work the server cannot finish, and about waiting for things properly
    instead of guessing with Start-Sleep.
#>

function Test-IsAdministrator {
    [CmdletBinding()]
    param()
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Administrator {
    [CmdletBinding()]
    param()
    if (-not (Test-IsAdministrator)) {
        throw 'This must run elevated. Right-click PowerShell and choose "Run as Administrator".'
    }
}

function Test-PendingReboot {
    <#
    .SYNOPSIS
        Reports whether Windows is waiting for a restart.

    .DESCRIPTION
        A pending reboot makes Install-ADDSForest refuse to run, and makes
        Rename-Computer behave unpredictably. Detecting it during preflight
        turns a confusing mid-pipeline failure into a clear instruction to
        reboot first.
    #>
    [CmdletBinding()]
    param()

    $reasons = [System.Collections.Generic.List[string]]::new()

    $keys = @{
        'Component Based Servicing' = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        'Windows Update'            = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
        'Pending computer rename'   = 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\JoinDomain'
    }
    foreach ($name in $keys.Keys) {
        if (Test-Path -LiteralPath $keys[$name]) { $reasons.Add($name) }
    }

    $sessionManager = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    $pendingRenames = Get-ItemProperty -LiteralPath $sessionManager -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue
    if ($pendingRenames -and $pendingRenames.PendingFileRenameOperations) {
        $reasons.Add('Pending file rename operations')
    }

    $active = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -Name ComputerName -ErrorAction SilentlyContinue).ComputerName
    $configured = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -Name ComputerName -ErrorAction SilentlyContinue).ComputerName
    if ($active -and $configured -and $active -ne $configured) {
        $reasons.Add("Computer rename pending ('$active' -> '$configured')")
    }

    return [pscustomobject]@{
        IsPending = ($reasons.Count -gt 0)
        Reasons   = $reasons.ToArray()
    }
}

function Test-DeploymentPrerequisite {
    <#
    .SYNOPSIS
        Read-only preflight. Changes nothing; reports what would stop the run.

    .DESCRIPTION
        Returns one object per check with a Status of Pass, Warn or Fail.
        Fail means the deployment cannot succeed and should not be started.
        Warn means it will probably work but something is worth knowing.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Config)

    $results = [System.Collections.Generic.List[pscustomobject]]::new()
    function Add-Check {
        param([string]$Name, [string]$Status, [string]$Detail)
        $results.Add([pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail })
    }

    # --- Identity and platform -------------------------------------------
    if (Test-IsAdministrator) {
        Add-Check 'Running elevated' 'Pass' ([Security.Principal.WindowsIdentity]::GetCurrent().Name)
    }
    else {
        Add-Check 'Running elevated' 'Fail' 'Start PowerShell with "Run as Administrator".'
    }

    $psVersion = $PSVersionTable.PSVersion
    if ($psVersion -ge [version]'5.1') {
        Add-Check 'PowerShell version' 'Pass' "$psVersion"
    }
    else {
        Add-Check 'PowerShell version' 'Fail' "$psVersion found; 5.1 or later required."
    }

    $os = Get-CimInstance Win32_OperatingSystem
    if ($os.ProductType -eq 1) {
        Add-Check 'Operating system' 'Fail' "$($os.Caption) is a client OS. Active Directory Domain Services requires Windows Server."
    }
    elseif ($os.ProductType -eq 2) {
        Add-Check 'Operating system' 'Warn' "$($os.Caption) is already a domain controller. Stage 2 will detect this and skip promotion."
    }
    else {
        Add-Check 'Operating system' 'Pass' "$($os.Caption) (build $($os.BuildNumber))"
    }

    $computerSystem = Get-CimInstance Win32_ComputerSystem
    if ($computerSystem.PartOfDomain) {
        Add-Check 'Domain membership' 'Warn' "Already joined to '$($computerSystem.Domain)'. This kit expects a standalone workgroup server."
    }
    else {
        Add-Check 'Domain membership' 'Pass' "Workgroup '$($computerSystem.Workgroup)'"
    }

    # --- Capacity ---------------------------------------------------------
    $memoryGb = [math]::Round($computerSystem.TotalPhysicalMemory / 1GB, 1)
    if ($memoryGb -lt 2) {
        Add-Check 'Memory' 'Fail' "$memoryGb GB. Windows Server 2022 with AD DS needs at least 2 GB; 4 GB recommended."
    }
    elseif ($memoryGb -lt 4) {
        Add-Check 'Memory' 'Warn' "$memoryGb GB. Workable, but 4 GB gives a much better experience."
    }
    else {
        Add-Check 'Memory' 'Pass' "$memoryGb GB"
    }

    $systemDrive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'"
    $freeGb = [math]::Round($systemDrive.FreeSpace / 1GB, 1)
    if ($freeGb -lt 10) {
        Add-Check 'Free disk space' 'Fail' "$freeGb GB free on $env:SystemDrive. At least 10 GB is needed for the AD database, IIS and logs."
    }
    elseif ($freeGb -lt 20) {
        Add-Check 'Free disk space' 'Warn' "$freeGb GB free on $env:SystemDrive."
    }
    else {
        Add-Check 'Free disk space' 'Pass' "$freeGb GB free on $env:SystemDrive"
    }

    # --- Pending state ----------------------------------------------------
    $pending = Test-PendingReboot
    if ($pending.IsPending) {
        Add-Check 'Pending reboot' 'Fail' "Restart before deploying. Reasons: $($pending.Reasons -join '; ')"
    }
    else {
        Add-Check 'Pending reboot' 'Pass' 'None detected.'
    }

    # --- Networking -------------------------------------------------------
    try {
        $adapter = Get-TargetAdapter -InterfaceAlias (Get-ConfigValue $Config.Network 'InterfaceAlias' '')
        Add-Check 'Network adapter' 'Pass' "$($adapter.Name) ($($adapter.InterfaceDescription))"

        $plan = Resolve-NetworkPlan -Config $Config -Adapter $adapter
        Add-Check 'Addressing plan' 'Pass' $plan.Summary

        if ($plan.Mode -eq 'Dhcp') {
            Add-Check 'Addressing mode' 'Warn' 'AddressingMode is Dhcp. A domain controller should hold a fixed address; the DNS client will still be pinned to this server.'
        }
    }
    catch {
        Add-Check 'Network adapter' 'Fail' $_.Exception.Message
    }

    try {
        $dnsTest = Resolve-DnsName -Name 'microsoft.com' -Type A -DnsOnly -QuickTimeout -ErrorAction Stop
        if ($dnsTest) { Add-Check 'Internet name resolution' 'Pass' 'Public DNS resolves. Forwarders will work.' }
    }
    catch {
        Add-Check 'Internet name resolution' 'Warn' 'Could not resolve a public name. The domain will still build; internet access from the VM may not work.'
    }

    # --- Configuration sanity --------------------------------------------
    $name = $Config.Server.ComputerName
    if ($env:COMPUTERNAME -eq $name) {
        Add-Check 'Target computer name' 'Pass' "Already '$name'."
    }
    else {
        Add-Check 'Target computer name' 'Pass' "Will rename '$env:COMPUTERNAME' -> '$name' in Stage 1."
    }

    if ($Config.Domain.DnsName -like '*.local') {
        Add-Check 'Domain name' 'Warn' "'$($Config.Domain.DnsName)' uses the .local suffix, which collides with mDNS/Bonjour, cannot hold a public certificate, and cannot be used directly for Entra ID hybrid sync. Acceptable for a lab; use a real routable name in production."
    }
    else {
        Add-Check 'Domain name' 'Pass' $Config.Domain.DnsName
    }

    $usersCsv = $Config.Paths.UsersCsv
    if (Test-Path -LiteralPath $usersCsv) {
        $rowCount = @(Import-Csv -LiteralPath $usersCsv).Count
        Add-Check 'User source data' 'Pass' "$rowCount user(s) in $usersCsv"
    }
    else {
        Add-Check 'User source data' 'Fail' "Not found: $usersCsv"
    }

    # --- Virtualisation ---------------------------------------------------
    if ($computerSystem.Manufacturer -match 'VMware') {
        $toolbox = Join-Path $env:ProgramFiles 'VMware\VMware Tools\VMwareToolboxCmd.exe'
        if (Test-Path -LiteralPath $toolbox) {
            Add-Check 'VMware Tools' 'Warn' 'Installed. Its host time synchronisation fights the Windows Time service on a domain controller; Stage 4 disables it.'
        }
        else {
            Add-Check 'VMware Tools' 'Warn' 'Not installed. Install it for a usable console (clipboard, screen resolution, clean shutdown).'
        }
    }

    return $results.ToArray()
}

function Install-DeploymentFeature {
    <#
    .SYNOPSIS
        Installs Windows roles and features, with a usable answer for 0x800f081f.

    .DESCRIPTION
        Install-WindowsFeature fails with 0x800f081f - "the source files could
        not be found" - when the component payload for a role is not present in
        the local side-by-side store and Windows cannot reach a repair source.
        It is common on evaluation and trimmed images, and on servers whose
        WinSxS store has been cleaned with /ResetBase.

        The cure is to point the installer at the side-by-side store on the
        Windows installation media. Set Features.SourcePath in configuration
        and it is used automatically, for example:

            Features = @{ SourcePath = 'wim:D:\sources\install.wim:4' }

        The trailing number is the image index matching the installed edition -
        find it with:

            Get-WindowsImage -ImagePath D:\sources\install.wim

        Already-installed features are skipped, so this is safe to re-run.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string[]] $Name,
        [switch] $IncludeManagementTools,
        [string] $SourcePath
    )

    $pending = @()
    foreach ($featureName in $Name) {
        $feature = Get-WindowsFeature -Name $featureName -ErrorAction Stop
        if (-not $feature) { throw "'$featureName' is not a recognised Windows feature on this server." }
        if ($feature.Installed) {
            Write-DeploymentLog -Level SKIP -Message "Feature '$featureName' is already installed."
            continue
        }
        $pending += $featureName
    }
    if ($pending.Count -eq 0) { return }

    if (-not $PSCmdlet.ShouldProcess(($pending -join ', '), 'Install Windows feature')) { return }

    $parameters = @{ Name = $pending; ErrorAction = 'Stop' }
    if ($IncludeManagementTools) { $parameters['IncludeManagementTools'] = $true }
    if ($SourcePath) {
        $parameters['Source'] = $SourcePath
        Write-DeploymentLog -Message "Installing $($pending -join ', ') using payload source '$SourcePath'."
    }

    $payloadMissing = {
        param($ErrorRecord)
        $text = "$($ErrorRecord.Exception.Message)"
        return ($text -match '0x800f081f' -or $text -match 'source files could not be found')
    }

    try {
        $result = Install-WindowsFeature @parameters
    }
    catch {
        if (-not (& $payloadMissing $_)) { throw }

        # 0x800f081f means the component payload is not in the local store and
        # Windows could not reach a repair source. Rather than stop and make
        # someone hand-type a source string, look for the installation media
        # that is almost always still attached to a freshly built VM.
        if ($SourcePath) {
            throw "Windows rejected the payload source '$SourcePath' for $($pending -join ', '). Check the path and that the image index matches this edition (Get-WindowsImage -ImagePath <path to install.wim>). Original error: $($_.Exception.Message)"
        }

        Write-DeploymentLog -Level WARN -Message "Component payload missing for $($pending -join ', ') (0x800f081f). Searching for Windows installation media..."
        $discovered = Find-WindowsPayloadSource

        if (-not $discovered) {
            throw (@(
                    "Windows could not find the component payload for: $($pending -join ', ') (0x800f081f),"
                    'and no usable Windows installation media is attached to this machine.'
                    ''
                    'This is a Windows servicing problem, not a configuration problem - the role binaries'
                    'are absent from this image, which is common on evaluation and trimmed builds.'
                    ''
                    'To fix it:'
                    '  1. Attach the Windows Server ISO to the VM (VM > Settings > CD/DVD > Use ISO image),'
                    '     and tick "Connected".'
                    '  2. Re-run the deployment - the media is detected automatically from here.'
                    ''
                    '  If detection still cannot pick an image (an unusual edition, say), set it explicitly:'
                    '       Get-WindowsImage -ImagePath D:\sources\install.wim'
                    '     then put the matching index in Config\DeploymentConfig.psd1:'
                    '       Features = @{ SourcePath = ''wim:D:\sources\install.wim:4'' }'
                    ''
                    "Original error: $($_.Exception.Message)"
                ) -join [Environment]::NewLine)
        }

        Write-DeploymentLog -Level SUCCESS -Message "Found installation media - retrying with payload source '$discovered'."
        $parameters['Source'] = $discovered

        try {
            $result = Install-WindowsFeature @parameters
        }
        catch {
            throw "Retry with the detected payload source '$discovered' also failed for $($pending -join ', '). The media may not match this edition. Run 'Get-WindowsImage -ImagePath <install.wim>' and set Features.SourcePath explicitly. Original error: $($_.Exception.Message)"
        }
    }

    if (-not $result.Success) {
        throw "Install-WindowsFeature reported failure for $($pending -join ', ') (exit code $($result.ExitCode))."
    }

    Write-DeploymentLog -Level SUCCESS -Message "Installed $($pending -join ', '). Restart needed: $($result.RestartNeeded)"
    return $result
}

function Wait-ForActiveDirectory {
    <#
    .SYNOPSIS
        Blocks until Active Directory actually answers queries.

    .DESCRIPTION
        A startup-triggered task fires as soon as the Task Scheduler service is
        running, which on a freshly promoted domain controller is well before
        Active Directory Web Services is ready to serve the AD PowerShell
        module. Polling for a real successful query is the only reliable test -
        the service being "Running" is not the same as being ready.

        This replaces the original scripts' Start-Sleep -Seconds 10, which was
        a guess that happened to work on the machine it was written on.
    #>
    [CmdletBinding()]
    param(
        [int] $TimeoutMinutes = 15,
        [int] $PollSeconds = 10
    )

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $attempt = 0
    while ((Get-Date) -lt $deadline) {
        $attempt++
        try {
            $domain = Get-ADDomain -ErrorAction Stop
            Write-DeploymentLog -Level SUCCESS -Message "Active Directory is responding (domain '$($domain.DNSRoot)', attempt $attempt)."
            return $domain
        }
        catch {
            $remaining = [int]($deadline - (Get-Date)).TotalSeconds
            Write-DeploymentLog -Message "Active Directory not ready yet (attempt $attempt, ${remaining}s budget left): $($_.Exception.Message)"
            Start-Sleep -Seconds $PollSeconds
        }
    }
    throw "Active Directory did not become available within $TimeoutMinutes minute(s). Check the ADWS and NTDS services, and the DC's own DNS client settings."
}

function Wait-ForService {
    <#
    .SYNOPSIS
        Waits for a service to reach a state, rather than sleeping and hoping.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [ValidateSet('Running', 'Stopped')] [string] $Status = 'Running',
        [int] $TimeoutSeconds = 180
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if ($service -and $service.Status -eq $Status) { return $service }
        Start-Sleep -Seconds 3
    }
    throw "Service '$Name' did not reach state '$Status' within $TimeoutSeconds seconds."
}
