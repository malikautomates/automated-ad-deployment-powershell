# Environment Design Specification

**Document status:** Baseline
**Applies to:** All labs in this repository
**Platform:** Windows Server 2022 Datacenter (Evaluation), Windows 10 x64, VMware Workstation 17,
Microsoft 365 / Microsoft Entra ID

---

## 1. Purpose

This document defines the environment every lab in this repository was performed against:
topology, addressing, naming, directory layout, and the Microsoft 365 tenant used for the
onboarding half. Every value environment-specific to the automation lives in one file,
[`Deployment/Config/DeploymentConfig.psd1`](../Deployment/Config/DeploymentConfig.psd1); this
document explains the reasoning behind those values rather than repeating them.

Where a lab deviates from this specification, the deviation is stated in that lab.

> **Scope.** This is a self-built lab on a single workstation, not production client work. The
> organisation (`Vortex AI`), its staff and its branches are fictional and exist to give each
> configuration a realistic reason to exist.

---

## 2. Topology

```
 Windows 11 host (VMware Workstation 17)
 │
 └── vmnet8  NAT  192.168.133.0/24   gateway/DNS proxy 192.168.133.2   DHCP pool .128–.254
      │
      ├── VTX-DC01      Windows Server 2022 Datacenter (Evaluation)
      │                 192.168.133.129/24 (DHCP lease pinned as static)
      │                 AD DS · DNS · File Services · IIS/FTP (disabled) · Windows Server Backup
      │
      └── VORTEXAI-PC   Windows 10 x64
                        192.168.133.128/24 (DHCP) · DNS → 192.168.133.129

 Microsoft 365 tenant   VortexAI654.onmicrosoft.com   (cloud-only; shared with the
                        microsoft-365-administration-lab repository)
```

| Host | Role | vCPU | Memory | Disk | Network |
|---|---|---|---|---|---|
| `VTX-DC01` | First domain controller, DNS, file server | 4 | 8 GB | 60 GB | NAT |
| `VORTEXAI-PC` | Domain-joined client used for sign-in and access tests | — | — | — | NAT |

The server VM was deliberately sized above the deployment's stated minimum (4 GB RAM, 20 GB
free disk) so that role installation and promotion were not memory-bound during capture.

---

## 3. Addressing

| Decision | Options considered | Selected | Rationale |
|---|---|---|---|
| Network type | Bridged; NAT; host-only | NAT | Internet access for Windows Update and the PowerShell Gallery, without placing a lab DHCP/DNS server on the physical LAN. |
| Server address | Choose a static address; pin the current DHCP lease; stay on DHCP | Pin the current lease (`AddressingMode = 'PinCurrentLease'`) | No address has to be chosen, and reachability does not change mid-deployment (the SSH session in Lab 01 survives). A DC is the DNS server its clients use to find it, so its address must never move. |
| DNS client on the DC | Loopback only; own address only; own address + loopback | Own address, then `127.0.0.1` | Pinned by Stage 3 after DNS is installed. Stage 1 deliberately leaves the upstream resolver in place, because the server does not host DNS yet. |
| DNS forwarders | Public resolvers; the NAT resolver recorded before promotion | Recorded upstream resolver (`192.168.133.2`) | The resolver the VM already used successfully; no external dependency is introduced. |

> **Known constraint.** VMware's NAT DHCP pool on `vmnet8` starts at `.128`, and `.129` sits
> inside it. With the two VMs used here this is harmless; a third VM on the subnet should get a
> reservation or an address below `.128`. Recorded in the configuration file beside the value.

---

## 4. Naming

| Object | Value | Convention |
|---|---|---|
| Forest / domain (DNS) | `vortexai.local` | See the note below |
| NetBIOS name | `VORTEXAI` | ≤ 15 characters |
| Domain controller | `VTX-DC01` | `<org>-<role><sequence>` — the second DC is obviously `VTX-DC02` |
| Client | `VortexAI-PC` | Lab client |
| UPN suffix | `VortexAI654.onmicrosoft.com` | Matches a domain verified in the Microsoft 365 tenant |
| Role groups | `ROLE_<Department\|Branch\|AllStaff>` | Global scope — *who someone is* |
| Resource groups | `RES_<Resource>_<Read\|Modify>` | Domain local scope — *what a resource allows* |
| Logon names (onboarding) | first initial + surname, lowercased | `cpulisic`; a digit is appended on collision |

> **On `.local`.** The suffix is legacy: it collides with mDNS/Bonjour and can never hold a
> publicly trusted certificate. It is tolerable here only because the UPN suffix — the identity
> people actually sign in with — is a tenant-verified domain. Preflight warns about it on every
> run. The production choice is a subdomain of a registered domain, for example
> `corp.vortexai.ca`; the change is two lines in the configuration file.

---

## 5. Directory layout

### 5.1 Organizational units

```
vortexai.local
└── VortexAI
    ├── Users ─────────── Winnipeg · Vancouver · Calgary
    ├── Groups ────────── Roles · Resources
    ├── Computers ─────── Servers · Workstations
    └── ServiceAccounts
```

Twelve OUs, all protected from accidental deletion. **Users are separated by branch, not
department.** OUs exist to scope Group Policy and delegate administration, and both follow
geography — a branch site link, a branch help-desk delegate, a branch drive mapping. Department
is an attribute and a group membership, because people change department far more often than
they change city.

### 5.2 Group model (AGDLP)

```
Account  →  Global role group  →  Domain local resource group  →  NTFS permission
cpulisic     ROLE_Sales              RES_Sales_Modify                C:\VortexData\Sales
```

| Type | Count | Scope | Appears on ACLs |
|---|---|---|---|
| `ROLE_*` — all-staff, 7 departments, 3 branches | 11 | Global | Never |
| `RES_*` — per resource, read or modify | 12 | Domain local | Always |

Every person carries three role groups — all-staff, department, branch — so correct access for a
new hire follows from one row of input, and a transfer is a membership change rather than an ACL
review.

### 5.3 Accounts

15 accounts from [`Deployment/Data/Users.csv`](../Deployment/Data/Users.csv): 14 staff across
three branches and one shared `Support` account in `ServiceAccounts`. The CSV is an identity
feed only — it carries **no password column**. Every account receives its own generated
password at run time and must change it at first sign-in.

### 5.4 File resources

Eleven folders under `C:\VortexData`, each published as an SMB share: `VortexData` (root),
`Company`, `Finance`, `HR`, `IT`, `Sales`, `Public`, `Branches`, and `Branches\{Winnipeg,
Vancouver, Calgary}`. Inheritance is disabled on every folder; `SYSTEM` and
`BUILTIN\Administrators` are re-applied automatically, and every grant uses
`ContainerInherit,ObjectInherit` so it reaches files created later.

---

## 6. Security baseline

Applied by Stage 4 of the deployment and asserted by Stage 5.

| Control | Setting |
|---|---|
| AD Recycle Bin | Enabled (irreversible by design, so enabled at build time) |
| Password policy | Minimum length 14, complexity on, history 24, maximum age 365 days |
| Account lockout | Threshold 10, 15-minute duration and observation window |
| Advanced audit policy | Logon, Logoff, Account Lockout, Credential Validation, User Account Management, Security Group Management, Directory Service Changes |
| SMBv1 | Disabled |
| Remote Desktop | Enabled with Network Level Authentication |
| Time | PDC emulator syncs from `time.windows.com` and `pool.ntp.org`; VMware Tools host time sync disabled |
| Restart survival | Scheduled task as `NT AUTHORITY\SYSTEM` — no stored credential, no auto-logon |
| DSRM password | Generated, stored with machine-scoped DPAPI, restricted to Administrators and SYSTEM |

---

## 7. Microsoft 365 tenant

| Item | Value |
|---|---|
| Tenant | `VortexAI654.onmicrosoft.com` (no custom domain) |
| Identity model | Cloud-only. UPNs match on-premises so Entra Connect *could* sync; it is not installed |
| Licences observed | `SPE_E5` (Microsoft 365 E5), `AAD_PREMIUM_P2`, `Microsoft_Entra_ID_Governance` |
| Graph modules | `Microsoft.Graph.Authentication`, `.Users`, `.Users.Actions`, `.Groups`, `.Identity.DirectoryManagement` |
| Graph scopes (onboarding) | `User.ReadWrite.All`, `Group.ReadWrite.All`, `Organization.Read.All` |

The same tenant is administered in the
[microsoft-365-administration-lab](https://github.com/malikautomates/microsoft-365-administration-lab)
repository, which is why several staff names appear in both.

---

## 8. Evidence handling

All screenshots were reviewed individually before publication. Redacted regions are marked
`REDACTED` and cover: a generated initial password, a Microsoft sign-in session token, the
administrator's sign-in address, an Entra object ID, an SSH host key fingerprint, the Windows
product ID, a MAC and link-local IPv6 address, and the host machine's local username. Private
RFC 1918 addresses in the isolated NAT network are left visible because the labs depend on them.
