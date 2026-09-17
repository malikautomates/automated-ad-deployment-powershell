@{
    # =================================================================
    #  Vortex AI - Active Directory deployment configuration
    # =================================================================
    #
    #  This file is the ONLY place environment-specific values belong.
    #  None of the stage scripts contain an IP address, a domain name, a
    #  group name or a folder path. Pointing this deployment at another
    #  site means editing this file and nothing else.
    #
    #  It is loaded with Import-PowerShellDataFile, so it is pure data
    #  and cannot execute code, and it is schema-checked before the
    #  deployment touches the server.
    #
    #  Organisation modelled here:
    #    Vortex AI, 15 staff across three Canadian branches -
    #    Winnipeg (head office), Vancouver, Calgary.
    # =================================================================

    Domain          = @{
        # Internal AD namespace. Private, never resolvable on the
        # internet, and safe in a lab because it cannot collide with a
        # real domain.
        #
        # The .local suffix is legacy - it collides with mDNS/Bonjour and
        # can never hold a publicly trusted certificate - and preflight
        # will warn about it every run. It is workable here because the
        # UPN suffix below carries the identity that actually matters.
        #
        # Cleanest upgrade if you own a domain: 'corp.vortexai.ca'.
        # Changing these two lines is the only edit needed.
        DnsName     = 'vortexai.local'
        NetBiosName = 'VORTEXAI'
    }

    Server          = @{
        # VTX = Vortex, DC = domain controller, 01 = first of its kind.
        # Role-and-sequence naming, so the second DC is obviously VTX-DC02.
        # Must stay within the 15-character NetBIOS limit.
        ComputerName = 'VTX-DC01'
    }

    Network         = @{
        # AddressingMode:
        #
        #   PinCurrentLease  Read whatever DHCP has already assigned and
        #                    make exactly that permanent. Nothing about
        #                    reachability changes and no address has to
        #                    be chosen by hand. This is the default.
        #
        #   Static           Use IPAddress / PrefixLength / DefaultGateway
        #                    below. Use this when the address is dictated
        #                    by an IP plan.
        #
        #   Dhcp             Leave addressing alone. Supported so the
        #                    option exists, but a domain controller is
        #                    also the DNS server every client uses to
        #                    find it - an address that can move is not a
        #                    supportable production configuration. The
        #                    DNS client is pinned to this server either
        #                    way, because a lease renewal would otherwise
        #                    re-point the DC at a resolver that knows
        #                    nothing about the AD zone.
        AddressingMode = 'PinCurrentLease'

        # Leave empty to auto-detect, which requires exactly one
        # connected adapter. Set it explicitly (for example 'Ethernet0')
        # on any machine with more than one NIC.
        InterfaceAlias = ''

        # Used only when AddressingMode = 'Static'. These match the VM's
        # current VMware NAT lease, so switching modes gives the same
        # result.
        #
        # Worth knowing: VMware's NAT DHCP pool on vmnet8 defaults to
        # .128-.254, and .129 sits inside it. With a single VM this is
        # harmless. If you ever run a second VM on this subnet, either
        # move this below .128 or add a reservation in VMware's NAT
        # settings.
        IPAddress      = '192.168.133.129'
        PrefixLength   = 24
        DefaultGateway = '192.168.133.2'

        # DNS forwarders for the DC once it hosts DNS itself. Leave empty
        # to inherit whatever resolver the NIC was using before the
        # change - usually what you want, and how the VM keeps working
        # after promotion.
        Forwarders     = @()
    }

    Paths           = @{
        DeploymentRoot = 'C:\ADDeployment'

        # Relative paths resolve against DeploymentRoot, so the kit keeps
        # working when it is copied somewhere else. An absolute path is
        # honoured exactly as written.
        UsersCsv       = 'Data\Users.csv'
    }

    Identity        = @{
        # THE IMPORTANT LINE FOR HYBRID IDENTITY.
        #
        # The internal AD domain is vortexai.local, which can never be
        # verified in a Microsoft 365 tenant. Setting an alternative UPN
        # suffix means users sign in as malik@VortexAI654.onmicrosoft.com
        # both on-premises and in the cloud - one identity, one password,
        # and accounts that Entra Connect can actually sync.
        #
        # An .onmicrosoft.com domain is verified in the tenant by
        # default. Swap this for a custom verified domain (vortexai.ca)
        # once one is added to the tenant.
        #
        # Leave empty to fall back to Domain.DnsName.
        UpnSuffix                    = 'VortexAI654.onmicrosoft.com'
        Company                      = 'Vortex AI'

        # Length of the generated per-user password. Every account gets
        # its own random value; none is stored in the CSV.
        PasswordLength               = 20

        # Forces the generated password to be single-use.
        RequirePasswordChangeAtLogon = $true
    }

    # -----------------------------------------------------------------
    #  Organizational units
    #
    #  Listed parents-first; created in this order.
    #
    #  Users are separated by BRANCH rather than by department. That is
    #  deliberate: OUs exist to scope Group Policy and to delegate
    #  administration, and both of those follow geography - a Vancouver
    #  site link, a Calgary help-desk admin, a branch-specific drive
    #  mapping. Department is an attribute and a group membership, which
    #  is where it belongs, because people change department far more
    #  often than they change city.
    # -----------------------------------------------------------------
    OrganizationalUnits = @(
        @{ Name = 'VortexAI'; Parent = ''; Description = 'Root OU for all Vortex AI managed objects' }

        @{ Name = 'Users'; Parent = 'OU=VortexAI'; Description = 'All staff accounts, divided by branch' }
        @{ Name = 'Winnipeg'; Parent = 'OU=Users,OU=VortexAI'; Description = 'Winnipeg - head office' }
        @{ Name = 'Vancouver'; Parent = 'OU=Users,OU=VortexAI'; Description = 'Vancouver branch' }
        @{ Name = 'Calgary'; Parent = 'OU=Users,OU=VortexAI'; Description = 'Calgary branch' }

        @{ Name = 'Groups'; Parent = 'OU=VortexAI'; Description = 'Security groups' }
        @{ Name = 'Roles'; Parent = 'OU=Groups,OU=VortexAI'; Description = 'Global role groups - who someone is' }
        @{ Name = 'Resources'; Parent = 'OU=Groups,OU=VortexAI'; Description = 'Domain local resource groups - what a resource allows' }

        @{ Name = 'Computers'; Parent = 'OU=VortexAI'; Description = 'Domain-joined machines' }
        @{ Name = 'Servers'; Parent = 'OU=Computers,OU=VortexAI'; Description = 'Member servers' }
        @{ Name = 'Workstations'; Parent = 'OU=Computers,OU=VortexAI'; Description = 'Client workstations' }

        @{ Name = 'ServiceAccounts'; Parent = 'OU=VortexAI'; Description = 'Non-human accounts' }
    )

    # -----------------------------------------------------------------
    #  Groups - AGDLP
    #
    #      Accounts -> Global group -> Domain Local group -> Permission
    #
    #  ROLE_ groups (global) answer "who is this person?" - their
    #  department, their branch, whether they are staff at all.
    #  RES_ groups (domain local) answer "what does this resource
    #  allow?". Only RES_ groups ever appear on an ACL.
    #
    #  The payoff: access changes become membership changes, not ACL
    #  edits on a file server, and there is one place to answer "who can
    #  reach this folder?".
    #
    #  Membership of the ROLE_ groups comes from Data\Users.csv, which is
    #  treated as the HR feed. Nesting of ROLE_ into RES_ is
    #  infrastructure and lives here.
    #
    #  Identity strings in FolderStructure must carry the NetBIOS domain
    #  prefix, because that is the form Windows reports them in.
    # -----------------------------------------------------------------
    Groups          = @(
        # --- Role groups: everyone ------------------------------------
        @{ Name = 'ROLE_AllStaff'; Scope = 'Global'; Path = 'Roles'; Description = 'Role: every member of staff' }

        # --- Role groups: department ----------------------------------
        @{ Name = 'ROLE_Executive'; Scope = 'Global'; Path = 'Roles'; Description = 'Role: executive leadership' }
        @{ Name = 'ROLE_IT'; Scope = 'Global'; Path = 'Roles'; Description = 'Role: information technology' }
        @{ Name = 'ROLE_Finance'; Scope = 'Global'; Path = 'Roles'; Description = 'Role: finance' }
        @{ Name = 'ROLE_HR'; Scope = 'Global'; Path = 'Roles'; Description = 'Role: human resources' }
        @{ Name = 'ROLE_Sales'; Scope = 'Global'; Path = 'Roles'; Description = 'Role: sales' }
        @{ Name = 'ROLE_Marketing'; Scope = 'Global'; Path = 'Roles'; Description = 'Role: marketing' }
        @{ Name = 'ROLE_Operations'; Scope = 'Global'; Path = 'Roles'; Description = 'Role: operations' }

        # --- Role groups: branch --------------------------------------
        @{ Name = 'ROLE_Winnipeg'; Scope = 'Global'; Path = 'Roles'; Description = 'Role: Winnipeg head office staff' }
        @{ Name = 'ROLE_Vancouver'; Scope = 'Global'; Path = 'Roles'; Description = 'Role: Vancouver branch staff' }
        @{ Name = 'ROLE_Calgary'; Scope = 'Global'; Path = 'Roles'; Description = 'Role: Calgary branch staff' }

        # --- Resource groups: company-wide areas ----------------------
        @{
            Name         = 'RES_Company_Read'
            Scope        = 'DomainLocal'; Path = 'Resources'
            Description  = 'Resource: read on the company file tree'
            MemberGroups = @('ROLE_AllStaff')
        }
        @{
            Name         = 'RES_Company_Modify'
            Scope        = 'DomainLocal'; Path = 'Resources'
            Description  = 'Resource: modify on the company shared area'
            MemberGroups = @('ROLE_IT')
        }

        # --- Resource groups: departmental areas ----------------------
        @{
            Name         = 'RES_Finance_Modify'
            Scope        = 'DomainLocal'; Path = 'Resources'
            Description  = 'Resource: modify on the Finance share'
            MemberGroups = @('ROLE_Finance')
        }
        @{
            Name         = 'RES_Finance_Read'
            Scope        = 'DomainLocal'; Path = 'Resources'
            Description  = 'Resource: read on the Finance share'
            MemberGroups = @('ROLE_Executive')
        }
        @{
            Name         = 'RES_HR_Modify'
            Scope        = 'DomainLocal'; Path = 'Resources'
            Description  = 'Resource: modify on the HR share'
            MemberGroups = @('ROLE_HR')
        }
        @{
            Name         = 'RES_HR_Read'
            Scope        = 'DomainLocal'; Path = 'Resources'
            Description  = 'Resource: read on the HR share'
            MemberGroups = @('ROLE_Executive')
        }
        @{
            Name         = 'RES_IT_Modify'
            Scope        = 'DomainLocal'; Path = 'Resources'
            Description  = 'Resource: modify on the IT share'
            MemberGroups = @('ROLE_IT')
        }
        @{
            Name         = 'RES_Sales_Modify'
            Scope        = 'DomainLocal'; Path = 'Resources'
            Description  = 'Resource: modify on the Sales share'
            MemberGroups = @('ROLE_Sales')
        }
        @{
            Name         = 'RES_Sales_Read'
            Scope        = 'DomainLocal'; Path = 'Resources'
            Description  = 'Resource: read on the Sales share'
            MemberGroups = @('ROLE_Marketing')
        }

        # --- Resource groups: per-branch areas ------------------------
        @{
            Name         = 'RES_Winnipeg_Modify'
            Scope        = 'DomainLocal'; Path = 'Resources'
            Description  = 'Resource: modify on the Winnipeg branch share'
            MemberGroups = @('ROLE_Winnipeg')
        }
        @{
            Name         = 'RES_Vancouver_Modify'
            Scope        = 'DomainLocal'; Path = 'Resources'
            Description  = 'Resource: modify on the Vancouver branch share'
            MemberGroups = @('ROLE_Vancouver')
        }
        @{
            Name         = 'RES_Calgary_Modify'
            Scope        = 'DomainLocal'; Path = 'Resources'
            Description  = 'Resource: modify on the Calgary branch share'
            MemberGroups = @('ROLE_Calgary')
        }
    )

    # -----------------------------------------------------------------
    #  Folders, their permissions, and the shares that expose them
    #
    #  Inheritance is disabled on every folder here, and SYSTEM plus
    #  BUILTIN\Administrators are re-applied automatically whatever this
    #  list says - a folder with no SYSTEM entry breaks backup,
    #  antivirus and shadow copies.
    #
    #  Every grant is applied with ContainerInherit,ObjectInherit so it
    #  reaches files and subfolders created later.
    #
    #  The two container folders (VortexData, Branches) grant read to all
    #  staff purely so people can traverse down to what they can open.
    #  The folders beneath them break inheritance, so that read does not
    #  leak into Finance or HR.
    # -----------------------------------------------------------------
    FolderStructure = @(
        @{
            Path             = 'C:\VortexData'
            ShareName        = 'VortexData'
            ShareDescription = 'Vortex AI file tree - root'
            Permissions      = @(
                @{ Identity = 'VORTEXAI\RES_Company_Read'; Rights = 'ReadAndExecute' }
            )
        }
        @{
            Path             = 'C:\VortexData\Company'
            ShareName        = 'Company'
            ShareDescription = 'Company-wide documents - all staff'
            Permissions      = @(
                @{ Identity = 'VORTEXAI\RES_Company_Read'; Rights = 'ReadAndExecute' }
                @{ Identity = 'VORTEXAI\RES_Company_Modify'; Rights = 'Modify' }
            )
        }
        @{
            Path             = 'C:\VortexData\Finance'
            ShareName        = 'Finance'
            ShareDescription = 'Finance department - restricted'
            Permissions      = @(
                @{ Identity = 'VORTEXAI\RES_Finance_Modify'; Rights = 'Modify' }
                @{ Identity = 'VORTEXAI\RES_Finance_Read'; Rights = 'ReadAndExecute' }
            )
        }
        @{
            Path             = 'C:\VortexData\HR'
            ShareName        = 'HR'
            ShareDescription = 'Human resources - restricted'
            Permissions      = @(
                @{ Identity = 'VORTEXAI\RES_HR_Modify'; Rights = 'Modify' }
                @{ Identity = 'VORTEXAI\RES_HR_Read'; Rights = 'ReadAndExecute' }
            )
        }
        @{
            Path             = 'C:\VortexData\IT'
            ShareName        = 'IT'
            ShareDescription = 'IT department - builds, scripts, documentation'
            Permissions      = @(
                @{ Identity = 'VORTEXAI\RES_IT_Modify'; Rights = 'Modify' }
            )
        }
        @{
            Path             = 'C:\VortexData\Sales'
            ShareName        = 'Sales'
            ShareDescription = 'Sales - pipeline, pricing, proposals'
            Permissions      = @(
                @{ Identity = 'VORTEXAI\RES_Sales_Modify'; Rights = 'Modify' }
                @{ Identity = 'VORTEXAI\RES_Sales_Read'; Rights = 'ReadAndExecute' }
            )
        }
        @{
            Path             = 'C:\VortexData\Branches'
            ShareName        = 'Branches'
            ShareDescription = 'Per-branch working areas'
            Permissions      = @(
                @{ Identity = 'VORTEXAI\RES_Company_Read'; Rights = 'ReadAndExecute' }
            )
        }
        @{
            Path             = 'C:\VortexData\Branches\Winnipeg'
            ShareName        = 'Winnipeg'
            ShareDescription = 'Winnipeg head office working area'
            Permissions      = @(
                @{ Identity = 'VORTEXAI\RES_Winnipeg_Modify'; Rights = 'Modify' }
            )
        }
        @{
            Path             = 'C:\VortexData\Branches\Vancouver'
            ShareName        = 'Vancouver'
            ShareDescription = 'Vancouver branch working area'
            Permissions      = @(
                @{ Identity = 'VORTEXAI\RES_Vancouver_Modify'; Rights = 'Modify' }
            )
        }
        @{
            Path             = 'C:\VortexData\Branches\Calgary'
            ShareName        = 'Calgary'
            ShareDescription = 'Calgary branch working area'
            Permissions      = @(
                @{ Identity = 'VORTEXAI\RES_Calgary_Modify'; Rights = 'Modify' }
            )
        }
        @{
            Path             = 'C:\VortexData\Public'
            ShareName        = 'Public'
            ShareDescription = 'Open read-only drop area'
            # 'Everyone' includes anonymous and guest sessions.
            # 'Authenticated Users' is the safer production choice and is
            # a one-word change here.
            Permissions      = @(
                @{ Identity = 'Everyone'; Rights = 'ReadAndExecute' }
            )
        }
    )

    Features        = @{
        # FTP present but switched off.
        #
        # Flagging this honestly: IIS and FTP on a domain controller is
        # not something a production environment should do. It puts a
        # network-facing service on the machine holding every credential
        # in the domain, and FTP has no transport encryption. On a real
        # network this belongs on a member server, with FTPS or SFTP.
        # Set InstallFtp to $false if you do not need it.
        InstallFtp     = $true
        FtpServiceName = 'FTPSVC'

        # EVERY Windows role the deployment needs, installed together in
        # Stage 1 - before the first reboot, while an operator is still
        # watching the console.
        #
        # Installing them up front rather than one stage at a time matters
        # because of how this fails. A missing component payload (0x800f081f)
        # is easy to deal with at Stage 1, where you can attach an ISO and
        # re-run. The same error at Stage 3 or 4 happens unattended, as
        # SYSTEM, with no window on screen. One early failure beats three
        # late ones.
        #
        # Later stages still check for what they need, so they simply find
        # these already present and skip.
        #
        # DNS is here deliberately: Install-ADDSForest -InstallDns would
        # otherwise pull that payload during Stage 2, which runs unattended.
        # Pre-installing it is supported - promotion detects and configures
        # the existing role.
        #
        # Trim this list to match: drop Web-Server and Web-FTP-Server if
        # InstallFtp is $false, drop Windows-Server-Backup if Backup.Enabled
        # stays $false and you never intend to use it.
        Required       = @(
            'AD-Domain-Services'      # the directory itself
            'RSAT-AD-PowerShell'      # the ActiveDirectory module the stages call
            'DNS'                     # the domain's DNS, configured during promotion
            'Web-Server'              # IIS - prerequisite for FTP
            'Web-FTP-Server'          # the FTP requirement, left disabled
            'Windows-Server-Backup'   # wbadmin, for the system state job
        )

        # Payload source for role installation.
        #
        # Leave empty on a normal image. Set it when Install-WindowsFeature
        # fails with 0x800f081f - "the source files could not be found" -
        # which happens on evaluation and trimmed images whose side-by-side
        # component store does not carry the role binaries.
        #
        # Point it at the Windows Server installation media. Attach the ISO,
        # then find the image index matching the installed edition:
        #
        #     Get-WindowsImage -ImagePath D:\sources\install.wim
        #
        # and set, for example:
        #
        #     SourcePath = 'wim:D:\sources\install.wim:4'
        #
        # Used by every role install in the pipeline - AD DS, IIS/FTP and
        # Windows Server Backup.
        SourcePath     = ''
    }

    Dns             = @{
        CreateReverseLookupZone = $true
        EnableScavenging        = $true
        ScavengingIntervalDays  = 7
    }

    Time            = @{
        # The PDC emulator of the forest root is the authoritative clock
        # for the entire domain. If it drifts more than five minutes from
        # reality, Kerberos starts rejecting tickets and the errors
        # mention neither time nor Kerberos.
        ConfigurePdcTimeSource = $true
        NtpServers             = @('time.windows.com', 'pool.ntp.org')

        # VMware Tools synchronises guest time from the host, which
        # fights the Windows Time service. On a DC, Windows must win.
        DisableVMwareToolsSync = $true
    }

    PasswordPolicy  = @{
        # Applied after the accounts are created, so the generated
        # 20-character passwords are not rejected by a stricter rule.
        Apply                  = $true
        MinPasswordLength      = 14
        ComplexityEnabled      = $true
        MaxPasswordAgeDays     = 365
        MinPasswordAgeDays     = 1
        PasswordHistoryCount   = 24
        LockoutThreshold       = 10
        LockoutDurationMinutes = 15
        LockoutWindowMinutes   = 15
    }

    Security        = @{
        EnableAdRecycleBin = $true
        DisableSmb1        = $true
        EnableRdp          = $true

        AuditSubcategories = @(
            @{ Name = 'Logon'; Success = $true; Failure = $true }
            @{ Name = 'Logoff'; Success = $true; Failure = $false }
            @{ Name = 'Account Lockout'; Success = $true; Failure = $true }
            @{ Name = 'User Account Management'; Success = $true; Failure = $true }
            @{ Name = 'Security Group Management'; Success = $true; Failure = $true }
            @{ Name = 'Directory Service Changes'; Success = $true; Failure = $true }
            @{ Name = 'Credential Validation'; Success = $true; Failure = $true }
        )
    }

    Backup          = @{
        # Off by default, on purpose.
        #
        # wbadmin cannot write a system state backup to the volume it is
        # backing up, so on a single-disk VM there is nowhere valid to
        # put it. The feature is still installed and the task is still
        # created, but left disabled until a target exists.
        #
        # Give the VM a second disk, set TargetPath to 'E:', flip Enabled
        # to $true, and it becomes a working nightly backup.
        Enabled    = $false
        TargetPath = ''
        DailyAt    = '02:00'
    }

    Logging         = @{
        RetentionDays = 30
    }

    # -----------------------------------------------------------------
    #  Optional: Microsoft 365 / Entra ID onboarding
    #  (Scripts\9-OnboardMicrosoft365.ps1)
    #
    #  NOT part of the automatic pipeline. Requires hybrid identity to
    #  already be in place - see the README.
    # -----------------------------------------------------------------
    Microsoft365    = @{
        Enabled               = $false

        TenantId              = '<entra-tenant-id>'
        AppId                 = '<app-registration-client-id>'
        CertificateThumbprint = '<cert-thumbprint-in-localmachine-my>'

        # Must be verified in the tenant. The .onmicrosoft.com domain
        # always is, which is why it works as a starting point.
        VerifiedDomain        = 'VortexAI654.onmicrosoft.com'
        SyncWaitMinutes       = 15

        # Hostname of the Entra Connect server. Leave blank to rely on
        # its normal 30-minute sync schedule.
        EntraConnectServer    = ''

        # Group-based licensing in Entra ID is reconciled continuously by
        # Microsoft, including REVOKING when someone leaves the group. A
        # script assigning licences one at a time cannot match that, so
        # the default is to let the platform do it and only report.
        UseGroupBasedLicensing = $true
        GroupLicenseMap        = @{}

        # AD group name -> the Microsoft 365 Group ID behind the Team.
        # Get the id from the Teams admin center, or:
        #   Get-MgGroup -Filter "displayName eq 'Finance'" | Select-Object Id
        #
        # Mapping these to the Teams already in the tenant:
        #   ROLE_AllStaff  -> All Company
        #   ROLE_Finance   -> Finance
        #   ROLE_HR        -> HR
        #   ROLE_IT        -> IT
        # 'GetTrained' has no on-premises equivalent - it is a
        # cloud-only Team, which is fine and needs nothing here.
        GroupTeamMap           = @{
            # ROLE_AllStaff = '<group-id-for-All-Company>'
            # ROLE_Finance  = '<group-id-for-Finance>'
            # ROLE_HR       = '<group-id-for-HR>'
            # ROLE_IT       = '<group-id-for-IT>'
        }
    }
}
