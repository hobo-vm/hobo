# Captures the primary screen of the session it runs in to a PNG. SSH runs in session 0, which
# has no desktop, so run.sh runs this through a scheduled task in vagrant's interactive session.
param([string]$Path = 'C:\hobo\shot.png')

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
# Without DPI awareness, Bounds reports scaled pixels and the capture is cropped.
Add-Type -Namespace Hobo -Name Dpi -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
[Hobo.Dpi]::SetProcessDPIAware() | Out-Null

$bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
$tmp = "$Path.partial"
$bitmap.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png)
$graphics.Dispose(); $bitmap.Dispose()
Move-Item -Force $tmp $Path
