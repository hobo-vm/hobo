// Windows on VZ (hobo-51j): boots a disk with VZ's EFI, NVMe, virtio-gpu, USB input and NAT, in a
// window behind the others, and saves that window to win-NNN.png every 15 s. See README.md.
//   swiftc -O -o vz-boot vz-boot.swift -framework Virtualization -framework AppKit
//   codesign --force --sign - --entitlements ../../entitlements.plist vz-boot
//   ./vz-boot <work dir> <raw or ASIF disk> [--usb-iso <iso>]
// It runs until killed.
import AppKit
import Foundation
import Virtualization

let args = CommandLine.arguments
let work = URL(filePath: args[1])
let diskURL = URL(filePath: args[2])
let mac = "5a:48:4f:42:4f:01"

func log(_ s: String) {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
    print("\(f.string(from: .now)) \(s)"); fflush(stdout)
}

@MainActor final class Delegate: NSObject, @MainActor VZVirtualMachineDelegate {
    func guestDidStop(_ vm: VZVirtualMachine) { log("guest stopped"); exit(0) }
    func virtualMachine(_ vm: VZVirtualMachine, didStopWithError error: any Error) { log("stopped with error: \(error)"); exit(1) }
}

@MainActor func makeConfig() throws -> VZVirtualMachineConfiguration {
    let idFile = work.appending(path: "machine-identifier.bin")
    if !FileManager.default.fileExists(atPath: idFile.path) {
        try VZGenericMachineIdentifier().dataRepresentation.write(to: idFile)
    }
    let platform = VZGenericPlatformConfiguration()
    platform.machineIdentifier = VZGenericMachineIdentifier(dataRepresentation: try Data(contentsOf: idFile))!

    let varsFile = work.appending(path: "efi-vars.fd")
    let boot = VZEFIBootLoader()
    boot.variableStore = FileManager.default.fileExists(atPath: varsFile.path)
        ? VZEFIVariableStore(url: varsFile)
        : try VZEFIVariableStore(creatingVariableStoreAt: varsFile)

    let graphics = VZVirtioGraphicsDeviceConfiguration()
    graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1920, heightInPixels: 1200)]

    let attachment = try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false, cachingMode: .cached, synchronizationMode: .fsync)
    let storage = VZNVMExpressControllerDeviceConfiguration(attachment: attachment)

    let net = VZVirtioNetworkDeviceConfiguration()
    net.attachment = VZNATNetworkDeviceAttachment()
    net.macAddress = VZMACAddress(string: mac)!

    let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
    serial.attachment = try VZFileSerialPortAttachment(url: work.appending(path: "vz-console.log"), append: false)

    let config = VZVirtualMachineConfiguration()
    config.platform = platform
    config.bootLoader = boot
    config.cpuCount = 4
    config.memorySize = 8 << 30
    config.graphicsDevices = [graphics]
    var storages: [VZStorageDeviceConfiguration] = [storage]
    if let i = args.firstIndex(of: "--usb-iso") {
        // First, so the firmware tries the installer before the empty fallback.
        storages.insert(VZUSBMassStorageDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(url: URL(filePath: args[i + 1]), readOnly: true)), at: 0)
    }
    config.storageDevices = storages
    config.networkDevices = [net]
    config.serialPorts = [serial]
    config.keyboards = [VZUSBKeyboardConfiguration()]
    config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
    config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
    try config.validate()
    return config
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = MainActor.assumeIsolated { Delegate() }
var keep: [AnyObject] = []

Task { @MainActor in
    do {
        let vm = VZVirtualMachine(configuration: try makeConfig())
        vm.delegate = delegate
        let view = VZVirtualMachineView()
        view.virtualMachine = vm
        // Behind the other windows, so it never takes focus; an off-screen one captures only black.
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 960, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.title = "hobo spike: Windows on VZ"; window.orderBack(nil)
        keep += [vm, view, window]
        try await vm.start()
        log("VZ started the VM; state \(vm.state.rawValue)")
        var n = 0
        while true {
            try await Task.sleep(for: .seconds(15))
            n += 1
            let shot = Process()
            shot.executableURL = URL(filePath: "/usr/sbin/screencapture")
            shot.arguments = ["-x", "-o", "-l\(window.windowNumber)", work.appending(path: "win-\(String(format: "%03d", n)).png").path]
            try? shot.run(); shot.waitUntilExit()
            log("capture status \(shot.terminationStatus)")
            log("tick \(n) state \(vm.state.rawValue)")
        }
    } catch {
        log("error: \(error)")
        exit(2)
    }
}
app.run()
