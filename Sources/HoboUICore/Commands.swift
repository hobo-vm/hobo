import Foundation
@_exported import ArgumentParser

/// `hobo ui`'s commands, parsed by both sides: `hobo` checks them on the host (for `--help` and
/// usage errors before reaching the guest), then sends the arguments as they were to `hobo-ui`
/// in the guest, which parses them again and runs them (`UICommand`).
public struct HoboUI: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "hobo ui <vm>",
        abstract: "Drive a guest's apps through accessibility.",
        discussion: """
            snapshot prints an app's elements, each with a ref such as e12 that the other commands act on. \
            A ref keeps its number across snapshots while the element is there; one that has gone fails as stale. \
            Coordinates and frames are screenshot pixels, the same as in a hobo screenshot PNG. \
            Clicks, drags, scrolls and keys are real input events, as a person's would be. \
            --app takes an app ID (a macOS bundle ID, a Linux desktop app ID such as org.gnome.TextEditor, a \
            Windows AUMID or exe name such as notepad), a name or pid:<n>, and defaults to the frontmost app. \
            Shortcuts are the guest's own: cmd+s on macOS, ctrl+s on Linux and Windows.
            """,
        subcommands: [Snapshot.self, At.self, Click.self, Drag.self, Scroll.self, TypeText.self, Key.self, Menu.self, Choose.self, Wait.self]
    )

    public init() {}

    public struct AppOption: ParsableArguments {
        @Option(help: ArgumentHelp("The app: an ID (bundle ID, desktop app ID, AUMID or exe name), a name, or pid:<n>. Default: the frontmost app.", valueName: "app"))
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
                and children past the first 50 of a container, which are counted instead. \
                A macOS app's menu bar isn't shown: menu lists its menus and chooses from them.
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

    public struct At: ParsableCommand {
        public static let configuration = CommandConfiguration(
            abstract: "Show what's at a point: the element there, the elements it's in, and any menu open elsewhere.",
            discussion: """
                For a point read off a screenshot: the element a click there would reach, whichever app it's in, \
                as snapshot lines from its window down, each with its ref. An open menu the point isn't in is named, \
                since a click there would go to closing it.
                """
        )
        @Argument(help: ArgumentHelp("A point in pixels.", valueName: "x,y")) public var point: String
        @Flag(help: "Print the result as JSON.") public var json = false
        public init() {}

        public func validate() throws {
            if try parsePoint(point) == nil { throw ValidationError("give a point such as 840,412, not a ref: snapshot --root \(point) shows an element") }
        }
    }

    public struct Click: ParsableCommand {
        public static let configuration = CommandConfiguration(
            abstract: "Click an element or a point.",
            discussion: """
                Brings the element's app to the front and clicks the centre of it with a real mouse event, \
                failing if another window, sheet, popover or menu is over that point, or the element is scrolled out of its scroll area. \
                It first waits, for up to 2 s, for windows over it to finish animating in or out: a prompt or sheet \
                can be there to accessibility before it's there to click, and gone from it before it stops taking clicks. \
                --text clicks the one element showing exactly that text, e.g. click --text Remove --role menuitem, \
                and fails listing them if several do; with --contains, the one showing it as part of its text, \
                for a label that carries more, such as a photo cell's capture time. --in <ref> looks only inside that \
                element, such as the list when an inspector shows the same name. --press performs the element's default action instead (AXPress, AT-SPI's first action, UI Automation's Invoke), with no mouse.
                """
        )
        @OptionGroup public var target: AppOption
        @Argument(help: ArgumentHelp("A ref (e12) or a point in pixels (840,412).", valueName: "ref|x,y")) public var at: String?
        @Option(help: ArgumentHelp("Click the element whose title, value or label is exactly this, instead of a ref.", valueName: "text")) public var text: String?
        @Option(help: ArgumentHelp("With --text, only elements of this role as snapshot shows it, e.g. button.", valueName: "role")) public var role: String?
        @Flag(help: "With --text, match elements showing it as part of their text, not all of it.") public var contains = false
        @Option(name: .customLong("in"), help: ArgumentHelp("With --text, only elements inside this one.", valueName: "ref")) public var `in`: String?
        @Option(help: ArgumentHelp("Modifiers held down: cmd, shift, opt, ctrl.", valueName: "cmd,shift")) public var mods: String?
        @Flag(help: "Right-click.") public var right = false
        @Flag(help: "Double-click.") public var double = false
        @Flag(help: "Perform the element's default action rather than clicking.") public var press = false
        public init() {}

        public func validate() throws {
            switch (at, text) {
            case (nil, nil): throw ValidationError("give a ref, a point or --text")
            case (.some, .some): throw ValidationError("give a ref or point, or --text, not both")
            case (nil, let text?):
                if text.isEmpty { throw ValidationError("--text needs some text") }
                if let scope = self.in, RefMap.parse(scope) == nil { throw ValidationError("--in takes a ref such as e12") }
            case (let at?, nil):
                if role != nil { throw ValidationError("--role goes with --text") }
                if self.in != nil { throw ValidationError("--in goes with --text") }
                if contains { throw ValidationError("--contains goes with --text") }
                let point = try parsePoint(at)
                if press && point != nil { throw ValidationError("--press needs a ref or --text, not a point") }
            }
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

    /// What a scroll that fails to parse got wrong, when it's a direction given as an option
    /// (`scroll e5 --down 10`): the direction and line count are positional.
    public static func scrollHint(for arguments: [String]) -> String? {
        guard arguments.first == "scroll" else { return nil }
        let rest = Array(arguments.dropFirst())
        guard let index = rest.firstIndex(where: { directionOption($0) != nil }),
              let (direction, attachedLines) = directionOption(rest[index]) else { return nil }
        // --down=10 carries its lines; --down 10 has them in the next argument.
        let lines = attachedLines ?? rest.dropFirst(index + 1).first.flatMap { Int($0) }.map(String.init)
        // The ref or point: the first argument that isn't an option, --app's value, or a number.
        let target = rest.indices.first { i in
            !rest[i].hasPrefix("-") && Int(rest[i]) == nil && (i == 0 || rest[i - 1] != "--app")
        }.map { rest[$0] } ?? "<ref|x,y>"
        let example = (["scroll", target, direction] + [lines].compactMap { $0 }).joined(separator: " ")
        return "the direction and line count are arguments after the ref or point, not options: \(example)"
    }

    /// What a command given `--ref e12` got wrong: to the commands whose first argument is a ref
    /// (`click e12`), a ref is an argument. Others take one by an option of their own, or none.
    public static func refOptionHint(for arguments: [String]) -> String? {
        let names = HoboUI.configuration.subcommands.map { $0._commandName }
        let takingARef = [Click._commandName, Scroll._commandName, Drag._commandName]
        guard let command = arguments.first(where: names.contains), takingARef.contains(command),
              let index = arguments.firstIndex(where: { $0 == "--ref" || $0.hasPrefix("--ref=") }) else { return nil }
        let given = arguments[index].split(separator: "=", maxSplits: 1).dropFirst().first.map(String.init)
            ?? arguments.dropFirst(index + 1).first
        let ref = given.flatMap { RefMap.parse($0) != nil ? $0 : nil } ?? "e12"
        return "a ref is an argument, not an option: \(command) \(ref)"
    }

    /// What an `at` given `--app` got wrong: it answers for whichever app is at the point.
    public static func atAppHint(for arguments: [String]) -> String? {
        guard arguments.first == At._commandName, arguments.contains(where: { $0 == "--app" || $0.hasPrefix("--app=") }) else { return nil }
        return "at takes no --app: it shows what's at the point, whichever app that's in"
    }

    /// The direction and any `=lines` of an argument like `--down` or `--down=10`.
    private static func directionOption(_ argument: String) -> (direction: String, lines: String?)? {
        guard argument.hasPrefix("--") else { return nil }
        let parts = argument.dropFirst(2).split(separator: "=", maxSplits: 1).map(String.init)
        guard let name = parts.first, ScrollDirection(rawValue: name) != nil else { return nil }
        return (name, parts.count > 1 ? parts[1] : nil)
    }

    public struct TypeText: ParsableCommand {
        public static let configuration = CommandConfiguration(
            commandName: "type",
            abstract: "Type text into whatever has focus, or into an element.",
            discussion: """
                The text goes as Unicode key events, whatever the keyboard layout, and is added where the cursor is. \
                --into clicks the element first. --replace selects all (cmd+a) before typing, so the text takes the \
                place of what the field had; with "" it empties the field.
                """
        )
        @OptionGroup public var target: AppOption
        @Argument(help: "The text.") public var text: String
        @Option(help: ArgumentHelp("Click this element first.", valueName: "ref")) public var into: String?
        @Flag(help: "Replace what's there rather than add to it.") public var replace = false
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
                A menu's title alone ("File") lists its items: enabled, checked and their shortcuts. \
                Titles are as the open menu shows them ("Undo Typing", not "Undo"): on macOS the app comes forward and each menu on the way \
                is opened and closed again first, which is when an app brings its items up to date.
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

    public struct Choose: ParsableCommand {
        public static let configuration = CommandConfiguration(
            abstract: "Choose a file or folder in an app's open or save panel.",
            discussion: """
                With the panel showing, goes to the path through its Go to Folder sheet, then clicks its Open or Save \
                button, failing if the panel is still there afterwards. In a save panel the path is the file to save. \
                (A path typed into a panel loses the character after its first /, while that sheet opens.) \
                On Linux it goes through the file chooser's location bar (Ctrl-L), and in GNOME's save dialog \
                names the file in its File Name box. On Windows it types the path into the dialog's File name box.
                """
        )
        @OptionGroup public var target: AppOption
        @Argument(help: ArgumentHelp("The file or folder in the guest, from / or ~, or a drive (C:\\…) on Windows.", valueName: "path")) public var path: String
        public init() {}

        public func validate() throws {
            if !path.hasPrefix("/") && !path.hasPrefix("~") && path.wholeMatch(of: /[A-Za-z]:[\\\/].*/) == nil {
                throw ValidationError("give a path in the guest from / or ~, or from a drive on Windows, not \(path)")
            }
        }
    }

    public struct Wait: ParsableCommand {
        public static let configuration = CommandConfiguration(
            abstract: "Wait until an element or text is there, or gone.",
            discussion: """
                Checks every 100 ms. With only --app, waits for the app to be running with a window. \
                --text matches part of what an element shows, as click --text --contains does: \
                wait --text "3 photos" finds "3 photos, 1 selected"; --role keeps it to elements of that role, \
                as in wait --text Move --role button. On a timeout it prints the app's snapshot and exits 1; a --gone wait first names the element still there, \
                since a view that's hidden can still be an accessibility element.
                """
        )
        @OptionGroup public var target: AppOption
        @Option(help: ArgumentHelp("Wait for this element.", valueName: "ref")) public var ref: String?
        @Option(help: ArgumentHelp("Wait for an element showing this text, whole or as part of its title, value or label.", valueName: "text")) public var text: String?
        @Option(help: ArgumentHelp("With --text, only elements of this role as snapshot shows it, e.g. button.", valueName: "role")) public var role: String?
        @Flag(help: "Wait for it to be gone instead.") public var gone = false
        @Option(help: "Seconds to wait.") public var timeout: Double = 10
        public init() {}

        public func validate() throws {
            if ref != nil && text != nil { throw ValidationError("give --ref or --text, not both") }
            if ref == nil && text == nil && target.app == nil { throw ValidationError("give --ref, --text or --app") }
            if let ref, RefMap.parse(ref) == nil { throw ValidationError("--ref takes a ref such as e12") }
            // Empty text is part of everything an element shows, so the wait would say nothing.
            if text?.isEmpty == true { throw ValidationError("--text needs some text") }
            if role != nil && text == nil { throw ValidationError("--role goes with --text") }
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
    // `click "$ref"` with the variable unset: a script's search of a snapshot found nothing.
    if text.trimmingCharacters(in: .whitespaces).isEmpty {
        throw ValidationError("the ref or point is empty: if it came from a snapshot, the search for it found nothing")
    }
    let parts = text.split(separator: ",", omittingEmptySubsequences: false)
    guard parts.count == 2, let x = Int(parts[0].trimmingPrefix(" ")), let y = Int(parts[1].trimmingPrefix(" ")) else {
        // `click 840 412`: the point split in two at a space.
        if Int(text) != nil { throw ValidationError("a point is one argument, x,y with a comma: \(text),<y>, not \(text) <y>") }
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
