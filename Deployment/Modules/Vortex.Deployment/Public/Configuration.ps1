<#
    Configuration loading. One file describes the environment; the stage scripts
    contain no environment-specific values at all. Retargeting this deployment
    at a different site should mean editing Config\DeploymentConfig.psd1 and
    nothing else.
#>

function Get-ConfigValue {
    <#
    .SYNOPSIS
        Reads an OPTIONAL configuration key, returning a default when absent.

    .DESCRIPTION
        Required keys are guaranteed present by schema validation and can be
        dereferenced directly. Everything optional goes through here, so a
        missing or newly added key yields a documented default rather than a
        null-reference failure partway through an unattended run.

    .EXAMPLE
        $days = Get-ConfigValue $Config.Logging 'RetentionDays' 30
    #>
    [CmdletBinding()]
    param(
        $Hashtable,
        [Parameter(Mandatory)] [string] $Key,
        $Default = $null
    )

    if ($null -eq $Hashtable) { return $Default }
    if (-not ($Hashtable -is [hashtable])) { return $Default }
    if (-not $Hashtable.ContainsKey($Key)) { return $Default }

    $value = $Hashtable[$Key]
    if ($null -eq $value) { return $Default }
    return $value
}

function Import-DeploymentConfig {
    <#
    .SYNOPSIS
        Loads, validates and normalises the deployment configuration.

    .DESCRIPTION
        Import-PowerShellDataFile is used rather than dot-sourcing a .ps1 so the
        configuration is pure data and cannot execute code.

        Validation happens here, once, and reports every problem together. A
        configuration error should stop the deployment before it touches the
        server, not after it has already changed the IP address.

    .PARAMETER Path
        Path to DeploymentConfig.psd1.

    .PARAMETER DeploymentRoot
        Overrides Paths.DeploymentRoot from the file. Useful when the kit has
        been copied somewhere other than its configured home.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $DeploymentRoot
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Configuration file not found: $Path"
    }

    try {
        $config = Import-PowerShellDataFile -LiteralPath $Path -ErrorAction Stop
    }
    catch {
        throw "Configuration file '$Path' is not valid PowerShell data: $($_.Exception.Message)"
    }

    if ($DeploymentRoot) {
        if (-not $config.ContainsKey('Paths')) { $config['Paths'] = @{} }
        $config.Paths['DeploymentRoot'] = $DeploymentRoot
    }

    $problems = Test-DeploymentConfigSchema -Config $config
    if ($problems.Count -gt 0) {
        $detail = ($problems | ForEach-Object { "  - $_" }) -join [Environment]::NewLine
        throw "Configuration at '$Path' is invalid:$([Environment]::NewLine)$detail"
    }

    # Derive the working directories from the root so only one path is ever
    # configured by hand. Anything already set in the file is respected.
    $root = $config.Paths.DeploymentRoot
    $output = Get-ConfigValue $config.Paths 'OutputRoot' (Join-Path $root 'Output')
    $config.Paths['OutputRoot'] = $output
    $config.Paths['Logs'] = Get-ConfigValue $config.Paths 'Logs'    (Join-Path $output 'Logs')
    $config.Paths['Reports'] = Get-ConfigValue $config.Paths 'Reports' (Join-Path $output 'Reports')
    $config.Paths['Secrets'] = Get-ConfigValue $config.Paths 'Secrets' (Join-Path $output 'Secrets')
    $config.Paths['StateFile'] = Get-ConfigValue $config.Paths 'StateFile' (Join-Path $output 'deployment-state.json')
    $config.Paths['Scripts'] = Get-ConfigValue $config.Paths 'Scripts' (Join-Path $root 'Scripts')
    $config.Paths['Modules'] = Get-ConfigValue $config.Paths 'Modules' (Join-Path $root 'Modules')
    $config.Paths['ConfigFile'] = (Resolve-Path -LiteralPath $Path).Path

    # Data paths may be written relative to the deployment root, so the kit
    # keeps working when it is copied somewhere other than its configured home -
    # which is exactly what happens between an authoring machine and a server.
    # An absolute path is always honoured as given.
    foreach ($key in 'UsersCsv') {
        $value = [string](Get-ConfigValue $config.Paths $key '')
        if ($value -and -not [System.IO.Path]::IsPathRooted($value)) {
            $config.Paths[$key] = Join-Path $root $value
        }
    }

    return $config
}

function Get-DeploymentDomainDn {
    <#
    .SYNOPSIS
        Converts a DNS domain name into its distinguished name form.

    .EXAMPLE
        Get-DeploymentDomainDn -DnsName 'vortexai.local'   # DC=vortexai,DC=local
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $DnsName)

    return (($DnsName -split '\.' | ForEach-Object { "DC=$_" }) -join ',')
}
