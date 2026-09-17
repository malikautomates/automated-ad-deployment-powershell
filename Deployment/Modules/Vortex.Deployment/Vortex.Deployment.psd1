@{
    RootModule           = 'Vortex.Deployment.psm1'
    ModuleVersion        = '2.0.0'
    GUID                 = 'f4a1d6c2-3b57-4e18-9a0d-71c5e8b23f40'
    Author               = 'Vortex AI Infrastructure'
    CompanyName          = 'VortexAI'
    Copyright            = '(c) Vortex AI. Internal use.'
    Description          = 'Shared engine for the Vortex AI Active Directory domain controller deployment: configuration loading, structured logging, resumable state, addressing, directory object creation and post-deployment validation.'

    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop')

    # Deliberately NOT declared as RequiredModules. ActiveDirectory and DnsServer
    # only exist once the corresponding roles are installed, which this very
    # deployment is what installs. Declaring them here would make the module
    # impossible to import during Stage 1.
    RequiredModules      = @()

    FunctionsToExport    = @(
        # Configuration
        'Import-DeploymentConfig'
        'Get-ConfigValue'
        'Get-DeploymentDomainDn'

        # Logging and the unit-of-work wrapper
        'Initialize-DeploymentLog'
        'Write-DeploymentLog'
        'Complete-DeploymentLog'
        'Get-DeploymentLogPath'
        'Invoke-DeploymentStep'

        # Resumable state
        'Initialize-DeploymentState'
        'Save-DeploymentState'
        'Get-DeploymentState'
        'Test-DeploymentStepComplete'
        'Set-DeploymentStepComplete'
        'Test-DeploymentStageComplete'
        'Set-DeploymentStageComplete'
        'Set-DeploymentFact'
        'Get-DeploymentFact'
        'Reset-DeploymentState'

        # Host environment
        'Test-IsAdministrator'
        'Assert-Administrator'
        'Test-PendingReboot'
        'Test-DeploymentPrerequisite'
        'Install-DeploymentFeature'
        'Wait-ForActiveDirectory'
        'Wait-ForService'

        # Networking
        'Get-TargetAdapter'
        'Resolve-NetworkPlan'
        'Set-DeploymentNetwork'
        'ConvertTo-NetworkId'
        'Set-DomainControllerDnsClient'

        # Reboot survival
        'Register-DeploymentResumeTask'
        'Unregister-DeploymentResumeTask'
        'Test-DeploymentResumeTask'
        'Request-DeploymentRestart'

        # Secrets
        'New-RandomPassword'
        'Protect-DeploymentSecret'
        'Unprotect-DeploymentSecret'
        'ConvertTo-PlainText'
        'Export-DeploymentSecretReport'

        # Directory objects
        'Resolve-OuPath'
        'Resolve-TargetOu'
        'New-DeploymentOuTree'
        'New-DeploymentGroupModel'
        'Import-DeploymentUser'

        # File system resources
        'Set-DeploymentFolderAcl'
        'New-DeploymentShare'

        # Validation
        'Get-DeploymentDesignValidationResult'
        'Get-DeploymentValidationResult'
        'Export-DeploymentValidationReport'
    )

    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()

    PrivateData          = @{
        PSData = @{
            Tags         = @('ActiveDirectory', 'DomainController', 'Deployment', 'WindowsServer')
            ReleaseNotes = 'See CHANGELOG.md in the deployment root.'
        }
    }
}
