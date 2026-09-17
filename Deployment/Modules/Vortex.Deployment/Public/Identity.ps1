<#
    Directory objects: the OU tree, users, and the group model.

    The group model is AGDLP, which is Microsoft's standard and the thing most
    lab scripts skip:

        Accounts  ->  Global group  ->  Domain Local group  ->  Permission

    Global groups describe who someone is ("MBsales"). Domain local groups
    describe what a resource allows ("RES_MBprices_Modify"). Only domain local
    groups ever appear on an ACL.

    The point is that access changes become membership changes. Granting a
    global group directly on a folder - which the original scripts did - means
    every future permission change is an ACL edit on a file server, and there is
    no single place to see who can reach what.
#>

function Resolve-OuPath {
    <#
    .SYNOPSIS
        Builds a full distinguished name for an OU from configuration.

    .PARAMETER Name
        The OU's own name.

    .PARAMETER Parent
        Relative parent path such as 'OU=Users,OU=VortexAI'. Empty means the OU sits
        directly under the domain root.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [string] $Parent,
        [Parameter(Mandatory)] [string] $DomainDn
    )

    if ([string]::IsNullOrWhiteSpace($Parent)) {
        return "OU=$Name,$DomainDn"
    }
    return "OU=$Name,$Parent,$DomainDn"
}

function Resolve-TargetOu {
    <#
    .SYNOPSIS
        Turns a CSV TargetOu value into a distinguished name.

    .DESCRIPTION
        Accepts either an explicit relative path ('OU=Sales,OU=Users,OU=VortexAI')
        or the bare name of an OU defined in configuration ('Sales'), which is
        friendlier to type in a spreadsheet. A bare name that matches more than
        one configured OU is an error rather than a guess.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $TargetOu,
        [Parameter(Mandatory)] [hashtable] $Config,
        [Parameter(Mandatory)] [string] $DomainDn
    )

    if ($TargetOu -match '^OU=') {
        return "$TargetOu,$DomainDn"
    }

    # Note: deliberately not named $matches - that is an automatic variable.
    $candidates = @(Get-ConfigValue $Config 'OrganizationalUnits' @() | Where-Object { $_.Name -eq $TargetOu })
    if ($candidates.Count -eq 0) {
        throw "TargetOu '$TargetOu' is not defined in OrganizationalUnits, and is not an explicit 'OU=...' path."
    }
    if ($candidates.Count -gt 1) {
        throw "TargetOu '$TargetOu' matches $($candidates.Count) configured OUs. Use an explicit 'OU=...,OU=...' path instead."
    }
    return Resolve-OuPath -Name $candidates[0].Name -Parent (Get-ConfigValue $candidates[0] 'Parent' '') -DomainDn $DomainDn
}

function New-DeploymentOuTree {
    <#
    .SYNOPSIS
        Creates the organisational unit structure.

    .DESCRIPTION
        OUs are created in configuration order, so parents must be listed before
        their children.

        Every OU is created with accidental-deletion protection on. That places
        an explicit Deny on delete operations - the single cheapest safeguard in
        Active Directory, and the reason most accidental mass-deletions get
        stopped at the first click.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [hashtable] $Config,
        [Parameter(Mandatory)] [string] $DomainDn
    )

    foreach ($ou in @(Get-ConfigValue $Config 'OrganizationalUnits' @())) {
        $parent = Get-ConfigValue $ou 'Parent' ''
        $dn = Resolve-OuPath -Name $ou.Name -Parent $parent -DomainDn $DomainDn

        if (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$dn'" -ErrorAction SilentlyContinue) {
            Write-DeploymentLog -Level SKIP -Message "OU already exists: $dn"
            continue
        }

        $parentPath = if ($parent) { "$parent,$DomainDn" } else { $DomainDn }
        if ($PSCmdlet.ShouldProcess($dn, 'Create organizational unit')) {
            New-ADOrganizationalUnit -Name $ou.Name -Path $parentPath `
                -Description (Get-ConfigValue $ou 'Description' '') `
                -ProtectedFromAccidentalDeletion $true -ErrorAction Stop
            Write-DeploymentLog -Message "Created OU: $dn"
        }
    }
}

function New-DeploymentGroupModel {
    <#
    .SYNOPSIS
        Creates the security groups and the global-into-domain-local nesting.

    .DESCRIPTION
        Runs in two passes. Every group object is created first, then nesting is
        applied, so a resource group may reference a role group that appears
        later in the configuration file.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [hashtable] $Config,
        [Parameter(Mandatory)] [string] $DomainDn
    )

    $groups = @(Get-ConfigValue $Config 'Groups' @())

    foreach ($grp in $groups) {
        if (Get-ADGroup -Filter "Name -eq '$($grp.Name)'" -ErrorAction SilentlyContinue) {
            Write-DeploymentLog -Level SKIP -Message "Group already exists: $($grp.Name)"
            continue
        }

        $path = Resolve-TargetOu -TargetOu (Get-ConfigValue $grp 'Path' 'Groups') -Config $Config -DomainDn $DomainDn
        if ($PSCmdlet.ShouldProcess($grp.Name, "Create $($grp.Scope) security group in $path")) {
            New-ADGroup -Name $grp.Name -SamAccountName $grp.Name `
                -GroupScope $grp.Scope -GroupCategory Security -Path $path `
                -Description (Get-ConfigValue $grp 'Description' '') -ErrorAction Stop
            Write-DeploymentLog -Message "Created $($grp.Scope) group '$($grp.Name)' in $path"
        }
    }

    foreach ($grp in $groups) {
        foreach ($nested in @(Get-ConfigValue $grp 'MemberGroups' @())) {
            $current = @(Get-ADGroupMember -Identity $grp.Name -ErrorAction SilentlyContinue | Select-Object -ExpandProperty SamAccountName)
            if ($current -contains $nested) {
                Write-DeploymentLog -Level SKIP -Message "'$nested' is already nested in '$($grp.Name)'."
                continue
            }
            if ($PSCmdlet.ShouldProcess($grp.Name, "Nest group '$nested'")) {
                Add-ADGroupMember -Identity $grp.Name -Members $nested -ErrorAction Stop
                Write-DeploymentLog -Message "Nested '$nested' into '$($grp.Name)' (AGDLP)."
            }
        }
    }
}

function Import-DeploymentUser {
    <#
    .SYNOPSIS
        Creates user accounts from the CSV feed and returns their credentials.

    .DESCRIPTION
        Treats the CSV as an HR feed: it carries identity attributes and group
        membership, and nothing about infrastructure.

        Each account gets its own generated password and is created enabled,
        with a forced password change at first logon, in its target OU, with a
        UPN. The original script's accounts were created disabled, with a shared
        password, in the default Users container, with no UPN - which is four
        separate reasons they were not usable accounts.

    .OUTPUTS
        One object per created account with Account, Secret and Purpose, for the
        credential handover file.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [hashtable] $Config,
        [Parameter(Mandatory)] [string] $DomainDn
    )

    $csvPath = $Config.Paths.UsersCsv
    if (-not (Test-Path -LiteralPath $csvPath)) {
        throw "User source data not found at $csvPath."
    }

    $identity = Get-ConfigValue $Config 'Identity' @{}
    $upnSuffix = Get-ConfigValue $identity 'UpnSuffix' $Config.Domain.DnsName
    $passwordLength = [int](Get-ConfigValue $identity 'PasswordLength' 20)
    $mustChange = [bool](Get-ConfigValue $identity 'RequirePasswordChangeAtLogon' $true)

    $created = [System.Collections.Generic.List[pscustomobject]]::new()
    $rows = @(Import-Csv -LiteralPath $csvPath)

    foreach ($row in $rows) {
        $sam = ([string]$row.SamAccountName).Trim()
        if (-not $sam) {
            Write-DeploymentLog -Level WARN -Message 'Skipping a CSV row with no SamAccountName.'
            continue
        }

        if (Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue) {
            Write-DeploymentLog -Level SKIP -Message "User already exists: $sam"
            continue
        }

        $ouDn = Resolve-TargetOu -TargetOu ([string]$row.TargetOu).Trim() -Config $Config -DomainDn $DomainDn

        # Expiry: blank or 'never' means no expiry. Anything else must be an
        # unambiguous yyyy-MM-dd so the file cannot be read differently on a
        # machine with different regional settings - the original data used
        # 'Dec 31, 2024', which only parses under specific cultures.
        $expiry = $null
        $rawExpiry = ([string]$row.AccountExpiry).Trim()
        if ($rawExpiry -and $rawExpiry -ne 'never') {
            $parsed = [datetime]::MinValue
            $ok = [datetime]::TryParseExact($rawExpiry, 'yyyy-MM-dd',
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::None, [ref]$parsed)
            if (-not $ok) {
                throw "User '$sam' has AccountExpiry '$rawExpiry', which is not in yyyy-MM-dd format."
            }
            $expiry = $parsed
            if ($expiry -lt (Get-Date)) {
                Write-DeploymentLog -Level WARN -Message "User '$sam' has an expiry date in the past ($rawExpiry). The account will be created but immediately unusable. Update Users.csv if that is not intended."
            }
        }

        $password = New-RandomPassword -Length $passwordLength
        $securePassword = ConvertTo-SecureString -String $password -AsPlainText -Force

        $displayName = ([string]$row.DisplayName).Trim()
        if (-not $displayName) { $displayName = (("$($row.GivenName) $($row.Surname)").Trim()) }
        if (-not $displayName) { $displayName = $sam }

        $parameters = @{
            Name                  = $displayName
            SamAccountName        = $sam
            UserPrincipalName     = "$sam@$upnSuffix"
            DisplayName           = $displayName
            Path                  = $ouDn
            AccountPassword       = $securePassword
            Enabled               = $true
            ChangePasswordAtLogon = $mustChange
            ErrorAction           = 'Stop'
        }

        # Only send attributes that actually have a value; New-ADUser rejects
        # empty strings for several of these.
        $optional = @{
            GivenName   = $row.GivenName
            Surname     = $row.Surname
            Description = $row.Description
            Title       = $row.Title
            Department  = $row.Department
            Office      = $row.Office
            City        = $row.City
            State       = $row.Province
            Country     = $row.Country
            Company     = Get-ConfigValue $identity 'Company' ''
        }
        foreach ($key in $optional.Keys) {
            $value = ([string]$optional[$key]).Trim()
            if ($value) { $parameters[$key] = $value }
        }
        if ($expiry) { $parameters['AccountExpirationDate'] = $expiry }

        if ($PSCmdlet.ShouldProcess($sam, "Create user in $ouDn")) {
            New-ADUser @parameters
            Write-DeploymentLog -Message "Created user '$sam' ($displayName) in $ouDn"

            $created.Add([pscustomobject]@{
                    Account = $sam
                    Secret  = $password
                    Purpose = 'Initial password - must be changed at first logon'
                })
        }

        foreach ($groupName in (([string]$row.Groups) -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
            if (-not (Get-ADGroup -Filter "Name -eq '$groupName'" -ErrorAction SilentlyContinue)) {
                Write-DeploymentLog -Level WARN -Message "User '$sam' lists group '$groupName', which does not exist. Skipping that membership."
                continue
            }
            $existing = @(Get-ADGroupMember -Identity $groupName -ErrorAction SilentlyContinue | Select-Object -ExpandProperty SamAccountName)
            if ($existing -contains $sam) { continue }

            if ($PSCmdlet.ShouldProcess($sam, "Add to group '$groupName'")) {
                Add-ADGroupMember -Identity $groupName -Members $sam -ErrorAction Stop
                Write-DeploymentLog -Message "Added '$sam' to '$groupName'."
            }
        }
    }

    Write-DeploymentLog -Level SUCCESS -Message "Processed $($rows.Count) CSV row(s); created $($created.Count) new account(s)."
    return $created.ToArray()
}
