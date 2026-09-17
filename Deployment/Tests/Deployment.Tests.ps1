#Requires -Version 5.1
<#
    Pester 5 suite for the Vortex AI deployment.

    Two distinct sets of tests:

      Unit        Pure functions - config validation, path building, subnet
                  maths, password generation. These run anywhere, including on
                  a workstation, and need no Active Directory.

      Integration Post-deployment assertions, run against a finished domain
                  controller. These delegate entirely to
                  Get-DeploymentValidationResult - the same function Stage 5
                  uses - so the test suite and the deployment report can never
                  drift apart. Adding a check in one place adds it to both.

    Pester 5 is not on a stock Windows Server, and installing it needs internet
    access. The deployment therefore does NOT depend on it: Stage 5 is the
    authoritative validator and has no external dependencies. This suite is for
    a workstation or a build agent.

        Install-Module Pester -MinimumVersion 5.0 -Force -SkipPublisherCheck
        Invoke-Pester -Path .\Tests\Deployment.Tests.ps1

    Integration tests skip themselves automatically when Active Directory is
    not present, so the same file is safe to run from either place.
#>

BeforeAll {
    $script:Root = Split-Path -Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:Root 'Modules\Vortex.Deployment\Vortex.Deployment.psd1') -Force
    $script:Config = Import-DeploymentConfig `
        -Path (Join-Path $script:Root 'Config\DeploymentConfig.psd1') `
        -DeploymentRoot $script:Root

    $script:IsDomainController = $null -ne (Get-Module -ListAvailable -Name ActiveDirectory) -and
    (Get-CimInstance Win32_OperatingSystem).ProductType -eq 2
}

Describe 'Configuration' {

    It 'loads and passes schema validation' {
        $script:Config | Should -Not -BeNullOrEmpty
        $script:Config.Domain.DnsName | Should -Not -BeNullOrEmpty
    }

    It 'resolves relative data paths against the deployment root' {
        $script:Config.Paths.UsersCsv | Should -Exist
    }

    It 'derives every working directory from the deployment root' {
        foreach ($key in 'Logs', 'Reports', 'Secrets', 'StateFile') {
            $script:Config.Paths[$key] | Should -Not -BeNullOrEmpty
        }
    }

    It 'rejects a single-label domain name' {
        $bad = @{
            Domain  = @{ DnsName = 'vortexai'; NetBiosName = 'VORTEXAI' }
            Server  = @{ ComputerName = 'SRV1' }
            Network = @{ AddressingMode = 'Dhcp' }
            Paths   = @{ DeploymentRoot = 'C:\X'; UsersCsv = 'a.csv' }
        }
        $problems = InModuleScope Vortex.Deployment -Parameters @{ cfg = $bad } { Test-DeploymentConfigSchema -Config $cfg }
        $problems -join ' ' | Should -Match 'single-label'
    }

    It 'rejects a NetBIOS name longer than 15 characters' {
        $bad = @{
            Domain  = @{ DnsName = 'vortexai.local'; NetBiosName = 'AAAAAAAAAAAAAAAAAA' }
            Server  = @{ ComputerName = 'SRV1' }
            Network = @{ AddressingMode = 'Dhcp' }
            Paths   = @{ DeploymentRoot = 'C:\X'; UsersCsv = 'a.csv' }
        }
        $problems = InModuleScope Vortex.Deployment -Parameters @{ cfg = $bad } { Test-DeploymentConfigSchema -Config $cfg }
        $problems -join ' ' | Should -Match '15-character'
    }

    It 'rejects an invalid FileSystemRights value' {
        $bad = @{
            Domain          = @{ DnsName = 'vortexai.local'; NetBiosName = 'VortexAI' }
            Server          = @{ ComputerName = 'SRV1' }
            Network         = @{ AddressingMode = 'Dhcp' }
            Paths           = @{ DeploymentRoot = 'C:\X'; UsersCsv = 'a.csv' }
            FolderStructure = @(@{ Path = 'C:\X'; Permissions = @(@{ Identity = 'Everyone'; Rights = 'Telepathy' }) })
        }
        $problems = InModuleScope Vortex.Deployment -Parameters @{ cfg = $bad } { Test-DeploymentConfigSchema -Config $cfg }
        $problems -join ' ' | Should -Match 'not a valid FileSystemRights'
    }

    It 'rejects a group nesting a group that does not exist' {
        $bad = @{
            Domain  = @{ DnsName = 'vortexai.local'; NetBiosName = 'VortexAI' }
            Server  = @{ ComputerName = 'SRV1' }
            Network = @{ AddressingMode = 'Dhcp' }
            Paths   = @{ DeploymentRoot = 'C:\X'; UsersCsv = 'a.csv' }
            Groups  = @(@{ Name = 'RES_X'; Scope = 'DomainLocal'; MemberGroups = @('Ghost') })
        }
        $problems = InModuleScope Vortex.Deployment -Parameters @{ cfg = $bad } { Test-DeploymentConfigSchema -Config $cfg }
        $problems -join ' ' | Should -Match "nests 'Ghost'"
    }
}

Describe 'Distinguished name construction' {

    It 'converts a DNS name to a domain DN' {
        Get-DeploymentDomainDn -DnsName 'vortexai.local' | Should -BeExactly 'DC=vortexai,DC=local'
        Get-DeploymentDomainDn -DnsName 'ad.vortexai.ca' | Should -BeExactly 'DC=ad,DC=vortexai,DC=ca'
    }

    It 'places a top-level OU directly under the domain' {
        Resolve-OuPath -Name 'VortexAI' -Parent '' -DomainDn 'DC=vortexai,DC=local' |
            Should -BeExactly 'OU=VortexAI,DC=vortexai,DC=local'
    }

    It 'nests a child OU under its parent path' {
        Resolve-OuPath -Name 'Winnipeg' -Parent 'OU=Users,OU=VortexAI' -DomainDn 'DC=vortexai,DC=local' |
            Should -BeExactly 'OU=Winnipeg,OU=Users,OU=VortexAI,DC=vortexai,DC=local'
    }

    It 'resolves a bare OU name from configuration' {
        Resolve-TargetOu -TargetOu 'Vancouver' -Config $script:Config -DomainDn 'DC=vortexai,DC=local' |
            Should -BeExactly 'OU=Vancouver,OU=Users,OU=VortexAI,DC=vortexai,DC=local'
    }

    It 'accepts an explicit relative OU path' {
        Resolve-TargetOu -TargetOu 'OU=Groups,OU=VortexAI' -Config $script:Config -DomainDn 'DC=vortexai,DC=local' |
            Should -BeExactly 'OU=Groups,OU=VortexAI,DC=vortexai,DC=local'
    }

    It 'fails loudly on an OU that is not configured' {
        { Resolve-TargetOu -TargetOu 'Nowhere' -Config $script:Config -DomainDn 'DC=vortexai,DC=local' } |
            Should -Throw '*not defined in OrganizationalUnits*'
    }
}

Describe 'Subnet arithmetic' {

    It 'computes the network id for <prefix>' -ForEach @(
        @{ Address = '192.168.133.129'; Prefix = 24; Expected = '192.168.133.0/24' }
        @{ Address = '10.10.10.34'; Prefix = 27; Expected = '10.10.10.32/27' }
        @{ Address = '172.16.40.5'; Prefix = 16; Expected = '172.16.0.0/16' }
        @{ Address = '10.1.2.3'; Prefix = 8; Expected = '10.0.0.0/8' }
        @{ Address = '10.1.2.3'; Prefix = 32; Expected = '10.1.2.3/32' }
    ) {
        ConvertTo-NetworkId -IPAddress $Address -PrefixLength $Prefix | Should -BeExactly $Expected
    }
}

Describe 'Password generation' {

    It 'honours the requested length' {
        (New-RandomPassword -Length 20).Length | Should -Be 20
        (New-RandomPassword -Length 32).Length | Should -Be 32
    }

    It 'always satisfies Windows complexity requirements' {
        # Sampled rather than asserted once: complexity is guaranteed by
        # construction, and this is the test that would catch a regression in
        # that construction.
        1..200 | ForEach-Object {
            $password = New-RandomPassword -Length 16
            $password | Should -Match '[A-Z]'
            $password | Should -Match '[a-z]'
            $password | Should -Match '[0-9]'
            $password | Should -Match '[^A-Za-z0-9]'
        }
    }

    It 'excludes characters that are ambiguous when transcribed' {
        $sample = -join (1..100 | ForEach-Object { New-RandomPassword -Length 24 })
        # Case-sensitive on purpose: -Match would fold 'O' and 'o' together and
        # silently pass a set that still contained one of them.
        # Uppercase L is deliberately NOT in this list - it is unambiguous. The
        # confusable pairs are O/o/zero and l/one/I/i.
        $sample | Should -Not -CMatch '[Oo0l1Ii]'
    }

    It 'does not repeat itself' {
        $generated = 1..500 | ForEach-Object { New-RandomPassword -Length 20 }
        ($generated | Select-Object -Unique).Count | Should -Be 500
    }

    It 'refuses a length short enough to be weak' {
        { New-RandomPassword -Length 4 } | Should -Throw
    }
}

Describe 'User source data' {

    BeforeAll {
        $script:Users = @(Import-Csv -LiteralPath $script:Config.Paths.UsersCsv)
        $script:GroupNames = @($script:Config.Groups.Name)
        $script:Branches = @('Winnipeg', 'Vancouver', 'Calgary')
    }

    It 'has at least one user' {
        $script:Users.Count | Should -BeGreaterThan 0
    }

    It 'gives every user a SamAccountName and a target OU' {
        foreach ($user in $script:Users) {
            $user.SamAccountName | Should -Not -BeNullOrEmpty
            $user.TargetOu | Should -Not -BeNullOrEmpty
        }
    }

    It 'points every user at an OU that exists in configuration' {
        foreach ($user in $script:Users) {
            { Resolve-TargetOu -TargetOu $user.TargetOu -Config $script:Config -DomainDn 'DC=vortexai,DC=local' } |
                Should -Not -Throw
        }
    }

    It 'only references groups that the configuration defines' {
        foreach ($user in $script:Users) {
            foreach ($group in (($user.Groups -split ';') | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
                $script:GroupNames | Should -Contain $group
            }
        }
    }

    It 'uses unambiguous yyyy-MM-dd expiry dates' {
        # The original data used 'Dec 31, 2024', which parses differently (or
        # not at all) depending on the machine's regional settings.
        foreach ($user in $script:Users) {
            $expiry = ([string]$user.AccountExpiry).Trim()
            if (-not $expiry -or $expiry -eq 'never') { continue }
            $expiry | Should -Match '^\d{4}-\d{2}-\d{2}$'
        }
    }

    It 'has no account expiry already in the past' {
        foreach ($user in $script:Users) {
            $expiry = ([string]$user.AccountExpiry).Trim()
            if (-not $expiry -or $expiry -eq 'never') { continue }
            [datetime]::ParseExact($expiry, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) |
                Should -BeGreaterThan (Get-Date)
        }
    }

    It 'carries no password column' {
        # Passwords are generated per user at deployment time. A password column
        # reappearing in this file is a regression worth failing the build over.
        $script:Users[0].PSObject.Properties.Name | Should -Not -Contain 'Password'
    }
}

Describe 'Group model (AGDLP)' {

    It 'grants folder permissions only to domain local groups' {
        # Member enumeration, not Select-Object -ExpandProperty: config entries
        # are hashtables, and -ExpandProperty cannot read a hashtable key.
        $domainLocal = @(@($script:Config.Groups | Where-Object Scope -eq 'DomainLocal').Name)

        foreach ($folder in $script:Config.FolderStructure) {
            foreach ($permission in $folder.Permissions) {
                $leaf = ($permission.Identity -split '\\')[-1]
                # Well-known principals are allowed through; anything else must
                # be a resource group, which is the whole point of AGDLP.
                if ($leaf -in 'Everyone', 'Authenticated Users', 'Administrators', 'SYSTEM', 'CREATOR OWNER') { continue }
                $domainLocal | Should -Contain $leaf -Because "'$leaf' is on the ACL for $($folder.Path), so it must be a domain local resource group"
            }
        }
    }

    It 'only nests global groups inside domain local groups' {
        $byName = @{}
        foreach ($group in $script:Config.Groups) { $byName[$group.Name] = $group }

        foreach ($group in $script:Config.Groups) {
            if (-not $group.ContainsKey('MemberGroups')) { continue }
            $group.Scope | Should -BeExactly 'DomainLocal' -Because "$($group.Name) nests other groups"
            foreach ($nested in $group.MemberGroups) {
                $byName[$nested].Scope | Should -BeExactly 'Global' -Because "$nested is nested inside the resource group $($group.Name)"
            }
        }
    }

    It 'gives every folder a share name so it is reachable over the network' {
        foreach ($folder in $script:Config.FolderStructure) {
            $folder.ShareName | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Post-deployment validation' -Tag 'Integration' -Skip:(-not $script:IsDomainController) {

    BeforeAll {
        Initialize-DeploymentState -Path $script:Config.Paths.StateFile | Out-Null
        $script:Results = Get-DeploymentValidationResult -Config $script:Config
    }

    It 'produced validation results' {
        $script:Results.Count | Should -BeGreaterThan 0
    }

    It '<Category> / <Check>' -ForEach @(
        # Populated at discovery time from the same function Stage 5 uses, so
        # this suite can never test something different from what the
        # deployment reports.
        $(
            try {
                $root = Split-Path -Path $PSScriptRoot -Parent
                Import-Module (Join-Path $root 'Modules\Vortex.Deployment\Vortex.Deployment.psd1') -Force -ErrorAction Stop
                if ((Get-CimInstance Win32_OperatingSystem).ProductType -eq 2) {
                    $cfg = Import-DeploymentConfig -Path (Join-Path $root 'Config\DeploymentConfig.psd1') -DeploymentRoot $root
                    Initialize-DeploymentState -Path $cfg.Paths.StateFile | Out-Null
                    Get-DeploymentValidationResult -Config $cfg |
                        Where-Object Status -ne 'WARN' |
                        ForEach-Object { @{ Category = $_.Category; Check = $_.Check; Status = $_.Status; Expected = $_.Expected; Actual = $_.Actual } }
                }
                else { @() }
            }
            catch { @() }
        )
    ) {
        $Status | Should -BeExactly 'PASS' -Because "expected '$Expected' but found '$Actual'"
    }
}
