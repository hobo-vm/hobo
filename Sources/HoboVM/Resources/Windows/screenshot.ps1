# hobo screenshot: writes a PNG of vagrant's desktop to stdout. Run in the desktop session.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing, System.Windows.Forms
Add-Type -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();' -Name Dpi -Namespace Hobo
[Hobo.Dpi]::SetProcessDPIAware() | Out-Null
$bounds = [Windows.Forms.Screen]::PrimaryScreen.Bounds
$bitmap = New-Object Drawing.Bitmap $bounds.Width, $bounds.Height
$graphics = [Drawing.Graphics]::FromImage($bitmap)
$graphics.CopyFromScreen($bounds.Location, [Drawing.Point]::Empty, $bounds.Size)
$png = New-Object IO.MemoryStream
$bitmap.Save($png, [Drawing.Imaging.ImageFormat]::Png)
$out = [Console]::OpenStandardOutput()
$png.WriteTo($out)
$out.Flush()
