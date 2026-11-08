import AppKit
import HoboCore

/// The one manual step of a `create`: with the guest booted into recoveryOS, the VM window comes to
/// the front with a panel of instructions beside it, and the person runs `csrutil disable`. Their
/// shutting the guest down is the signal that they're done. Paste doesn't reach recoveryOS, so the
/// commands are to be typed. Checked on macOS 27.2 (2026-11-02): Options → Continue sometimes shows
/// a language picker first (a fresh build did, a clone didn't), with no user picker seen so far, and
/// `csrutil disable` asks y/n and then hobo's password.
@MainActor
enum SIPRecoveryStep {
    enum Outcome { case shutDown, cancelled }

    /// Whether this process can show windows: `create` runs AppKit's loop only in a GUI session.
    static var canShowUI: Bool { NSApp?.isRunning == true }

    /// Shows the window and panel for `guest` (already booted into recovery) until it stops or the
    /// person cancels. `notice` heads the panel, e.g. after a try that left SIP on.
    static func run(_ guest: GuestVM, name: String, notice: String?, log: @escaping (String) -> Void) async -> Outcome {
        let window = VMWindow(guest: guest, vmName: name, title: "\(name) — recoveryOS", log: log)
        let panel = InstructionsPanel(notice: notice)
        let cancel = CancelFlag()
        window.onCancelBuild = { cancel.isSet = true }
        panel.onCancel = { cancel.isSet = true }
        window.show()
        panel.show(beside: window.frame)
        // Bounces the Dock icon (the process is a regular app while the window shows) and rings the
        // terminal bell, since the person has likely walked away from a long build.
        NSApp.requestUserAttention(.criticalRequest)
        log("\u{7}Waiting for you in the \(name) window: turn SIP off in recoveryOS (instructions beside it)")
        defer {
            panel.close()
            window.close()
        }
        while !guest.isStopped {
            if cancel.isSet { return .cancelled }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return .shutDown
    }

    @MainActor private final class CancelFlag { var isSet = false }
}

/// The floating instructions beside the VM window.
@MainActor
private final class InstructionsPanel: NSObject {
    private let panel: NSPanel
    var onCancel: (() -> Void)?

    init(notice: String?) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 10),
            styleMask: [.titled, .utilityWindow, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        super.init()
        panel.title = "Turn off System Integrity Protection"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        var rows: [NSView] = []
        if let notice {
            let label = NSTextField(wrappingLabelWithString: notice)
            label.textColor = .systemRed
            rows.append(label)
        }
        rows.append(NSTextField(wrappingLabelWithString: "In the VM window (typing there; paste doesn't reach recoveryOS):"))
        let steps: [(text: String, command: String?)] = [
            ("Click Options, then Continue. If it asks for a language, pick one and click the arrow; if it asks for a user, pick \(Conventions.username) (password \(Conventions.password)).", nil),
            ("From the menu bar, choose Utilities › Terminal.", nil),
            ("Type this, press Return, then answer y:", "csrutil disable"),
            ("When asked, type the password:", Conventions.password),
            ("When it says SIP is off, choose Apple menu › Shut Down. The build carries on by itself.", nil),
        ]
        for (index, step) in steps.enumerated() {
            rows.append(NSTextField(wrappingLabelWithString: "\(index + 1). \(step.text)"))
            if let command = step.command {
                let code = NSTextField(labelWithString: "    \(command)")
                code.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize + 1, weight: .semibold)
                code.isSelectable = true
                rows.append(code)
            }
        }
        rows.append(NSButton(title: "Cancel Build", target: self, action: #selector(cancel)))

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for row in rows where row is NSTextField {
            row.widthAnchor.constraint(equalToConstant: 368).isActive = true
        }
        panel.contentView = stack
        panel.setContentSize(stack.fittingSize)
    }

    /// To the right of `frame` if the screen has room, else over its top-right corner, top edges
    /// aligned. Never to the left: the guest's menu bar (Apple menu, Utilities) is at the top left,
    /// and recoveryOS has nothing but status icons at the top right.
    func show(beside frame: NSRect) {
        let size = panel.frame.size
        let visible = NSScreen.main?.visibleFrame ?? frame
        var x = frame.maxX + 12
        if x + size.width > visible.maxX { x = min(frame.maxX, visible.maxX) - size.width }
        panel.setFrameTopLeftPoint(NSPoint(x: x, y: min(frame.maxY, visible.maxY)))
        panel.orderFrontRegardless()
    }

    func close() { panel.orderOut(nil) }

    @objc private func cancel() { onCancel?() }
}
