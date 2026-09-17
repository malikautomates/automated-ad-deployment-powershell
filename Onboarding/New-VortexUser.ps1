#Requires -Version 5.1
<#
.SYNOPSIS
    Onboards one new starter: Active Directory account, group membership,
    Microsoft 365 account, and a licence.

.DESCRIPTION
    A day-two tool, not part of the deployment pipeline. Run it once per new
    hire, from the domain controller or any machine with RSAT.

    It does four things:

      1. Creates the AD account in the right branch OU, with a generated
         password and a UPN that matches the Microsoft 365 tenant.
      2. Adds them to their three role groups - all-staff, department and
         branch - so file access follows automatically through AGDLP.
      3. Finds or creates their Microsoft 365 account.
      4. Sets usage location, assigns a licence, and adds them to the
         department's Microsoft 365 group.

    Step 3 deliberately looks before it creates. In a hybrid environment
    Entra Connect has already made the cloud account and creating another
    would produce a duplicate; in a cloud-only tenant nothing has, so one is
    needed. Checking first means the same script is correct either way.

    The OU tree, group names and UPN suffix are read from
    Config\DeploymentConfig.psd1, so this script and the deployment cannot
    disagree about how the directory is laid out.

.PARAMETER Branch
    Which office. Determines the OU and the branch role group.

.PARAMETER Department
    Determines the department role group and the Microsoft 365 group.

.PARAMETER SamAccountName
    Logon name. Defaults to first initial + surname, lowercased, with a
    number appended if that is already taken.

.PARAMETER LicenseSku
    SKU part number to assign, e.g. SPE_E5, ENTERPRISEPACK, EMS. Run with
    -ListLicenses to see what the tenant actually owns and how many seats
    are free. Pass 'None' to skip licensing.

.PARAMETER SkipCloud
    Create the AD account and group memberships only. Use this when Entra
    Connect will handle the cloud side, or when you have no tenant access.

.PARAMETER ListLicenses
    Print the tenant's SKUs and available seats, then exit. Changes nothing.

.PARAMETER SkipModuleInstall
    Do not install the Microsoft Graph modules automatically. The script will
    stop with the exact Install-Module command instead. For servers where
    software arrives through a managed process rather than the Gallery.

.EXAMPLE
    .\New-VortexUser.ps1 -FirstName Ada -LastName Okonkwo -Branch Vancouver `
        -Department Finance -JobTitle 'Financial Analyst'

.EXAMPLE
    .\New-VortexUser.ps1 -FirstName Ada -LastName Okonkwo -Branch Calgary `
        -Department IT -JobTitle 'Support Analyst' -WhatIf
    Shows every action without performing any of them.

.EXAMPLE
    .\New-VortexUser.ps1 -ListLicenses
    Shows which licences the tenant owns and how many seats are free.

.NOTES
    Prerequisites are handled automatically. On first run the script installs
    the five Microsoft Graph modules it uses, enabling TLS 1.2 and adding the
    NuGet provider first - both of which otherwise fail on a fresh Windows
    Server with an error that does not mention either. Expect a few minutes
    the first time; every run after that finds them present and skips.

    It installs to AllUsers when elevated, CurrentUser otherwise. Use
    -SkipModuleInstall to opt out, or install by hand with:

        Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Users,
                       Microsoft.Graph.Users.Actions, Microsoft.Graph.Groups,
                       Microsoft.Graph.Identity.DirectoryManagement -Scope AllUsers

    Only those five sub-modules are used, not the full Microsoft.Graph
    meta-module, which pulls in around forty and takes far longer for no gain.

    Sign-in is interactive, which suits a tool a person runs. For unattended
    use, swap Connect-MgGraph for certificate-based app authentication - see
    Scripts\9-OnboardMicrosoft365.ps1 in this kit.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, ParameterSetName = 'Create')]
    [string] $FirstName,

    [Parameter(Mandatory, ParameterSetName = 'Create')]
    [string] $LastName,

    [Parameter(Mandatory, ParameterSetName = 'Create')]
    [ValidateSet('Winnipeg', 'Vancouver', 'Calgary')]
    [string] $Branch,

    [Parameter(Mandatory, ParameterSetName = 'Create')]
    [ValidateSet('Executive', 'IT', 'Finance', 'HR', 'Sales', 'Marketing', 'Operations')]
    [string] $Department,

    [Parameter(Mandatory, ParameterSetName = 'Create')]
    [string] $JobTitle,

    [Parameter(ParameterSetName = 'Create')]
    [string] $SamAccountName,

    [Parameter(ParameterSetName = 'Create')]
    [string] $Manager,

    [Parameter(ParameterSetName = 'Create')]
    [string] $LicenseSku = 'SPE_E5',

    [Parameter(ParameterSetName = 'Create')]
    [switch] $SkipCloud,

    # Mirror of -SkipCloud: do the Microsoft 365 half only. For finishing an
    # onboarding whose cloud steps failed after the AD account was created.
    [Parameter(ParameterSetName = 'Create')]
    [switch] $SkipAD,

    [Parameter(Mandatory, ParameterSetName = 'List')]
    [switch] $ListLicenses,

    # Opt out of the automatic module install - for locked-down servers where
    # software is delivered by another process.
    [switch] $SkipModuleInstall,

    [string] $ConfigPath
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
#  Small helpers
# ---------------------------------------------------------------------------

function Write-Step {
    param([string] $Message, [ValidateSet('Info', 'Good', 'Warn', 'Skip')] [string] $Level = 'Info')
    $colour = @{ Info = 'White'; Good = 'Green'; Warn = 'Yellow'; Skip = 'DarkGray' }[$Level]
    $prefix = @{ Info = '  ->'; Good = '  OK'; Warn = '  !!'; Skip = '  --' }[$Level]
    Write-Host "$prefix $Message" -ForegroundColor $colour
}

function New-TempPassword {
    <#
        Cryptographic RNG, not Get-Random, because this is a credential.
        Characters that are misread when typed from a note are left out
        (O/o/0 and l/1/I/i), and one character of each required class is
        placed first so Windows complexity is met by construction rather
        than by luck.
    #>
    param([int] $Length = 16)

    $upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower = 'abcdefghjkmnpqrstuvwxyz'
    $digit = '23456789'
    $symbol = '!#%+-=?@_'
    $all = $upper + $lower + $digit + $symbol

    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $pick = {
            param($set)
            $bytes = New-Object byte[] 4
            $rng.GetBytes($bytes)
            $set[[int]([BitConverter]::ToUInt32($bytes, 0) % [uint32]$set.Length)]
        }
        $chars = [System.Collections.Generic.List[char]]::new()
        foreach ($set in $upper, $lower, $digit, $symbol) { $chars.Add((& $pick $set)) }
        while ($chars.Count -lt $Length) { $chars.Add((& $pick $all)) }

        for ($i = $chars.Count - 1; $i -gt 0; $i--) {
            $bytes = New-Object byte[] 4
            $rng.GetBytes($bytes)
            $j = [int]([BitConverter]::ToUInt32($bytes, 0) % [uint32]($i + 1))
            $swap = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $swap
        }
        return -join $chars
    }
    finally { $rng.Dispose() }
}

function Assert-GraphModule {
    <#
        Makes sure the Microsoft Graph modules this script needs are present,
        installing them from the PowerShell Gallery if they are not.

        Three things bite on a freshly built Windows Server and are handled
        here, because none of them produce an error that names the real cause:

          - PowerShell 5.1 negotiates TLS 1.0 by default. The Gallery refused
            that years ago, so the download fails with a vague "unable to
            connect" instead of anything about protocols.
          - The NuGet provider is absent, and Install-Module stops to ask for
            it interactively - which hangs a script nobody is watching.
          - PSGallery is untrusted by default, producing a second prompt.

        Installs to AllUsers when elevated so scheduled tasks and other admins
        can use them, and falls back to CurrentUser rather than failing.
    #>
    param(
        [Parameter(Mandatory)] [string[]] $Name,
        [switch] $SkipInstall
    )

    $missing = @($Name | Where-Object { -not (Get-Module -ListAvailable -Name $_) })
    if ($missing.Count -eq 0) {
        Write-Step 'Microsoft Graph modules already present.' Skip
        return
    }

    if ($SkipInstall) {
        throw "These modules are missing and -SkipModuleInstall was given: $($missing -join ', '). Install them with: Install-Module $($missing -join ', ') -Scope AllUsers"
    }

    $elevated = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $scope = if ($elevated) { 'AllUsers' } else { 'CurrentUser' }

    Write-Step "Installing $($missing.Count) Microsoft Graph module(s) to $scope - this takes a few minutes the first time."
    Write-Step "Missing: $($missing -join ', ')"
    if ($WhatIfPreference) {
        # Prerequisites are installed even on a dry run, deliberately: -WhatIf
        # still signs in to Graph and performs read-only lookups, which need the
        # modules. What -WhatIf protects is the directory and the tenant.
        Write-Step 'Installing prerequisites despite -WhatIf - the dry run needs them for its read-only lookups.' Warn
    }

    try {
        [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

        # -ListAvailable matters. Without it, Get-PackageProvider on a fresh
        # Windows PowerShell 5.1 tries to bootstrap NuGet itself and stops at an
        # interactive "would you like to install nuget now?" prompt - before the
        # non-interactive install below ever runs. Seen on the lab server.
        $nuget = Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue |
            Where-Object { $_.Version -ge [version]'2.8.5.201' }
        if (-not $nuget) {
            Write-Step 'Adding the NuGet package provider first.'
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope $scope -Force `
                -WhatIf:$false -ErrorAction Stop | Out-Null
        }

        # -Force also suppresses the "untrusted repository" confirmation, which
        # would otherwise stop an unattended run dead.
        Install-Module -Name $missing -Repository PSGallery -Scope $scope `
            -Force -AllowClobber -WhatIf:$false -ErrorAction Stop

        Write-Step "Installed: $($missing -join ', ')." Good
    }
    catch {
        throw (@(
                "Could not install the Microsoft Graph modules: $($_.Exception.Message)"
                ''
                'Usually one of:'
                '  - no internet access from this server (the Gallery is reached over HTTPS)'
                '  - a proxy that needs configuring for PowerShellGet'
                '  - PowerShellGet itself is too old: Install-Module PowerShellGet -Force'
                ''
                'To carry on without the cloud steps for now, re-run with -SkipCloud.'
                'To install by hand on a machine that does have access:'
                "  Install-Module $($missing -join ', ') -Scope AllUsers"
            ) -join [Environment]::NewLine)
    }
}

function Get-UniqueSamAccountName {
    <#
        First initial + surname, lowercased and stripped of anything Active
        Directory will not accept. A digit is appended if the name is taken,
        so a second A. Okonkwo becomes aokonkwo2 rather than failing.
    #>
    param([string] $FirstName, [string] $LastName)

    $base = ("{0}{1}" -f $FirstName.Substring(0, 1), $LastName).ToLower() -replace '[^a-z0-9]', ''
    if ($base.Length -gt 20) { $base = $base.Substring(0, 20) }

    $candidate = $base
    $suffix = 2
    while (Get-ADUser -Filter "SamAccountName -eq '$candidate'" -ErrorAction SilentlyContinue) {
        $candidate = "{0}{1}" -f $base.Substring(0, [Math]::Min($base.Length, 19)), $suffix
        $suffix++
    }
    return $candidate
}

# The Graph modules the cloud steps need. Only the pieces used are listed -
# installing the whole Microsoft.Graph meta-module pulls in about forty
# sub-modules and takes far longer for no benefit here.
$GraphModules = @(
    'Microsoft.Graph.Authentication'               # Connect-MgGraph
    'Microsoft.Graph.Users'                        # Get-MgUser, New-MgUser, Update-MgUser
    'Microsoft.Graph.Users.Actions'                # Set-MgUserLicense - NOT in .Users, despite the name
    'Microsoft.Graph.Groups'                       # Get-MgGroup, New-MgGroupMember
    'Microsoft.Graph.Identity.DirectoryManagement' # Get-MgSubscribedSku
)

# Department -> the Microsoft 365 group (and therefore Team) they join.
# Names must match the group's displayName in the tenant exactly. Departments
# absent from this table simply get no Microsoft 365 group.
$Microsoft365GroupMap = @{
    Finance = 'Finance'
    HR      = 'HR'
    IT      = 'IT'
}
# Everyone lands in this one regardless of department. Empty string disables it.
$AllStaffMicrosoft365Group = 'All Company'

# ---------------------------------------------------------------------------
#  Configuration - reuse the deployment's view of the directory
# ---------------------------------------------------------------------------

if (-not $ConfigPath) {
    # Look in several sensible places rather than assuming one layout, so this
    # script keeps working whether it lives inside the deployment kit, in its
    # own folder beside it, or anywhere at all on a server where the kit has
    # been deployed to C:\ADDeployment.
    # Walk up from the script, but guard every step: Split-Path on a drive
    # root ('C:\') returns an empty string, and Join-Path then throws. A script
    # dropped in C:\New-VortexUser hits that on the second hop.
    $parent = Split-Path -Path $PSScriptRoot -Parent
    $grandparent = if ($parent) { Split-Path -Path $parent -Parent } else { $null }

    $searched = @( Join-Path $PSScriptRoot 'Config\DeploymentConfig.psd1' )   # beside the script
    if ($parent) {
        $searched += Join-Path $parent 'Config\DeploymentConfig.psd1'                       # script inside the kit's Scripts folder
        $searched += Join-Path $parent 'Deployment\Config\DeploymentConfig.psd1'            # repository layout: Onboarding\ beside Deployment\
        $searched += Join-Path $parent 'Vortex-ADDeployment\Config\DeploymentConfig.psd1'   # kit is a sibling folder
    }
    if ($grandparent) {
        $searched += Join-Path $grandparent 'Vortex-ADDeployment\Config\DeploymentConfig.psd1'
    }
    # The deployed location on a server, which is where it will be in practice
    # no matter where someone drops this script.
    $searched += 'C:\ADDeployment\Config\DeploymentConfig.psd1'
    $ConfigPath = $searched | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

    if (-not $ConfigPath) {
        throw (@(
                'Cannot find DeploymentConfig.psd1. Looked in:'
                ($searched | ForEach-Object { "  $_" })
                ''
                'Point at it explicitly with -ConfigPath, for example:'
                '  -ConfigPath C:\ADDeployment\Config\DeploymentConfig.psd1'
            ) -join [Environment]::NewLine)
    }
    Write-Verbose "Using configuration: $ConfigPath"
}
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Cannot find the deployment configuration at '$ConfigPath'."
}

$config = Import-PowerShellDataFile -LiteralPath $ConfigPath
$domainDns = $config.Domain.DnsName
$domainDn = ($domainDns -split '\.' | ForEach-Object { "DC=$_" }) -join ','
$upnSuffix = $config.Identity.UpnSuffix
if (-not $upnSuffix) { $upnSuffix = $domainDns }
$company = $config.Identity.Company

# ---------------------------------------------------------------------------
#  -ListLicenses: read-only, exits early
# ---------------------------------------------------------------------------

if ($ListLicenses) {
    Assert-GraphModule -Name 'Microsoft.Graph.Authentication', 'Microsoft.Graph.Identity.DirectoryManagement' `
        -SkipInstall:$SkipModuleInstall
    Import-Module Microsoft.Graph.Authentication, Microsoft.Graph.Identity.DirectoryManagement -ErrorAction Stop
    Connect-MgGraph -Scopes 'Organization.Read.All' -NoWelcome
    Get-MgSubscribedSku | ForEach-Object {
        [pscustomobject]@{
            Sku       = $_.SkuPartNumber
            Total     = $_.PrepaidUnits.Enabled
            Used      = $_.ConsumedUnits
            Available = $_.PrepaidUnits.Enabled - $_.ConsumedUnits
        }
    } | Sort-Object Sku | Format-Table -AutoSize
    Disconnect-MgGraph | Out-Null
    return
}

# ---------------------------------------------------------------------------
#  Work out who this person is
# ---------------------------------------------------------------------------

Import-Module ActiveDirectory -ErrorAction Stop

if (-not $SamAccountName) {
    $SamAccountName = Get-UniqueSamAccountName -FirstName $FirstName -LastName $LastName
}
if ($SamAccountName.Length -gt 20) {
    throw "SamAccountName '$SamAccountName' is longer than the 20-character limit Active Directory allows."
}
$existingAdUser = Get-ADUser -Filter "SamAccountName -eq '$SamAccountName'" -ErrorAction SilentlyContinue
if ($existingAdUser -and -not $SkipAD) {
    throw "An account named '$SamAccountName' already exists. Pass -SamAccountName to choose another, or -SkipAD to finish the Microsoft 365 half for this existing account."
}
if ($SkipAD -and -not $existingAdUser) {
    throw "-SkipAD was given but no AD account named '$SamAccountName' exists. Drop -SkipAD to create it."
}

$displayName = "$FirstName $LastName"
$userPrincipalName = "$SamAccountName@$upnSuffix"
$targetOu = "OU=$Branch,OU=Users,OU=VortexAI,$domainDn"

# Three role groups: everyone, their department, their branch. This is the
# whole point of the AGDLP model the domain was built with - file and share
# access follows from these, with no ACL ever touched.
$roleGroups = @('ROLE_AllStaff', "ROLE_$Department", "ROLE_$Branch")

Write-Host ''
Write-Host "  Onboarding $displayName" -ForegroundColor Cyan
Write-Host "  Logon name   : $SamAccountName"
Write-Host "  Sign-in (UPN): $userPrincipalName"
Write-Host "  Office       : $Branch"
Write-Host "  Department   : $Department - $JobTitle"
Write-Host "  AD location  : $targetOu"
Write-Host "  Role groups  : $($roleGroups -join ', ')"
Write-Host "  Licence      : $(if ($SkipCloud) { 'skipped (-SkipCloud)' } else { $LicenseSku })"
Write-Host ''

if (-not (Get-ADOrganizationalUnit -Identity $targetOu -ErrorAction SilentlyContinue)) {
    throw "Target OU '$targetOu' does not exist. Has the domain been built with Invoke-Deployment.ps1?"
}

# ---------------------------------------------------------------------------
#  1. Active Directory account
# ---------------------------------------------------------------------------

$tempPassword = New-TempPassword -Length 16

if ($SkipAD) {
    Write-Step "Using the existing AD account '$SamAccountName' (-SkipAD)." Skip
    # No AD password was set on this run, so there is nothing to hand over.
    $tempPassword = $null
}
elseif ($PSCmdlet.ShouldProcess($SamAccountName, "Create AD user in $targetOu")) {
    $adParameters = @{
        Name                  = $displayName
        GivenName             = $FirstName
        Surname               = $LastName
        DisplayName           = $displayName
        SamAccountName        = $SamAccountName
        UserPrincipalName     = $userPrincipalName
        Path                  = $targetOu
        Title                 = $JobTitle
        Department            = $Department
        Office                = $Branch
        Company               = $company
        AccountPassword       = (ConvertTo-SecureString $tempPassword -AsPlainText -Force)
        Enabled               = $true
        ChangePasswordAtLogon = $true
        ErrorAction           = 'Stop'
    }
    if ($Manager) {
        $managerObject = Get-ADUser -Filter "SamAccountName -eq '$Manager'" -ErrorAction SilentlyContinue
        if ($managerObject) { $adParameters['Manager'] = $managerObject.DistinguishedName }
        else { Write-Step "No account found for manager '$Manager' - leaving the field empty." Warn }
    }

    New-ADUser @adParameters
    Write-Step "Created AD account '$SamAccountName'." Good
}

# ---------------------------------------------------------------------------
#  2. Role groups
# ---------------------------------------------------------------------------

foreach ($group in $(if ($SkipAD) { @() } else { $roleGroups })) {
    if (-not (Get-ADGroup -Filter "Name -eq '$group'" -ErrorAction SilentlyContinue)) {
        Write-Step "Group '$group' does not exist - skipping." Warn
        continue
    }
    if ($PSCmdlet.ShouldProcess($SamAccountName, "Add to $group")) {
        Add-ADGroupMember -Identity $group -Members $SamAccountName -ErrorAction Stop
        Write-Step "Added to '$group'." Good
    }
}

if ($SkipCloud) {
    Write-Host ''
    Write-Step 'Cloud steps skipped (-SkipCloud).' Skip
    Write-Host ''
    if ($WhatIfPreference) {
        Write-Host '  Dry run complete (-WhatIf) - nothing was created or changed.' -ForegroundColor Cyan
        Write-Host ''
        return
    }
    Write-Host "  Temporary password: $tempPassword" -ForegroundColor Yellow
    Write-Host '  Deliver it in person or through your password manager, never by email.' -ForegroundColor Yellow
    Write-Host '  It must be changed at first sign-in.' -ForegroundColor Yellow
    Write-Host ''
    return
}

# ---------------------------------------------------------------------------
#  3. Microsoft 365 account
# ---------------------------------------------------------------------------

Write-Host ''
Assert-GraphModule -Name $GraphModules -SkipInstall:$SkipModuleInstall
Import-Module $GraphModules -ErrorAction Stop

Write-Step 'Signing in to Microsoft Graph (a browser window will open)...'
Connect-MgGraph -Scopes 'User.ReadWrite.All', 'Group.ReadWrite.All', 'Organization.Read.All' -NoWelcome

try {
    # Look before creating. If Entra Connect is syncing this domain the cloud
    # account already exists, and making a second one produces a duplicate
    # identity that is tedious to unpick.
    $cloudUser = Get-MgUser -Filter "userPrincipalName eq '$userPrincipalName'" -ErrorAction SilentlyContinue

    if ($cloudUser) {
        Write-Step "Microsoft 365 account already exists (synced or created earlier) - using it." Skip
    }
    elseif ($PSCmdlet.ShouldProcess($userPrincipalName, 'Create Microsoft 365 account')) {
        $cloudUser = New-MgUser -DisplayName $displayName `
            -UserPrincipalName $userPrincipalName `
            -MailNickname $SamAccountName `
            -AccountEnabled `
            -GivenName $FirstName -Surname $LastName `
            -JobTitle $JobTitle -Department $Department -OfficeLocation $Branch `
            -CompanyName $company `
            -PasswordProfile @{
            # -SkipAD means no password was generated this run, so make one
            # solely for the cloud account being created here.
            Password                      = $(if ($tempPassword) { $tempPassword } else { $script:tempPassword = New-TempPassword -Length 16; $script:tempPassword })
            ForceChangePasswordNextSignIn = $true
        } -ErrorAction Stop
        Write-Step "Created Microsoft 365 account '$userPrincipalName'." Good
    }

    # ------------------------------------------------------------------
    #  4. Usage location, then licence
    # ------------------------------------------------------------------

    if ($cloudUser -and $LicenseSku -ne 'None') {
        # A licence cannot be assigned without a usage location - Microsoft
        # needs to know which country's service availability applies. The
        # error it returns otherwise does not mention usage location at all.
        if (-not $cloudUser.UsageLocation) {
            if ($PSCmdlet.ShouldProcess($userPrincipalName, 'Set usage location to CA')) {
                Update-MgUser -UserId $cloudUser.Id -UsageLocation 'CA' -ErrorAction Stop
                Write-Step 'Usage location set to CA (required before licensing).' Good
            }
        }

        $sku = Get-MgSubscribedSku | Where-Object SkuPartNumber -eq $LicenseSku
        if (-not $sku) {
            Write-Step "The tenant owns no '$LicenseSku' subscription. Run -ListLicenses to see what is available." Warn
        }
        else {
            $available = $sku.PrepaidUnits.Enabled - $sku.ConsumedUnits
            if ($available -le 0) {
                Write-Step "No '$LicenseSku' seats free ($($sku.ConsumedUnits) of $($sku.PrepaidUnits.Enabled) used). Buy another seat, then assign it." Warn
            }
            elseif ($PSCmdlet.ShouldProcess($userPrincipalName, "Assign $LicenseSku")) {
                Set-MgUserLicense -UserId $cloudUser.Id `
                    -AddLicenses @(@{ SkuId = $sku.SkuId }) -RemoveLicenses @() -ErrorAction Stop | Out-Null
                Write-Step "Assigned $LicenseSku ($($available - 1) seat(s) left)." Good
            }
        }
    }

    # ------------------------------------------------------------------
    #  5. Microsoft 365 groups (these are what back the Teams)
    # ------------------------------------------------------------------

    $targetGroups = @()
    if ($AllStaffMicrosoft365Group) { $targetGroups += $AllStaffMicrosoft365Group }
    if ($Microsoft365GroupMap.ContainsKey($Department)) { $targetGroups += $Microsoft365GroupMap[$Department] }

    foreach ($groupName in $targetGroups) {
        $group = Get-MgGroup -Filter "displayName eq '$groupName'" -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $group) {
            Write-Step "No Microsoft 365 group called '$groupName' in the tenant - skipping." Warn
            continue
        }

        $alreadyMember = Get-MgGroupMember -GroupId $group.Id -All -ErrorAction SilentlyContinue |
            Where-Object Id -eq $cloudUser.Id
        if ($alreadyMember) {
            Write-Step "Already a member of '$groupName'." Skip
            continue
        }

        if ($PSCmdlet.ShouldProcess($userPrincipalName, "Add to Microsoft 365 group '$groupName'")) {
            New-MgGroupMember -GroupId $group.Id -DirectoryObjectId $cloudUser.Id -ErrorAction Stop
            Write-Step "Added to '$groupName' (and its Team, if one is attached)." Good
        }
    }
}
catch {
    # Deliberately not re-thrown. The AD account exists by now and its
    # generated password is shown only once, at the end of this script -
    # aborting here would leave a real account whose credential nobody knows.
    # Licensing and Teams membership can be finished by hand; a lost password
    # means resetting it.
    Write-Step "Cloud step failed: $($_.Exception.Message)" Warn
    Write-Step 'The AD account and its groups were created successfully. Finish the Microsoft 365 side by hand, or re-run with -SkipAD once the cause is fixed.' Warn
    $script:CloudIncomplete = $true
}
finally {
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
}

# ---------------------------------------------------------------------------
#  Handover
# ---------------------------------------------------------------------------

Write-Host ''
if ($WhatIfPreference) {
    # A dry run creates nothing, so there is no account to hand over and no
    # password to show. An earlier version printed "Onboarding complete" and a
    # freshly generated password here, which read as though the account existed.
    Write-Host '  Dry run complete (-WhatIf) - nothing was created or changed.' -ForegroundColor Cyan
    Write-Host "  Re-run without -WhatIf to onboard $displayName ($userPrincipalName)." -ForegroundColor Cyan
    Write-Host ''
    return
}
if ($script:CloudIncomplete) {
    Write-Host '  Onboarding PARTIALLY complete - Active Directory done, Microsoft 365 unfinished.' -ForegroundColor Yellow
}
else {
    Write-Host '  Onboarding complete.' -ForegroundColor Green
}
Write-Host ''
Write-Host "  Name       : $displayName"
Write-Host "  Sign-in    : $userPrincipalName"
if ($tempPassword) {
    Write-Host "  Password   : $tempPassword" -ForegroundColor Yellow
}
else {
    Write-Host '  Password   : unchanged (-SkipAD; the existing account keeps its password)' -ForegroundColor DarkGray
}
Write-Host ''
Write-Host '  The password is single-use - it must be changed at first sign-in.' -ForegroundColor Yellow
Write-Host '  Deliver it in person or through a password manager, never by email.' -ForegroundColor Yellow
Write-Host ''
Write-Host '  Note: file and share access comes from the role groups above, so there is' -ForegroundColor DarkGray
Write-Host '  nothing to set on any folder. Teams membership may take a few minutes to' -ForegroundColor DarkGray
Write-Host '  appear in the client.' -ForegroundColor DarkGray
Write-Host ''
