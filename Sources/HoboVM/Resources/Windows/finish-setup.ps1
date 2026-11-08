# The end of a Windows guest's setup, run as SYSTEM by a startup task. Windows' first-run setup (OOBE)
# runs in a session of its own temporary user, defaultuser0: it restarts the machine about a minute after
# the first logon, carries on after that restart, and clears the auto-login settings as it goes. So what
# must outlast it happens once its session has ended. Then one more restart, for Winlogon to see them,
# with sshd enabled: SSH answering is what tells Hobo that setup has finished.
$ErrorActionPreference = 'Stop'
$log = 'C:\ProgramData\Hobo\setup.log'

# setup.ps1 also starts this straight away, in case a build of Windows doesn't restart. This key doesn't
# outlive a restart, so finding it means that restart hasn't happened yet: give it time to.
if (Test-Path HKLM:\SOFTWARE\Hobo\SetupBoot) { Start-Sleep -Seconds 300 }

# After the restart, OOBE logs defaultuser0 on again to finish, which takes seconds, so wait for that
# session to come and go. A session of vagrant's means OOBE has already finished. The limit is for a
# build of Windows that does this differently, and keeps create well inside its wait for SSH.
$limitMinutes = 5
$deadline = (Get-Date).AddMinutes($limitMinutes)
$oobeSessionSeen = $false
while ($true) {
    # cmd, since quser writes to stderr when nobody is logged on, which PowerShell would stop at.
    $sessions = cmd.exe /c 'quser 2>nul'
    if ($sessions -match '\bdefaultuser0\b') { $oobeSessionSeen = $true }
    elseif ($oobeSessionSeen -or $sessions -match '\bvagrant\b') { break }
    if ((Get-Date) -gt $deadline) {
        Add-Content $log "$(Get-Date -Format s) finish-setup: OOBE's session didn't end within $limitMinutes minutes; continuing"
        break
    }
    Start-Sleep -Seconds 2
}

$winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty $winlogon AutoAdminLogon '1'
Set-ItemProperty $winlogon DefaultUserName 'vagrant'
Set-ItemProperty $winlogon DefaultPassword 'vagrant'
Remove-ItemProperty $winlogon AutoLogonCount -ErrorAction SilentlyContinue

Set-Service sshd -StartupType Automatic
# In this order: deleting a task doesn't stop it while it runs, and a restart first would leave it to run again.
schtasks.exe /delete /tn hobo-finish-setup /f
shutdown.exe /r /t 0
