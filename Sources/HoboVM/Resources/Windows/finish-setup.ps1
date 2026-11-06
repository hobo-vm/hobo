# The end of a Windows guest's setup, run as SYSTEM by a startup task. Windows' first-run setup restarts
# the machine about a minute after the first logon and clears the auto-login settings as it goes, so
# what must outlast it happens after that restart. Then one more restart, for Winlogon to see them,
# with sshd enabled: SSH answering is what tells Hobo that setup has finished.
$ErrorActionPreference = 'Stop'

# setup.ps1 also starts this straight away, in case a build of Windows doesn't restart. This key doesn't
# outlive a restart, so finding it means that restart hasn't happened yet: give it time to.
if (Test-Path HKLM:\SOFTWARE\Hobo\SetupBoot) { Start-Sleep -Seconds 300 }

$winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty $winlogon AutoAdminLogon '1'
Set-ItemProperty $winlogon DefaultUserName 'vagrant'
Set-ItemProperty $winlogon DefaultPassword 'vagrant'
Remove-ItemProperty $winlogon AutoLogonCount -ErrorAction SilentlyContinue

Set-Service sshd -StartupType Automatic
# In this order: deleting a task doesn't stop it while it runs, and a restart first would leave it to run again.
schtasks.exe /delete /tn hobo-finish-setup /f
shutdown.exe /r /t 0
