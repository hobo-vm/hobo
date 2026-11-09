import AppKit
import HoboAppModel
import SwiftUI

/// Hobo.app: the library window over the same core the CLI uses (designs/hobo-app.md). VMs run in
/// their own `hobo _vm-run` processes under launchd, so quitting the app never stops one.
@main
struct HoboApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        Window("Hobo", id: "library") {
            LibraryView(library: delegate.library)
                .frame(minWidth: 760, minHeight: 460)
        }
        .defaultSize(width: 1000, height: 700)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Install Command Line Tool…") { delegate.installCommandLineTool() }
            }
            CommandGroup(replacing: .newItem) {
                Button("New VM…") { delegate.library.presentNewVM = true }
                    .keyboardShortcut("n")
                Button("Create from Recipe…") { delegate.library.presentRecipePicker = true }
                    .keyboardShortcut("o")
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let library = LibraryWindowState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        library.model.startWatching()
    }

    /// Closing the window quits, except while a build runs, which would be cancelled.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !library.model.buildInProgress
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let build = library.model.build, !build.finished else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quitting cancels building \(build.name)."
        alert.informativeText = "The VM is deleted, as it is when hobo create is interrupted."
        alert.addButton(withTitle: "Keep Building")
        alert.addButton(withTitle: "Quit")
        alert.buttons[1].hasDestructiveAction = true
        if alert.runModal() == .alertSecondButtonReturn { library.model.cancelBuildAndQuit() }
        return .terminateCancel
    }

    func installCommandLineTool() {
        let tool = CommandLineTool()
        let alert = NSAlert()
        switch tool.state {
        case .installed:
            alert.messageText = "The hobo command is installed."
            alert.informativeText = "\(tool.link.path) links to this app's \(tool.target.path)."
            alert.runModal()
            return
        case .missing:
            alert.messageText = "Install the hobo command?"
            alert.informativeText = "This links \(tool.link.path) to this app, which needs an administrator's password."
        case .linkedElsewhere(let destination):
            alert.messageText = "Replace the hobo command?"
            alert.informativeText = "\(tool.link.path) is a link to \(destination). Replacing it links it to this app, which needs an administrator's password."
        case .otherFile:
            alert.messageText = "Replace the hobo command?"
            alert.informativeText = "\(tool.link.path) is another file. Replacing it links it to this app, which needs an administrator's password."
        }
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try tool.install()
        } catch {
            library.model.failure = "Couldn't install the hobo command: \(error)"
        }
    }
}

/// The library model plus which sheets the menu commands asked for.
@MainActor @Observable
final class LibraryWindowState {
    let model = Library()
    var presentNewVM = false
    var presentRecipePicker = false
}
