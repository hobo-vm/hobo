# A [[provision]] step for the Windows VM that `make windows-ui` builds hobo ui's Windows backend in:
# the .NET SDK, machine-wide, on PATH for every later session.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$installer = Join-Path $env:TEMP 'dotnet-install.ps1'
Invoke-WebRequest https://dot.net/v1/dotnet-install.ps1 -OutFile $installer
& $installer -Channel 8.0 -InstallDir 'C:\Program Files\dotnet'
$path = [Environment]::GetEnvironmentVariable('Path', 'Machine')
if ($path -notlike '*C:\Program Files\dotnet*') {
    [Environment]::SetEnvironmentVariable('Path', "$path;C:\Program Files\dotnet", 'Machine')
}
[Environment]::SetEnvironmentVariable('DOTNET_CLI_TELEMETRY_OPTOUT', '1', 'Machine')
