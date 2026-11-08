# hobo exec --gui: SSH sessions live in session 0, which has no desktop, so the command goes through a
# one-shot scheduled task in hobo's interactive session (gui-run.ps1). The task can't share this
# process's streams, so its output comes back through files, passed on here as it arrives.
param([string]$Marker, [string]$Encoded)
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"
Write-Marker $Marker

# Auto-login can finish after SSH answers. 125 is what exec --gui exits with for this on every guest.
$deadline = (Get-Date).AddSeconds(60)
while (-not (Get-Process explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -gt 0 })) {
    if ((Get-Date) -gt $deadline) {
        [Console]::Error.WriteLine("hobo's desktop session isn't up after 60 seconds")
        exit 125
    }
    Start-Sleep -Milliseconds 500
}

$name = "hobo-gui-$PID"
$directory = "$PSScriptRoot\gui\$name"
New-Item -ItemType Directory -Force $directory | Out-Null
Set-Content "$directory\command" $Encoded -Encoding Ascii
$stdout = "$directory\stdout"
$stderr = "$directory\stderr"
foreach ($file in $stdout, $stderr) { [IO.File]::WriteAllBytes($file, [byte[]]@()) }

function Copy-New($from, $to, $buffer) {
    while (($count = $from.Read($buffer, 0, $buffer.Length)) -gt 0) { $to.Write($buffer, 0, $count); $to.Flush() }
}

# conhost --headless keeps a console window from flashing onto the desktop, and into screenshots.
$action = New-ScheduledTaskAction -Execute conhost.exe -Argument "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSScriptRoot\gui-run.ps1`" `"$directory`""
$principal = New-ScheduledTaskPrincipal -UserId hobo -LogonType Interactive -RunLevel Highest
Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Force | Out-Null
try {
    Start-ScheduledTask -TaskName $name
    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $outFile = [IO.File]::Open($stdout, 'Open', 'Read', $share)
    $errFile = [IO.File]::Open($stderr, 'Open', 'Read', $share)
    $toOut = [Console]::OpenStandardOutput()
    $toErr = [Console]::OpenStandardError()
    $buffer = New-Object byte[] 65536
    # The task reads as Ready until it's running, so only Ready after that means it has ended.
    $hasRun = $false
    $startBy = (Get-Date).AddSeconds(30)
    while ($true) {
        # Checked before reading, so what was written before the command ended still gets read.
        $done = Test-Path "$directory\status"
        $running = (Get-ScheduledTask -TaskName $name).State -eq 'Running'
        if ($running) { $hasRun = $true }
        $stopped = -not $running -and ($hasRun -or (Get-Date) -gt $startBy)
        Copy-New $outFile $toOut $buffer
        Copy-New $errFile $toErr $buffer
        if ($done) { break }
        # Checked again: having just finished is fine, and the next pass reads the last of its output.
        if ($stopped -and -not (Test-Path "$directory\status")) {
            [Console]::Error.WriteLine("the desktop session's task ended without an exit status")
            exit 1
        }
        Start-Sleep -Milliseconds 100
    }
    $outFile.Close()
    $errFile.Close()
    $status = [int](Get-Content "$directory\status" -Raw)
} finally {
    Unregister-ScheduledTask -TaskName $name -Confirm:$false
    Remove-Item -Recurse -Force $directory -ErrorAction SilentlyContinue
}
exit $status
