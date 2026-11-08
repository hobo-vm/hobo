# Keeps the desktop at the size of the VM's display, which follows the window, for a resizable display
# ([windows] resizable_display). Run in vagrant's desktop session by the hobo-display-follower logon
# task, and once by create with -Once: Windows starts at 1024x768 whatever the display offers.
# When the host resizes the display, the patched viogpudo takes the new size as its custom mode and
# pulses a named event, but Windows only switches modes when something in the session asks.
# virtio-win's own helper, viogpuap.exe, never finds the adapter here: it stops at the first display
# device that isn't the virtio GPU, and Microsoft Basic Display comes first. This script does its job instead.
param([switch]$Once)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;

public static class HoboDisplayFollower {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DISPLAY_DEVICE {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string deviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string deviceString;
        public int stateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string deviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string deviceKey;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string deviceName;
        public short specVersion, driverVersion, size, driverExtra;
        public int fields, positionX, positionY, displayOrientation, displayFixedOutput;
        public short color, duplex, yResolution, ttOption, collate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string formName;
        public short logPixels;
        public int bitsPerPel, pelsWidth, pelsHeight, displayFlags, displayFrequency;
        public int icmMethod, icmIntent, mediaType, ditherType, reserved1, reserved2, panningWidth, panningHeight;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct OPENADAPTERFROMHDC { public IntPtr hdc; public uint adapter; public uint luidLow; public int luidHigh; public uint vidPnSourceId; }

    [StructLayout(LayoutKind.Sequential)]
    struct ESCAPE {
        public uint adapter, device;
        public int type; // D3DKMT_ESCAPE_DRIVERPRIVATE
        public uint flags;
        public IntPtr privateData;
        public uint privateDataSize;
        public uint context;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplayDevices(string device, int index, ref DISPLAY_DEVICE displayDevice, int flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplaySettings(string device, int mode, ref DEVMODE devMode);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int ChangeDisplaySettingsEx(string device, ref DEVMODE devMode, IntPtr window, int flags, IntPtr parameter);
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateDC(string driver, string device, string output, IntPtr devMode);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll")] static extern int D3DKMTOpenAdapterFromHdc(ref OPENADAPTERFROMHDC open);
    [DllImport("gdi32.dll")] static extern int D3DKMTEscape(ref ESCAPE escape);
    [DllImport("gdi32.dll")] static extern int D3DKMTCloseAdapter(ref uint adapter); // D3DKMT_CLOSEADAPTER
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr OpenEvent(int access, bool inherit, string name);

    const string VirtioGPU = @"PCI\VEN_1AF4&DEV_1050";
    const int AttachedToDesktop = 0x1, Synchronize = 0x100000, CurrentSettings = -1;
    const int PelsWidth = 0x80000, PelsHeight = 0x100000, UpdateRegistry = 0x1;
    const ushort GetDeviceID = 0, GetCustomResolution = 1; // viogpum.h

    class Adapter { public string device; public uint kmtAdapter; public EventWaitHandle resized; }

    // The driver's private escape: VIOGPU_ESCAPE, a type, a length and 4 bytes of data, packed.
    static bool Escape(uint adapter, ushort type, out ushort first, out ushort second) {
        first = second = 0;
        IntPtr data = Marshal.AllocHGlobal(8);
        try {
            Marshal.WriteInt16(data, 0, (short)type);
            Marshal.WriteInt16(data, 2, 4);
            Marshal.WriteInt32(data, 4, 0);
            var escape = new ESCAPE { adapter = adapter, privateData = data, privateDataSize = 8 };
            if (D3DKMTEscape(ref escape) != 0) return false;
            first = (ushort)Marshal.ReadInt16(data, 4);
            second = (ushort)Marshal.ReadInt16(data, 6);
            return true;
        } finally {
            Marshal.FreeHGlobal(data);
        }
    }

    static List<Adapter> FindAdapters() {
        var adapters = new List<Adapter>();
        var info = new DISPLAY_DEVICE();
        info.cb = Marshal.SizeOf(info);
        for (int index = 0; EnumDisplayDevices(null, index, ref info, 0); index++) {
            if ((info.stateFlags & AttachedToDesktop) == 0 || !info.deviceID.StartsWith(VirtioGPU, StringComparison.OrdinalIgnoreCase)) continue;
            IntPtr hdc = CreateDC(null, info.deviceName, null, IntPtr.Zero);
            if (hdc == IntPtr.Zero) continue;
            var open = new OPENADAPTERFROMHDC { hdc = hdc };
            int status = D3DKMTOpenAdapterFromHdc(ref open);
            DeleteDC(hdc);
            if (status != 0) continue;
            // Asking for the ID is also what makes the driver create the event.
            ushort id, unused;
            IntPtr eventHandle = Escape(open.adapter, GetDeviceID, out id, out unused)
                ? OpenEvent(Synchronize, false, @"Global\VioGpuResolutionEvent" + id) : IntPtr.Zero;
            // Closed, or the 2-second retries at logon would open another each time.
            if (eventHandle == IntPtr.Zero) { D3DKMTCloseAdapter(ref open.adapter); continue; }
            var resized = new EventWaitHandle(false, EventResetMode.ManualReset);
            resized.SafeWaitHandle = new Microsoft.Win32.SafeHandles.SafeWaitHandle(eventHandle, true);
            adapters.Add(new Adapter { device = info.deviceName, kmtAdapter = open.adapter, resized = resized });
        }
        return adapters;
    }

    // Switches the desktop to the driver's custom mode, the display's size. Returns why it couldn't.
    static string Follow(Adapter adapter) {
        ushort width, height;
        if (!Escape(adapter.kmtAdapter, GetCustomResolution, out width, out height)) return "the driver didn't give its size";
        if (width == 0 || height == 0) return "the driver has no size yet";
        var mode = new DEVMODE();
        mode.size = (short)Marshal.SizeOf(mode);
        if (!EnumDisplaySettings(adapter.device, CurrentSettings, ref mode)) return "no current mode";
        if (mode.pelsWidth == width && mode.pelsHeight == height) return null;
        mode.pelsWidth = width;
        mode.pelsHeight = height;
        mode.fields = PelsWidth | PelsHeight;
        // Saved, so the desktop comes back at this size after a restart, before this task runs.
        int result = ChangeDisplaySettingsEx(adapter.device, ref mode, IntPtr.Zero, UpdateRegistry, IntPtr.Zero);
        return result == 0 ? null : "ChangeDisplaySettingsEx returned " + result + " for " + width + "x" + height;
    }

    public static void Run(bool once) {
        List<Adapter> adapters;
        // The adapter can still be starting when the session logs on.
        var deadline = DateTime.Now.AddSeconds(60);
        while ((adapters = FindAdapters()).Count == 0) {
            if (once && DateTime.Now > deadline) throw new Exception("no virtio GPU on the desktop after 60 seconds");
            Thread.Sleep(2000);
        }
        if (once) {
            foreach (var adapter in adapters) {
                string failure = Follow(adapter);
                if (failure != null) throw new Exception(adapter.device + ": " + failure);
            }
            return;
        }
        var handles = adapters.ConvertAll(a => (WaitHandle)a.resized).ToArray();
        while (true) {
            foreach (var adapter in adapters) Follow(adapter);
            // The driver pulses the event, so a resize between Follow and the wait would be missed:
            // the timeout catches it.
            WaitHandle.WaitAny(handles, 2000);
        }
    }
}
'@
[HoboDisplayFollower]::Run($Once)
