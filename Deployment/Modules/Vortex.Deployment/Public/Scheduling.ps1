<#
    Surviving the reboots.

    The pipeline has to restart itself twice: once after the rename, once after
    forest promotion. How that is done is the single biggest security decision
    in this kit.

    Rejected: Windows auto-logon. It requires writing the administrator password
    to HKLM\...\Winlogon\DefaultPassword as reversible plaintext, readable by
    anything running on the box, and it leaves a logged-on privileged desktop
    sitting at the console.

    Rejected: a scheduled task registered with a stored user credential. Better,
    but on this particular pipeline it is also fragile. The credential would be
    captured as MACHINE\Administrator while the server is still in a workgroup;
    promotion then retires the local SAM account, and Stage 1 renames the
    machine, so the stored principal is stale twice over.

    Chosen: run as NT AUTHORITY\SYSTEM. SYSTEM is already a local administrator
    on a domain controller, is unaffected by renames or promotion, and needs no
    password stored anywhere at all. There is no credential file in this design.
#>

function Register-DeploymentResumeTask {
    <#
    .SYNOPSIS
        Registers the startup task that resumes the deployment after a reboot.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $TaskName,
        [Parameter(Mandatory)] [string] $ScriptPath,
        [string] $Arguments = '-Resume',
        [int] $StartupDelaySeconds = 30
    )

    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        throw "Cannot schedule a resume task for '$ScriptPath' - the file does not exist."
    }

    if (-not $PSCmdlet.ShouldProcess($TaskName, 'Register startup task running as SYSTEM')) { return }

    Unregister-DeploymentResumeTask -TaskName $TaskName

    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action = New-ScheduledTaskAction -Execute $powershell `
        -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$ScriptPath`" $Arguments"

    $trigger = New-ScheduledTaskTrigger -AtStartup
    # A short delay lets the core services finish coming up before the stage
    # starts logging. The stage still waits properly for AD on its own; this
    # only keeps the log readable.
    try { $trigger.Delay = "PT${StartupDelaySeconds}S" } catch { }

    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RestartCount 2 -RestartInterval (New-TimeSpan -Minutes 5) `
        -ExecutionTimeLimit (New-TimeSpan -Hours 2)

    Register-ScheduledTask -TaskName $TaskName `
        -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
        -Description 'Vortex AI Active Directory deployment - resumes the pipeline after a restart. Removed automatically when the deployment completes.' `
        -ErrorAction Stop | Out-Null

    Write-DeploymentLog -Level SUCCESS -Message "Scheduled task '$TaskName' registered to resume at startup as SYSTEM (no stored credential)."
}

function Unregister-DeploymentResumeTask {
    <#
    .SYNOPSIS
        Removes the resume task. Safe to call when it does not exist.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $TaskName)

    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-DeploymentLog -Message "Removed scheduled task '$TaskName'."
    }
}

function Test-DeploymentResumeTask {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $TaskName)
    return [bool](Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)
}

function Request-DeploymentRestart {
    <#
    .SYNOPSIS
        Restarts the server, after confirming the pipeline can pick itself up.

    .DESCRIPTION
        Refuses to reboot if the resume task is missing. Rebooting without it
        would strand the deployment half-finished with nothing scheduled to
        continue - the operator would have to notice and intervene.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $ResumeTaskName,
        [string] $Reason = 'to continue the deployment',
        [int] $DelaySeconds = 10
    )

    if (-not (Test-DeploymentResumeTask -TaskName $ResumeTaskName)) {
        throw "Refusing to restart: resume task '$ResumeTaskName' is not registered, so the deployment would not continue after the reboot."
    }

    if (-not $PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Restart $Reason")) { return }

    Write-DeploymentLog -Level SUCCESS -Message "Restarting in $DelaySeconds seconds $Reason. The deployment resumes automatically at startup."
    Complete-DeploymentLog -Outcome 'complete - restarting'
    Start-Sleep -Seconds $DelaySeconds
    Restart-Computer -Force
}
