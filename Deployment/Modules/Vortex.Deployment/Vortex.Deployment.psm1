#Requires -Version 5.1

<#
    Vortex.Deployment - shared engine for the Vortex AI Active Directory deployment.

    Public\   functions the stage scripts are allowed to call.
    Private\  implementation detail; never exported.

    Public functions are discovered from the abstract syntax tree rather than
    listed by hand, so adding a function to Public\ exports it and nothing has
    to be kept in sync. FindAll is called with $false so helpers nested inside a
    function body stay private.
#>

# Version 1.0, deliberately, not 2.0 or Latest.
#
# 1.0 catches references to uninitialised variables - the check that earns its
# keep, and the one that caught a real scoping bug in the validator.
#
# 2.0 additionally rejects reading a property that does not exist. That sounds
# good and is actively harmful here, because PowerShell 5.1 itself supplies
# .Count and .Length on scalars as a convenience, and StrictMode 2.0 does not
# recognise that shim. Ordinary, idiomatic code like "if ($x.Count -gt 0)" then
# throws the moment a filter happens to return exactly one item instead of two.
# It cost this deployment two failed runs on a correctly configured server.
#
# The array-handling that provoked those failures has been fixed at source
# regardless; this setting is the safety net, not the fix.
Set-StrictMode -Version 1.0

# Module scope, so it applies to every function defined here regardless of what
# the calling script has set. Without it, a cmdlet that emits a NON-terminating
# error (Set-Acl being the dangerous one) lets execution fall through to the
# success path and the step reports as completed when it did nothing. Steps that
# genuinely tolerate failure say so explicitly with -ErrorAction SilentlyContinue.
$ErrorActionPreference = 'Stop'

$script:ModuleRoot = $PSScriptRoot

# Module-scope state, initialised here so strict mode never sees an undefined
# variable if a function is called before its initialiser has run.
$script:DeploymentStageName = $null
$script:DeploymentLogFile = $null
$script:DeploymentTranscriptActive = $false
$script:DeploymentStatePath = $null
$script:DeploymentState = $null

$publicFunctions = [System.Collections.Generic.List[string]]::new()

foreach ($folder in 'Private', 'Public') {
    $directory = Join-Path $script:ModuleRoot $folder
    if (-not (Test-Path -LiteralPath $directory)) { continue }

    foreach ($file in Get-ChildItem -LiteralPath $directory -Filter '*.ps1' -File | Sort-Object Name) {
        try {
            . $file.FullName
        }
        catch {
            throw "Failed to load module file '$($file.FullName)': $($_.Exception.Message)"
        }

        if ($folder -ne 'Public') { continue }

        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
        $definitions = $ast.FindAll(
            { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },
            $false)
        foreach ($definition in $definitions) { $publicFunctions.Add($definition.Name) }
    }
}

Export-ModuleMember -Function $publicFunctions
