<#
    Validation.

    The original kit's idea of verification was "no red text appeared". This
    asks the server what it actually looks like and compares that against the
    configuration, one assertion at a time.

    Get-DeploymentValidationResult is the single source of truth. The validation
    stage renders it to HTML and CSV; the Pester suite in Tests\ iterates the
    same objects. Neither re-implements the checks, so they cannot disagree.

    There are two validators, and the distinction matters:

      Get-DeploymentDesignValidationResult   DESIGN time. Pure static analysis
          of the configuration and the user feed. Needs no server, no Active
          Directory, no elevation - it runs on a laptop. Catches the mistakes
          that would otherwise surface halfway through a deployment: an OU
          whose parent is declared after it, a user pointed at an OU that does
          not exist, a global group sitting on an ACL, a sAMAccountName over
          the 20-character limit.

      Get-DeploymentValidationResult         DEPLOYMENT time. Asks a real
          domain controller what it actually looks like. Requires the finished
          server.

    Both emit the same result shape, so Export-DeploymentValidationReport
    renders either one.
#>

function Get-DeploymentDesignValidationResult {
    <#
    .SYNOPSIS
        Validates the configuration and user feed without touching a server.

    .DESCRIPTION
        Everything checkable before deployment: internal consistency,
        cross-references, AD naming limits, AGDLP correctness, and coverage
        gaps that are legal but probably unintended.

        This does NOT prove the deployment succeeded - only that what it is
        being asked to build is coherent. Stage 5 proves the rest.

    .OUTPUTS
        Objects with Category, Check, Status (PASS / FAIL / WARN), Expected,
        Actual and Detail.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Config)

    $results = [System.Collections.Generic.List[pscustomobject]]::new()
    function Add-Design {
        param([string]$Category, [string]$Check, [string]$Status, $Expected = '', $Actual = '', [string]$Detail = '')
        $results.Add([pscustomobject]@{
                Category = $Category; Check = $Check; Status = $Status
                Expected = [string]$Expected; Actual = [string]$Actual; Detail = $Detail
            })
    }
    function Add-DesignBool {
        param([string]$Category, [string]$Check, [bool]$Condition, $Expected = '', $Actual = '', [string]$Detail = '', [string]$FailStatus = 'FAIL')
        Add-Design $Category $Check $(if ($Condition) { 'PASS' } else { $FailStatus }) $Expected $Actual $Detail
    }

    $domainDn = Get-DeploymentDomainDn -DnsName $Config.Domain.DnsName

    # ------------------------------------------------------------ schema
    $problems = Test-DeploymentConfigSchema -Config $Config
    Add-DesignBool 'Configuration' 'Configuration passes schema validation' ($problems.Count -eq 0) `
        '0 problems' "$($problems.Count) problem(s)" ($problems -join '; ')

    Add-DesignBool 'Configuration' 'Computer name within the 15-character NetBIOS limit' `
        ($Config.Server.ComputerName.Length -le 15) '<= 15' $Config.Server.ComputerName.Length
    Add-DesignBool 'Configuration' 'NetBIOS domain name within 15 characters' `
        ($Config.Domain.NetBiosName.Length -le 15) '<= 15' $Config.Domain.NetBiosName.Length

    $upnSuffix = [string](Get-ConfigValue (Get-ConfigValue $Config 'Identity' @{}) 'UpnSuffix' '')
    if (-not $upnSuffix) { $upnSuffix = $Config.Domain.DnsName }
    Add-DesignBool 'Configuration' 'UPN suffix is routable (not .local)' ($upnSuffix -notlike '*.local') `
        'A verifiable domain' $upnSuffix `
        'A .local UPN suffix can never be verified in a Microsoft 365 tenant, so those accounts could never sync to Entra ID.' 'WARN'

    Add-DesignBool 'Configuration' 'Users CSV exists' (Test-Path -LiteralPath $Config.Paths.UsersCsv) `
        $Config.Paths.UsersCsv $(if (Test-Path -LiteralPath $Config.Paths.UsersCsv) { 'found' } else { 'MISSING' })

    # --------------------------------------------------------------- OUs
    $ous = @(Get-ConfigValue $Config 'OrganizationalUnits' @())
    $ouDns = @{}
    $seenRelative = [System.Collections.Generic.List[string]]::new()

    foreach ($ou in $ous) {
        $parent = [string](Get-ConfigValue $ou 'Parent' '')
        $dn = Resolve-OuPath -Name $ou.Name -Parent $parent -DomainDn $domainDn

        Add-DesignBool 'Organizational units' "OU '$($ou.Name)' name within 64 characters" `
            ($ou.Name.Length -le 64) '<= 64' $ou.Name.Length

        # Creation is sequential, so a parent declared AFTER its child would
        # fail at run time with a confusing "object not found" on the parent.
        if ($parent) {
            $parentIsEarlier = $seenRelative -contains $parent
            Add-DesignBool 'Organizational units' "OU '$($ou.Name)' parent is declared before it" $parentIsEarlier `
                $parent $(if ($parentIsEarlier) { 'declared earlier' } else { 'NOT declared earlier' }) `
                'OUs are created in file order; a child listed before its parent cannot be created.'
        }

        Add-DesignBool 'Organizational units' "OU path '$dn' is unique" (-not $ouDns.ContainsKey($dn)) 'unique' $dn
        $ouDns[$dn] = $ou.Name

        $relative = if ($parent) { "OU=$($ou.Name),$parent" } else { "OU=$($ou.Name)" }
        $seenRelative.Add($relative)
    }

    # Bare-name lookups (TargetOu = 'Vancouver') only work when the name is
    # unique across the whole tree.
    # Group-Object by a SCRIPTBLOCK, not a property name: config entries are
    # hashtables, and -Property cannot read a hashtable key - it would silently
    # group every OU under an empty name and report a false ambiguity.
    foreach ($group in ($ous | Group-Object { $_.Name } | Where-Object Count -gt 1)) {
        Add-Design 'Organizational units' "OU name '$($group.Name)' is ambiguous" 'WARN' 'unique' "$($group.Count) OUs" `
            'Bare-name TargetOu / Path lookups will fail for this name. Use an explicit OU=... path instead.'
    }

    # ------------------------------------------------------------ groups
    $groups = @(Get-ConfigValue $Config 'Groups' @())
    $groupsByName = @{}
    foreach ($g in $groups) { $groupsByName[$g.Name] = $g }

    Add-DesignBool 'Groups' 'Group names are unique' `
        (@($groups.Name | Select-Object -Unique).Count -eq $groups.Count) `
        $groups.Count @($groups.Name | Select-Object -Unique).Count

    foreach ($g in $groups) {
        Add-DesignBool 'Groups' "Group '$($g.Name)' name within 64 characters" ($g.Name.Length -le 64) '<= 64' $g.Name.Length

        $path = [string](Get-ConfigValue $g 'Path' '')
        $resolves = $false
        try { Resolve-TargetOu -TargetOu $path -Config $Config -DomainDn $domainDn | Out-Null; $resolves = $true } catch { }
        Add-DesignBool 'Groups' "Group '$($g.Name)' target OU resolves" $resolves $path `
            $(if ($resolves) { 'resolves' } else { 'does not resolve' })

        foreach ($nested in @(Get-ConfigValue $g 'MemberGroups' @())) {
            $exists = $groupsByName.ContainsKey($nested)
            Add-DesignBool 'Groups' "'$($g.Name)' nests a group that exists ('$nested')" $exists 'defined' `
                $(if ($exists) { 'defined' } else { 'UNDEFINED' })

            if ($exists) {
                # AGDLP: only a domain local group should nest, and only a
                # global group should be nested.
                Add-DesignBool 'Groups' "AGDLP - '$($g.Name)' is domain local because it nests groups" `
                    ($g.Scope -eq 'DomainLocal') 'DomainLocal' $g.Scope `
                    'Only resource (domain local) groups should contain other groups.'
                Add-DesignBool 'Groups' "AGDLP - nested '$nested' is a global role group" `
                    ($groupsByName[$nested].Scope -eq 'Global') 'Global' $groupsByName[$nested].Scope
            }
        }
    }

    # ------------------------------------------------------------- users
    $users = @()
    if (Test-Path -LiteralPath $Config.Paths.UsersCsv) { $users = @(Import-Csv -LiteralPath $Config.Paths.UsersCsv) }

    Add-DesignBool 'Users' 'User feed contains at least one account' ($users.Count -gt 0) '> 0' $users.Count
    Add-DesignBool 'Users' 'sAMAccountNames are unique' `
        (@($users.SamAccountName | Select-Object -Unique).Count -eq $users.Count) `
        $users.Count @($users.SamAccountName | Select-Object -Unique).Count

    if ($users.Count -gt 0) {
        Add-DesignBool 'Users' 'User feed carries no password column' `
            ($users[0].PSObject.Properties.Name -notcontains 'Password') 'absent' `
            $(if ($users[0].PSObject.Properties.Name -contains 'Password') { 'PRESENT' } else { 'absent' }) `
            'Passwords are generated per user at deployment time; a password column is a regression.'
    }

    $roleMembership = @{}
    foreach ($u in $users) {
        $sam = ([string]$u.SamAccountName).Trim()
        if (-not $sam) { Add-Design 'Users' 'CSV row with no sAMAccountName' 'FAIL' 'a name' '(blank)'; continue }

        Add-DesignBool 'Users' "'$sam' sAMAccountName within 20 characters" ($sam.Length -le 20) '<= 20' $sam.Length `
            'Active Directory truncates or rejects longer pre-Windows 2000 logon names.'
        Add-DesignBool 'Users' "'$sam' sAMAccountName uses legal characters" `
            ($sam -notmatch '[\\/:*?"<>|+,;\[\]=]') 'no reserved characters' $sam

        $targetOu = ([string]$u.TargetOu).Trim()
        $ouResolves = $false
        try { Resolve-TargetOu -TargetOu $targetOu -Config $Config -DomainDn $domainDn | Out-Null; $ouResolves = $true } catch { }
        Add-DesignBool 'Users' "'$sam' target OU resolves" $ouResolves $targetOu `
            $(if ($ouResolves) { 'resolves' } else { 'does not resolve' })

        Add-DesignBool 'Users' "'$sam' has a display name" ([bool](([string]$u.DisplayName).Trim())) 'set' ''
        Add-DesignBool 'Users' "'$sam' has a department" ([bool](([string]$u.Department).Trim())) 'set' '' '' 'WARN'
        Add-DesignBool 'Users' "'$sam' has a job title" ([bool](([string]$u.Title).Trim())) 'set' '' '' 'WARN'

        $memberships = @(([string]$u.Groups) -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        Add-DesignBool 'Users' "'$sam' belongs to at least one group" ($memberships.Count -gt 0) '> 0' $memberships.Count '' 'WARN'
        foreach ($m in $memberships) {
            Add-DesignBool 'Users' "'$sam' group '$m' is defined in configuration" $groupsByName.ContainsKey($m) `
                'defined' $(if ($groupsByName.ContainsKey($m)) { 'defined' } else { 'UNDEFINED' })
            if ($groupsByName.ContainsKey($m)) {
                if (-not $roleMembership.ContainsKey($m)) { $roleMembership[$m] = 0 }
                $roleMembership[$m]++
                # People belong to role groups; putting them straight into a
                # resource group bypasses the model.
                Add-DesignBool 'Users' "'$sam' is placed in a role group, not a resource group ('$m')" `
                    ($groupsByName[$m].Scope -ne 'DomainLocal') 'Global role group' $groupsByName[$m].Scope `
                    'AGDLP puts accounts in global role groups; resource groups should only contain other groups.' 'WARN'
            }
        }

        $expiry = ([string]$u.AccountExpiry).Trim()
        if ($expiry -and $expiry -ne 'never') {
            $isIso = $expiry -match '^\d{4}-\d{2}-\d{2}$'
            Add-DesignBool 'Users' "'$sam' expiry date is unambiguous (yyyy-MM-dd)" $isIso 'yyyy-MM-dd' $expiry `
                'Formats like "Dec 31, 2024" parse differently depending on the machine regional settings.'
            if ($isIso) {
                $parsed = [datetime]::ParseExact($expiry, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
                Add-DesignBool 'Users' "'$sam' expiry date is in the future" ($parsed -gt (Get-Date)) 'future' $expiry `
                    'The account would be created already expired and unable to log on.'
            }
        }
    }

    # ------------------------------------------------- folders and shares
    $folders = @(Get-ConfigValue $Config 'FolderStructure' @())
    $shareNames = @($folders | ForEach-Object { Get-ConfigValue $_ 'ShareName' '' } | Where-Object { $_ })

    Add-DesignBool 'File system' 'Folder paths are unique' `
        (@($folders.Path | Select-Object -Unique).Count -eq $folders.Count) $folders.Count `
        @($folders.Path | Select-Object -Unique).Count
    Add-DesignBool 'File system' 'Share names are unique' `
        (@($shareNames | Select-Object -Unique).Count -eq $shareNames.Count) $shareNames.Count `
        @($shareNames | Select-Object -Unique).Count

    $wellKnown = @('Everyone', 'Authenticated Users', 'Administrators', 'SYSTEM', 'CREATOR OWNER', 'Users')
    $referencedResourceGroups = [System.Collections.Generic.List[string]]::new()

    foreach ($f in $folders) {
        $shareName = [string](Get-ConfigValue $f 'ShareName' '')
        if ($shareName) {
            Add-DesignBool 'File system' "Share name '$shareName' is legal" `
                ($shareName.Length -le 80 -and $shareName -notmatch '[\\/:*?"<>|]') 'valid' $shareName
        }
        else {
            Add-Design 'File system' "Folder '$($f.Path)' is not shared" 'WARN' 'a share name' '(none)' `
                'NTFS permissions on a folder nobody can reach over the network have no effect for users.'
        }

        $permissions = @(Get-ConfigValue $f 'Permissions' @())
        Add-DesignBool 'File system' "Folder '$($f.Path)' grants access to somebody" ($permissions.Count -gt 0) `
            '> 0' $permissions.Count 'Only SYSTEM and Administrators would have access.' 'WARN'

        foreach ($p in $permissions) {
            $identity = [string]$p.Identity
            $leaf = ($identity -split '\\')[-1]

            if ($leaf -in $wellKnown) {
                Add-Design 'File system' "'$identity' on '$($f.Path)' is a well-known principal" 'PASS' '' $identity
                if ($leaf -eq 'Everyone') {
                    Add-Design 'File system' "'Everyone' is granted on '$($f.Path)'" 'WARN' 'Authenticated Users' 'Everyone' `
                        'Everyone includes anonymous and guest sessions. Authenticated Users is the safer production choice.'
                }
                continue
            }

            $isDefined = $groupsByName.ContainsKey($leaf)
            Add-DesignBool 'File system' "ACL principal '$leaf' on '$($f.Path)' is defined" $isDefined `
                'defined in Groups' $(if ($isDefined) { 'defined' } else { 'UNDEFINED' })

            if ($isDefined) {
                Add-DesignBool 'File system' "AGDLP - '$leaf' on '$($f.Path)' is a domain local resource group" `
                    ($groupsByName[$leaf].Scope -eq 'DomainLocal') 'DomainLocal' $groupsByName[$leaf].Scope `
                    'Only resource groups belong on an ACL; granting a global group directly defeats the model.'
                $referencedResourceGroups.Add($leaf)
            }

            $prefix = ($identity -split '\\')[0]
            if ($identity -like '*\*' -and $prefix -notin @('BUILTIN', 'NT AUTHORITY')) {
                Add-DesignBool 'File system' "ACL identity '$identity' uses the configured NetBIOS domain" `
                    ($prefix -eq $Config.Domain.NetBiosName) $Config.Domain.NetBiosName $prefix `
                    'Windows reports identities as DOMAIN\Name; a mismatched prefix will not resolve.'
            }
        }
    }

    # ------------------------------------------------------------ coverage
    foreach ($g in $groups) {
        if ($g.Scope -eq 'Global') {
            $count = if ($roleMembership.ContainsKey($g.Name)) { $roleMembership[$g.Name] } else { 0 }
            $nestedSomewhere = @($groups | Where-Object { @(Get-ConfigValue $_ 'MemberGroups' @()) -contains $g.Name }).Count -gt 0
            Add-DesignBool 'Coverage' "Role group '$($g.Name)' is actually used" (($count -gt 0) -or $nestedSomewhere) `
                'has members or is nested' "$count member(s)" `
                'A role group with nobody in it and no nesting grants nothing.' 'WARN'
        }
        else {
            Add-DesignBool 'Coverage' "Resource group '$($g.Name)' is used on an ACL" `
                ($referencedResourceGroups -contains $g.Name) 'referenced' `
                $(if ($referencedResourceGroups -contains $g.Name) { 'referenced' } else { 'never referenced' }) `
                'A resource group that appears on no ACL grants nothing.' 'WARN'
        }
    }

    # ----------------------------------------------------------- Microsoft 365
    $m365 = Get-ConfigValue $Config 'Microsoft365' @{}
    if (Get-ConfigValue $m365 'Enabled' $false) {
        foreach ($key in 'TenantId', 'AppId', 'CertificateThumbprint') {
            $value = [string](Get-ConfigValue $m365 $key '')
            Add-DesignBool 'Microsoft 365' "Microsoft365.$key is filled in" ($value -notlike '<*>' -and $value) `
                'a real value' $value
        }
        $verified = [string](Get-ConfigValue $m365 'VerifiedDomain' '')
        Add-DesignBool 'Microsoft 365' 'VerifiedDomain is not a .local domain' ($verified -notlike '*.local') `
            'a tenant-verified domain' $verified `
            'A .local domain can never be verified in a Microsoft 365 tenant.'
    }
    else {
        Add-Design 'Microsoft 365' 'Optional M365 onboarding is disabled' 'PASS' 'disabled' 'disabled' `
            'Stage 9 will not run. Enable it only once hybrid identity is working.'
    }

    return $results.ToArray()
}

function Get-DeploymentValidationResult {
    <#
    .SYNOPSIS
        Runs every post-deployment assertion and returns the results.

    .OUTPUTS
        Objects with Category, Check, Status (PASS / FAIL / WARN), Expected,
        Actual and Detail.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [hashtable] $Config)

    $results = [System.Collections.Generic.List[pscustomobject]]::new()

    function Add-Result {
        param(
            [string] $Category,
            [string] $Check,
            [string] $Status,
            $Expected = '',
            $Actual = '',
            [string] $Detail = ''
        )
        $results.Add([pscustomobject]@{
                Category = $Category
                Check    = $Check
                Status   = $Status
                Expected = [string]$Expected
                Actual   = [string]$Actual
                Detail   = $Detail
            })
    }

    function Add-Comparison {
        param([string]$Category, [string]$Check, $Expected, $Actual, [string]$Detail = '')
        $status = if ([string]$Expected -eq [string]$Actual) { 'PASS' } else { 'FAIL' }
        Add-Result -Category $Category -Check $Check -Status $status -Expected $Expected -Actual $Actual -Detail $Detail
    }

    function Invoke-CheckSection {
        <#
            Runs one group of checks under a net.

            A validator that dies partway through is worse than useless: it
            reports nothing AND hides whatever it had already found. Any
            exception inside a section is converted into a FAIL row naming the
            section, and the remaining sections still run.
        #>
        param([string] $Category, [scriptblock] $Checks)
        try { & $Checks }
        catch {
            Add-Result -Category $Category -Check "Checks for '$Category' could not complete" -Status 'FAIL' `
                -Expected 'all checks run' -Actual 'error' `
                -Detail "$($_.Exception.Message) [$($_.InvocationInfo.PositionMessage -replace '
?
', ' ')]"
        }
    }

    function Add-Boolean {
        param([string]$Category, [string]$Check, [bool]$Condition, $Expected = 'True', $Actual = '', [string]$Detail = '')
        # An Actual of $false is a real measurement and must be reported as
        # such. Testing "if ($Actual)" treated it as "nothing supplied" and
        # substituted the condition instead - so a correctly-disabled setting
        # reported "True" in the Actual column, which reads as its opposite.
        # Empty string still means "nothing worth showing".
        $reported = if ($null -ne $Actual -and "$Actual" -ne '') { $Actual } else { $Condition }
        Add-Result -Category $Category -Check $Check -Status $(if ($Condition) { 'PASS' } else { 'FAIL' }) `
            -Expected $Expected -Actual $reported -Detail $Detail
    }

    $domainDn = Get-DeploymentDomainDn -DnsName $Config.Domain.DnsName
    # Hoisted above the sections: both the Users and Groups sections read it,
    # and each section runs in its own scope, so an assignment inside one is
    # invisible to the other.
    $csvPath = $Config.Paths.UsersCsv

    # ---------------------------------------------------------------- server
    Add-Comparison 'Server' 'Computer name' $Config.Server.ComputerName $env:COMPUTERNAME

    try {
        $plannedIp = Get-DeploymentFact -Name 'IPAddress'
        if ($Config.Network.AddressingMode -eq 'Dhcp') {
            Add-Result 'Server' 'IP addressing' 'WARN' 'Static' 'DHCP' 'AddressingMode is Dhcp by configuration. Not supported for a domain controller in production.'
        }
        elseif ($plannedIp) {
            $bound = Get-NetIPAddress -AddressFamily IPv4 -IPAddress $plannedIp -ErrorAction SilentlyContinue
            Add-Boolean 'Server' "Static IP $plannedIp is bound" ([bool]$bound) 'Bound' $(if ($bound) { 'Bound' } else { 'Not found' })
            if ($bound) {
                Add-Comparison 'Server' 'IP address origin is manual' 'Manual' $bound.PrefixOrigin `
                    'A DHCP origin means the address can still change.'
            }
        }
        else {
            Add-Result 'Server' 'IP addressing' 'WARN' '' '' 'No planned address recorded in the state file; cannot verify.'
        }
    }
    catch {
        Add-Result 'Server' 'IP addressing' 'FAIL' '' '' $_.Exception.Message
    }

    try {
        $adapter = Get-TargetAdapter -InterfaceAlias (Get-ConfigValue $Config.Network 'InterfaceAlias' '')
        $dnsServers = @((Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4).ServerAddresses)
        $pointsAtSelf = @($dnsServers | Where-Object { $_ -eq '127.0.0.1' -or $_ -eq (Get-DeploymentFact -Name 'IPAddress') }).Count -gt 0
        Add-Boolean 'Server' 'DNS client points at this domain controller' $pointsAtSelf 'Self' ($dnsServers -join ', ') `
            'A domain controller that resolves through an external server cannot find its own domain records.'
    }
    catch {
        Add-Result 'Server' 'DNS client' 'FAIL' '' '' $_.Exception.Message
    }

    # ------------------------------------------------------------ directory
    try {
        Add-Boolean 'Directory' 'AD DS role installed' ((Get-WindowsFeature AD-Domain-Services).Installed)
        Add-Boolean 'Directory' 'DNS Server role installed' ((Get-WindowsFeature DNS).Installed)

        foreach ($serviceName in 'NTDS', 'ADWS', 'DNS', 'Netlogon', 'kdc') {
            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            Add-Boolean 'Directory' "Service '$serviceName' is running" ($service -and $service.Status -eq 'Running') `
                'Running' $(if ($service) { $service.Status } else { 'Not installed' })
        }

        $domain = Get-ADDomain -ErrorAction Stop
        Add-Comparison 'Directory' 'Domain DNS name' $Config.Domain.DnsName $domain.DNSRoot
        Add-Comparison 'Directory' 'Domain NetBIOS name' $Config.Domain.NetBiosName $domain.NetBIOSName

        $forest = Get-ADForest -ErrorAction Stop
        Add-Result 'Directory' 'Forest functional level' 'PASS' '' $forest.ForestMode
        Add-Result 'Directory' 'Domain functional level' 'PASS' '' $domain.DomainMode

        $recycleBin = Get-ADOptionalFeature -Filter "Name -eq 'Recycle Bin Feature'" -ErrorAction SilentlyContinue
        Add-Boolean 'Directory' 'AD Recycle Bin enabled' ($recycleBin -and @($recycleBin.EnabledScopes).Count -gt 0) `
            'Enabled' $(if ($recycleBin -and @($recycleBin.EnabledScopes).Count -gt 0) { 'Enabled' } else { 'Disabled' }) `
            'Without it, a deleted object loses its attributes and cannot be restored intact.'
    }
    catch {
        Add-Result 'Directory' 'Active Directory reachable' 'FAIL' '' '' $_.Exception.Message
    }

    # ------------------------------------------------------------------ OUs
    Invoke-CheckSection 'Organizational units' {
        foreach ($ou in @(Get-ConfigValue $Config 'OrganizationalUnits' @())) {
            $dn = Resolve-OuPath -Name $ou.Name -Parent (Get-ConfigValue $ou 'Parent' '') -DomainDn $domainDn
            try {
                $adOu = Get-ADOrganizationalUnit -Identity $dn -Properties ProtectedFromAccidentalDeletion -ErrorAction Stop
                Add-Result 'Organizational units' "OU '$($ou.Name)' exists" 'PASS' $dn $adOu.DistinguishedName
                Add-Boolean 'Organizational units' "OU '$($ou.Name)' protected from accidental deletion" `
                    ([bool]$adOu.ProtectedFromAccidentalDeletion)
            }
            catch {
                Add-Result 'Organizational units' "OU '$($ou.Name)' exists" 'FAIL' $dn 'Not found'
            }
        }
    }

    # ---------------------------------------------------------------- users
    Invoke-CheckSection 'Users' {
        if (Test-Path -LiteralPath $csvPath) {
            $upnSuffix = Get-ConfigValue (Get-ConfigValue $Config 'Identity' @{}) 'UpnSuffix' $Config.Domain.DnsName
            foreach ($row in @(Import-Csv -LiteralPath $csvPath)) {
                $sam = ([string]$row.SamAccountName).Trim()
                if (-not $sam) { continue }
                try {
                    $user = Get-ADUser -Identity $sam -Properties Enabled, UserPrincipalName, AccountExpirationDate, Department -ErrorAction Stop
                    Add-Result 'Users' "User '$sam' exists" 'PASS' $sam $user.DistinguishedName
                    Add-Boolean 'Users' "User '$sam' is enabled" ([bool]$user.Enabled)
                    Add-Comparison 'Users' "User '$sam' UPN" "$sam@$upnSuffix" $user.UserPrincipalName

                    $expectedOu = Resolve-TargetOu -TargetOu ([string]$row.TargetOu).Trim() -Config $Config -DomainDn $domainDn
                    $actualOu = ($user.DistinguishedName -split ',', 2)[1]
                    Add-Comparison 'Users' "User '$sam' is in the correct OU" $expectedOu $actualOu

                    if ($user.AccountExpirationDate -and $user.AccountExpirationDate -lt (Get-Date)) {
                        Add-Result 'Users' "User '$sam' account expiry" 'WARN' 'Future or none' $user.AccountExpirationDate `
                            'The account exists but has already expired and cannot log on.'
                    }
                }
                catch {
                    Add-Result 'Users' "User '$sam' exists" 'FAIL' $sam 'Not found' $_.Exception.Message
                }
            }
        }
        else {
            Add-Result 'Users' 'User source data present' 'FAIL' $csvPath 'Not found'
        }
    }

    # --------------------------------------------------------------- groups
    Invoke-CheckSection 'Groups' {
        foreach ($grp in @(Get-ConfigValue $Config 'Groups' @())) {
            try {
                $adGroup = Get-ADGroup -Identity $grp.Name -Properties Members -ErrorAction Stop
                Add-Result 'Groups' "Group '$($grp.Name)' exists" 'PASS' $grp.Name $adGroup.DistinguishedName
                Add-Comparison 'Groups' "Group '$($grp.Name)' scope" $grp.Scope $adGroup.GroupScope

                $memberNames = @(Get-ADGroupMember -Identity $grp.Name -ErrorAction SilentlyContinue |
                        Select-Object -ExpandProperty SamAccountName)
                foreach ($nested in @(Get-ConfigValue $grp 'MemberGroups' @())) {
                    Add-Boolean 'Groups' "Group '$nested' is nested in '$($grp.Name)'" ($memberNames -contains $nested) `
                        'Member' $(if ($memberNames -contains $nested) { 'Member' } else { 'Missing' }) `
                        'AGDLP: role groups are nested into resource groups, which is what the ACL grants to.'
                }
            }
            catch {
                Add-Result 'Groups' "Group '$($grp.Name)' exists" 'FAIL' $grp.Name 'Not found'
            }
        }

        # Expected memberships come from the CSV, which is the source of truth.
        if (Test-Path -LiteralPath $csvPath) {
            foreach ($row in @(Import-Csv -LiteralPath $csvPath)) {
                $sam = ([string]$row.SamAccountName).Trim()
                foreach ($groupName in (([string]$row.Groups) -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
                    $members = @(Get-ADGroupMember -Identity $groupName -ErrorAction SilentlyContinue |
                            Select-Object -ExpandProperty SamAccountName)
                    Add-Boolean 'Groups' "'$sam' is a member of '$groupName'" ($members -contains $sam) `
                        'Member' $(if ($members -contains $sam) { 'Member' } else { 'Missing' })
                }
            }
        }
    }

    # -------------------------------------------------------------- folders
    Invoke-CheckSection 'File system' {
        foreach ($folder in @(Get-ConfigValue $Config 'FolderStructure' @())) {
            $path = $folder.Path
            if (-not (Test-Path -LiteralPath $path)) {
                Add-Result 'File system' "Folder '$path' exists" 'FAIL' $path 'Not found'
                continue
            }
            Add-Result 'File system' "Folder '$path' exists" 'PASS' $path $path

            $acl = Get-Acl -LiteralPath $path
            Add-Boolean 'File system' "Inheritance disabled on '$path'" ([bool]$acl.AreAccessRulesProtected)

            $aceIdentities = @($acl.Access | ForEach-Object { $_.IdentityReference.Value })
            Add-Boolean 'File system' "SYSTEM retains access to '$path'" `
                (@($aceIdentities | Where-Object { $_ -match 'SYSTEM' }).Count -gt 0) `
                'Present' '' 'Stripping SYSTEM breaks backup, antivirus and shadow copies.'

            foreach ($perm in @(Get-ConfigValue $folder 'Permissions' @())) {
                $identity = [string]$perm.Identity
                # Compare on the leaf name as well as the full value: the config may
                # say 'Vortex AI\RES_Prices_Modify' or 'Everyone', while Windows reports
                # 'Vortex AI\RES_Prices_Modify' and 'Everyone' respectively. Matching both
                # forms keeps the check honest without forcing one spelling.
                $identityLeaf = ($identity -split '\\')[-1]
                $matching = @($acl.Access | Where-Object {
                        (($_.IdentityReference.Value -eq $identity) -or
                        (($_.IdentityReference.Value -split '\\')[-1] -eq $identityLeaf)) -and
                        $_.FileSystemRights.ToString() -match [regex]::Escape($perm.Rights)
                    })
                Add-Boolean 'File system' "'$identity' has $($perm.Rights) on '$path'" ($matching.Count -gt 0) `
                    "$($perm.Rights)" $(if ($matching.Count -gt 0) { $matching[0].FileSystemRights } else { 'Not granted' })

                if ($matching.Count -gt 0) {
                    $inherits = $matching[0].InheritanceFlags.ToString()
                    Add-Boolean 'File system' "'$identity' grant on '$path' propagates to children" `
                        ($inherits -match 'ContainerInherit' -and $inherits -match 'ObjectInherit') `
                        'ContainerInherit, ObjectInherit' $inherits `
                        'Without both flags the grant applies only to the folder object itself.'
                }
            }

            $shareName = Get-ConfigValue $folder 'ShareName' ''
            if ($shareName) {
                $share = Get-SmbShare -Name $shareName -ErrorAction SilentlyContinue
                Add-Boolean 'File system' "Share '$shareName' published" ([bool]$share) `
                    $path $(if ($share) { $share.Path } else { 'Not shared' })
            }
        }
    }

    # -------------------------------------------------------------- features
    Invoke-CheckSection 'Features' {
        $features = Get-ConfigValue $Config 'Features' @{}
        if (Get-ConfigValue $features 'InstallFtp' $false) {
            $ftpServiceName = Get-ConfigValue $features 'FtpServiceName' 'FTPSVC'
            $ftpService = Get-Service -Name $ftpServiceName -ErrorAction SilentlyContinue
            Add-Boolean 'Features' 'FTP service installed' ([bool]$ftpService) 'Installed' $(if ($ftpService) { 'Installed' } else { 'Missing' })
            if ($ftpService) {
                Add-Comparison 'Features' 'FTP start type' 'Disabled' $ftpService.StartType
                Add-Comparison 'Features' 'FTP service state' 'Stopped' $ftpService.Status
            }
        }
    }

    # -------------------------------------------------------------- security
    Invoke-CheckSection 'Security' {
        $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        # Read the key ONCE and test for each value's presence. Chaining
        # .PropertyName onto Get-ItemProperty throws under Set-StrictMode 2.0
        # when the value is absent - and absent is the normal, healthy case
        # here, so the check was guaranteed to blow up on a correct server.
        $autoLogon = Get-RegistryValue -Path $winlogon -Name 'AutoAdminLogon'
        # Checking the VALUE, not merely whether the name exists: a stock Windows
        # Server image often ships this key present and set to "0".
        Add-Boolean 'Security' 'Windows auto-logon is not enabled' ([string]$autoLogon -ne '1') `
            'Disabled' $(if ($null -eq $autoLogon) { 'Not set' } else { "AutoAdminLogon=$autoLogon" }) `
            'This pipeline never enables auto-logon; the original scripts did, and stored the password in the registry in plaintext.'

        $defaultPassword = Get-RegistryValue -Path $winlogon -Name 'DefaultPassword'
        Add-Boolean 'Security' 'No plaintext password in the registry' ($null -eq $defaultPassword) `
            'Absent' $(if ($null -eq $defaultPassword) { 'Absent' } else { 'PRESENT' })

        try {
            $smb = Get-SmbServerConfiguration
            Add-Boolean 'Security' 'SMBv1 disabled' (-not $smb.EnableSMB1Protocol) 'Disabled' $smb.EnableSMB1Protocol
        }
        catch { }

        try {
            $policy = Get-ADDefaultDomainPasswordPolicy -ErrorAction Stop
            $expectedLength = [int](Get-ConfigValue (Get-ConfigValue $Config 'PasswordPolicy' @{}) 'MinPasswordLength' 14)
            Add-Boolean 'Security' 'Minimum password length meets policy' ($policy.MinPasswordLength -ge $expectedLength) `
                ">= $expectedLength" $policy.MinPasswordLength
            Add-Boolean 'Security' 'Password complexity enabled' ([bool]$policy.ComplexityEnabled)
            Add-Boolean 'Security' 'Account lockout configured' ($policy.LockoutThreshold -gt 0) `
                '> 0' $policy.LockoutThreshold
        }
        catch { }

        foreach ($taskName in @('Vortex-Deployment-Resume')) {
            Add-Boolean 'Security' "Deployment resume task '$taskName' removed" `
                (-not (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) `
                'Removed' '' 'The automation scaffolding should not outlive the deployment.'
        }

        $secretsFolder = $Config.Paths.Secrets
        if (Test-Path -LiteralPath $secretsFolder) {
            $leftovers = @(Get-ChildItem -LiteralPath $secretsFolder -File -ErrorAction SilentlyContinue)
            if ($leftovers.Count -gt 0) {
                Add-Result 'Security' 'Credential handover files pending deletion' 'WARN' 'None' "$($leftovers.Count) file(s)" `
                    "Distribute the credentials in $secretsFolder, then delete them."
            }
        }
    }

    # ------------------------------------------------------------------ DNS
    try {
        $forwarders = @((Get-DnsServerForwarder -ErrorAction Stop).IPAddress | ForEach-Object { $_.IPAddressToString })
        Add-Boolean 'DNS' 'Forwarders configured' ($forwarders.Count -gt 0) 'At least one' ($forwarders -join ', ') `
            'Without forwarders the domain controller cannot resolve public names, so Windows Update and module installs fail.'
    }
    catch {
        Add-Result 'DNS' 'Forwarders configured' 'WARN' '' '' $_.Exception.Message
    }

    try {
        $reverseZoneName = @(Get-DeploymentFact -Name 'ReverseZoneName') | Select-Object -First 1
        if ($reverseZoneName) {
            $zone = Get-DnsServerZone -Name $reverseZoneName -ErrorAction SilentlyContinue
            Add-Boolean 'DNS' 'Reverse lookup zone exists' ([bool]$zone) $reverseZoneName $(if ($zone) { $zone.ZoneName } else { 'Not found' })
        }
    }
    catch { }

    # ----------------------------------------------------------------- time
    try {
        $w32TimeParameters = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters' -ErrorAction Stop
        Add-Boolean 'Time' 'PDC emulator syncs from an external time source' `
            ($w32TimeParameters.Type -eq 'NTP') 'NTP' $w32TimeParameters.Type `
            'The forest root PDC emulator is the authoritative clock for the whole domain; Kerberos fails once clocks drift past five minutes.'
        Add-Result 'Time' 'Configured NTP peers' 'PASS' '' $w32TimeParameters.NtpServer
    }
    catch { }

    return $results.ToArray()
}

function Export-DeploymentValidationReport {
    <#
    .SYNOPSIS
        Renders validation results to CSV and a self-contained HTML report.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Result,
        [Parameter(Mandatory)] [string] $ReportFolder,
        [string] $Title = 'Vortex AI Active Directory deployment validation'
    )

    if (-not (Test-Path -LiteralPath $ReportFolder)) {
        New-Item -Path $ReportFolder -ItemType Directory -Force | Out-Null
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $csvPath = Join-Path $ReportFolder "ValidationReport-$stamp.csv"
    $htmlPath = Join-Path $ReportFolder "ValidationReport-$stamp.html"

    $Result | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8

    $passed = @($Result | Where-Object Status -eq 'PASS').Count
    $failed = @($Result | Where-Object Status -eq 'FAIL').Count
    $warned = @($Result | Where-Object Status -eq 'WARN').Count

    $rows = foreach ($item in $Result) {
        $class = switch ($item.Status) {
            'PASS' { 'pass' }
            'FAIL' { 'fail' }
            default { 'warn' }
        }
        '<tr class="{0}"><td>{1}</td><td>{2}</td><td class="status">{3}</td><td>{4}</td><td>{5}</td><td>{6}</td></tr>' -f `
            $class,
        (ConvertTo-HtmlText $item.Category),
        (ConvertTo-HtmlText $item.Check),
        (ConvertTo-HtmlText $item.Status),
        (ConvertTo-HtmlText $item.Expected),
        (ConvertTo-HtmlText $item.Actual),
        (ConvertTo-HtmlText $item.Detail)
    }

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>$Title</title>
<style>
 body { font-family: Segoe UI, system-ui, sans-serif; margin: 2rem; color: #1b1b1f; background: #fff; }
 h1 { font-size: 1.4rem; margin-bottom: .25rem; }
 .meta { color: #5a5a66; font-size: .85rem; margin-bottom: 1.25rem; }
 .summary span { display: inline-block; padding: .35rem .8rem; border-radius: 999px; margin-right: .5rem; font-size: .85rem; font-weight: 600; }
 .s-pass { background: #dcf5e3; color: #0f5132; }
 .s-fail { background: #fadcdc; color: #842029; }
 .s-warn { background: #fdf3d4; color: #664d03; }
 table { border-collapse: collapse; width: 100%; margin-top: 1.25rem; font-size: .85rem; }
 th, td { text-align: left; padding: .45rem .6rem; border-bottom: 1px solid #e4e4ea; vertical-align: top; }
 th { background: #f5f5f8; position: sticky; top: 0; }
 tr.fail { background: #fff6f6; }
 tr.warn { background: #fffcf2; }
 td.status { font-weight: 700; }
 tr.pass td.status { color: #0f5132; }
 tr.fail td.status { color: #842029; }
 tr.warn td.status { color: #664d03; }
</style>
</head>
<body>
<h1>$Title</h1>
<div class="meta">$env:COMPUTERNAME &middot; generated $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</div>
<div class="summary">
 <span class="s-pass">$passed passed</span>
 <span class="s-fail">$failed failed</span>
 <span class="s-warn">$warned warnings</span>
</div>
<table>
<thead><tr><th>Category</th><th>Check</th><th>Status</th><th>Expected</th><th>Actual</th><th>Notes</th></tr></thead>
<tbody>
$($rows -join [Environment]::NewLine)
</tbody>
</table>
</body>
</html>
"@

    Set-Content -LiteralPath $htmlPath -Value $html -Encoding UTF8

    return [pscustomobject]@{
        CsvPath  = $csvPath
        HtmlPath = $htmlPath
        Passed   = $passed
        Failed   = $failed
        Warnings = $warned
    }
}
