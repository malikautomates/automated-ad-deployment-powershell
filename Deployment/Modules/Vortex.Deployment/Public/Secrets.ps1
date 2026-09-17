<#
    Secret handling.

    The original kit shipped one password for everybody, in a text file, and
    also wrote it into the registry in plaintext. This replaces all of that:

      - Every user account gets its own random password, generated at run time.
      - Passwords are single-use: accounts are created with "must change at next
        logon", so the generated value stops being a credential the moment the
        person signs in.
      - The handover file lives in a directory whose ACL is Administrators and
        SYSTEM only, and the pipeline tells the operator to destroy it once the
        passwords have been distributed.

    The honest limitation: that handover file is readable by an administrator
    while it exists. In a real environment the generated passwords would go
    straight into a secrets manager or an identity platform's own delivery
    channel instead of a file on disk. That is a deliberate, documented trade
    for a self-contained kit with no external dependencies.
#>

function New-RandomPassword {
    <#
    .SYNOPSIS
        Generates a cryptographically random password that satisfies Windows
        complexity requirements by construction.

    .DESCRIPTION
        Uses a cryptographic RNG, not Get-Random, which is seeded
        pseudo-randomness and unfit for credentials.

        Characters that are easily confused when read aloud or copied by hand
        (O/o/0, l/1/I/i) are excluded, as are characters that would need escaping in
        CSV or PowerShell. One character from each required class is placed
        first and the whole string is then shuffled, so complexity is guaranteed
        rather than hoped for.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([ValidateRange(12, 128)] [int] $Length = 20)

    $upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower = 'abcdefghjkmnpqrstuvwxyz'
    $digit = '23456789'
    $symbol = '!#%+-=?@_'
    $all = $upper + $lower + $digit + $symbol

    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        function Get-RandomChar {
            param([string] $Set)
            $bytes = New-Object byte[] 4
            $rng.GetBytes($bytes)
            $value = [BitConverter]::ToUInt32($bytes, 0)
            return $Set[[int]($value % [uint32]$Set.Length)]
        }

        $chars = [System.Collections.Generic.List[char]]::new()
        $chars.Add((Get-RandomChar $upper))
        $chars.Add((Get-RandomChar $lower))
        $chars.Add((Get-RandomChar $digit))
        $chars.Add((Get-RandomChar $symbol))
        while ($chars.Count -lt $Length) { $chars.Add((Get-RandomChar $all)) }

        # Fisher-Yates, so the guaranteed characters are not always in the
        # first four positions.
        for ($i = $chars.Count - 1; $i -gt 0; $i--) {
            $bytes = New-Object byte[] 4
            $rng.GetBytes($bytes)
            $j = [int]([BitConverter]::ToUInt32($bytes, 0) % [uint32]($i + 1))
            $swap = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $swap
        }

        return -join $chars
    }
    finally {
        $rng.Dispose()
    }
}

function Protect-DeploymentSecret {
    <#
    .SYNOPSIS
        Encrypts a string to disk using machine-scoped DPAPI.

    .DESCRIPTION
        Machine scope rather than user scope is essential here: the value is
        written by an interactive administrator and read back by SYSTEM after a
        reboot. A user-scoped blob (what Export-Clixml produces) could not be
        decrypted by the account that needs it.

        The blob is bound to this machine. Copied elsewhere, it is unreadable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [securestring] $Secret,
        [Parameter(Mandatory)] [string] $Path
    )

    Add-Type -AssemblyName System.Security

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secret)
    try {
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        $bytes = [Text.Encoding]::UTF8.GetBytes($plain)
        $protected = [Security.Cryptography.ProtectedData]::Protect(
            $bytes, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)

        # Only lock down the directory when this function is the one creating
        # it. Re-ACLing a directory that already existed would be a surprising
        # side effect on a caller-supplied path - the file's own ACL below is
        # what actually protects the secret.
        $folder = Split-Path -Path $Path -Parent
        if ($folder -and -not (Test-Path -LiteralPath $folder)) {
            New-ProtectedDirectory -Path $folder | Out-Null
        }

        [IO.File]::WriteAllBytes($Path, $protected)
        Set-RestrictiveFileAcl -Path $Path

        [array]::Clear($bytes, 0, $bytes.Length)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Unprotect-DeploymentSecret {
    <#
    .SYNOPSIS
        Reads back a value written by Protect-DeploymentSecret.
    #>
    [CmdletBinding()]
    [OutputType([securestring])]
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Protected secret not found at $Path."
    }

    Add-Type -AssemblyName System.Security

    $protected = [IO.File]::ReadAllBytes($Path)
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect(
        $protected, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
    try {
        $secure = New-Object securestring
        foreach ($char in [Text.Encoding]::UTF8.GetString($bytes).ToCharArray()) { $secure.AppendChar($char) }
        $secure.MakeReadOnly()
        return $secure
    }
    finally {
        [array]::Clear($bytes, 0, $bytes.Length)
    }
}

function ConvertTo-PlainText {
    <#
    .SYNOPSIS
        Unwraps a SecureString. Kept in one place so every use is easy to audit.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [securestring] $Secret)

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secret)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Export-DeploymentSecretReport {
    <#
    .SYNOPSIS
        Writes the credential handover file into the protected secrets folder.

    .PARAMETER Entry
        Objects with Account, Secret and Purpose properties.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [object[]] $Entry,
        [Parameter(Mandatory)] [string] $SecretsFolder,
        [string] $FileName
    )

    if (-not $FileName) {
        $FileName = "Credentials-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
    }

    # Same rule as Protect-DeploymentSecret: create the folder locked down if it
    # does not exist, but never silently re-ACL one that does. The file's own
    # ACL is what guarantees the protection either way.
    if (-not (Test-Path -LiteralPath $SecretsFolder)) {
        New-ProtectedDirectory -Path $SecretsFolder | Out-Null
    }
    $path = Join-Path $SecretsFolder $FileName

    if (-not $PSCmdlet.ShouldProcess($path, 'Write credential handover file')) { return $path }

    $Entry | Select-Object Account, Secret, Purpose | Export-Csv -LiteralPath $path -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
    Set-RestrictiveFileAcl -Path $path

    Write-DeploymentLog -Level WARN -Message "Credential handover file written to $path"
    Write-DeploymentLog -Level WARN -Message 'It is readable by administrators. Distribute the passwords, then delete it. User passwords are single-use (change required at first logon); the DSRM password is not - store that one in your password manager.'

    return $path
}
