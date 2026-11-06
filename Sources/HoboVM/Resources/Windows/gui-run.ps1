# The desktop session's half of hobo exec --gui, run by gui-exec.ps1's scheduled task: runs the command
# with its output in files, and records its exit status last, which is what says it has finished.
param([string]$Directory)
. "$PSScriptRoot\common.ps1"

# Unbuffered, for gui-exec.ps1 to pass on as it arrives; it has these files open too.
function Open-Output([string]$Path) {
    return New-Object IO.FileStream($Path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite, 1)
}

$status = 1
try {
    $arguments = Read-Command (Get-Content "$Directory\command" -Raw).Trim()
    $command = Resolve-Command $arguments
    if (-not $command) {
        [IO.File]::AppendAllText("$Directory\stderr", "$($arguments[0]): not found`n")
        $status = 127
    } else {
        # Not Start-Process, whose ExitCode is empty for a command that ends quickly.
        $process = New-Object Diagnostics.Process
        $process.StartInfo.FileName = $command.Program
        $process.StartInfo.Arguments = $command.Arguments
        $process.StartInfo.UseShellExecute = $false
        $process.StartInfo.RedirectStandardOutput = $true
        $process.StartInfo.RedirectStandardError = $true
        $started = $false
        try {
            [void]$process.Start()
            $started = $true
        } catch {
            [IO.File]::AppendAllText("$Directory\stderr", (Format-StartFailure $arguments[0] $_) + "`n")
            $status = 126
        }
        if ($started) {
            Set-Content "$Directory\pid" $process.Id -Encoding Ascii
            $stdout = Open-Output "$Directory\stdout"
            $stderr = Open-Output "$Directory\stderr"
            $copies = @(
                $process.StandardOutput.BaseStream.CopyToAsync($stdout),
                $process.StandardError.BaseStream.CopyToAsync($stderr)
            )
            $process.WaitForExit()
            # An app it left running can hold the pipes open forever, so don't wait long for their end.
            [void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]$copies, 2000)
            $status = $process.ExitCode
        }
    }
} catch {
    [IO.File]::AppendAllText("$Directory\stderr", "$_`n")
}
# Moved into place, so that gui-exec.ps1 never reads it half-written.
Set-Content "$Directory\status.new" $status -Encoding Ascii
Move-Item "$Directory\status.new" "$Directory\status"
exit 0
