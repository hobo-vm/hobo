# Runs a PowerShell script file in vagrant's interactive desktop session and waits for it: the
# prototype of `hobo exec --gui` for Windows (design decision 20). SSH sessions live in session 0,
# which has no desktop, so the work goes through a one-shot scheduled task whose principal is the
# logged-on user with an Interactive logon (no stored password needed).
param(
    [Parameter(Mandatory)] [string]$Script,
    [string[]]$Arguments = @(),
    [int]$TimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'
$name = "hobo-gui-$PID"
# conhost --headless keeps a console window from flashing onto (and into) the desktop.
$taskArgs = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$Script`" " + ($Arguments -join ' ')
$action = New-ScheduledTaskAction -Execute conhost.exe -Argument $taskArgs
$principal = New-ScheduledTaskPrincipal -UserId vagrant -LogonType Interactive -RunLevel Highest
Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Force | Out-Null
try {
    Start-ScheduledTask -TaskName $name
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 250
        $state = (Get-ScheduledTask -TaskName $name).State
    } while ($state -eq 'Running' -and (Get-Date) -lt $deadline)
    if ($state -eq 'Running') { throw "$Script still running after $TimeoutSeconds s" }
    $result = (Get-ScheduledTaskInfo -TaskName $name).LastTaskResult
    exit $result
} finally {
    Unregister-ScheduledTask -TaskName $name -Confirm:$false
}
