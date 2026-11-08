# hobo exec: runs a command as a child with this process's own stdin, stdout and stderr, so its
# output stays byte for byte what it wrote, and exits with its status.
param([string]$Encoded)
$ProgressPreference = 'SilentlyContinue'
. "$PSScriptRoot\common.ps1"

$arguments = Read-Command $Encoded
$command = Resolve-Command $arguments
if (-not $command) {
    [Console]::Error.WriteLine("$($arguments[0]): not found")
    exit 127
}
$start = New-Object Diagnostics.ProcessStartInfo
$start.FileName = $command.Program
$start.Arguments = $command.Arguments
$start.UseShellExecute = $false
try {
    $process = [Diagnostics.Process]::Start($start)
} catch {
    [Console]::Error.WriteLine((Format-StartFailure $arguments[0] $_))
    exit 126
}
$process.WaitForExit()
exit $process.ExitCode
