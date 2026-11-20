// Spike: can a CLI see host USB devices through AccessoryAccess, and hand one to a VZ guest?
// See README.md.

import AccessoryAccess
import AppKit
import Foundation
import Virtualization

func log(_ message: String) {
    FileHandle.standardError.write(Data("[\(String(format: "%.2f", ProcessInfo.processInfo.systemUptime))] \(message)\n".utf8))
}

/// "1050:0407" from the accessory's device descriptor (idVendor at offset 8, idProduct at 10).
func ids(_ accessory: AAUSBAccessory) -> String {
    let d = [UInt8](accessory.deviceDescriptorData)
    guard d.count >= 12 else { return "?:?" }
    return String(format: "%04x:%04x", UInt16(d[8]) | UInt16(d[9]) << 8, UInt16(d[10]) | UInt16(d[11]) << 8)
}

final class Listener: NSObject, AAUSBAccessoryListener, @unchecked Sendable {
    var onConnect: (@Sendable (AAUSBAccessory) -> Void)?
    func usbAccessoryDidConnect(_ usbAccessory: AAUSBAccessory) {
        log("connect    \(ids(usbAccessory)) registryID=\(usbAccessory.registryID)")
        onConnect?(usbAccessory)
    }
    func usbAccessoryDidDisconnect(_ usbAccessory: AAUSBAccessory) {
        log("disconnect \(ids(usbAccessory)) registryID=\(usbAccessory.registryID)")
    }
}

final class ControllerDelegate: NSObject, VZUSBController.Delegate {
    func usbController(_ usbController: VZUSBController, usbPassthroughDeviceDidDisconnect device: VZUSBPassthroughDevice) {
        log("guest lost the passthrough device (host unplug)")
    }
}

let listener = Listener()
let controllerDelegate = ControllerDelegate()
nonisolated(unsafe) var machine: VZVirtualMachine?

/// Registers the listener for every USB device and reports what is already connected.
func register(then: @escaping @Sendable ([AAUSBAccessory]) -> Void) {
    log("registering listener")
    AAUSBAccessoryManager.shared.registerListener(listener, matchingCriteria: []) { accessories, error in
        if let error {
            log("register failed: \(error)")
            exit(1)
        }
        log("registered; \(accessories.count) already connected")
        for accessory in accessories { log("present    \(ids(accessory)) registryID=\(accessory.registryID)") }
        then(accessories)
    }
}

/// A bare Linux guest on a copy of a hobo disk: enough to boot and enumerate USB.
func bootConfiguration(disk: URL, console: URL, passthrough: AAUSBAccessory?) throws -> VZVirtualMachineConfiguration {
    let directory = disk.deletingLastPathComponent()
    let bootLoader = VZEFIBootLoader()
    let variables = directory.appending(path: "efi-variables")
    bootLoader.variableStore = FileManager.default.fileExists(atPath: variables.path)
        ? VZEFIVariableStore(url: variables)
        : try VZEFIVariableStore(creatingVariableStoreAt: variables)

    let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
    serial.attachment = try VZFileSerialPortAttachment(url: console, append: false)

    let network = VZVirtioNetworkDeviceConfiguration()
    network.attachment = VZNATNetworkDeviceAttachment()

    let usb = VZXHCIControllerConfiguration()
    if let passthrough { usb.usbDevices = [VZUSBPassthroughDeviceConfiguration(device: passthrough)] }

    let config = VZVirtualMachineConfiguration()
    config.platform = VZGenericPlatformConfiguration()
    config.bootLoader = bootLoader
    config.cpuCount = 2
    config.memorySize = 2 << 30
    config.storageDevices = [VZVirtioBlockDeviceConfiguration(
        attachment: try VZDiskImageStorageDeviceAttachment(url: disk, readOnly: false, cachingMode: .cached, synchronizationMode: .fsync)
    )]
    config.networkDevices = [network]
    config.serialPorts = [serial]
    config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
    config.usbControllers = [usb]
    try config.validate()
    return config
}

@MainActor
func boot(disk: URL, console: URL, target: String, atBoot: Bool, accessories: [AAUSBAccessory]) {
    let accessory = accessories.first { ids($0) == target }
    if accessory == nil { log("no \(target) connected yet; will attach when it appears") }
    do {
        let vm = VZVirtualMachine(configuration: try bootConfiguration(
            disk: disk, console: console, passthrough: atBoot ? accessory : nil
        ))
        machine = vm
        vm.start { result in
            if case .failure(let error) = result {
                log("start failed: \(error)")
                exit(1)
            }
            log("vm started; usb controllers=\(vm.usbControllers.count) devices=\(vm.usbControllers.first?.usbDevices.count ?? 0)")
            vm.usbControllers.first?.delegate = controllerDelegate
            if !atBoot, let accessory { hotAttach(accessory) }
        }
    } catch {
        log("configuration failed: \(error)")
        exit(1)
    }
    listener.onConnect = { accessory in
        guard ids(accessory) == target else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { hotAttach(accessory) } }
    }
}

@MainActor
func hotAttach(_ accessory: AAUSBAccessory) {
    guard let controller = machine?.usbControllers.first else { return log("no usb controller") }
    do {
        let device = try VZUSBPassthroughDevice(configuration: VZUSBPassthroughDeviceConfiguration(device: accessory))
        log("attaching \(ids(accessory))")
        controller.attach(device: device) { error in
            log(error.map { "attach failed: \($0)" } ?? "attached; devices=\(controller.usbDevices.count)")
        }
    } catch {
        log("passthrough device init failed: \(error)")
    }
}

// usage: spike [--policy none|accessory|regular] list [seconds]
//        spike [--policy ...] boot <disk> <console-log> <vid:pid> [--at-boot]
var arguments = Array(CommandLine.arguments.dropFirst())
var policy = "none"
if arguments.first == "--policy" {
    policy = arguments[1]
    arguments.removeFirst(2)
}
log("pid \(getpid()) policy=\(policy)")

if policy != "none" {
    let app = MainActor.assumeIsolated { NSApplication.shared }
    MainActor.assumeIsolated { _ = app.setActivationPolicy(policy == "regular" ? .regular : .accessory) }
}

switch arguments.first {
case "list":
    let seconds = arguments.count > 1 ? Double(arguments[1])! : 5
    register { _ in }
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
case "boot":
    let disk = URL(fileURLWithPath: arguments[1]), console = URL(fileURLWithPath: arguments[2])
    let target = arguments[3].lowercased(), atBoot = arguments.contains("--at-boot")
    register { accessories in
        DispatchQueue.main.async {
            MainActor.assumeIsolated { boot(disk: disk, console: console, target: target, atBoot: atBoot, accessories: accessories) }
        }
    }
default:
    log("usage: spike [--policy none|accessory|regular] list [seconds] | boot <disk> <console-log> <vid:pid> [--at-boot]")
    exit(64)
}

if policy == "none" {
    dispatchMain()
} else {
    MainActor.assumeIsolated { NSApplication.shared.run() }
}
