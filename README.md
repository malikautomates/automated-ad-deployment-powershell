# Automated Active Directory Deployment and User Onboarding

[![CI](https://github.com/malikautomates/automated-ad-deployment-powershell/actions/workflows/ci.yml/badge.svg)](https://github.com/malikautomates/automated-ad-deployment-powershell/actions/workflows/ci.yml)
![PowerShell 5.1](https://img.shields.io/badge/PowerShell-5.1-5391FE?logo=powershell&logoColor=white)
![Windows Server 2022](https://img.shields.io/badge/Windows%20Server-2022-0078D4)
![Microsoft Graph](https://img.shields.io/badge/Microsoft%20Graph-PowerShell%20SDK-0078D4)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

Two PowerShell tools, built and run end to end on a real Windows Server 2022 lab, and documented
across seven labs from a bare virtual machine to a new starter signing in:

1. **[Deployment](Deployment/)** — one command turns a freshly installed server into the first
   domain controller of a new forest: addressing, rename, promotion, a 12-OU tree, 15 accounts,
   23 AGDLP groups, 11 permissioned shares and a security baseline. It restarts itself twice with
   **no stored credential and no auto-logon**, resumes after a failure, and finishes by validating
   the server against its own configuration.
2. **[Onboarding](Onboarding/)** — one command creates a new starter's Active Directory account,
   role groups, Microsoft 365 account, licence and Team membership, reading the same configuration
   so the two tools can never disagree about how the directory is laid out.

**Platform:** Windows Server 2022 · Windows 10 · Windows PowerShell 5.1 · VMware Workstation 17
**Cloud:** Microsoft 365 / Entra ID via the Microsoft Graph PowerShell SDK
**Organisation modelled:** `Vortex AI` (fictional) — domain `vortexai.local`, tenant `VortexAI654.onmicrosoft.com`

---

## At a glance

| | |
|---|---|
| **Operator input** | One command per tool. Two restarts handled automatically. |
| **Environment-specific values in scripts** | None — every IP, name, group and path lives in [`DeploymentConfig.psd1`](Deployment/Config/DeploymentConfig.psd1) |
| **Directory built** | 12 OUs · 15 accounts across 3 branches · 11 global + 12 domain local groups · 11 SMB shares |
| **Credentials stored on disk** | None reusable. DSRM secret DPAPI-protected; initial passwords single-use and ACL-restricted until handed over |
| **On-server validation** | 288 passed · 1 failed · 1 warning — the failure was a bug in the orchestrator, root-caused and fixed ([Lab 04 §5.1](labs/04-baseline-and-validation/README.md#51-fail--deployment-resume-task-vortex-deployment-resume-removed)) |
| **Offline design validation** | 410 passed · 0 failed · 1 intentional warning, on every push |
| **Unit tests** | 33 Pester tests on every push; integration tests self-skip off a domain controller |
| **Evidence** | 77 screenshots, individually reviewed, sensitive values redacted |

---

## Scope and approach

This repository is written as operational documentation rather than a tutorial.

**Every lab states its rationale.** Where more than one valid approach existed, the options and the
basis for the choice are recorded. Configuration without rationale shows a procedure was followed;
rationale shows it was understood.

**Every lab ends with verification.** A change is not complete until its effect is confirmed. Each
lab closes with the commands that prove the intended state, and says plainly which of them were
captured as evidence and which were not.

**Faults are documented, not omitted.** Where something failed — or where a gap was found only on
reviewing the evidence — the symptom, diagnosis, cause and resolution are recorded, including
whether the fix was re-verified on the server or only in code.

Standards shared by all labs — topology, addressing, naming, directory layout and baseline — are
defined once in [docs/environment.md](docs/environment.md).

---

## Laboratory index

### Build

| # | Lab | Summary | Status |
|---|---|---|---|
| 00 | [Server build](labs/00-server-build/) | Windows Server 2022 evaluation VM on an isolated NAT network, deliberately left unconfigured for the automation | Complete |
| 01 | [Remote access and kit transfer](labs/01-remote-access-and-kit-transfer/) | OpenSSH Server enabled once at the console; kit transferred over SCP and staged at `C:\ADDeployment` | Complete |
| 02 | [Automated forest deployment](labs/02-automated-forest-deployment/) | Stages 0–2: preflight, addressing, rename, promotion across two self-managed restarts — and the stored-credential design it replaced | Complete |

### Directory

| # | Lab | Summary | Status |
|---|---|---|---|
| 03 | [Directory build](labs/03-directory-build/) | Stage 3: branch-based OU tree, AGDLP role and resource groups, 15 accounts from a CSV feed, 11 shares with explicit ACLs | Complete |
| 04 | [Security baseline and validation](labs/04-baseline-and-validation/) | Stages 4–5: Recycle Bin, DNS, time, password policy, auditing; a 290-check validation report with its one failure root-caused | Complete |

### Operations

| # | Lab | Summary | Status |
|---|---|---|---|
| 05 | [Client join and access verification](labs/05-client-join-and-access-verification/) | Windows 10 domain join, first sign-in with a forced password change, and Kerberos and logon events read back from the DC | Complete |
| 06 | [New user onboarding](labs/06-new-user-onboarding/) | One command from new hire to signed-in user across Active Directory and Microsoft 365, with three onboarding bugs found in the evidence and fixed | Complete |

---

## Highlights

**Restarts survived without a credential.** The build restarts itself twice. Windows auto-logon
would store the administrator password in plaintext; a stored credential would go stale twice as
the machine is renamed and the local account is absorbed into the domain. The pipeline instead
registers a startup task as `NT AUTHORITY\SYSTEM`, which needs no password at all — and
[Lab 02](labs/02-automated-forest-deployment/) documents the stored-credential design it replaced.

**A validator that tests the build, not the script.** Stage 5 asks the finished server what it
looks like — IP origin, service state, every OU DN, every user's OU and UPN, group scope and
nesting, ACL rights *and* inheritance flags, audit subcategories — and compares each against
configuration. When it reported a failure, the cause was in the orchestrator, not the server, and
[Lab 04](labs/04-baseline-and-validation/) says so.

**AGDLP, so access follows people.** Accounts → global role groups → domain local resource groups →
ACL. A new Calgary finance hire gets correct access from one row of input; a transfer is a group
membership change, never an ACL edit.

**Evidence held to the same standard as the code.** Reviewing the onboarding screenshots surfaced
three real bugs — a dry run that printed a password, an interactive NuGet prompt in a
non-interactive install, and a missing Graph module — plus a verification command whose output was
silently swallowed by PowerShell's formatter. All are documented in
[Lab 06](labs/06-new-user-onboarding/); the code bugs are fixed.

---

## Capability matrix

| Capability | Labs |
|---|---|
| Windows Server installation and virtualisation | 00 |
| Secure remote administration (OpenSSH, SCP) | 01 |
| AD DS forest deployment and DC promotion | 02 |
| Unattended, resumable PowerShell orchestration | 02, 04 |
| OU design for delegation and Group Policy scoping | 03 |
| Role-based access control (AGDLP) and NTFS/SMB permissions | 03, 05 |
| Bulk identity provisioning from a data feed | 03 |
| DC hardening: password/lockout policy, auditing, SMBv1, Recycle Bin | 04 |
| DNS administration: forwarders, reverse zones, scavenging | 04, 05 |
| Automated compliance validation and reporting | 04 |
| Domain join, Kerberos and logon event analysis | 05 |
| User lifecycle automation across AD and Microsoft 365 (Graph) | 06 |
| Microsoft 365 licensing and least-privilege Graph consent | 06 |
| Testing and CI: Pester, PSScriptAnalyzer, GitHub Actions | All |

---

## Repository structure

```
.
├── README.md
├── LICENSE
├── PSScriptAnalyzerSettings.psd1
├── .github/workflows/ci.yml            Lint, unit tests, design validation, screenshot check
├── Deployment/
│   ├── Config/DeploymentConfig.psd1    Every environment-specific value
│   ├── Data/Users.csv                  Identity feed - no passwords
│   ├── Modules/Vortex.Deployment/      The engine: manifest, Public/, Private/
│   ├── Modules/Vortex.Microsoft365/    Optional Graph helpers (app-only auth)
│   ├── Scripts/Invoke-Deployment.ps1   Orchestrator - the only entry point
│   ├── Scripts/Test-DeploymentDesign.ps1  Offline configuration check
│   ├── Scripts/Stages/0..5             One stage per file
│   └── Tests/Deployment.Tests.ps1      Pester 5 suite
├── Onboarding/
│   └── New-VortexUser.ps1              Self-contained day-two tool
├── docs/
│   ├── environment.md                  Design specification shared by all labs
│   ├── LAB-TEMPLATE.md                 Structure applied to every lab
│   ├── DEPLOYMENT-RUNBOOK.md           Step by step, from a bare VM
│   ├── ONBOARDING-RUNBOOK.md           Step by step, per new hire
│   └── CHANGELOG.md
├── labs/
│   └── NN-lab-name/
│       ├── README.md                   Lab documentation
│       └── images/                     Evidence referenced by the lab
└── scripts/
    └── Test-LabImages.ps1              Every screenshot referenced, none orphaned
```

---

## Getting started

### Validate the design — on any Windows machine, no server needed

```powershell
.\Deployment\Scripts\Test-DeploymentDesign.ps1
```

Expect `410 passed, 0 failed, 1 warning`. The warning is the deliberate `Everyone` grant on the
public share.

### Deploy the domain

Full procedure in **[docs/DEPLOYMENT-RUNBOOK.md](docs/DEPLOYMENT-RUNBOOK.md)**; the lab walk-through
starts at [Lab 01](labs/01-remote-access-and-kit-transfer/).

```powershell
# Copy Deployment\ to C:\ADDeployment on the target server, then:
Get-ChildItem C:\ADDeployment -Recurse -File | Unblock-File
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

C:\ADDeployment\Scripts\Invoke-Deployment.ps1 -Only 0     # preflight, read-only
C:\ADDeployment\Scripts\Invoke-Deployment.ps1 -WhatIf     # dry run
C:\ADDeployment\Scripts\Invoke-Deployment.ps1             # go
```

| Flag | Effect |
|---|---|
| `-WhatIf` | Describes every action, performs none |
| `-Only 5` | Runs one stage — validation doubles as a recurring health check |
| `-StartFrom 3` | Begins at a stage |
| `-Force` | Re-runs steps already recorded complete (every step is idempotent) |
| `-Reset` | Forgets recorded progress; changes nothing on the server |

### Onboard a user

Full procedure in **[docs/ONBOARDING-RUNBOOK.md](docs/ONBOARDING-RUNBOOK.md)**.

```powershell
.\Onboarding\New-VortexUser.ps1 -ListLicenses
.\Onboarding\New-VortexUser.ps1 -FirstName Ada -LastName Okonkwo `
    -Branch Vancouver -Department Finance -JobTitle 'Financial Analyst' -WhatIf
```

| Flag | Effect |
|---|---|
| `-WhatIf` | Describes every change, performs none |
| `-ListLicenses` | Tenant SKUs and free seats; changes nothing |
| `-SkipCloud` | Active Directory half only |
| `-SkipAD` | Microsoft 365 half only — finishes an onboarding whose cloud steps failed |
| `-Manager` | Records the manager relationship |
| `-LicenseSku` | Override the default `SPE_E5`, or `None` |

### Requirements

- Windows Server 2022 or 2019, Desktop Experience; 4 GB RAM and 20 GB free disk minimum
- Windows PowerShell 5.1 — no other runtime on the server
- For onboarding's cloud half: a Microsoft 365 tenant and a Global Administrator to consent once

---

## Testing

```powershell
Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Force -SkipPublisherCheck
Invoke-Pester -Path .\Deployment\Tests\Deployment.Tests.ps1
```

Unit tests — configuration schema, distinguished-name construction, subnet arithmetic, password
generation, CSV and AGDLP invariants — run anywhere. Integration tests delegate to the same
function Stage 5 uses, so the test suite and the on-server report cannot drift, and they skip
themselves unless run on a domain controller.

CI runs on every push to `main`, on Windows PowerShell 5.1: PSScriptAnalyzer (build fails on Error
severity; one rule excluded with its justification in
[`PSScriptAnalyzerSettings.psd1`](PSScriptAnalyzerSettings.psd1)), the Pester suite, the offline
design validation, and [`Test-LabImages.ps1`](scripts/Test-LabImages.ps1).

---

## Known limitations

Stated plainly, because a project that claims none is not being honest:

- **`.local` internal domain.** Legacy suffix: collides with mDNS and can never hold a public
  certificate. Workable only because the UPN suffix is a tenant-verified domain. Preflight warns on
  every run; `corp.vortexai.ca` is a two-line change.
- **IIS and FTP on a domain controller.** Built because the original specification required them,
  and left installed-but-disabled. Production would never put a network-facing service with no
  transport encryption on the machine holding every credential in the domain.
- **`Everyone` on the public share.** Deliberately open; production uses `Authenticated Users`.
- **A shared `Support` sign-in account.** Activity cannot be attributed to a person. Production uses
  a shared mailbox with delegated access.
- **Single domain controller.** No replication partner — a single point of failure.
- **System state backup staged, not enabled.** `wbadmin` cannot back up system state to the volume
  it is backing up, so a single-disk VM has nowhere valid to put it.
- **Hybrid identity prepared, not live.** UPNs match a verified tenant domain; Entra Connect is not
  installed.
- **Domain join uses a Domain Administrator.** Production delegates *Create Computer objects* on the
  Workstations OU to a join account, and redirects the default computers container.
- **No tiered admin model, LAPS or Group Policy baseline.** Deliberately out of scope.
- **Not every fix is re-verified on the server.** The 2.1.x fixes are covered by tests and CI; the
  labs state which ones have not been re-run end to end.

---

## Related work

- [microsoft-365-administration-lab](https://github.com/malikautomates/microsoft-365-administration-lab) —
  the same `Vortex AI` tenant, administered across 13 labs: identity, PIM, Conditional Access,
  Exchange Online, Teams, SharePoint, Purview and Intune.

---

## Contact

- **Email:** [m.abdulmaliksani008@gmail.com](mailto:m.abdulmaliksani008@gmail.com)
- **LinkedIn:** [linkedin.com/in/muhammed-abdulmalik-a84131267](https://www.linkedin.com/in/muhammed-abdulmalik-a84131267)
- **GitHub:** [@malikautomates](https://github.com/malikautomates)

Released under the [MIT License](LICENSE).
