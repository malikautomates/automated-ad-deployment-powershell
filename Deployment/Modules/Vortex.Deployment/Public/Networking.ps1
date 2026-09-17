<#
    Addressing for the domain controller.

    A DC is also the DNS server every member of the domain uses to find it, so
    two things matter far more than they would on an ordinary server:

      1. The address must not move. Everything that points at this machine
         points at it by IP.
      2. The DNS client must be pinned. If the NIC keeps taking DNS from DHCP,
         every lease renewal re-points the DC at a resolver that knows nothing
         about the AD zone, and domain lookups start failing intermittently.

    PinCurrentLease exists so (1) can be satisfied without anyone having to
    choose an address: whatever DHCP already handed out becomes the permanent
    static address.
#>

function Get-TargetAdapter {
    <#
    .SYNOPSIS
        Resolves exactly which NIC to configure.

    .DESCRIPTION
        The original scripts used (Get-NetAdapter).InterfaceIndex, which returns
        an array the moment a second adapter exists and then silently
        misconfigures the wrong one. Ambiguity is treated as an error here, with
        a message naming the adapters and the setting that resolves it.
    #>
    [CmdletBinding()]
    param([string] $InterfaceAlias)

    if ($InterfaceAlias) {
        $adapter = Get-NetAdapter -Name $InterfaceAlias -ErrorAction SilentlyContinue
        if (-not $adapter) {
            $available = (Get-NetAdapter | Select-Object -ExpandProperty Name) -join ', '
            throw "Network adapter '$InterfaceAlias' not found. Adapters on this machine: $available"
        }
        return $adapter
    }

    $candidates = @(Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and -not $_.Virtual })
    if ($candidates.Count -eq 0) {
        $candidates = @(Get-NetAdapter | Where-Object { $_.Status -eq 'Up' })
    }
    if ($candidates.Count -eq 0) {
        throw 'No connected network adapter found. Check the VM network settings and that the adapter is enabled.'
    }
    if ($candidates.Count -gt 1) {
        throw ("Found {0} connected adapters ({1}). Set Network.InterfaceAlias in DeploymentConfig.psd1 to the one to configure." -f `
                $candidates.Count, ($candidates.Name -join ', '))
    }
    return $candidates[0]
}

function Resolve-NetworkPlan {
    <#
    .SYNOPSIS
        Works out the addressing to apply, without applying it.

    .DESCRIPTION
        Separating the decision from the change means preflight can show exactly
        what will happen, -WhatIf is meaningful, and the chosen address can be
        written to the state file before anything is touched.

        Modes:
          PinCurrentLease  Read what DHCP has already assigned and make that
                           permanent. Nothing about reachability changes.
          Static           Use the explicit values from configuration.
          Dhcp             Leave addressing alone. Supported, not recommended;
                           the DNS client is still pinned to this server.

    .PARAMETER UpstreamDnsOverride
        Forces the upstream resolver recorded for later use as a DNS forwarder.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable] $Config,
        $Adapter,
        [string[]] $UpstreamDnsOverride
    )

    if (-not $Adapter) {
        $Adapter = Get-TargetAdapter -InterfaceAlias (Get-ConfigValue $Config.Network 'InterfaceAlias' '')
    }

    $mode = $Config.Network.AddressingMode
    $ipConfig = Get-NetIPConfiguration -InterfaceIndex $Adapter.ifIndex -ErrorAction Stop

    $currentIp = @($ipConfig.IPv4Address) | Select-Object -First 1
    $currentGateway = @($ipConfig.IPv4DefaultGateway) | Select-Object -First 1

    # Whatever is resolving names right now is what the DC should forward to
    # once it owns DNS itself. Its own addresses and loopback are excluded so a
    # re-run cannot make the server its own forwarder (which would be a loop).
    $ownAddresses = @($ipConfig.IPv4Address.IPAddress)
    $upstream = @(
        @($ipConfig.DNSServer | Where-Object { $_.AddressFamily -eq 2 } | ForEach-Object { $_.ServerAddresses }) |
            Where-Object { $_ -and $_ -notlike '127.*' -and $_ -notin $ownAddresses }
    )

    if ($UpstreamDnsOverride) { $upstream = @($UpstreamDnsOverride) }
    elseif (Get-ConfigValue $Config.Network 'Forwarders') { $upstream = @($Config.Network.Forwarders) }
    elseif ($upstream.Count -eq 0 -and $currentGateway) { $upstream = @($currentGateway.NextHop) }

    switch ($mode) {
        'PinCurrentLease' {
            if (-not $currentIp) {
                throw "AddressingMode is PinCurrentLease but adapter '$($Adapter.Name)' has no IPv4 address to pin. Check that DHCP is reachable, or switch to AddressingMode = 'Static'."
            }
            if (-not $currentGateway) {
                throw "AddressingMode is PinCurrentLease but adapter '$($Adapter.Name)' has no default gateway. Switch to AddressingMode = 'Static' and set the values explicitly."
            }
            $plan = [pscustomobject]@{
                Mode           = $mode
                InterfaceAlias = $Adapter.Name
                InterfaceIndex = $Adapter.ifIndex
                IPAddress      = $currentIp.IPAddress
                PrefixLength   = $currentIp.PrefixLength
                DefaultGateway = $currentGateway.NextHop
                UpstreamDns    = $upstream
                WasDhcp        = ($currentIp.PrefixOrigin -eq 'Dhcp')
                Summary        = ''
            }
        }
        'Static' {
            $plan = [pscustomobject]@{
                Mode           = $mode
                InterfaceAlias = $Adapter.Name
                InterfaceIndex = $Adapter.ifIndex
                IPAddress      = $Config.Network.IPAddress
                PrefixLength   = [int]$Config.Network.PrefixLength
                DefaultGateway = $Config.Network.DefaultGateway
                UpstreamDns    = $upstream
                WasDhcp        = ($currentIp -and $currentIp.PrefixOrigin -eq 'Dhcp')
                Summary        = ''
            }
        }
        'Dhcp' {
            $plan = [pscustomobject]@{
                Mode           = $mode
                InterfaceAlias = $Adapter.Name
                InterfaceIndex = $Adapter.ifIndex
                IPAddress      = $(if ($currentIp) { $currentIp.IPAddress } else { $null })
                PrefixLength   = $(if ($currentIp) { $currentIp.PrefixLength } else { $null })
                DefaultGateway = $(if ($currentGateway) { $currentGateway.NextHop } else { $null })
                UpstreamDns    = $upstream
                WasDhcp        = $true
                Summary        = ''
            }
        }
        default { throw "Unsupported AddressingMode '$mode'." }
    }

    $plan.Summary = if ($mode -eq 'Dhcp') {
        "Leave '$($plan.InterfaceAlias)' on DHCP (currently $($plan.IPAddress)); pin DNS client to this server; forward to $($plan.UpstreamDns -join ', ')."
    }
    else {
        "Set '$($plan.InterfaceAlias)' to $($plan.IPAddress)/$($plan.PrefixLength) gateway $($plan.DefaultGateway) (mode $mode); forward DNS to $($plan.UpstreamDns -join ', ')."
    }

    return $plan
}

function Set-DeploymentNetwork {
    <#
    .SYNOPSIS
        Applies an addressing plan produced by Resolve-NetworkPlan.

    .DESCRIPTION
        DNS is deliberately left pointing at the existing upstream resolver at
        this point. The server does not host DNS yet, so pointing it at itself
        now would leave it unable to resolve anything at all between this stage
        and forest promotion. Promotion installs DNS and repoints the client;
        Stage 4 then sets the forwarders recorded here.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] $Plan)

    if ($Plan.Mode -eq 'Dhcp') {
        Write-DeploymentLog -Level WARN -Message 'AddressingMode is Dhcp - leaving addressing untouched. A domain controller whose address can change is not a supported production configuration.'
        return
    }

    $index = $Plan.InterfaceIndex

    $existing = Get-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -eq $Plan.IPAddress -and $_.PrefixOrigin -eq 'Manual' }
    if ($existing) {
        Write-DeploymentLog -Message "Adapter '$($Plan.InterfaceAlias)' already holds $($Plan.IPAddress)/$($Plan.PrefixLength) statically - nothing to change."
        return
    }

    if (-not $PSCmdlet.ShouldProcess($Plan.InterfaceAlias, $Plan.Summary)) { return }

    # Order matters. DHCP has to release ownership of the interface before a
    # manual address can be bound, and the old address and default route have to
    # go before the new ones are added or New-NetIPAddress reports a conflict.
    Set-NetIPInterface -InterfaceIndex $index -Dhcp Disabled -ErrorAction SilentlyContinue

    Get-NetIPAddress -InterfaceIndex $index -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

    Get-NetRoute -InterfaceIndex $index -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

    New-NetIPAddress -InterfaceIndex $index `
        -IPAddress $Plan.IPAddress `
        -PrefixLength $Plan.PrefixLength `
        -DefaultGateway $Plan.DefaultGateway `
        -AddressFamily IPv4 -ErrorAction Stop | Out-Null

    if ($Plan.UpstreamDns -and $Plan.UpstreamDns.Count -gt 0) {
        Set-DnsClientServerAddress -InterfaceIndex $index -ServerAddresses $Plan.UpstreamDns -ErrorAction Stop
    }

    Write-DeploymentLog -Level SUCCESS -Message "Adapter '$($Plan.InterfaceAlias)' is now $($Plan.IPAddress)/$($Plan.PrefixLength), gateway $($Plan.DefaultGateway), DNS $($Plan.UpstreamDns -join ', ') (temporary - repointed at this server after promotion)."
}

function ConvertTo-NetworkId {
    <#
    .SYNOPSIS
        Turns an address and prefix length into a network id.

    .DESCRIPTION
        Used for the DNS reverse lookup zone, which is defined by the network
        rather than by any single host address.

    .EXAMPLE
        ConvertTo-NetworkId -IPAddress 192.168.133.129 -PrefixLength 24
        192.168.133.0/24
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $IPAddress,
        [Parameter(Mandatory)] [ValidateRange(1, 32)] [int] $PrefixLength
    )

    $addressBytes = ([ipaddress]$IPAddress).GetAddressBytes()

    $maskBytes = New-Object byte[] 4
    $bitsRemaining = $PrefixLength
    for ($i = 0; $i -lt 4; $i++) {
        $bitsInThisByte = [math]::Min(8, [math]::Max(0, $bitsRemaining))
        $maskBytes[$i] = [byte](( -bnot ((1 -shl (8 - $bitsInThisByte)) - 1)) -band 0xFF)
        $bitsRemaining -= $bitsInThisByte
    }

    $networkBytes = @()
    for ($i = 0; $i -lt 4; $i++) { $networkBytes += ($addressBytes[$i] -band $maskBytes[$i]) }

    return "$($networkBytes -join '.')/$PrefixLength"
}

function Set-DomainControllerDnsClient {
    <#
    .SYNOPSIS
        Points the DC's own DNS client at itself, the way it must stay.

    .DESCRIPTION
        Run after promotion. Its own address first and loopback second is the
        configuration Microsoft documents for a domain controller that hosts DNS.
        Setting this explicitly (rather than relying on what dcpromo left behind)
        also makes the setting static, so DHCP can never overwrite it.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $InterfaceAlias,
        [string] $SelfAddress
    )

    $adapter = Get-NetAdapter -Name $InterfaceAlias -ErrorAction Stop
    if (-not $SelfAddress) {
        $SelfAddress = (Get-NetIPConfiguration -InterfaceIndex $adapter.ifIndex).IPv4Address.IPAddress | Select-Object -First 1
    }

    $servers = @($SelfAddress, '127.0.0.1') | Where-Object { $_ } | Select-Object -Unique
    if ($PSCmdlet.ShouldProcess($InterfaceAlias, "Set DNS client servers to $($servers -join ', ')")) {
        Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $servers -ErrorAction Stop
        Write-DeploymentLog -Level SUCCESS -Message "DNS client on '$InterfaceAlias' pinned to $($servers -join ', ')."
    }
}
