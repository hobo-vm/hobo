# What exec.ps1, gui-exec.ps1 and gui-run.ps1 share. A command arrives as base64 of a JSON array of
# its arguments, which needs no quoting on the way through ssh and PowerShell.

function Read-Command([string]$Encoded) {
    $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Encoded))
    return @($json | ConvertFrom-Json)
}

# Hands sshd's caller this process's ID, for cancelling (GuestSSH.PIDMarker), unmangled by PowerShell's
# text formatting.
function Write-Marker([string]$Marker) {
    $bytes = [Text.Encoding]::ASCII.GetBytes("$Marker$PID`n")
    $out = [Console]::OpenStandardOutput()
    $out.Write($bytes, 0, $bytes.Length)
    $out.Flush()
}

# Quotes one argument the way CommandLineToArgvW, and so nearly every Windows program, reads it:
# backslashes only need doubling where they run into a quote.
function Format-Argument([string]$Argument) {
    if ($Argument -ne '' -and $Argument -notmatch '[\s"]') { return $Argument }
    $escaped = [regex]::Replace($Argument, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)\z', '$1$1')
    return '"' + $escaped + '"'
}

# The program to start and its command line. A program or a script runs as itself. Anything else
# PowerShell knows (Get-Process, dir) has no file to start, so a new PowerShell runs it.
function Resolve-Command([string[]]$Arguments) {
    $found = Get-Command $Arguments[0] -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $found) { return $null }
    $rest = @($Arguments | Select-Object -Skip 1)
    if ($found.CommandType -eq 'Application') {
        return @{ Program = $found.Source; Arguments = (@($rest | ForEach-Object { Format-Argument $_ }) -join ' ') }
    }
    # Quoted except for what looks like a parameter name, which PowerShell would otherwise take for a value.
    # PowerShell ends a single-quoted string at any of these four quotes as well as at the plain one.
    $words = @($Arguments | ForEach-Object { if ($_ -cmatch '^-[A-Za-z][A-Za-z0-9]*:?$') { $_ } else { "'" + [regex]::Replace($_, "['\u2018\u2019\u201A\u201B]", '$0$0') + "'" } })
    # $? is read straight away, since evaluating the if's condition resets it.
    $line = '$ProgressPreference = ''SilentlyContinue''; & ' + ($words -join ' ') + '; $failed = -not $?; if ($null -ne $LASTEXITCODE) { exit $LASTEXITCODE } elseif ($failed) { exit 1 }'
    # Not -EncodedCommand, which reports errors as CLIXML when its input is redirected.
    return @{
        Program = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command " + (Format-Argument $line)
    }
}
