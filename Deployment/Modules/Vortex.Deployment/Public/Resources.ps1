<#
    File system resources: folders, their NTFS permissions, and the SMB shares
    that make them reachable.

    Two corrections to how the original scripts did this:

    1. Inheritance flags. A FileSystemAccessRule built from three arguments
       applies to the folder object only - not to anything created inside it.
       Every rule here is built with ContainerInherit,ObjectInherit so the grant
       actually reaches files and subfolders.

    2. SYSTEM survives. Stripping inheritance removes SYSTEM and the local
       Administrators group along with everything else. A folder with no SYSTEM
       ACE breaks backup, antivirus, indexing and shadow copies in ways that
       surface much later and are hard to trace back. Those two are re-applied
       unconditionally, whatever the configuration says.
#>

function Set-DeploymentFolderAcl {
    <#
    .SYNOPSIS
        Creates a folder and applies an explicit, non-inherited ACL.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [object[]] $Permissions,
        [switch] $KeepCreatorOwner
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        if ($PSCmdlet.ShouldProcess($Path, 'Create directory')) {
            New-Item -Path $Path -ItemType Directory -Force | Out-Null
            Write-DeploymentLog -Message "Created folder '$Path'."
        }
    }
    else {
        Write-DeploymentLog -Level SKIP -Message "Folder already exists: $Path"
    }

    if (-not $PSCmdlet.ShouldProcess($Path, 'Apply explicit NTFS permissions with inheritance disabled')) { return }

    $acl = Get-Acl -LiteralPath $Path

    # Protect from inheritance and do not copy the inherited entries: this is
    # what "disable inheritance" means. The entries are dropped when the ACL is
    # written back.
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access | Where-Object { -not $_.IsInherited })) {
        $acl.RemoveAccessRule($rule) | Out-Null
    }

    $baseline = @(
        @{ Identity = 'NT AUTHORITY\SYSTEM'; Rights = 'FullControl' }
        @{ Identity = 'BUILTIN\Administrators'; Rights = 'FullControl' }
    )
    if ($KeepCreatorOwner) {
        $baseline += @{ Identity = 'CREATOR OWNER'; Rights = 'FullControl' }
    }

    $applied = 0
    foreach ($perm in @($baseline + $Permissions)) {
        $identity = [string]$perm.Identity
        $rights = [string]$perm.Rights
        try {
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $identity, $rights, 'ContainerInherit,ObjectInherit', 'None', 'Allow')
            $acl.AddAccessRule($rule)
            $applied++
        }
        catch {
            throw "Cannot grant '$rights' to '$identity' on '$Path': $($_.Exception.Message). Check that the account or group exists and that the name is spelled as DOMAIN\Name."
        }
    }

    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
    Write-DeploymentLog -Level SUCCESS -Message "Applied $applied explicit ACE(s) to '$Path' (inheritance disabled; SYSTEM and Administrators preserved)."
}

function New-DeploymentShare {
    <#
    .SYNOPSIS
        Publishes a folder as an SMB share.

    .DESCRIPTION
        NTFS permissions alone do not make a folder reachable over the network -
        the original scripts set ACLs on folders nobody outside the console
        could ever open.

        Share permissions are left broad on purpose and NTFS does the real
        access control. Maintaining two overlapping permission models is a
        classic source of "why can this person not open the folder" incidents;
        the accepted practice is to let one of them decide.

        Access-based enumeration is enabled so users only see what they can
        actually open.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Path,
        [string] $Description = '',
        [string[]] $FullAccess = @('BUILTIN\Administrators'),
        [string[]] $ChangeAccess = @('Authenticated Users'),
        [bool] $AccessBasedEnumeration = $true
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Cannot share '$Path' - the folder does not exist."
    }

    $existing = Get-SmbShare -Name $Name -ErrorAction SilentlyContinue
    if ($existing) {
        if ($existing.Path -ne $Path) {
            Write-DeploymentLog -Level WARN -Message "Share '$Name' already exists but points at '$($existing.Path)', not '$Path'. Leaving it alone - remove it by hand if that is wrong."
        }
        else {
            Write-DeploymentLog -Level SKIP -Message "Share '$Name' already exists for '$Path'."
        }
        return
    }

    if (-not $PSCmdlet.ShouldProcess($Name, "Share '$Path'")) { return }

    $parameters = @{
        Name        = $Name
        Path        = $Path
        Description = $Description
        ErrorAction = 'Stop'
    }
    if ($FullAccess) { $parameters['FullAccess'] = $FullAccess }
    if ($ChangeAccess) { $parameters['ChangeAccess'] = $ChangeAccess }

    New-SmbShare @parameters | Out-Null
    Set-SmbShare -Name $Name -FolderEnumerationMode $(if ($AccessBasedEnumeration) { 'AccessBased' } else { 'Unrestricted' }) -Force -ErrorAction SilentlyContinue

    Write-DeploymentLog -Level SUCCESS -Message "Shared '$Path' as \\$env:COMPUTERNAME\$Name"
}
