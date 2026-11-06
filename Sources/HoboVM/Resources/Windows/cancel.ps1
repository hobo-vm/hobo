# Ends a command exec.ps1 or gui-exec.ps1 is running, given that script's process ID: without a TTY,
# closing the ssh session doesn't reach it. A --gui command isn't that script's child, so it and its
# task are ended by name; the files it used go too, since the script gets no chance to clean up.
param([int]$ProcessId)
$ProgressPreference = 'SilentlyContinue'
$name = "hobo-gui-$ProcessId"
$directory = "$PSScriptRoot\gui\$name"
$command = if (Test-Path "$directory\pid") { (Get-Content "$directory\pid" -Raw).Trim() }
# The script first, so that it isn't cleaning up alongside this.
taskkill.exe /T /F /PID $ProcessId 2>&1 | Out-Null
if ($command) { taskkill.exe /T /F /PID $command 2>&1 | Out-Null }
Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $directory -ErrorAction SilentlyContinue
exit 0
