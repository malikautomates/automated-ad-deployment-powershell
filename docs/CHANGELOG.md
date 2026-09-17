# Changelog

## 2.1.1 - 2026-09-16

Published as a portfolio repository. Fixes found by reviewing the captured
onboarding evidence against the code.

### Added

- **Lab documentation** under `labs/` - seven labs from bare VM to onboarding,
  each with design decisions, captioned evidence, verification and faults.
  `docs/environment.md` holds the shared design specification.
- **Continuous integration** (`.github/workflows/ci.yml`) on Windows PowerShell
  5.1: PSScriptAnalyzer (fails on Error severity), the Pester unit suite, the
  offline design validation, and a check that every lab screenshot is
  referenced and present.
- `PSScriptAnalyzerSettings.psd1`, excluding one rule with its justification.
- `scripts/Test-LabImages.ps1`.

### Fixed

- **`New-VortexUser.ps1 -WhatIf` printed "Onboarding complete" and a password.**
  The handover block ran unconditionally, so a dry run displayed a freshly
  generated password for an account that did not exist. Dry runs now end with
  "Dry run complete - nothing was created or changed", on both the full and
  `-SkipCloud` paths.
- **First-run NuGet prompt.** `Get-PackageProvider -Name NuGet` bootstraps a
  missing provider on Windows PowerShell 5.1 and stops at an interactive prompt,
  before the script's non-interactive install could run. The check now uses
  `-ListAvailable` and compares against the 2.8.5.201 minimum.
- Module installation under `-WhatIf` is now explicit (`-WhatIf:$false`, with a
  message) rather than an unannounced side effect. The dry run needs the modules
  for its read-only Graph lookups.
- The onboarding script's help said it installs four Graph modules; it installs
  five, including `Microsoft.Graph.Users.Actions`, which is where
  `Set-MgUserLicense` lives.
- The onboarding script now finds the configuration in the repository layout
  (`Onboarding\` beside `Deployment\`).

### Changed

- Runbooks updated for the repository layout, with SSH/SCP documented as the
  primary kit transfer method.

## 2.1.0 - 2026-09-13

Fixes found by running the kit end to end against a real Windows Server 2022
evaluation VM.

### Added

- **All Windows roles are installed together, in Stage 1** - not one per stage.
  `Features.Required` lists every role the deployment needs (AD DS, RSAT, DNS,
  IIS, FTP, Windows Server Backup) and Stage 1 installs them in a single call
  before the first reboot. A missing component payload is cheap to fix at that
  point, while an operator is watching the console; the same failure at Stage 3
  or 4 happens unattended, as SYSTEM, with no window on screen. Later stages
  find the roles present and skip their own installs.
- **Automatic payload-source recovery.** `Install-DeploymentFeature` now handles
  0x800f081f ("the source files could not be found"), which stops role installs
  on evaluation and trimmed images whose component store lacks the binaries. On
  that error it searches attached volumes for Windows installation media,
  matches the image index to the running edition and flavour (Desktop
  Experience vs Server Core), and retries automatically. `Features.SourcePath`
  overrides the detection; if nothing usable is found, the error explains
  exactly what to attach. Used by every role install - AD DS, RSAT, IIS/FTP and
  Windows Server Backup.
- `Get-RegistryValue` - reads a registry value safely, returning `$null` when
  the key or value is absent.
- `Invoke-CheckSection` in the deployment validator - each group of checks runs
  under a net, so a failure becomes a FAIL row naming the section instead of
  aborting the stage. A validator that dies reports nothing AND hides what it
  had already found.

### Changed

- **`Set-StrictMode` lowered from 2.0 to 1.0** in the module. 1.0 keeps the
  check that earns its keep - references to uninitialised variables, which
  caught a real scoping bug. 2.0 additionally rejects reading a property that
  does not exist, and PowerShell 5.1 itself supplies `.Count` and `.Length` on
  scalars as a convenience that StrictMode 2.0 does not recognise. Idiomatic
  code like `if ($x.Count -gt 0)` therefore threw the moment a filter returned
  exactly one item. It cost two failed runs on a correctly configured server.
  The array handling that provoked it is fixed at source regardless; this is
  the safety net, not the fix.

### Fixed

- **Stage 5 always failed its own "resume task removed" check.** The orchestrator
  retired the scheduled task only after every stage completed - which requires
  Stage 5 to have finished - so the assertion ran while the task was necessarily
  still registered and could never pass. The task is now retired as soon as no
  remaining stage needs a reboot (after Stage 3), which is when it actually
  stops having a purpose.
- **The validation report showed `True` for settings that were correctly
  `False`.** `Add-Boolean` treated an Actual of `$false` as "nothing supplied"
  and substituted the pass/fail condition, so a correctly-disabled setting read
  as its own opposite in the Actual column. Empty string still means "nothing
  worth showing"; `$false` is now reported as measured.
- **Stage 1 crashed while recovering from a missing role payload.**
  `Find-WindowsPayloadSource` assigned an array from an `if` *expression*, and
  PowerShell unrolls a single-element array in that position - so the moment
  the edition filter matched exactly one image (the normal case), the result
  was a scalar and `.Count` threw. Now assigned inside each branch, with
  `@()` guards on every count and index.
- **Creating exactly one user would have crashed Stage 3.** `Import-DeploymentUser`
  returns an array, which unrolls to a scalar when it holds one element;
  `$credentials.Count` then failed. Latent - it needed a run that added a
  single account, so fifteen users worked and one would not have.
- **Stage 5 aborted on a correctly built server.** The auto-logon checks used
  `(Get-ItemProperty -Path X -Name Y).Y`, which throws under
  `Set-StrictMode -Version 2.0` when the value does not exist - and absent is
  the healthy answer for `DefaultPassword`. The check was guaranteed to fail
  precisely when the server was correct. Now uses `Get-RegistryValue`.
- **`ReverseZoneName` was recorded as an array, not a string.** A PowerShell
  `switch` evaluates *every* matching condition unless each branch breaks, so a
  /24 prefix satisfied both `-ge 24` and `-ge 16` and emitted two zone names.
  Replaced with `if`/`elseif`; consumers also tolerate the array form so an
  in-flight deployment does not need rebuilding.
- `$matches` used as a local variable name in media detection - it is an
  automatic variable populated by `-match`.

## 2.0.0 — 2026-09-13

Rewrite of the Vortex AI Active Directory deployment. Same required end state as the
original three-script kit; different structure, different security model, and
verification that actually verifies.

### Added

- **`Invoke-Deployment.ps1` orchestrator.** One entry point owning the stage
  list, progress and restarts. Supports `-WhatIf`, `-Only`, `-StartFrom`,
  `-Force`, `-Reset`.
- **Resumable state** in `Output\deployment-state.json`. A failure stops the
  pipeline without restarting the server; re-running continues from the first
  incomplete step.
- **Stage 0 preflight.** Read-only checks — elevation, OS edition, memory, disk,
  pending reboot, adapter resolution, the addressing plan, and name resolution.
  A `Fail` prevents the deployment from starting.
- **`Vortex.Deployment` module** with a real manifest, `Public`/`Private`
  separation, explicit exports and versioning.
- **`AddressingMode`** — `PinCurrentLease` (default), `Static`, `Dhcp`.
  `PinCurrentLease` makes the existing DHCP lease permanent, so no address has
  to be chosen and reachability does not change.
- **AGDLP group model.** Global role groups nested into domain local resource
  groups; only resource groups appear on ACLs.
- **Real OU tree** — `VORTEXAI` with Users/Sales/Supervisors/Troubleshooters,
  Groups, Computers/Servers/Workstations, ServiceAccounts. Users are created
  into it.
- **Per-user generated passwords**, cryptographic RNG, single-use, written to an
  ACL-restricted handover file.
- **SMB shares** for every folder, with access-based enumeration.
- **Stage 4 baseline** — AD Recycle Bin, DNS forwarders, reverse lookup zone,
  scavenging, PDC emulator NTP (plus disabling VMware Tools time sync), domain
  password and lockout policy, advanced audit subcategories, SMBv1 off, RDP with
  NLA, Windows Server Backup staged.
- **Stage 5 validation** producing HTML and CSV reports and Application event
  log entries.
- **Pester 5 suite** sharing the validation functions, so tests and report
  cannot drift.
- **Config schema validation** reporting every problem at once, before anything
  is changed.
- `RUNBOOK.md`, expanded `README.md`, this changelog.

### Changed

- **Restart survival is now a scheduled task running as `NT AUTHORITY\SYSTEM`.**
  No credential is stored on disk and Windows auto-logon is never touched. The
  previous design's stored credential would also have gone stale twice over —
  promotion retires the local SAM account and Stage 1 renames the machine.
- **The computer is renamed before promotion**, not after. Renaming a domain
  controller requires reissuing SPNs and rewriting DNS records.
- **The DSRM password is generated**, not reused from the administrator account,
  and stored with machine-scoped DPAPI.
- **`Users.csv` is an identity feed** — no password column. It now carries
  given/surname, title, department, office, target OU and group membership.
- **Group membership comes from the CSV**, not hardcoded in a script.
- Expiry dates are ISO `yyyy-MM-dd` and in the future. The originals were
  `Dec 31, 2023/2024/2025` — culture-dependent to parse, and all in the past,
  which would have created three accounts already expired.
- Waits poll for a real condition instead of `Start-Sleep`.
- Config paths may be relative to the deployment root, so the kit survives being
  copied elsewhere.

### Fixed

Carried over from the original scripts:

- Static IP was `10.10.10.40` while the script's own comment specified
  `10.10.10.34`, and DNS pointed at an address the server did not hold.
- `(Get-NetAdapter).interfaceindex` returns an array on a multi-NIC machine and
  silently misconfigures.
- `Install-ADDSForest -Force -Confirm` — `-Confirm` reinstates the prompt
  `-Force` exists to suppress, hanging an unattended run.
- Three-argument `FileSystemAccessRule` applies only to the folder object, so
  no granted permission reached files or subfolders.
- Stripping inheritance removed `NT AUTHORITY\SYSTEM`, breaking backup,
  antivirus and shadow copies.
- `New-ADUser` without `-Enabled $true` created every account disabled.
- ACLs granted to the *user* `Administrator` rather than
  `BUILTIN\Administrators`.
- OUs created with no accidental-deletion protection.

Fixed in the intermediate `Enterprise` revision:

- The auto-logon check tested whether `AutoAdminLogon` *existed* rather than its
  value. Stock Windows Server images ship it present and set to `0`, producing a
  false FAIL on a correct deployment.
- No DNS forwarders were configured, so the server lost public name resolution
  once it resolved through itself — breaking Windows Update and module installs.
- No time source configuration, leaving VMware Tools fighting the Windows Time
  service on the machine the whole domain takes its clock from.
- AD Recycle Bin was never enabled. It can only be turned on, never off, so
  missing it at build time is effectively permanent.
- `Paths.UsersCsv` was absolute, so the kit broke when copied anywhere else.

Found while testing this rewrite:

- Module functions did not inherit the calling script's `ErrorActionPreference`,
  so a non-terminating `Set-Acl` failure fell through to the success path and a
  step reported complete having changed nothing. Fixed with a module-scoped
  `$ErrorActionPreference = 'Stop'` plus explicit `-ErrorAction Stop` on
  state-changing cmdlets.
- `Protect-DeploymentSecret` and `Export-DeploymentSecretReport` re-ACL'd
  whatever directory they were pointed at. They now lock down a directory only
  when creating it, and restrict the secret file itself.
- The generated-password character set included lowercase `i`, contradicting the
  documented exclusion of confusable characters.
- `Select-Object -ExpandProperty` cannot read a hashtable key, so a test
  asserting the AGDLP rules silently evaluated against an empty set.

### Removed

- `RestoreSettings3.ps1`. It existed only to undo the auto-logon registry hack;
  with no auto-logon there is nothing to restore.
- The stored credential file and the `Secrets\deployment.cred.xml` mechanism.

---

## 1.0.0 — original

`ADInstallScript1.ps1`, `ADTaskScript2.ps1`, `RestoreSettings3.ps1`, chained by
Windows auto-logon and at-logon scheduled tasks, driven from `users.txt`.
Preserved in `PowerShellScript\` for comparison.
