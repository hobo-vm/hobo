import Foundation
@_exported import ArgumentParser

/// `hobo ui`'s commands, parsed by both sides: `hobo` checks them on the host (for `--help` and
/// usage errors before reaching the guest), then sends the arguments as they were to `hobo-ui`
/// in the guest, which parses them again and runs them (`UICommand`).
public struct HoboUI: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "hobo ui <vm>",
        abstract: "Drive a macOS guest's apps through accessibility.",
        discussion: """
            snapshot prints an app's elements, each with a ref such as e12 that the other commands act on. \
            A ref keeps its number across snapshots while the element is there; one that has gone fails as stale. \
            Coordinates and frames are screenshot pixels, the same as in a hobo screenshot PNG. \
            Clicks, drags, scrolls and keys are real input events, as a person's would be. \
            --app takes a bundle ID, a name or pid:<n>, and defaults to the frontmost app.
            """,
        subcommands: [Snapshot.self, Click.self, Drag.self, Scroll.self, TypeText.self, Key.self, Menu.self, Wait.self]
    )

    public init() {}

    public struct AppOption: ParsableArguments {
        @Option(help: ArgumentHelp("The app: a bundle ID, a name, or pid:<n>. Default: the frontmost app.", valueName: "app"))
        public var app: String?

        @Flag(help: "Print the result as JSON.")
        public var json = false

        public init() {}
    }

    public struct Snapshot: ParsableCommand {
        public static let configuration = CommandConfiguration(
            abstract: "Print an app's windows as a tree of elements with refs.",
            discussion: """
                Unnamed layout groups are left out, and without --all so are elements outside their scroll area \
                and children past the first 50 of a container, which are counted instead.
                """
        )
        @OptionGroup public var target: AppOption
        @Flag(help: "Show offscreen elements and every child.") public var all = false
        @Option(help: ArgumentHelp("Show only this element's subtree.", valueName: "ref")) public var root: String?
        @Option(help: "Show this many levels (1: windows only).") public var depth: Int?
        public init() {}

        public func validate() throws {
            if let root, RefMap.parse(root) == nil { throw ValidationError("--root takes a ref such as e12") }
            if let depth, depth < 1 { throw ValidationError("--depth must be at least 1") }
        }
    }

    public struct Click: ParsableCommand {
        public static let configuration = CommandConfiguration(
            abstract: "Click an element or a point.",
            discussion: """
                Brings the element's app to the front and clicks the centre of it with a real mouse event, \
                failing if something else is at that point (a sheet over it, or the element scrolled away). \
                --press performs the element's AXPress action instead, with no mouse.
                """
        )
        @OptionGroup public var target: AppOption
        @Argument(help: ArgumentHelp("A ref (e12) or a point in pixels (840,412).", valueName: "ref|x,y")) public var at: String
        @Option(help: ArgumentHelp("Modifiers held down: cmd, shift, opt, ctrl.", valueName: "cmd,shift")) public var mods: String?
        @Flag(help: "Right-click.") public var right = false
        @Flag(help: "Double-click.") public var double = false
        @Flag(help: "Perform AXPress rather than clicking.") public var press = false
        public init() {}

        public func validate() throws {
            let point = try parsePoint(at)
            if press && point != nil { throw ValidationError("--press needs a ref, not a point") }
            if press && (right || double || mods != nil) { throw ValidationError("--press takes no --right, --double or --mods") }
            if right && double { throw ValidationError("--right and --double can't go together") }
            if let mods { _ = try Modifier.parseList(mods) }
        }
    }

    public struct Drag: ParsableCommand {
        public static let configuration = CommandConfiguration(
            abstract: "Drag from one element or point to another.",
            discussion: "Real mouse events: down, a move over about 300 ms, a pause over the target, and up."
        )
        @OptionGroup public var target: AppOption
        @Argument(help: ArgumentHelp("Where the drag starts.", valueName: "ref|x,y")) public var from: String
        @Argument(help: ArgumentHelp("Where it drops.", valueName: "ref|x,y")) public var to: String
        @Option(help: ArgumentHelp("Modifiers held down.", valueName: "cmd,shift")) public var mods: String?
        public init() {}

        public func validate() throws {
            _ = try parsePoint(from)
            _ = try parsePoint(to)
            if let mods { _ = try Modifier.parseList(mods) }
        }
    }

    public struct Scroll: ParsableCommand {
        public static let configuration = CommandConfiguration(
            abstract: "Scroll at an element or point, or bring an element into view.",
            discussion: "hobo ui <vm> scroll e5 down 10 scrolls ten lines; hobo ui <vm> scroll --to e40 scrolls until e40 is visible."
        )
        @OptionGroup public var target: AppOption
        @Argument(help: ArgumentHelp("Where to scroll.", valueName: "ref|x,y")) public var at: String?
        @Argument(help: ArgumentHelp("up, down, left or right.", valueName: "direction")) public var direction: ScrollDirection?
        @Argument(help: "How many lines.") public var lines = 3
        @Option(help: ArgumentHelp("Scroll until this element is in view.", valueName: "ref")) public var to: String?
        public init() {}

        public func validate() throws {
            if let to {
                if RefMap.parse(to) == nil { throw ValidationError("--to takes a ref such as e12") }
                if at != nil { throw ValidationError("--to takes no other arguments") }
            } else {
                guard let at, direction != nil else { throw ValidationError("give where and which way, e.g. scroll e5 down, or --to <ref>") }
                _ = try parsePoint(at)
                if lines < 1 { throw ValidationError("scroll at least one line") }
            }
        }
    }

    public enum ScrollDirection: String, ExpressibleByArgument, Codable, Sendable {
        case up, down, left, right
    }

    public struct TypeText: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "type",
            abstract: "Type text into whatever has focus, or into an element.",
            discussion: "The text goes as Unicode key events, whatever the keyboard layout. --into clicks the element first."
        )
        @OptionGroup public var target: AppOption
        @Argument(help: "The text.") public var text: String
        @Option(help: ArgumentHelp("Click this element first.", valueName: "ref")) public var into: String?
        public init() {}

        public func validate() throws {
            if let into, RefMap.parse(into) == nil { throw ValidationError("--into takes a ref such as e12") }
        }
    }

    public struct Key: ParsableCommand {
        public static let configuration = CommandConfiguration(
            abstract: "Press a key, with modifiers.",
            discussion: "e.g. cmd+k, cmd+shift+z, return, escape, tab, up, f5. The key goes to whatever has focus."
        )
        @OptionGroup public var target: AppOption
        @Argument(help: ArgumentHelp("The key.", valueName: "cmd+k")) public var key: String
        public init() {}

        public func validate() throws { _ = try KeySpec.parse(key) }
    }

    public struct Menu: ParsableCommand {
        public static let configuration = CommandConfiguration(
            abstract: "Choose a menu item, or list a menu.",
            discussion: """
                "File > Save" chooses the item through accessibility, failing if it's disabled. \
                A menu's title alone ("File") lists its items: enabled, checked and their shortcuts.
                """
        )
        @OptionGroup public var target: AppOption
        @Argument(help: ArgumentHelp("Titles from the menu bar down, separated by >.", valueName: "path")) public var path: String
        public init() {}

        public var titles: [String] { MenuPath.parse(path) }

        public func validate() throws {
            if titles.isEmpty { throw ValidationError("give a menu, e.g. \"File > Save\"") }
        }
    }

    public struct Wait: ParsableCommand {
        public static let configuration = CommandConfiguration(
            abstract: "Wait until an element or text is there, or gone.",
            discussion: """
                Checks every 100 ms. With only --app, waits for the app to be running with a window. \
                On a timeout it prints the app's snapshot and exits 1.
                """
        )
        @OptionGroup public var target: AppOption
        @Option(help: ArgumentHelp("Wait for this element.", valueName: "ref")) public var ref: String?
        @Option(help: ArgumentHelp("Wait for an element showing this text (title, value or label).", valueName: "text")) public var text: String?
        @Flag(help: "Wait for it to be gone instead.") public var gone = false
        @Option(help: "Seconds to wait.") public var timeout: Double = 10
        public init() {}

        public func validate() throws {
            if ref != nil && text != nil { throw ValidationError("give --ref or --text, not both") }
            if ref == nil && text == nil && target.app == nil { throw ValidationError("give --ref, --text or --app") }
            if let ref, RefMap.parse(ref) == nil { throw ValidationError("--ref takes a ref such as e12") }
            // `nan` and `inf` parse as Doubles, and would wait forever.
            if !timeout.isFinite || timeout <= 0 { throw ValidationError("--timeout must be a number of seconds more than 0") }
        }
    }
}

/// Where a click, drag or scroll goes: an element by ref, or a point in pixels.
public enum UITarget: Equatable, Sendable {
    case ref(Int)
    case point(PixelPoint)

    public init(parsing text: String) throws(ValidationError) {
        if let ref = RefMap.parse(text) {
            self = .ref(ref)
        } else if let point = try parsePoint(text) {
            self = .point(point)
        } else {
            throw ValidationError("expected a ref such as e12 or a point such as 840,412, not \(text)")
        }
    }
}

/// `840,412` as a point; nil for a ref; throws for anything else.
func parsePoint(_ text: String) throws(ValidationError) -> PixelPoint? {
    if RefMap.parse(text) != nil { return nil }
    let parts = text.split(separator: ",", omittingEmptySubsequences: false)
    guard parts.count == 2, let x = Int(parts[0].trimmingPrefix(" ")), let y = Int(parts[1].trimmingPrefix(" ")) else {
        throw ValidationError("expected a ref such as e12 or a point such as 840,412, not \(text)")
    }
    return PixelPoint(x: x, y: y)
}

public enum MenuPath {
    /// `File > Save As…` → ["File", "Save As…"].
    public static func parse(_ path: String) -> [String] {
        path.components(separatedBy: ">").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Whether a menu's title is the one asked for: exactly, except that … and ... are the same.
    public static func matches(_ title: String, _ wanted: String) -> Bool {
        normalized(title) == normalized(wanted)
    }

    static func normalized(_ title: String) -> String { title.replacingOccurrences(of: "...", with: "…") }
}
