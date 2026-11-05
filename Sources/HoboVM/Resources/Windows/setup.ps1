# The Vagrant conventions for a Windows guest, run once as SYSTEM before the first logon: OpenSSH
# Server with PowerShell as its shell, the insecure keys, permanent auto-login, no sleep or lock
# screen, and the network watchdog. SSH answering is what tells Hobo this has finished, so sshd
# starts last.
$ErrorActionPreference = 'Stop'
$hobo = 'C:\ProgramData\Hobo'

$msi = Get-ChildItem "$hobo\OpenSSH-*.msi" | Select-Object -First 1
$install = Start-Process msiexec.exe -Wait -PassThru -ArgumentList '/i', "`"$($msi.FullName)`"", '/qn', '/norestart', 'ADDLOCAL=Server,Client'
if ($install.ExitCode -ne 0) { throw "OpenSSH's installer exited with $($install.ExitCode)" }
Set-Service sshd -StartupType Automatic
New-NetFirewallRule -Name hobo-sshd -DisplayName 'OpenSSH Server (Hobo)' -Direction Inbound `
    -Protocol TCP -LocalPort 22 -Action Allow -Profile Any | Out-Null
New-Item -Force HKLM:\SOFTWARE\OpenSSH | Out-Null
Set-ItemProperty HKLM:\SOFTWARE\OpenSSH DefaultShell 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'

# vagrant is an administrator, so sshd reads this file, which only Administrators and SYSTEM may write.
$keys = 'C:\ProgramData\ssh\administrators_authorized_keys'
Copy-Item "$hobo\authorized_keys" $keys -Force
icacls.exe $keys /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null

# The answer file's AutoLogon has a count; these make it permanent.
$winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty $winlogon AutoAdminLogon '1'
Set-ItemProperty $winlogon DefaultUserName 'vagrant'
Set-ItemProperty $winlogon DefaultPassword 'vagrant'
Remove-ItemProperty $winlogon AutoLogonCount -ErrorAction SilentlyContinue

powercfg /change standby-timeout-ac 0
powercfg /change monitor-timeout-ac 0
powercfg /hibernate off
New-Item -Force HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization | Out-Null
Set-ItemProperty HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization NoLockScreen 1 -Type DWord

# Restarts the NIC after a resume (network-watchdog.ps1).
$action = New-ScheduledTaskAction -Execute powershell.exe -Argument "-NoProfile -ExecutionPolicy Bypass -File $hobo\network-watchdog.ps1"
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit 0 -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName hobo-network-watchdog -Action $action -Trigger $trigger -Settings $settings -User SYSTEM -RunLevel Highest | Out-Null
Start-ScheduledTask -TaskName hobo-network-watchdog

Remove-Item $msi.FullName
Start-Service sshd
