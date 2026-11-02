# First-logon setup for the Windows spike, run from the config ISO by autounattend.xml as vagrant
# (an administrator). Installs the virtio drivers, OpenSSH Server and the Vagrant insecure keys,
# makes auto-logon permanent and turns off sleep. Logs to C:\hobo\setup.log; writes
# C:\hobo\setup-done when finished, which run.sh waits for over SSH.
param([string]$Drive)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force C:\hobo | Out-Null
Start-Transcript -Path C:\hobo\setup.log -Append

# Belt and braces: windowsPE should already have added NetKVM.
pnputil /add-driver "$Drive\drivers\*.inf" /subdirs /install

# OpenSSH Server: the pinned Win32-OpenSSH MSI (offline, no Feature on Demand download).
$msi = Get-ChildItem "$Drive\OpenSSH-ARM64-*.msi" | Select-Object -First 1
Start-Process msiexec.exe -Wait -ArgumentList '/i', $msi.FullName, '/qn', '/norestart', 'ADDLOCAL=Server,Client'
Set-Service sshd -StartupType Automatic
if (-not (Get-NetFirewallRule -Name hobo-sshd -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name hobo-sshd -DisplayName 'OpenSSH Server (hobo)' -Direction Inbound `
        -Protocol TCP -LocalPort 22 -Action Allow -Profile Any | Out-Null
}

# vagrant is an administrator, so sshd reads administrators_authorized_keys, which must be
# writable only by Administrators and SYSTEM.
$keys = 'C:\ProgramData\ssh\administrators_authorized_keys'
New-Item -ItemType Directory -Force C:\ProgramData\ssh | Out-Null
Copy-Item "$Drive\authorized_keys" $keys -Force
icacls.exe $keys /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F'

# Guest-side helpers: run a script in the interactive session, and the screenshot it runs.
Copy-Item "$Drive\run-in-session.ps1", "$Drive\screenshot.ps1" C:\hobo\ -Force

# Permanent auto-logon (the unattend's AutoLogon has a LogonCount) and no sleep or lock.
$winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty $winlogon AutoAdminLogon '1'
Set-ItemProperty $winlogon DefaultUserName 'vagrant'
Set-ItemProperty $winlogon DefaultPassword 'vagrant'
Remove-ItemProperty $winlogon AutoLogonCount -ErrorAction SilentlyContinue
powercfg /change standby-timeout-ac 0
powercfg /change monitor-timeout-ac 0
powercfg /hibernate off
New-Item -Force 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization' | Out-Null
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization' NoLockScreen 1 -Type DWord

Start-Service sshd
New-Item -ItemType File -Force C:\hobo\setup-done | Out-Null
Stop-Transcript
