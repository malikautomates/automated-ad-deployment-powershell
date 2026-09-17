# Runbook: onboarding a new starter

Creates one person's Active Directory account, puts them in the right groups,
creates their Microsoft 365 account, licenses them, and adds them to their
Team — from a single command.

**Time:** about 3 minutes per hire. The first ever run takes 5–10 minutes
longer while the Microsoft Graph modules install.

Worked example throughout: **Christian Pulisic**, Account Executive, Sales,
Vancouver.

---

## Before you start — one time only

| | |
|---|---|
| **Where** | `VTX-DC01`, or any machine with the AD PowerShell module (RSAT) |
| **Script lives at** | wherever you keep it - it finds its configuration on its own |
| **Signed in as** | `VORTEXAI\Administrator`, or another Domain Admin |
| **PowerShell** | Run as Administrator |
| **For the M365 half** | A **Global Administrator** account for the tenant |

The Graph modules install themselves on first run. Nothing to do in advance.

> The very first Graph sign-in asks a Global Administrator to consent to the
> permissions the script uses (create users, assign licences, manage group
> membership). Once consented, a User Administrator can run it from then on.

---

## 1. Decide two things

Everything else is derived. These two are not, because only you know them.

**Branch** — determines the OU and the branch role group:

`Winnipeg` · `Vancouver` · `Calgary`

**Department** — determines the department role group and the Microsoft 365
group:

`Executive` · `IT` · `Finance` · `HR` · `Sales` · `Marketing` · `Operations`

Anything outside these lists is rejected before the script touches the
directory, so a typo cannot create an account in the wrong place.

---

## 2. Check you have a licence to give

```powershell
cd C:\New-VortexUser     # or wherever you keep the script
.\New-VortexUser.ps1 -ListLicenses
```

> The script locates `DeploymentConfig.psd1` by itself - beside the script, in
> the repository's `Deployment\Config` folder, or at `C:\ADDeployment\Config`. If it
> cannot find it, the error lists every path it tried. Override with
> `-ConfigPath` if you keep the kit somewhere unusual.

```
Sku              Total Used Available
---              ----- ---- ---------
SPE_E5              25   18         7
EMS                 25    3        22
```

Note the SKU you want and that `Available` is above zero. If there are no free
seats the script still creates the account, but unlicensed — better to know now
than to explain it to the new starter.

This step changes nothing, and it is the cheapest way to confirm your Graph
sign-in works before the real run.

---

## 3. Dry run

```powershell
.\New-VortexUser.ps1 -FirstName Christian -LastName Pulisic `
    -Branch Vancouver -Department Sales -JobTitle 'Account Executive' -WhatIf
```

Read the header it prints:

```
  Onboarding Christian Pulisic
  Logon name   : cpulisic
  Sign-in (UPN): cpulisic@VortexAI654.onmicrosoft.com
  Office       : Vancouver
  Department   : Sales - Account Executive
  AD location  : OU=Vancouver,OU=Users,OU=VortexAI,DC=vortexai,DC=local
  Role groups  : ROLE_AllStaff, ROLE_Sales, ROLE_Vancouver
  Licence      : SPE_E5
```

Check the logon name and the OU. Everything below that is described but not
performed.

---

## 4. Run it

Same command, without `-WhatIf`:

```powershell
.\New-VortexUser.ps1 -FirstName Christian -LastName Pulisic `
    -Branch Vancouver -Department Sales -JobTitle 'Account Executive'
```

What happens, in order:

1. Creates the AD account, enabled, password change required at first sign-in
2. Adds them to their three role groups
3. Installs the Graph modules if this is the first run
4. Opens a browser for you to sign in to Microsoft 365
5. Looks for an existing cloud account and creates one only if there is none
6. Sets usage location, then assigns the licence
7. Adds them to `All Company` and their department's group

---

## 5. Hand over the credentials

The script ends with:

```
  Onboarding complete.

  Name       : Christian Pulisic
  Sign-in    : cpulisic@VortexAI654.onmicrosoft.com
  Password   : <generated>
```

**Copy the password before you close the window.** It is deliberately not
written to disk — a temporary password in a file is a temporary password
somebody else can read.

Give it to them in person, by phone, or through your password manager.
**Never by email**, which is the one channel they cannot yet access and which
keeps a permanent copy.

It is single-use: they must change it at first sign-in.

---

## 6. Verify

```powershell
Get-ADUser cpulisic -Properties MemberOf, Department, Office, Title |
    Select-Object SamAccountName, Enabled, UserPrincipalName, Department, Office, Title

Get-ADPrincipalGroupMembership cpulisic | Select-Object Name
```

Expect `ROLE_AllStaff`, `ROLE_Sales`, `ROLE_Vancouver`, plus `Domain Users`.

Or in the GUI — `dsa.msc` → `vortexai.local` → `VortexAI` → `Users` →
`Vancouver`.

**Confirm effective file access** — this is the check that proves the group
model is working, not just that objects exist:

```powershell
Get-ADGroupMember RES_Sales_Modify -Recursive | Select-Object SamAccountName
```

`cpulisic` should appear, without anyone having touched a folder permission.
That is AGDLP doing its job: he is in `ROLE_Sales`, which is nested in
`RES_Sales_Modify`, which is what the ACL on `C:\VortexData\Sales` grants to.

---

## 7. What the new starter does

1. Signs in to their workstation as `VORTEXAI\cpulisic` with the temporary
   password, and is prompted to change it
2. Signs in to Microsoft 365 at `office.com` with
   `cpulisic@VortexAI654.onmicrosoft.com`
3. Finds their shares at `\\VTX-DC01\Sales`, `\\VTX-DC01\Vancouver` and
   `\\VTX-DC01\Company`

They cannot sign in to the domain controller itself — ordinary users have no
"log on locally" right there, by design. Use a domain-joined workstation.

Teams membership can take a few minutes to appear in the client.

---

## Variations

**Contractor or fixed-term** — create them, then set an end date so the account
expires on its own:

```powershell
.\New-VortexUser.ps1 -FirstName Christian -LastName Pulisic -Branch Vancouver `
    -Department Sales -JobTitle 'Account Executive'

Set-ADAccountExpiration -Identity cpulisic -DateTime '2027-06-30'
```

**No Microsoft 365 account yet** — AD and groups only:

```powershell
.\New-VortexUser.ps1 ... -SkipCloud
```

**Record their manager** (use the manager's logon name):

```powershell
.\New-VortexUser.ps1 ... -Manager mei
```

**A different licence:**

```powershell
.\New-VortexUser.ps1 ... -LicenseSku ENTERPRISEPACK
.\New-VortexUser.ps1 ... -LicenseSku None      # create it, licence it later
```

**A name that collides** — a second C. Pulisic automatically becomes
`cpulisic2`. To choose the name yourself:

```powershell
.\New-VortexUser.ps1 ... -SamAccountName chrisp
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `running scripts is disabled` | Execution policy | `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force` |
| `Cannot find DeploymentConfig.psd1` | Kit is somewhere unexpected | The error lists every path tried; pass `-ConfigPath C:\ADDeployment\Config\DeploymentConfig.psd1` |
| `Target OU ... does not exist` | Domain not built, or a renamed OU | Check `dsa.msc`; the OU names must match the config |
| `Could not install the Microsoft Graph modules` | No internet, or a proxy | Install on a connected machine, or use `-SkipCloud` for now |
| `An account named 'cpulisic' already exists` | Duplicate | Pass `-SamAccountName` to choose another |
| Browser sign-in fails or consent is refused | Not a Global Admin | A Global Administrator must consent once |
| `The tenant owns no 'SPE_E5' subscription` | Wrong SKU name | `-ListLicenses` to see the real names |
| `No 'SPE_E5' seats free` | Licences exhausted | Buy a seat, then assign in the admin centre or re-run with `-LicenseSku` |
| `No Microsoft 365 group called 'X'` | Group map vs tenant mismatch | Edit `$Microsoft365GroupMap` near the top of the script |
| New starter can't sign in to `VTX-DC01` | Expected — not a fault | Ordinary users cannot log on to a DC. Use a workstation. |

### If a run fails partway

The script is not transactional: it may have created the AD account before
failing on the cloud side. Nothing is left broken, but re-running as-is will
stop at "account already exists".

Either finish the cloud half by hand in the admin centre, or remove the account
and start again:

```powershell
Remove-ADUser -Identity cpulisic -Confirm:$false
```

---

## Adding a department or branch

Both lists are `ValidateSet` values near the top of `New-VortexUser.ps1`. To add
one — say a Toronto office:

1. Add the OU and the `ROLE_Toronto` / `RES_Toronto_Modify` groups to
   `Deployment\Config\DeploymentConfig.psd1`
2. Apply them: `Invoke-Deployment.ps1 -Only 3`
3. Add `'Toronto'` to the `Branch` `ValidateSet` in `New-VortexUser.ps1`

Do them in that order. The script's validation is deliberately stricter than
the directory, so it refuses a branch that has nowhere to put people.
