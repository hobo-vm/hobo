import AppKit
import Virtualization

/// The on-demand window onto a running guest (`hobo view`, `start --gui`). Closing it asks
/// whether to keep the VM running headless or shut it down; the window is only ever hidden, so
/// the next `show` brings back the same one.
@MainActor
final class VMWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let view = VZVirtualMachineView()
    private let machine: VZVirtualMachine
    private let name: String
    private let log: (String) -> Void
    /// Called when the user picks Shut Down in the close dialog.
    var onShutDown: (() -> Void)?
    /// Whether the window is showing, as opposed to hidden by Keep Running or a shutdown.
    private(set) var isShown = false

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
        window.delegate = self
        window.center()
    }

    /// Shows the window in front and tries to take focus. A process launchd started can't always
    /// take focus from the active app (cooperative activation), so the window may need a click.
    func show() {
        // The guest display follows the window's size while it shows; turning this on resizes it.
        view.automaticallyReconfiguresDisplay = true
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate()
        isShown = true
    }

    /// Hides the window and puts the guest display back to its configured size.
    func hide() {
        window.orderOut(nil)
        isShown = false
        view.automaticallyReconfiguresDisplay = false
        do {
            try machine.graphicsDevices.first?.displays.first?.reconfigure(sizeInPixels: MacVMBundle.displayPixels)
        } catch {
            // The guest keeps the window's size until the next resize or boot; screenshots follow it.
            log("warning: couldn't reset the display to its configured size: \(error)")
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
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
                hide()
                onShutDown?()
            default:
                break
            }
        }
        return false
    }
}
