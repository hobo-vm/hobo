import AppKit
import Virtualization

/// The on-demand window onto a running guest (`hobo view`, `start --gui`). Closing it asks
/// whether to keep the VM running headless or shut it down; the window is only ever hidden, so
/// the next `show` brings back the same one. While it shows, the process is a regular app (Dock,
/// ⌘Tab, its own menu bar, full screen); hidden, it goes back to `.accessory`.
@MainActor
final class VMWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let view = VZVirtualMachineView()
    private let machine: VZVirtualMachine
    private let name: String
    private let log: (String) -> Void
    /// Called when the user picks Shut Down in the close dialog.
    var onShutDown: (() -> Void)?
    /// Set while `create` waits on the window (the recoveryOS step): closing the window, or the
    /// menu's Cancel Build, offers to cancel the build instead of Keep Running and Shut Down.
    var onCancelBuild: (() -> Void)?
    /// Whether the window is showing, as opposed to hidden by Keep Running or a shutdown.
    private(set) var isShown = false
    /// A hide waiting for the window to leave full screen, so it doesn't leave an empty Space.
    private var hidesAfterFullScreen = false

    init(guest: GuestVM, title: String, log: @escaping (String) -> Void) {
        machine = guest.machine
        name = title
        self.log = log
        view.virtualMachine = guest.machine
        // Host shortcuts (⌘Tab, ⌘Space) go to the guest while the window is focused.
        view.capturesSystemKeys = true
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        super.init()
        window.title = title
        window.contentView = view
        window.contentAspectRatio = MacVMBundle.displayPixels
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.delegate = self
        window.center()
    }

    var frame: NSRect { window.frame }

    /// Shows the window in front and tries to take focus. A process launchd started can't always
    /// take focus from the active app (cooperative activation), so the window may need a click.
    func show() {
        // The guest display follows the window's size while it shows; turning this on resizes it.
        view.automaticallyReconfiguresDisplay = true
        hidesAfterFullScreen = false
        // An `.accessory` app never owns the menu bar, so clicking it sent the window behind the
        // active app, and it had no ⌘Tab entry or full-screen Space.
        NSApp.setActivationPolicy(.regular)
        if NSApp.mainMenu == nil { NSApp.mainMenu = makeMenu() }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate()
        isShown = true
    }

    /// Hides the window and puts the guest display back to its configured size.
    func hide() {
        isShown = false
        if window.styleMask.contains(.fullScreen) {
            hidesAfterFullScreen = true
            window.toggleFullScreen(nil)
            return
        }
        window.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        view.automaticallyReconfiguresDisplay = false
        do {
            try machine.graphicsDevices.first?.displays.first?.reconfigure(sizeInPixels: MacVMBundle.displayPixels)
        } catch {
            // The guest keeps the window's size until the next resize or boot; screenshots follow it.
            log("warning: couldn't reset the display to its configured size: \(error)")
        }
    }

    /// Takes the window away for good once its guest has stopped (nothing left to resize).
    func close() {
        isShown = false
        window.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard hidesAfterFullScreen else { return }
        hidesAfterFullScreen = false
        hide()
    }

    /// The menu bar the window gets while it shows. No Quit: quitting would kill the VM, and the
    /// close dialog already offers Keep Running and Shut Down.
    private func makeMenu() -> NSMenu {
        let appMenu = NSMenu()
        if onCancelBuild != nil {
            appMenu.addItem(withTitle: "Cancel Building \(name)", action: #selector(confirmCancelBuild), keyEquivalent: "").target = self
        } else {
            appMenu.addItem(withTitle: "Keep \(name) Running in Background", action: #selector(keepRunning), keyEquivalent: "").target = self
            appMenu.addItem(withTitle: "Shut Down \(name)", action: #selector(shutDown), keyEquivalent: "").target = self
        }

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        let fullScreen = windowMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.control, .command]
        NSApp.windowsMenu = windowMenu

        let menu = NSMenu()
        for submenu in [appMenu, windowMenu] {
            let item = NSMenuItem()
            item.submenu = submenu
            menu.addItem(item)
        }
        return menu
    }

    @objc private func keepRunning() { hide() }

    @objc private func shutDown() {
        hide()
        onShutDown?()
    }

    @objc private func confirmCancelBuild() {
        let alert = NSAlert()
        alert.messageText = "Cancel building \(name)?"
        alert.informativeText = "The VM is deleted."
        alert.addButton(withTitle: "Cancel Build")
        alert.addButton(withTitle: "Keep Building")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.onCancelBuild?() }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if onCancelBuild != nil {
            confirmCancelBuild()
            return false
        }
        let alert = NSAlert()
        alert.messageText = "Keep \(name) running?"
        alert.informativeText = "Keep Running hides the window and leaves the VM running headless; hobo view \(name) shows it again."
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Shut Down")
        alert.addButton(withTitle: "Cancel")
        // A sheet, not a modal loop, so the control socket keeps being served while it is up.
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                hide()
            case .alertSecondButtonReturn:
                shutDown()
            default:
                break
            }
        }
        return false
    }
}
