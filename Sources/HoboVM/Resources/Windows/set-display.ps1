# Sets the desktop to a size: viogpudo starts at 1024x768, whatever size the VM's display has. Run once
# in the desktop session during create, for a resizable display ([windows] resizable_display); Windows
# remembers it, across reboots and in clones.
param([int]$Width, [int]$Height)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class HoboDisplay {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string deviceName;
        public short specVersion, driverVersion, size, driverExtra;
        public int fields, positionX, positionY, displayOrientation, displayFixedOutput;
        public short color, duplex, yResolution, ttOption, collate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string formName;
        public short logPixels;
        public int bitsPerPel, pelsWidth, pelsHeight, displayFlags, displayFrequency;
        public int icmMethod, icmIntent, mediaType, ditherType, reserved1, reserved2, panningWidth, panningHeight;
    }
    [DllImport("user32.dll")] public static extern int EnumDisplaySettingsA(string device, int mode, ref DEVMODE devMode);
    [DllImport("user32.dll")] public static extern int ChangeDisplaySettingsA(ref DEVMODE devMode, int flags);
}
'@
$mode = New-Object HoboDisplay+DEVMODE
$mode.size = [Runtime.InteropServices.Marshal]::SizeOf($mode)
[HoboDisplay]::EnumDisplaySettingsA($null, -1, [ref]$mode) | Out-Null # ENUM_CURRENT_SETTINGS
$mode.pelsWidth = $Width
$mode.pelsHeight = $Height
$mode.fields = 0x180000 # DM_PELSWIDTH | DM_PELSHEIGHT
$result = [HoboDisplay]::ChangeDisplaySettingsA([ref]$mode, 1) # CDS_UPDATEREGISTRY
if ($result -ne 0) { throw "ChangeDisplaySettings returned $result" }
