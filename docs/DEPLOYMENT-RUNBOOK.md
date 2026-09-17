# Runbook: deploying Vortex AI Active Directory on a fresh Windows Server 2022 VM

Step by step, for a brand new empty Windows Server 2022 virtual machine in
VMware Workstation. Nothing is assumed to be installed on it.

**Total time:** about 25-35 minutes, of which roughly 20 is the server working
on its own. **Restarts:** two, both automatic.

Every command below is typed **inside the VM**, in the VMware console window.

---

## 0. What you will end up with

| | |
|---|---|
| Server name | `VTX-DC01` |
| Forest / domain | `vortexai.local` (NetBIOS `VORTEXAI`) |
| Address | whatever DHCP gave it, made permanent (currently `192.168.133.129/24`) |
| DNS | this server, forwarding to your NAT resolver |
| OUs | 12 - `VortexAI` tree: Users (Winnipeg/Vancouver/Calgary), Groups (Roles/Resources), Computers (Servers/Workstations), ServiceAccounts |
| Users | 15 - 14 staff across three branches plus the `Support` service account, each with its own random password |
| Sign-in | `name@VortexAI654.onmicrosoft.com` - the same identity as the M365 tenant |
| Groups | 23 - 11 `ROLE_*` global (department, branch, all-staff), 12 `RES_*` domain local (AGDLP) |
| Folders | 11 under `C:\VortexData` - Company, Finance, HR, IT, Sales, Branches\{Winnipeg,Vancouver,Calgary}, Public - explicit ACLs, all shared |
| FTP | installed, stopped, disabled |
| Baseline | Recycle Bin, forwarders, reverse zone, NTP, password policy, auditing |
| Reports | `C:\ADDeployment\Output\` |

---

## 1. Validate the design first (on your own machine, not the VM)

Before copying anything anywhere, check the configuration is coherent. This
needs no server, no Active Directory and no elevation:

```powershell
.\Scripts\Test-DeploymentDesign.ps1
```

It reads `Config\DeploymentConfig.psd1` and `Data\Users.csv` and reports
anything that would fail later - a user pointed at a non-existent OU, a group
on an ACL that breaks the AGDLP model, a logon name over the 20-character
limit, an expiry date already in the past.

Expect `410 passed, 0 failed, 1 warning` on the shipped configuration. The one
warning is the deliberate `Everyone` grant on the public share.

Fix anything that fails here. It is far cheaper than finding it halfway through
a deployment.

---

## 2. Snapshot the clean VM first

Do this before anything else. It is the difference between "try again" and
"rebuild from the ISO".

**VMware Workstation → VM → Snapshot → Take Snapshot** → name it
`01 - clean install, pre-deployment`.

You will take a second one at the end.

---

## 3. Install VMware Tools

Needed for a usable console (clipboard, screen size) and for drag-and-drop file
transfer in the next step.

1. **VM → Install VMware Tools**
2. Inside the VM, open **File Explorer → DVD Drive** → run `setup64.exe`
3. Accept the defaults, then restart when prompted

> Stage 4 later disables VMware Tools' host time synchronisation. That is
> deliberate, not a mistake: it fights the Windows Time service, and on a domain
> controller Windows has to own the clock. Kerberos starts rejecting logons once
> clocks drift past five minutes.

---

## 4. Confirm the starting point

Log in as **Administrator**, open **PowerShell as Administrator**, and check:

```powershell
ipconfig
```

You should see an address on the VMware NAT subnet (`192.168.133.x`) with
gateway `192.168.133.2`. You do **not** need to write it down or change
anything — the deployment reads whatever DHCP gave it and makes that permanent.

---

## 5. Copy the kit onto the server

The repository's `Deployment` folder has to end up at **`C:\ADDeployment`**.
The folder name changes: `Deployment` in the repository becomes `ADDeployment`
on the server. The contents (`Config`, `Data`, `Modules`, `Scripts`, `Tests`)
sit directly inside it.

**Option A — SSH and SCP (what the lab used; no VMware Tools needed)**

Documented step by step, with screenshots, in
[Lab 01](../labs/01-remote-access-and-kit-transfer/). In short: enable OpenSSH
Server once from the VM console, zip `Deployment` on the host, then:

```powershell
# On the host
scp .\Deployment.zip Administrator@<server-ip>:C:\Deployment.zip

# On the server
Expand-Archive C:\Deployment.zip -DestinationPath C:\
Rename-Item C:\Deployment C:\ADDeployment
```

**Option B — drag and drop (needs VMware Tools)**

Drag the `Deployment` folder onto the VM's desktop, then in the VM:

```powershell
Move-Item "$env:USERPROFILE\Desktop\Deployment" C:\ADDeployment
```

**Option C — shared folder**

VM → Settings → Options → Shared Folders → Always enabled → Add → point at the
repository folder. Then in the VM:

```powershell
Copy-Item '\\vmware-host\Shared Folders\<repository>\Deployment' C:\ADDeployment -Recurse
```

### Verify the copy

```powershell
Get-ChildItem C:\ADDeployment
```

You should see `Config`, `Data`, `Modules`, `Scripts` and `Tests`. If you
instead see a single `Deployment` folder, you nested it one level too deep —
move its contents up.

---

## 6. Unblock the files

Windows marks files that arrive from another machine, and a blocked `.psm1`
will not import. This is the single most common reason a copied PowerShell kit
fails on first run.

```powershell
Get-ChildItem C:\ADDeployment -Recurse -File | Unblock-File
```

Then allow scripts to run in this session:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
```

`-Scope Process` means it lasts only as long as this PowerShell window — it
changes nothing permanently. The scheduled task that resumes after each restart
passes `-ExecutionPolicy Bypass` itself, so it does not depend on this.

---

## 7. Preflight — check before you change anything

```powershell
C:\ADDeployment\Scripts\Invoke-Deployment.ps1 -Only 0
```

This changes nothing at all. It reports one line per check:

```
Check                     Status  Detail
-----                     ------  ------
Running elevated          Pass    VTX-DC01\Administrator
PowerShell version        Pass    5.1.20348....
Operating system          Pass    Microsoft Windows Server 2022 Standard
Domain membership         Pass    Workgroup 'WORKGROUP'
Memory                    Pass    4 GB
Free disk space           Pass    98.2 GB free on C:
Pending reboot            Pass    None detected.
Network adapter           Pass    Ethernet0 (Intel(R) 82574L ...)
Addressing plan           Pass    Set 'Ethernet0' to 192.168.133.129/24 gateway 192.168.133.2 ...
Internet name resolution  Pass    Public DNS resolves. Forwarders will work.
Target computer name      Pass    Will rename 'WIN-XXXX' -> 'VTX-DC01' in Stage 1.
Domain name               Warn    'vortexai.local' uses the .local suffix ...
User source data          Pass    15 user(s) in C:\ADDeployment\Data\Users.csv
```

**Any `Fail` stops the deployment.** Fix it and re-run. `Warn` is informational
— the `.local` warning is expected and is explained in the README.

> If **Pending reboot** fails, just restart the VM and run preflight again.
> A pending reboot makes forest promotion refuse to start.

---

## 8. Dry run

See every action the deployment would take, without taking any of them:

```powershell
C:\ADDeployment\Scripts\Invoke-Deployment.ps1 -WhatIf
```

Everything prints in magenta as `Would run: ...`. Nothing is changed, no task is
registered, and the server does not restart. Worth two minutes.

---

## 9. Run it

```powershell
C:\ADDeployment\Scripts\Invoke-Deployment.ps1
```

Then leave it alone. Here is what happens, and what you should see:

### Stage 1 — Initialize-Server (~2 minutes, then restart #1)

Applies the static address, installs the AD DS role binaries, renames the
server to `VTX-DC01`, registers the resume task, restarts.

> Your console may blink when the address is applied. That is expected. If you
> were connected over SSH or RDP instead of the console, **this is where the
> session drops** — reconnect afterwards on the same address.

### Restart #1 → Stage 2 — Install-ADForest (~6-10 minutes, then restart #2)

Runs on its own, as `SYSTEM`, with **no PowerShell window on screen**. The login
screen just sits there. This is normal and is not a hang.

Generates the DSRM password, then promotes the forest. Promotion is silent for
several minutes.

To watch progress, log in and tail the log:

```powershell
Get-Content (Get-ChildItem C:\ADDeployment\Output\Logs\*.log | Sort-Object LastWriteTime | Select-Object -Last 1).FullName -Wait
```

### Restart #2 → Stages 3, 4, 5 (~8-12 minutes, no further restart)

Again unattended, again no visible window.

- **Stage 3** waits for Active Directory to actually answer (this takes a few
  minutes after a fresh promotion — it is polling, not stuck), then creates the
  OUs, users, groups, folders, shares and FTP.
- **Stage 4** applies the baseline.
- **Stage 5** validates and writes the report.

When it finishes, the resume task removes itself.

---

## 10. Confirm it worked

Log in as **`VORTEXAI\Administrator`** with the same password you have been using.

```powershell
Get-ChildItem C:\ADDeployment\Output\Reports
```

Open the newest `ValidationReport-*.html` in Edge. Every row should be green.

Spot-check by hand:

```powershell
Get-ADDomain | Select-Object DNSRoot, NetBIOSName, DomainMode
Get-ADUser -Filter * | Select-Object SamAccountName, Enabled, DistinguishedName
Get-ADGroup -Filter * -SearchBase 'OU=Groups,OU=VortexAI,DC=vortexai,DC=local' | Select-Object Name, GroupScope
Get-SmbShare | Where-Object Path -like 'C:\VortexData*' | Select-Object Name, Path
Get-Service FTPSVC | Select-Object Name, Status, StartType
(Get-Acl C:\VortexData\Finance).Access | Format-Table IdentityReference, FileSystemRights, InheritanceFlags

# Head count per branch
'Winnipeg','Vancouver','Calgary' | ForEach-Object {
    $n = @(Get-ADUser -Filter * -SearchBase "OU=$_,OU=Users,OU=VortexAI,DC=vortexai,DC=local").Count
    "{0,-10} {1}" -f $_, $n
}

# The AGDLP chain end to end - who can actually modify Finance?
Get-ADGroupMember -Identity RES_Finance_Modify -Recursive | Select-Object SamAccountName
```

---

## 11. Collect the passwords, then destroy the file

```powershell
Get-ChildItem C:\ADDeployment\Output\Secrets
Import-Csv C:\ADDeployment\Output\Secrets\InitialUserPasswords.csv | Format-Table
Import-Csv C:\ADDeployment\Output\Secrets\DSRM-password.csv | Format-Table
```

- **User passwords** are single-use — every account must change its password at
  first logon, so these stop being credentials as soon as they are used.
- **The DSRM password is not single-use.** It is the break-glass credential for
  booting the DC into Directory Services Restore Mode. **Put it in your password
  manager now.** If you lose it you cannot repair a broken directory.

Then delete them:

```powershell
Remove-Item C:\ADDeployment\Output\Secrets\*.csv -Force
```

Re-run validation and the "credential files pending deletion" warning clears:

```powershell
C:\ADDeployment\Scripts\Invoke-Deployment.ps1 -Only 5
```

---

## 12. Snapshot the finished build

**VM → Snapshot → Take Snapshot** → `02 - Vortex AI domain controller, validated`.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `...is not digitally signed` or module will not import | Files still marked as coming from another machine | `Get-ChildItem C:\ADDeployment -Recurse -File \| Unblock-File` |
| `running scripts is disabled on this system` | Execution policy | `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force` |
| Preflight: **Pending reboot** | Windows is waiting on a restart | Restart, run preflight again |
| Preflight: **Multiple connected adapters** | More than one NIC | Set `Network.InterfaceAlias` in `Config\DeploymentConfig.psd1` |
| Nothing seems to happen after a restart | Expected — stages run as SYSTEM with no visible window | Tail the newest log in `Output\Logs` |
| Stage 3 sits on "Active Directory not ready yet" | ADWS still starting after promotion | Wait. It polls for 15 minutes and this often takes 3-5 |
| Deployment stopped with a red FAILED banner | A step failed; nothing further ran and it did not restart | Read the log, fix the cause, re-run the same command — it resumes where it stopped |
| `Unable to find a default server with Active Directory Web Services running` | AD queried before it was ready | Re-run; the wait handles it |
| Validation: FTP checks fail | IIS install did not complete | `Invoke-Deployment.ps1 -Only 3 -Force`, then `-Only 5` |
| Validation: forwarders warning | No upstream resolver detected | Set `Network.Forwarders = @('192.168.133.2')` in config, `-Only 4 -Force` |
| VM has no internet after deployment | Forwarders not set | As above |
| Want to change config and re-apply | — | Edit the config, then `-Only <stage> -Force` |

### Useful commands

```powershell
# Where did it get to?
Get-Content C:\ADDeployment\Output\deployment-state.json

# Is the resume task still registered?
Get-ScheduledTask -TaskName 'Vortex-Deployment-Resume'

# Deployment events in the Windows event log
Get-EventLog -LogName Application -Source 'Vortex-ADDeployment' -Newest 40 |
    Format-Table TimeGenerated, EntryType, Message -Wrap

# Re-run one stage
C:\ADDeployment\Scripts\Invoke-Deployment.ps1 -Only 4 -Force

# Forget recorded progress (does NOT undo anything on the server)
C:\ADDeployment\Scripts\Invoke-Deployment.ps1 -Reset
```

### Starting completely over

Revert to snapshot `01 - clean install, pre-deployment`. That is the only clean
way — a promoted domain controller cannot be tidily un-promoted back to the
state the deployment expects.

---

## Optional: changing the environment

All of this is `Config\DeploymentConfig.psd1`. Nothing is hardcoded in the
scripts.

**Use a real domain instead of `.local`:**

```powershell
Domain = @{ DnsName = 'ad.vortexai.ca'; NetBiosName = 'VORTEXAI' }
```

**Pin a specific address instead of the current lease:**

```powershell
Network = @{
    AddressingMode = 'Static'
    IPAddress      = '192.168.133.10'
    PrefixLength   = 24
    DefaultGateway = '192.168.133.2'
}
```

> `192.168.133.129` sits inside VMware's default NAT DHCP pool (`.128`-`.254`).
> With one VM this never matters. If you add a second VM on this subnet, either
> move the DC below `.128` as above, or add a reservation in VMware's NAT
> settings.

**Add users:** append rows to `Data\Users.csv`, then:

```powershell
C:\ADDeployment\Scripts\Invoke-Deployment.ps1 -Only 3
```

Existing accounts are skipped; only the new ones are created, and only their
passwords appear in the new handover file.

**Turn on system state backup:** give the VM a second virtual disk, then set
`Backup.Enabled = $true` and `Backup.TargetPath = 'E:'` and re-run stage 4.
`wbadmin` cannot back up a volume to itself, which is why this is off by
default on a single-disk machine.
