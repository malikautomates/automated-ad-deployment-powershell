# Lab 06 — New User Onboarding Automation

**Objective:** Onboard a new starter end to end from one command — Active Directory account, role
groups, Microsoft 365 account, licence and Team membership — then prove the account works from a
domain-joined client.
**Environment:** `VTX-DC01` (runs the script), `VortexAI-PC` (sign-in test), tenant `VortexAI654.onmicrosoft.com`.
**Prerequisites:** Labs 03 and 05; a Microsoft 365 tenant and a Global Administrator for first-run consent.
**Automation:** [`Onboarding/New-VortexUser.ps1`](../../Onboarding/New-VortexUser.ps1) — self-contained, no module dependency on the deployment kit.
**Duration:** About 3 minutes per hire; 5–10 minutes more on the very first run while Graph modules install.

---

## 1. Scenario

Christian Pulisic joins the Vancouver branch as an Account Executive in Sales. Done by hand,
onboarding touches two consoles and a dozen fields, and the usual failures are small and
expensive: an account in the wrong OU, a missed group that surfaces as an access ticket a week
later, a licence assigned before the usage location so the portal rejects it, or a duplicate cloud
identity in a tenant that is already syncing. The requirement is a day-two tool a service desk
analyst can run safely, that derives everything it can and asks only for what it cannot know.

---

## 2. Design decisions

| Decision | Options considered | Selected | Rationale |
|---|---|---|---|
| Relationship to the deployment | A stage in the pipeline; a separate tool | Separate script that reads the **same** `DeploymentConfig.psd1` | Onboarding is a recurring operation, not part of the build. Sharing the configuration means the two cannot disagree about OUs, group names or the UPN suffix. |
| Input | Free text; validated sets | `ValidateSet` for branch and department | A typo is rejected before the directory is touched, so it cannot create an account in the wrong place. |
| Access assignment | Grant folders; add role groups | Three role groups — all-staff, department, branch | AGDLP from Lab 03 does the rest. No ACL is ever edited during onboarding. |
| Cloud account | Always create; look first | Look up by UPN, create only if absent | In a hybrid tenant Entra Connect has already created the account and a second would be a duplicate identity; in a cloud-only tenant nothing has. One script is correct in both. |
| Graph authentication | App-only certificate; delegated interactive | Delegated interactive, least scopes (`User.ReadWrite.All`, `Group.ReadWrite.All`, `Organization.Read.All`) | A person runs this tool, and every change is attributable to that person in the audit log. The unattended equivalent uses certificate auth in `Deployment/Scripts/9-OnboardMicrosoft365.ps1`. |
| Licensing | Assign blindly; check seats | Set usage location first, then check free seats before assigning | `Set-MgUserLicense` fails without a usage location, with an error that never mentions it. A seat check turns a hard failure into a clear warning. |
| Partial failure | Abort; continue | If the cloud half fails, finish and show the password | The AD account already exists and its password is shown only once. Aborting would leave a real account whose credential nobody holds. `-SkipAD` finishes the cloud half later. |
| Credential handover | Email; write to a file; show once on screen | Show once, never written to disk | Instructs the operator to deliver it in person or through a password manager. Forced change at first sign-in on both sides. |

---

## 3. Implementation

### Step 1 — The script

![New-VortexUser.ps1 synopsis: four things it does and why step 3 looks before it creates](images/06-01-onboarding-script-synopsis.png)

The comment-based help, readable on the server with `Get-Help .\New-VortexUser.ps1 -Full`: what the
tool does, and why the cloud step looks before it creates.

![New-TempPassword: cryptographic RNG, confusable characters excluded, complexity by construction](images/06-02-password-generator-source.png)

The password generator: `RandomNumberGenerator` rather than `Get-Random`, `O/o/0` and `l/1/I/i`
excluded so a password read aloud or from a note is not mistyped, and one character of each class
placed first so complexity is guaranteed rather than probable.

---

### Step 2 — Confirm tenant access from the server

![Microsoft sign-in from the server's browser, account redacted](images/06-03-tenant-sign-in-from-server.png)

Signing in to the tenant from the domain controller's browser to confirm outbound access to
Microsoft Entra before running Graph. Session token and administrator address redacted.

![Azure portal home signed in to the VORTEX AI tenant](images/06-04-azure-portal-signed-in.png)

Signed in to the Vortex AI tenant. The administrator's sign-in address is redacted.

---

### Step 3 — First run: prerequisites and licence inventory

```powershell
cd C:\New-VortexUser
.\New-VortexUser.ps1 -ListLicenses
```

![Script staged in C:\New-VortexUser; first run installing two missing Graph modules](images/06-05-script-staged-on-server.png)

`-ListLicenses` is read-only. On first use it finds the Graph modules missing and installs only the
two that listing needs.

![NuGet provider prompt interrupting the module install](images/06-06-graph-module-auto-install.png)

An interactive NuGet bootstrap prompt appeared mid-install — a fault in a script designed to run
without prompts. Diagnosed and fixed in §5.1.

![Web Account Manager sign-in picker](images/06-07-graph-sign-in-prompt.png)

Modules installed; `Connect-MgGraph` opens the Windows sign-in picker (Web Account Manager).

![Consent dialog: Microsoft Graph Command Line Tools requesting organization read and basic profile](images/06-08-graph-consent.png)

The consent screen shows exactly the permission `-ListLicenses` requests —
`Organization.Read.All`, surfacing as *Read organization information* — and nothing broader.
*Consent on behalf of your organization* is left unticked. Account redacted.

![Tenant SKUs: AAD_PREMIUM_P2, Entra ID Governance, SPE_E5 with 18 seats free](images/06-09-tenant-licence-inventory.png)

What the tenant owns and how many seats are free. `SPE_E5` (Microsoft 365 E5) has 18 available, so
the default licence can be assigned.

---

### Step 4 — Dry run

```powershell
.\New-VortexUser.ps1 -FirstName Christian -LastName Pulisic `
    -Branch Vancouver -Department Sales -JobTitle 'Account Executive' -WhatIf
```

![The onboarding command with -WhatIf](images/06-10-onboarding-command.png)

The same command that will be run for real, with `-WhatIf`.

![Dry-run output: derived identity, What if lines, and a handover block that should not have appeared](images/06-11-dry-run.png)

Everything derived from five inputs: logon name `cpulisic`, UPN on the tenant domain, target OU
`OU=Vancouver,OU=Users,OU=VortexAI`, three role groups, licence `SPE_E5`. Each change is described
as a `What if:` line and none is performed. The closing *Onboarding complete* block with a
password was a bug — see §5.2. Password redacted.

---

### Step 5 — Run it

```powershell
.\New-VortexUser.ps1 -FirstName Christian -LastName Pulisic `
    -Branch Vancouver -Department Sales -JobTitle 'Account Executive'
```

![Real run: AD account created, three role groups added, Microsoft 365 account created, usage location set](images/06-12-real-run.png)

The real run below the dry run: `OK Created AD account 'cpulisic'`, added to `ROLE_AllStaff`,
`ROLE_Sales` and `ROLE_Vancouver`, Graph modules already present, `OK Created Microsoft 365
account`, `OK Usage location set to CA`. The output continues below the captured frame.

---

### Step 6 — Verify on-premises

![ADUC: Christian Pulisic properties in the Vancouver OU](images/06-13-ad-account-properties.png)

The account in `VortexAI\Users\Vancouver`, with name, display name and office set by the script.

```powershell
Get-ADPrincipalGroupMembership cpulisic | Select-Object Name
```

![Get-ADPrincipalGroupMembership cpulisic: Domain Users, ROLE_AllStaff, ROLE_Sales, ROLE_Vancouver](images/06-14-group-membership-query.png)

Exactly the three role groups plus `Domain Users`. A second command in the same paste produced no
visible output — see §5.3.

---

### Step 7 — Verify in Microsoft 365

![Microsoft 365 admin center: Christian Pulisic, cpulisic@VortexAI654.onmicrosoft.com, no administrator access](images/06-15-m365-account.png)

The cloud account in the Microsoft 365 admin center with the matching UPN and no administrator
roles. Entra object ID in the address bar redacted.

---

### Step 8 — First sign-in from the client

![Windows sign-in on VortexAI-PC as cpulisic](images/06-16-first-sign-in.png)

The new starter signing in on the domain-joined client with the one-time password.

![The user's password must be changed before signing in](images/06-17-password-change-required.png)

Single-use password enforced.

![New password and confirmation entry](images/06-18-new-password-entry.png)

The user chooses their own password.

![Your password has been changed](images/06-19-password-changed.png)

Change accepted against the domain password policy from Lab 04.

![Welcome screen for Christian Pulisic](images/06-20-profile-loading.png)

Profile loading with the display name the script set.

![Your info: CHRISTIAN PULISIC, VORTEXAI\cpulisic](images/06-21-signed-in-identity.png)

Signed in as `VORTEXAI\cpulisic` — a working domain identity created without opening Active
Directory Users and Computers or the Microsoft 365 admin center.

---

## 4. Verification

| Check | Command | Success criterion |
|---|---|---|
| AD account | `Get-ADUser cpulisic -Properties Office, Title, Department` | In `OU=Vancouver`, attributes set |
| Role groups | `Get-ADPrincipalGroupMembership cpulisic \| Select Name` | `ROLE_AllStaff`, `ROLE_Sales`, `ROLE_Vancouver` |
| AGDLP effect | `Get-ADGroupMember RES_Sales_Modify -Recursive \| Select SamAccountName` | Includes `cpulisic` |
| Cloud account | `Get-MgUser -UserId cpulisic@VortexAI654.onmicrosoft.com -Property UsageLocation` | Exists, `UsageLocation CA` |
| Licence | `Get-MgUserLicenseDetail -UserId cpulisic@VortexAI654.onmicrosoft.com` | `SPE_E5` |
| Sign-in | Interactive sign-in on a domain-joined client | Forced password change, then desktop |

Evidenced above: the AD account, role groups, the cloud account, and sign-in. Not evidenced: the
recursive AGDLP query (§5.3), and the licence and Microsoft 365 group assignment, whose output fell
below the captured frame (§5.4).

---

## 5. Faults encountered

### 5.1 An interactive NuGet prompt stopped a non-interactive install

**Symptom.** *"The provider 'nuget v2.8.5.208' is not installed … Would you like PackageManagement
to automatically download and install 'nuget' now?"* — mid-run, waiting for input.

**Diagnosis.** The prompt appeared immediately after *Missing: …* and **before** the script's own
*Adding the NuGet package provider first* line, so it was raised by the existence check, not by the
install that was meant to handle it.

**Cause.** On Windows PowerShell 5.1, `Get-PackageProvider -Name NuGet` attempts to bootstrap a
missing provider and prompts to do so — so a check intended to *avoid* the prompt can trigger it.
(`Install-Module` raises the same prompt if it reaches a missing provider first.) Because the
server ran an earlier revision of the script (§5.4), which of the two raised it on this run is not
certain; both paths are closed by the fix.

**Resolution.** The check now uses `Get-PackageProvider -ListAvailable`, which inspects installed
providers without bootstrapping, and compares the version against the 2.8.5.201 minimum. **Not
re-verified on the server** — reproducing it needs a machine that has never had NuGet installed.

### 5.2 `-WhatIf` printed "Onboarding complete" and a password

**Symptom.** The dry run ended with the same handover block as a real run, including a freshly
generated password for an account that did not exist.

**Cause.** The handover section ran unconditionally. Every change above it honoured
`ShouldProcess`; the summary did not know it was a dry run.

**Resolution.** Under `-WhatIf` the script now prints *Dry run complete - nothing was created or
changed* and exits before the handover, on both the full and `-SkipCloud` paths. Related: module
installation deliberately still happens on a dry run (the read-only Graph lookups need it) and now
says so explicitly and passes `-WhatIf:$false`, rather than looking like a side effect.

### 5.3 A verification command produced no visible output

**Symptom.** Two commands pasted together — `Get-ADPrincipalGroupMembership … | Select Name` and
`Get-ADGroupMember RES_Sales_Modify -Recursive | Select SamAccountName` — showed only the first
result.

**Cause.** PowerShell formats consecutive pipeline output as one table using the first object's
properties. The second command's objects had no `Name` property and rendered as blank rows.

**Resolution.** Run the commands separately, or end each with `| Format-Table`. The recursive
membership check is therefore listed in §4 but not claimed as evidenced.

### 5.4 Licence assignment is not evidenced, and the server ran an earlier script version

**Symptom.** The captured frame of the real run ends at *Usage location set to CA*.

**Diagnosis.** The script on the server was 25,412 bytes (Step 3 screenshot), and its dry run
reported only `Microsoft.Graph.Users` and `.Groups` as missing. `Set-MgUserLicense` is **not** in
`Microsoft.Graph.Users` — it ships in `Microsoft.Graph.Users.Actions`.

**Cause.** The version run on the server did not list `Users.Actions` among its required modules.

**Resolution.** The committed script requires `Microsoft.Graph.Users.Actions`, with a comment
recording why. Whether the licence and Microsoft 365 group steps succeeded on this run is not
shown, so it is not claimed; the verification commands in §4 confirm it on the next run.

---

## 6. Capabilities demonstrated

- User lifecycle automation across Active Directory and Microsoft 365 with the Microsoft Graph PowerShell SDK
- Hybrid-aware identity design: UPN alignment and look-before-create for cloud accounts
- Least-privilege delegated Graph scopes and consent review
- Microsoft 365 licensing: SKU inventory, seat checks, usage location
- `ShouldProcess`/`-WhatIf` support and safe partial-failure handling
- Diagnosing PowerShellGet/PackageManagement bootstrap behaviour on Windows Server
- Evidence discipline: stating what a screenshot does and does not prove

---

## 7. References

| Source | Behaviour confirmed |
|---|---|
| Microsoft Learn — *Set-MgUserLicense* | Module location (`Microsoft.Graph.Users.Actions`) and usage-location prerequisite |
| Microsoft Learn — *Connect-MgGraph* | Delegated scopes and Web Account Manager sign-in on Windows |
| Microsoft Learn — *Get-PackageProvider* | `-ListAvailable` lists installed providers without bootstrapping |
| Microsoft Learn — *Product names and service plan identifiers for licensing* | `SPE_E5` = Microsoft 365 E5 |
| Microsoft Learn — *about_Format.ps1xml* / output formatting | First-object property selection for mixed pipeline output |

---

## Screenshot checklist

| File | Content |
|---|---|
| `06-01-onboarding-script-synopsis.png` | Script synopsis |
| `06-02-password-generator-source.png` | Password generator |
| `06-03-tenant-sign-in-from-server.png` | Tenant sign-in (token and account redacted) |
| `06-04-azure-portal-signed-in.png` | Azure portal (account redacted) |
| `06-05-script-staged-on-server.png` | First run, module install |
| `06-06-graph-module-auto-install.png` | NuGet prompt |
| `06-07-graph-sign-in-prompt.png` | Sign-in picker |
| `06-08-graph-consent.png` | Consent (account redacted) |
| `06-09-tenant-licence-inventory.png` | Licence inventory |
| `06-10-onboarding-command.png` | Onboarding command |
| `06-11-dry-run.png` | Dry run (password redacted) |
| `06-12-real-run.png` | Real run (password redacted) |
| `06-13-ad-account-properties.png` | AD account |
| `06-14-group-membership-query.png` | Role group membership |
| `06-15-m365-account.png` | Microsoft 365 account (object ID redacted) |
| `06-16-first-sign-in.png` | First sign-in |
| `06-17-password-change-required.png` | Change required |
| `06-18-new-password-entry.png` | New password |
| `06-19-password-changed.png` | Password changed |
| `06-20-profile-loading.png` | Profile loading |
| `06-21-signed-in-identity.png` | Signed-in identity |
