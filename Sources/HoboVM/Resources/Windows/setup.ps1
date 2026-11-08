# The guest conventions for a Windows guest, run once as SYSTEM before the first logon: OpenSSH
# Server with PowerShell as its shell, the insecure key, no sleep or lock screen, shares and the
# network watchdog. finish-setup.ps1 does the rest, after Windows' own first-run setup has finished.
$ErrorActionPreference = 'Stop'
$hobo = 'C:\ProgramData\Hobo'

# Hobo's own scripts run through hobo-agent, and provision steps as scripts, which Windows refuses by default.
Set-ExecutionPolicy Bypass -Scope LocalMachine -Force

function Install-Msi([string]$Pattern, [string[]]$Options = @()) {
    $msi = Get-ChildItem "$hobo\$Pattern" | Select-Object -First 1
    $install = Start-Process msiexec.exe -Wait -PassThru -ArgumentList (@('/i', "`"$($msi.FullName)`"", '/qn', '/norestart') + $Options)
    if ($install.ExitCode -ne 0) { throw "$($msi.Name) exited with $($install.ExitCode)" }
    Remove-Item $msi.FullName
}

Install-Msi 'OpenSSH-*.msi' 'ADDLOCAL=Server,Client'
# Off until finish-setup.ps1, which turns it on with hobo-agent, whose answering says setup has finished.
Stop-Service sshd -ErrorAction SilentlyContinue
Set-Service sshd -StartupType Disabled
New-NetFirewallRule -Name hobo-sshd -DisplayName 'OpenSSH Server (Hobo)' -Direction Inbound `
    -Protocol TCP -LocalPort 22 -Action Allow -Profile Any | Out-Null
New-Item -Force HKLM:\SOFTWARE\OpenSSH | Out-Null
Set-ItemProperty HKLM:\SOFTWARE\OpenSSH DefaultShell 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'

# hobo is an administrator, so sshd reads this file, which only Administrators and SYSTEM may write.
$keys = 'C:\ProgramData\ssh\administrators_authorized_keys'
Copy-Item "$hobo\authorized_keys" $keys -Force
icacls.exe $keys /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null

powercfg /change standby-timeout-ac 0
powercfg /change monitor-timeout-ac 0
powercfg /hibernate off
New-Item -Force HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization | Out-Null
Set-ItemProperty HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization NoLockScreen 1 -Type DWord

# Shares: virtio-win's service mounts the VM's virtio-fs device on Z:, with each share a folder there,
# so ones added later appear with nothing changed here. The device is always attached.
Install-Msi 'winfsp-*.msi'
sc.exe create VirtioFsSvc binPath= "$hobo\virtiofs.exe" start= auto depend= 'WinFsp.Launcher/VirtioFsDrv' DisplayName= 'Virtio FS Service' | Out-Null
if ($LASTEXITCODE -ne 0) { throw "creating the share service exited with $LASTEXITCODE" }
Start-Service VirtioFsSvc

# Restarts the NIC after a resume (network-watchdog.ps1).
$action = New-ScheduledTaskAction -Execute powershell.exe -Argument "-NoProfile -ExecutionPolicy Bypass -File $hobo\network-watchdog.ps1"
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit 0 -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName hobo-network-watchdog -Action $action -Trigger $trigger -Settings $settings -User SYSTEM -RunLevel Highest | Out-Null
Start-ScheduledTask -TaskName hobo-network-watchdog

$action = New-ScheduledTaskAction -Execute powershell.exe -Argument "-NoProfile -ExecutionPolicy Bypass -File $hobo\finish-setup.ps1"
Register-ScheduledTask -TaskName hobo-finish-setup -Action $action -Trigger $trigger -Settings $settings -User SYSTEM -RunLevel Highest | Out-Null
# Volatile, so that it's gone after a restart: finish-setup.ps1 tells from it whether one has happened.
[void][Microsoft.Win32.Registry]::LocalMachine.CreateSubKey('SOFTWARE\Hobo\SetupBoot', $true, [Microsoft.Win32.RegistryOptions]::Volatile)
Start-ScheduledTask -TaskName hobo-finish-setup
