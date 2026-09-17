<#
    Internal helpers. Not exported - these are implementation details the
    stage scripts should never call directly.
#>

function Test-DeploymentConfigSchema {
    <#
        Validates the whole configuration up front and reports EVERY problem at
        once, rather than failing on the first one and making the operator
        re-run to discover the next. A bad config should never survive long
        enough to half-configure a domain controller.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Config)

    $problems = [System.Collections.Generic.List[string]]::new()

    $requiredPaths = @(
        'Domain.DnsName'
        'Domain.NetBiosName'
        'Network.AddressingMode'
        'Server.ComputerName'
        'Paths.DeploymentRoot'
        'Paths.UsersCsv'
    )
    foreach ($path in $requiredPaths) {
        $node = $Config
        $ok = $true
        foreach ($segment in ($path -split '\.')) {
            if ($null -eq $node -or -not ($node -is [hashtable]) -or -not $node.ContainsKey($segment)) {
                $problems.Add("Missing required setting: $path")
                $ok = $false
                break
            }
            $node = $node[$segment]
        }
        if ($ok -and [string]::IsNullOrWhiteSpace([string]$node)) {
            $problems.Add("Required setting '$path' is present but empty.")
        }
    }

    $domain = Get-ConfigValue $Config 'Domain'
    if ($domain) {
        $dns = [string](Get-ConfigValue $domain 'DnsName' '')
        if ($dns -and $dns -notmatch '^[A-Za-z0-9]([A-Za-z0-9\-\.]*[A-Za-z0-9])?$') {
            $problems.Add("Domain.DnsName '$dns' is not a valid DNS name.")
        }
        if ($dns -and $dns -notlike '*.*') {
            $problems.Add("Domain.DnsName '$dns' is single-label. Single-label AD domains are unsupported by Microsoft and break client DNS resolution.")
        }
        $netbios = [string](Get-ConfigValue $domain 'NetBiosName' '')
        if ($netbios.Length -gt 15) {
            $problems.Add("Domain.NetBiosName '$netbios' exceeds the 15-character NetBIOS limit.")
        }
        if ($netbios -and $netbios -match '[^A-Za-z0-9\-]') {
            $problems.Add("Domain.NetBiosName '$netbios' contains characters illegal in a NetBIOS name.")
        }
    }

    $server = Get-ConfigValue $Config 'Server'
    if ($server) {
        $name = [string](Get-ConfigValue $server 'ComputerName' '')
        if ($name.Length -gt 15) {
            $problems.Add("Server.ComputerName '$name' exceeds the 15-character computer name limit.")
        }
        if ($name -and $name -match '[^A-Za-z0-9\-]') {
            $problems.Add("Server.ComputerName '$name' contains illegal characters. Use letters, digits and hyphens only.")
        }
    }

    $network = Get-ConfigValue $Config 'Network'
    if ($network) {
        $mode = [string](Get-ConfigValue $network 'AddressingMode' '')
        $validModes = @('PinCurrentLease', 'Static', 'Dhcp')
        if ($mode -and $mode -notin $validModes) {
            $problems.Add("Network.AddressingMode '$mode' is invalid. Valid values: $($validModes -join ', ').")
        }
        if ($mode -eq 'Static') {
            foreach ($key in 'IPAddress', 'PrefixLength', 'DefaultGateway') {
                if (-not (Get-ConfigValue $network $key)) {
                    $problems.Add("Network.$key is required when AddressingMode is 'Static'.")
                }
            }
        }
        foreach ($key in 'IPAddress', 'DefaultGateway') {
            $value = [string](Get-ConfigValue $network $key '')
            if ($value) {
                $parsed = [ipaddress]::Any
                if (-not [ipaddress]::TryParse($value, [ref]$parsed)) {
                    $problems.Add("Network.$key '$value' is not a valid IP address.")
                }
            }
        }
        $prefix = Get-ConfigValue $network 'PrefixLength' 0
        if ($prefix -and ($prefix -lt 1 -or $prefix -gt 32)) {
            $problems.Add("Network.PrefixLength '$prefix' must be between 1 and 32.")
        }
    }

    foreach ($ou in @(Get-ConfigValue $Config 'OrganizationalUnits' @())) {
        if (-not (Get-ConfigValue $ou 'Name')) {
            $problems.Add('Every OrganizationalUnits entry requires a Name.')
        }
    }

    $allGroupNames = [System.Collections.Generic.List[string]]::new()
    foreach ($grp in @(Get-ConfigValue $Config 'Groups' @())) {
        $groupName = Get-ConfigValue $grp 'Name'
        if (-not $groupName) { $problems.Add('Every Groups entry requires a Name.'); continue }
        $allGroupNames.Add($groupName)
        $scope = Get-ConfigValue $grp 'Scope'
        if ($scope -notin @('Global', 'DomainLocal', 'Universal')) {
            $problems.Add("Group '$groupName' has invalid Scope '$scope'. Valid: Global, DomainLocal, Universal.")
        }
    }
    # AGDLP sanity: a resource (domain local) group should only ever nest
    # groups that actually exist in this configuration.
    foreach ($grp in @(Get-ConfigValue $Config 'Groups' @())) {
        foreach ($nested in @(Get-ConfigValue $grp 'MemberGroups' @())) {
            if ($nested -notin $allGroupNames) {
                $problems.Add("Group '$(Get-ConfigValue $grp 'Name')' nests '$nested', which is not defined in Groups.")
            }
        }
    }

    $validRights = [enum]::GetNames([System.Security.AccessControl.FileSystemRights])
    foreach ($folder in @(Get-ConfigValue $Config 'FolderStructure' @())) {
        $folderPath = Get-ConfigValue $folder 'Path'
        if (-not $folderPath) { $problems.Add('Every FolderStructure entry requires a Path.'); continue }
        foreach ($perm in @(Get-ConfigValue $folder 'Permissions' @())) {
            $rights = [string](Get-ConfigValue $perm 'Rights' '')
            if ($rights -notin $validRights) {
                $problems.Add("Folder '$folderPath': '$rights' is not a valid FileSystemRights value.")
            }
            if (-not (Get-ConfigValue $perm 'Identity')) {
                $problems.Add("Folder '$folderPath' has a permission entry with no Identity.")
            }
        }
    }

    return , $problems.ToArray()
}

function ConvertTo-HashtableDeep {
    <#
        ConvertFrom-Json on PowerShell 5.1 returns PSCustomObject graphs, which
        have no ContainsKey and cannot take new keys cleanly. The state file is
        easier to work with as nested hashtables, so normalise on load.
    #>
    [CmdletBinding()]
    param($InputObject)

    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string] -and $InputObject -isnot [hashtable]) {
        $list = @()
        foreach ($item in $InputObject) { $list += , (ConvertTo-HashtableDeep -InputObject $item) }
        return , $list
    }

    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $result = @{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $result[$property.Name] = ConvertTo-HashtableDeep -InputObject $property.Value
        }
        return $result
    }

    if ($InputObject -is [hashtable]) {
        $result = @{}
        foreach ($key in $InputObject.Keys) {
            $result[$key] = ConvertTo-HashtableDeep -InputObject $InputObject[$key]
        }
        return $result
    }

    return $InputObject
}

function Get-RegistryValue {
    <#
        Reads one registry value, returning $null when the key or the value does
        not exist.

        The obvious idiom - (Get-ItemProperty -Path X -Name Y).Y - is a trap
        under Set-StrictMode 2.0, which treats reading a property that is not
        there as a terminating error. For checks whose healthy answer is "that
        value is absent", the obvious idiom fails exactly when the system is
        correct.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Name
    )

    $key = Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $key) { return $null }
    if ($key.PSObject.Properties.Name -notcontains $Name) { return $null }
    return $key.$Name
}

function ConvertTo-HtmlText {
    <#
        Minimal HTML escaping. Deliberately not System.Web.HttpUtility, which
        needs an assembly that is not loaded by default and is absent on Server
        Core installations.
    #>
    [CmdletBinding()]
    param([AllowNull()] [AllowEmptyString()] [string] $Text)

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}

function Write-DeploymentEventLog {
    <#
        Mirrors significant events into the Windows Application log so an
        unattended stage that fails at 03:00 is visible to monitoring, not just
        to whoever remembers to open a text file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('Information', 'Warning', 'Error')] [string] $EntryType = 'Information',
        [int] $EventId = 1000
    )
    $source = 'Vortex-ADDeployment'
    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists($source)) {
            New-EventLog -LogName Application -Source $source -ErrorAction Stop
        }
        $trimmed = $Message
        if ($trimmed.Length -gt 30000) { $trimmed = $trimmed.Substring(0, 30000) }
        Write-EventLog -LogName Application -Source $source -EntryType $EntryType -EventId $EventId -Message $trimmed -ErrorAction Stop
    }
    catch {
        # Event logging must never be the reason a deployment fails.
    }
}

function Find-WindowsPayloadSource {
    <#
        Locates the Windows installation media and works out which image index
        matches the running edition, so a role install that fails for want of
        payload (0x800f081f) can repair itself without anyone hand-typing a
        source string.

        Returns a source string such as 'wim:D:\sources\install.wim:4', or
        $null when no usable media is attached or the edition is ambiguous. The
        caller is expected to cope with $null rather than assume success.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $images = @()
    foreach ($volume in (Get-CimInstance Win32_LogicalDisk -ErrorAction SilentlyContinue)) {
        if (-not $volume.DeviceID) { continue }
        foreach ($leaf in 'install.wim', 'install.esd') {
            $candidate = Join-Path $volume.DeviceID (Join-Path 'sources' $leaf)
            if (-not (Test-Path -LiteralPath $candidate)) { continue }
            try {
                foreach ($image in (Get-WindowsImage -ImagePath $candidate -ErrorAction Stop)) {
                    $images += [pscustomobject]@{
                        Path  = $candidate
                        Index = $image.ImageIndex
                        Name  = $image.ImageName
                    }
                }
            }
            catch {
                # An unreadable image is not fatal - keep looking.
            }
        }
    }

    if (@($images).Count -eq 0) { return $null }

    # Narrow by edition. The running Caption looks like
    # "Microsoft Windows Server 2022 Datacenter Evaluation"; image names look
    # like "Windows Server 2022 Datacenter Evaluation (Desktop Experience)".
    $caption = (Get-CimInstance Win32_OperatingSystem).Caption -replace '^Microsoft\s+', ''
    $editionMatches = @($images | Where-Object { $_.Name -like "$caption*" })

    if (@($editionMatches).Count -eq 0) {
        # Fall back to matching on the distinguishing edition word only.
        foreach ($edition in 'Datacenter', 'Standard') {
            if ($caption -match $edition) {
                $editionMatches = @($images | Where-Object { $_.Name -match $edition })
                break
            }
        }
    }
    if (@($editionMatches).Count -eq 0) { return $null }

    # Server Core has no Explorer shell. Desktop Experience images are named
    # with that suffix; Core images are not.
    $isDesktopExperience = Test-Path -LiteralPath (Join-Path $env:SystemRoot 'explorer.exe')
    # Assigned INSIDE each branch, not from the if-expression as a whole.
    # PowerShell unrolls a single-element array when it is the output of a
    # scriptblock, so "$x = if (...) { @(...) }" silently yields a scalar when
    # the filter matches exactly one item - which is the normal case here.
    if ($isDesktopExperience) {
        $flavoured = @($editionMatches | Where-Object { $_.Name -match 'Desktop Experience' })
    }
    else {
        $flavoured = @($editionMatches | Where-Object { $_.Name -notmatch 'Desktop Experience' })
    }
    if (@($flavoured).Count -gt 0) { $editionMatches = @($flavoured) }

    if (@($editionMatches).Count -ne 1) { return $null }

    $chosen = @($editionMatches)[0]
    return "wim:$($chosen.Path):$($chosen.Index)"
}

function Set-RestrictiveFileAcl {
    <#
        Restricts a single file to Administrators and SYSTEM, without touching
        the directory it sits in. Used for anything holding a secret, so the
        protection travels with the file rather than depending on where it
        happens to live.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access | Where-Object { -not $_.IsInherited })) {
        $acl.RemoveAccessRule($rule) | Out-Null
    }
    foreach ($identity in 'BUILTIN\Administrators', 'NT AUTHORITY\SYSTEM') {
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $identity, 'FullControl', 'Allow')))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
}

function New-ProtectedDirectory {
    <#
        Creates a directory readable only by Administrators and SYSTEM. Used for
        anything holding secrets (temporary passwords, the DSRM password) so a
        non-admin who can browse the deployment root still cannot read them.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) { $acl.RemoveAccessRule($rule) | Out-Null }
    foreach ($identity in 'BUILTIN\Administrators', 'NT AUTHORITY\SYSTEM') {
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
    return $Path
}
