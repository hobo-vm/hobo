// Windows on VZ (hobo-51j): boots a disk with VZ's EFI, NVMe, virtio-gpu, USB input and NAT, in a
// window behind the others, and saves that window to latest.png every 10 s. See README.md, findings
// 20 and 21. The disk needs a framebuffer driver on its EFI partition to get past the logo.
//   swiftc -O -o vz-boot vz-boot.swift -framework Virtualization -framework AppKit
//   codesign --force --sign - --entitlements ../../entitlements.plist vz-boot
//   ./vz-boot <work dir> <raw or ASIF disk> --mac <mac> [--no-pmu] [--fgt] [--restore]
// SIGUSR1 pauses, saves to <work dir>/state.vzvmsave and exits; --restore starts from that file.
// SIGUSR2 bounces the NIC's link. It runs until the guest stops or it's killed.
import AppKit
import Foundation
import Virtualization
let args = CommandLine.arguments
let work = URL(filePath: args[1]); let diskURL = URL(filePath: args[2])
let mac = args[args.firstIndex(of: "--mac")! + 1]
let stateURL = work.appending(path: "state.vzvmsave")
func log(_ s: String) { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; print("\(f.string(from: .now)) \(s)"); fflush(stdout) }
@MainActor final class Delegate: NSObject, @MainActor VZVirtualMachineDelegate {
    func guestDidStop(_ vm: VZVirtualMachine) { log("guest stopped"); exit(0) }
    func virtualMachine(_ vm: VZVirtualMachine, didStopWithError error: any Error) { log("stopped with error: \(error)"); exit(1) }
}
func enable(_ p: VZGenericPlatformConfiguration, _ flag: String) {
    let sel = NSSelectorFromString("_set\(flag)EmulationEnabled:")
    typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
    unsafeBitCast(p.method(for: sel), to: Setter.self)(p, sel, true); log("set \(flag)")
}
@MainActor func makeConfig() throws -> VZVirtualMachineConfiguration {
    let idFile = work.appending(path: "machine-identifier.bin")
    if !FileManager.default.fileExists(atPath: idFile.path) { try VZGenericMachineIdentifier().dataRepresentation.write(to: idFile) }
    let platform = VZGenericPlatformConfiguration()
    platform.machineIdentifier = VZGenericMachineIdentifier(dataRepresentation: try Data(contentsOf: idFile))!
    if !args.contains("--no-pmu") { enable(platform, "PerformanceMonitoringUnit") }
    if args.contains("--fgt") { enable(platform, "FineGrainedTraps") }
    let varsFile = work.appending(path: "efi-vars.fd")
    let boot = VZEFIBootLoader()
    boot.variableStore = FileManager.default.fileExists(atPath: varsFile.path) ? VZEFIVariableStore(url: varsFile) : try VZEFIVariableStore(creatingVariableStoreAt: varsFile)
    let graphics = VZVirtioGraphicsDeviceConfiguration()
    graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1920, heightInPixels: 1200)]
    let attachment = try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false, cachingMode: .cached, synchronizationMode: .fsync)
    let net = VZVirtioNetworkDeviceConfiguration(); net.attachment = VZNATNetworkDeviceAttachment(); net.macAddress = VZMACAddress(string: mac)!
    let c = VZVirtualMachineConfiguration()
    c.platform = platform; c.bootLoader = boot; c.cpuCount = 4; c.memorySize = 8 << 30
    c.graphicsDevices = [graphics]; c.storageDevices = [VZNVMExpressControllerDeviceConfiguration(attachment: attachment)]
    c.networkDevices = [net]; c.keyboards = [VZUSBKeyboardConfiguration()]; c.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
    c.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
    try c.validate()
    do { try c.validateSaveRestoreSupport(); log("validateSaveRestoreSupport: ok") } catch { log("validateSaveRestoreSupport: \(error)") }
    return c
}
let app = NSApplication.shared; app.setActivationPolicy(.accessory)
let delegate = MainActor.assumeIsolated { Delegate() }
var keep: [AnyObject] = []
signal(SIGUSR1, SIG_IGN); signal(SIGUSR2, SIG_IGN)
Task { @MainActor in
    do {
        let vm = VZVirtualMachine(configuration: try makeConfig()); vm.delegate = delegate
        let view = VZVirtualMachineView(); view.virtualMachine = vm
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 960, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view; window.title = "hobo spike: Windows on VZ"; window.orderBack(nil)
        let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        src.setEventHandler { Task { @MainActor in
            do {
                let t = Date(); try await vm.pause(); log("paused")
                try await vm.saveMachineStateTo(url: stateURL)
                log("SAVED in \(String(format: "%.1f", Date().timeIntervalSince(t))) s"); exit(0)
            } catch { log("SAVE FAILED: \(error)"); exit(3) }
        } }
        let src2 = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        src2.setEventHandler { Task { @MainActor in
            vm.networkDevices[0].attachment = nil; log("link down")
            try? await Task.sleep(for: .seconds(2))
            vm.networkDevices[0].attachment = VZNATNetworkDeviceAttachment(); log("link up, new NAT attachment")
        } }
        src2.resume()
        src.resume(); keep += [vm, view, window, src, src2]
        if args.contains("--restore") {
            let t = Date(); try await vm.restoreMachineStateFrom(url: stateURL); try await vm.resume()
            log("RESTORED and resumed in \(String(format: "%.1f", Date().timeIntervalSince(t))) s; state \(vm.state.rawValue)")
        } else { try await vm.start(); log("started; state \(vm.state.rawValue)") }
        var n = 0
        while true {
            try await Task.sleep(for: .seconds(10)); n += 1
            let shot = Process(); shot.executableURL = URL(filePath: "/usr/sbin/screencapture")
            shot.arguments = ["-x", "-o", "-l\(window.windowNumber)", work.appending(path: "latest.png").path]
            try? shot.run(); shot.waitUntilExit()
        }
    } catch { log("error: \(error)"); exit(2) }
}
app.run()
