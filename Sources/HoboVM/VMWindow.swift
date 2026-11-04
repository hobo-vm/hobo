import AppKit
import Virtualization

/// The on-demand window onto a running guest (`hobo view`, `start --gui`). Closing it asks
/// whether to keep the VM running headless, suspend it or shut it down; the window is only ever hidden, so
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
    /// Called when the user picks Suspend; returns why the suspend failed, or nil once the state
    /// is saved (the process then exits).
    var onSuspend: (() async -> String?)?
    /// Set while `create` waits on the window (the recoveryOS step): closing the window, or the
    /// menu's Cancel Build, offers to cancel the build instead of Keep Running, Suspend and Shut Down.
    var onCancelBuild: (() -> Void)?
    /// Whether the window is showing, as opposed to hidden by Keep Running or a shutdown.
    private(set) var isShown = false
    /// A hide waiting for the window to leave full screen, so it doesn't leave an empty Space.
    private var hidesAfterFullScreen = false
    /// Whether the guest display follows the window in Retina pixels (VZ's automatic resizing) or,
    /// for a guest that doesn't scale its own UI, in points.
    private let hiDPI: Bool

    init(guest: GuestVM, title: String, log: @escaping (String) -> Void) {
        machine = guest.machine
        hiDPI = type(of: guest.bundle).hiDPIDisplay
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
        window.contentAspectRatio = GuestDisplay.pixels
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.delegate = self
        window.center()
    }

    var frame: NSRect { window.frame }

    /// Shows the window in front and tries to take focus. A process launchd started can't always
    /// take focus from the active app (cooperative activation), so the window may need a click.
    func show() {
        // The guest display follows the window's size while it shows: in Retina pixels by VZ (turning
        // this on resizes it), or in points by `followWindowInPoints`.
        view.automaticallyReconfiguresDisplay = hiDPI
        hidesAfterFullScreen = false
        // An `.accessory` app never owns the menu bar, so clicking it sent the window behind the
        // active app, and it had no ⌘Tab entry or full-screen Space.
        NSApp.setActivationPolicy(.regular)
        // Rebuilt on every show: its items target this window, and a process can show more than
        // one over its life (create's recoveryOS step opens a new one on each try).
        NSApp.mainMenu = makeMenu()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate()
        isShown = true
        followWindowInPoints()
    }

    /// Without HiDPI, sizes the guest display to the view in points; VZ's automatic resizing would
    /// use backing pixels. Not during a live resize, so a drag reconfigures once, at the end.
    private func followWindowInPoints() {
        guard !hiDPI, isShown, !window.inLiveResize else { return }
        let size = view.bounds.size
        guard size.width >= 1, size.height >= 1 else { return }
        do {
            try machine.graphicsDevices.first?.displays.first?.reconfigure(sizeInPixels: size)
        } catch {
            log("warning: couldn't resize the display to the window: \(error)")
        }
    }

    func windowDidResize(_ notification: Notification) { followWindowInPoints() }

    func windowDidEndLiveResize(_ notification: Notification) { followWindowInPoints() }

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
            try machine.graphicsDevices.first?.displays.first?.reconfigure(sizeInPixels: GuestDisplay.pixels)
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
    /// close dialog already offers Keep Running, Suspend and Shut Down.
    private func makeMenu() -> NSMenu {
        let appMenu = NSMenu()
        if onCancelBuild != nil {
            appMenu.addItem(withTitle: "Cancel Building \(name)", action: #selector(confirmCancelBuild), keyEquivalent: "").target = self
        } else {
            appMenu.addItem(withTitle: "Keep \(name) Running in Background", action: #selector(keepRunning), keyEquivalent: "").target = self
            appMenu.addItem(withTitle: "Suspend \(name)", action: #selector(suspend), keyEquivalent: "").target = self
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

    /// Hides the window while the state saves; a failed save brings it back with the reason.
    @objc private func suspend() {
        guard let onSuspend else { return }
        hide()
        Task { [weak self] in
            guard let failure = await onSuspend(), let self else { return }
            show()
            let alert = NSAlert()
            alert.messageText = "Couldn't suspend \(name)"
            alert.informativeText = failure
            alert.beginSheetModal(for: window, completionHandler: nil)
        }
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
        alert.informativeText = "Keep Running hides the window and leaves the VM running headless; hobo view \(name) shows it again. Suspend saves its state, and hobo start \(name) resumes it."
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Suspend")
        alert.addButton(withTitle: "Shut Down")
        alert.addButton(withTitle: "Cancel")
        // A sheet, not a modal loop, so the control socket keeps being served while it is up.
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                hide()
            case .alertSecondButtonReturn:
                suspend()
            case .alertThirdButtonReturn:
                shutDown()
            default:
                break
            }
        }
        return false
    }
}
