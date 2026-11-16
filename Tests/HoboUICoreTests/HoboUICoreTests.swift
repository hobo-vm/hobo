import CoreGraphics
import Foundation
import Testing
@testable import HoboUICore

/// A synthetic element: `hobo-ui`'s logic is tested on these, never on the host's live UI.
struct Fake: AccessibleElement {
    var a: ElementAttributes
    var kids: [Fake] = []

    init(_ role: String, _ title: String? = nil, id: String? = nil, value: String? = nil, frame: CGRect? = nil, _ kids: [Fake] = []) {
        a = ElementAttributes(role: role, title: title, identifier: id, value: value, frame: frame)
        self.kids = kids
    }

    init(_ role: String, _ kids: [Fake]) { self.init(role, nil, kids) }

    func attributes() -> ElementAttributes { a }
    func children() -> [Fake] { kids }
}

func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }

@Suite struct LocatorTests {
    let app = Fake("AXApplication", "Demo", [
        Fake("AXMenuBar"),
        Fake("AXWindow", "Main", [
            Fake("AXButton", "OK"),
            Fake("AXButton"),
            Fake("AXButton"),
            Fake("AXButton", "OK"),
        ]),
    ])

    @Test func indexesCountOnlySiblingsWithTheSameRoleAndName() {
        let steps = Locator.steps(for: app.kids[1].kids.map(\.a))
        #expect(steps.map(\.index) == [0, 0, 1, 1])
        #expect(steps.map(\.name) == ["OK", nil, nil, "OK"])
    }

    @Test func resolvesAPathItWalked() {
        let locator = Locator([.init(role: "window", name: "Main", index: 0), .init(role: "button", name: nil, index: 1)])
        #expect(locator.resolve(from: app)?.a == app.kids[1].kids[2].a)
    }

    @Test func aNamedElementSurvivesASiblingInsertedBeforeIt() {
        let locator = Locator([.init(role: "window", name: "Main", index: 0), .init(role: "button", name: "OK", index: 1)])
        var changed = app
        changed.kids[1].kids.insert(Fake("AXButton", "Cancel"), at: 0)
        #expect(locator.resolve(from: changed)?.a.title == "OK")
        #expect(locator.resolve(from: changed) != nil)
    }

    @Test func isStaleOnceTheElementIsRenamed() {
        let locator = Locator([.init(role: "window", name: "Main", index: 0), .init(role: "button", name: "OK", index: 1)])
        var renamed = app
        renamed.kids[1].kids[3] = Fake("AXButton", "Done")
        #expect(locator.resolve(from: renamed) == nil)
    }

    @Test func followsARenamedAncestorOnlyWhenItIsTheOnlyOneOfItsRole() {
        let locator = Locator([.init(role: "window", name: "Main", index: 0), .init(role: "button", name: "OK", index: 1)])
        var retitled = app
        retitled.kids[1].a.title = "Hello - Text Editor"
        #expect(locator.resolve(from: retitled)?.a == app.kids[1].kids[3].a)
        var twoWindows = retitled
        twoWindows.kids.append(Fake("AXWindow", "Second", retitled.kids[1].kids))
        #expect(locator.resolve(from: twoWindows) == nil, "which window is ambiguous")
        let window = Locator([.init(role: "window", name: "Main", index: 0)])
        #expect(window.resolve(from: retitled) == nil, "a renamed element itself is stale")
    }

    @Test func namesByIdentifierBeforeTitleAndNeverByValue() {
        #expect(ElementAttributes(role: "AXButton", title: "Save", identifier: "save").name == "save")
        #expect(ElementAttributes(role: "AXStaticText", value: "14 photos").name == nil)
    }
}

@Suite struct RefMapTests {
    @Test func keepsANumberPerLocatorAndNeverReusesOne() {
        var map = RefMap()
        let a = Locator([.init(role: "button", name: "A", index: 0)])
        let b = Locator([.init(role: "button", name: "B", index: 0)])
        #expect(map.ref(for: a) == 1)
        #expect(map.ref(for: b) == 2)
        #expect(map.ref(for: a) == 1)
        #expect(map.locator(for: 2) == b)
    }

    @Test func keepsARefThroughARenamedAncestorOnlyWhenItWasTheOnlyOneOfItsRole() {
        func path(_ window: String, sole: Bool) -> Locator {
            Locator([.init(role: "window", name: window, index: 0, soleOfRole: sole), .init(role: "textbox", name: "view", index: 0)])
        }
        var map = RefMap()
        #expect(map.ref(for: path("Untitled", sole: true)) == 1)
        #expect(map.ref(for: path("Hello - Text Editor", sole: true)) == 1)
        #expect(map.locator(for: 1) == path("Hello - Text Editor", sole: true))
        // Alongside another window, a window's name is what tells them apart.
        #expect(map.ref(for: path("Second", sole: false)) == 2)
    }

    /// Each hobo ui command loads the map afresh, so the rename is followed from the file too.
    @Test func keepsARefThroughARenameAfterALoad() throws {
        func path(_ window: String) -> Locator {
            Locator([.init(role: "window", name: window, index: 0, soleOfRole: true), .init(role: "textbox", name: "view", index: 0)])
        }
        var map = RefMap()
        #expect(map.ref(for: path("Untitled")) == 1)
        var loaded = try JSONDecoder().decode(RefMap.self, from: JSONEncoder().encode(map))
        #expect(loaded.ref(for: path("Hello - Text Editor")) == 1)
    }

    @Test func survivesTheFile() throws {
        var map = RefMap()
        _ = map.ref(for: Locator([.init(role: "window", name: "W", index: 0)]))
        let directory = FileManager.default.temporaryDirectory.appending(path: "hobo-ui-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RefStore(directory: directory)
        try store.save(map, for: "com.example.App")
        var loaded = store.load("com.example.App")
        #expect(loaded == map)
        #expect(loaded.ref(for: Locator([.init(role: "button", name: nil, index: 0)])) == 2)
        #expect(store.load("com.example.Other") == RefMap())
    }

    // Runs against one app at once mustn't each number their own copy, giving a ref two meanings.
    @Test func concurrentUpdatesNeverShareANumber() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "hobo-ui-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RefStore(directory: directory)
        DispatchQueue.concurrentPerform(iterations: 16) { index in
            _ = try? store.update("com.example.App") { $0.ref(for: Locator([.init(role: "button", name: "\(index)", index: 0)])) }
        }
        let refs = store.load("com.example.App").entries.map(\.ref)
        #expect(refs.sorted() == Array(1...16))
    }

    @Test func parsesRefs() {
        #expect(RefMap.parse("e12") == 12)
        #expect(RefMap.parse("e0") == nil)
        #expect(RefMap.parse("12") == nil)
        #expect(RefMap.parse("ex") == nil)
    }
}

@Suite struct SnapshotTests {
    func snapshot(_ app: Fake, _ options: SnapshotOptions = SnapshotOptions(), refs: inout RefMap) -> AppSnapshot {
        let elements = SnapshotBuilder(options: options, scale: PixelScale(1)).build(root: app, locator: Locator(), isApp: true, refs: &refs)
        return AppSnapshot(app: AppIdentity(name: "Demo", id: "com.example.Demo", pid: 7), scale: 1, elements: elements)
    }

    @Test func foldsUnnamedGroupsAndLeavesOutTheMenuBar() {
        var refs = RefMap()
        let app = Fake("AXApplication", [
            Fake("AXMenuBar", [Fake("AXMenuBarItem", "File")]),
            Fake("AXWindow", "Main", frame: rect(0, 25, 800, 600), [
                Fake("AXGroup", [Fake("AXGroup", [Fake("AXButton", "Save", id: "save", frame: rect(10, 40, 80, 28))])]),
                Fake("AXStaticText", value: "14 photos"),
            ]),
        ])
        #expect(snapshot(app, refs: &refs).text == """
            app Demo (com.example.Demo) pid 7
            - window "Main" [e1] (0,25 800×600)
              - button "Save" [e2] #save (10,40 80×28)
              - text [e3] = "14 photos"
            """)
    }

    @Test func keepsRefsAcrossSnapshotsAndNumbersNewElementsOnward() {
        var refs = RefMap()
        var app = Fake("AXApplication", [Fake("AXWindow", "Main", [Fake("AXButton", "A"), Fake("AXButton", "B")])])
        _ = snapshot(app, refs: &refs)
        app.kids[0].kids.insert(Fake("AXButton", "New"), at: 0)
        let second = snapshot(app, refs: &refs)
        #expect(second.elements[0].children.map(\.ref) == ["e4", "e2", "e3"])
    }

    @Test func countsOffscreenChildrenAndThoseOverTheLimit() {
        var refs = RefMap()
        let rows = (0..<200).map { Fake("AXRow", "Row \($0)", frame: rect(0, Double($0) * 20, 100, 20)) }
        let app = Fake("AXApplication", [Fake("AXWindow", "Main", [Fake("AXScrollArea", "List", frame: rect(0, 0, 100, 1200), rows)])])
        let area = snapshot(app, refs: &refs).elements[0].children[0]
        #expect(area.children.count == 50)
        #expect(area.more == 10)
        #expect(area.offscreen == 140)
        let all = snapshot(app, SnapshotOptions(all: true), refs: &refs).elements[0].children[0]
        #expect(all.children.count == 200)
        #expect(all.more == nil && all.offscreen == nil)
    }

    // `snapshot --root e2`: the element itself heads the tree, under the ref it already had.
    @Test func aRootShowsItsOwnSubtreeUnderItsRef() throws {
        var refs = RefMap()
        let app = Fake("AXApplication", [Fake("AXWindow", "Main", [Fake("AXGroup", "Panel", [Fake("AXButton", "A")]), Fake("AXButton", "B")])])
        _ = snapshot(app, refs: &refs)
        let locator = try #require(refs.locator(for: 2))
        let panel = try #require(locator.resolve(from: app))
        let shown = SnapshotBuilder(options: SnapshotOptions(), scale: PixelScale(1)).build(root: panel, locator: locator, isApp: false, refs: &refs)
        #expect(shown.map(\.ref) == ["e2"])
        #expect(shown[0].children.map(\.ref) == ["e3"])
    }

    // A scroll area inside another shows only what both let through.
    @Test func nestedScrollAreasClipToBoth() {
        var refs = RefMap()
        let rows = (0..<10).map { Fake("AXRow", "Row \($0)", frame: rect(0, Double($0) * 20, 100, 20)) }
        let app = Fake("AXApplication", [Fake("AXWindow", "Main", [
            Fake("AXScrollArea", "Outer", frame: rect(0, 0, 100, 60), [Fake("AXScrollArea", "Inner", frame: rect(0, 0, 100, 200), rows)]),
        ])])
        let inner = snapshot(app, refs: &refs).elements[0].children[0].children[0]
        #expect(inner.children.map(\.name) == ["Row 0", "Row 1", "Row 2"])
        #expect(inner.offscreen == 7)
    }

    @Test func depthOneShowsWindowsOnly() {
        var refs = RefMap()
        let app = Fake("AXApplication", [Fake("AXWindow", "Main", [Fake("AXButton", "A")])])
        let shown = snapshot(app, SnapshotOptions(depth: 1), refs: &refs)
        #expect(shown.elements[0].children.isEmpty)
        #expect(shown.elements[0].deeper == 1)
        #expect(shown.text.hasSuffix("  … 1 deeper"))
    }

    @Test func showsStatesAndQuotesValuesOnOneLine() {
        var node = SnapshotNode(
            ref: 5, attributes: ElementAttributes(role: "AXCheckBox", title: "Wrap", value: "1", enabled: false), scale: PixelScale(1)
        )
        #expect(AppSnapshot.line(node) == #"checkbox "Wrap" [e5] disabled checked"#)
        node = SnapshotNode(ref: 6, attributes: ElementAttributes(role: "AXTextArea", value: "a \"b\"\nc"), scale: PixelScale(1))
        #expect(AppSnapshot.line(node) == #"textbox [e6] = "a \"b\"\nc""#)
        node = SnapshotNode(ref: 7, attributes: ElementAttributes(role: "AXTextArea", value: "a\r\nb\rc"), scale: PixelScale(1))
        #expect(AppSnapshot.line(node) == #"textbox [e7] = "a\r\nb\rc""#)
        #expect(AppSnapshot.quoted(String(repeating: "x", count: 81)) == "\"" + String(repeating: "x", count: 80) + "…\"")
    }

    @Test func leavesOutWhatSaysNothing() {
        // AppKit's made-up identifiers, and zero-size elements such as a scroll bar's hidden arrows.
        #expect(ElementAttributes(role: "AXScrollArea", identifier: "_NS:8").identifier == nil)
        var refs = RefMap()
        let app = Fake("AXApplication", [Fake("AXWindow", "Main", [Fake("AXButton", "Shown"), Fake("AXButton", "Hidden", frame: .zero)])])
        let window = snapshot(app, refs: &refs).elements[0]
        #expect(window.children.map(\.name) == ["Shown"])
        #expect(window.offscreen == 1)
    }

    @Test func showsAnUnnamedElementBySubrole() {
        let close = ElementAttributes(role: "AXButton", subrole: "AXCloseButton")
        #expect(SnapshotNode(ref: 1, attributes: close, scale: PixelScale(1)).role == "closebutton")
        let named = ElementAttributes(role: "AXButton", subrole: "AXCloseButton", title: "Close")
        #expect(SnapshotNode(ref: 1, attributes: named, scale: PixelScale(1)).role == "button")
    }

    @Test func framesAreScreenshotPixels() {
        let scale = PixelScale(2)
        #expect(scale.pixels(rect(10, 20, 30, 40)) == PixelRect(x: 20, y: 40, width: 60, height: 80))
        #expect(scale.points(PixelPoint(x: 840, y: 412)) == CGPoint(x: 420, y: 206))
        var refs = RefMap()
        let app = Fake("AXApplication", [Fake("AXWindow", "Main")])
        let shown = SnapshotBuilder(options: SnapshotOptions(), scale: scale).build(root: app, locator: Locator(), isApp: true, refs: &refs)
        #expect(AppSnapshot(app: AppIdentity(name: "Demo", id: nil, pid: 7), scale: 2, elements: shown).text == """
            app Demo pid 7
            scale 2
            - window "Main" [e1]
            """)
    }

    @Test func findsTextAnywhere() {
        let app = Fake("AXApplication", [Fake("AXWindow", "Main", [Fake("AXGroup", [Fake("AXStaticText", value: "14 photos")])])])
        let found = allElements(under: app, locator: Locator()).filter { $0.1.contains("photos") }
        #expect(found.map(\.2.description) == ["window:Main[0]/group[0]/text[0]"])
    }
}

@Suite struct ShowingTextTests {
    let app = Fake("AXApplication", [
        Fake("AXMenuBar", [Fake("AXMenuBarItem", "Remove")]),
        Fake("AXWindow", "Main", [
            Fake("AXButton", "Remove"),
            Fake("AXButton", "Remove All"),
            Fake("AXMenu", [Fake("AXMenuItem", "Remove")]),
            Fake("AXCell", "NAS", [Fake("AXStaticText", value: "NAS")]),
            Fake("AXButton", "Save…"),
            Fake("AXCheckBox", "bold", value: "1"),
            Fake("AXStaticText", value: "1"),
        ]),
    ])

    func found(_ text: String, role: String? = nil) -> [String] {
        elements(showing: text, role: role, under: app).map(\.2.description)
    }

    @Test func saysWhatTheMenuBarShows() {
        let app = Fake("AXApplication", [
            Fake("AXMenuBar", [Fake("AXMenuBarItem", "Edit", [Fake("AXMenu", [Fake("AXMenuItem", "Undo Typing")])])]),
            Fake("AXWindow", "Main", [Fake("AXButton", "Remove")]),
        ])
        #expect(menuBarShows("Edit", under: app))
        #expect(menuBarShows("Undo Typing", under: app))
        #expect(!menuBarShows("Undo", under: app))
        #expect(menuBarShows("Undo", partial: true, under: app))
        #expect(!menuBarShows("Remove", under: app))
    }

    @Test func matchesTheWholeTextOutsideTheMenuBar() {
        #expect(found("Remove") == ["window:Main[0]/button:Remove[0]", "window:Main[0]/menu[0]/menuitem:Remove[0]"])
        #expect(found("Remov").isEmpty)
        #expect(found("Save...") == ["window:Main[0]/button:Save…[0]"])
    }

    @Test func containsMatchesPartOfTheTextOnlyOncePerElement() {
        func partly(_ text: String) -> [String] { elements(showing: text, partial: true, role: nil, under: app).map(\.2.description) }
        #expect(partly("Remove A") == ["window:Main[0]/button:Remove All[0]"])
        #expect(partly("Remov").count == 3)
        // The cell, not its text as well.
        #expect(partly("NA") == ["window:Main[0]/cell:NAS[0]"])
        #expect(elements(showing: "Remov", partial: true, role: "button", under: app).count == 2)
    }

    @Test func includeKeepsOnlyTheElementsItAccepts() {
        let inMenu = elements(showing: "Remove", role: nil, under: app) { $0.attributes().role == "menuitem" }
        #expect(inMenu.map(\.2.description) == ["window:Main[0]/menu[0]/menuitem:Remove[0]"])
    }

    @Test func aCheckboxStateIsNotTextItShows() {
        #expect(found("1") == ["window:Main[0]/text[0]"])
    }

    /// `wait --text` (part of the text) looks where `click --text` (all of it) does, at the same text.
    @Test func waitingForTextAgreesWithClickingIt() {
        func waited(_ text: String) -> [String] {
            searchableElements(under: app).filter { $0.1.contains(text) }.map(\.2.description)
        }
        #expect(waited("Save...") == found("Save..."))
        #expect(waited("1") == found("1"))
        #expect(waited("Remov") == [
            "window:Main[0]/button:Remove[0]", "window:Main[0]/button:Remove All[0]", "window:Main[0]/menu[0]/menuitem:Remove[0]",
        ])
    }

    @Test func aRoleNarrowsToWhatSnapshotCallsIt() {
        #expect(found("Remove", role: "menuitem") == ["window:Main[0]/menu[0]/menuitem:Remove[0]"])
        #expect(found("Remove", role: "MenuItem").count == 1)
        #expect(found("Remove", role: "checkbox").isEmpty)
    }

    @Test func anElementInsideAnotherMatchIsLeftToTheOuterOne() {
        #expect(found("NAS") == ["window:Main[0]/cell:NAS[0]"])
        #expect(found("NAS", role: "text") == ["window:Main[0]/cell:NAS[0]/text[0]"])
    }

    @Test func matchesInOneFrameAreOneMatch() {
        let item = rect(10, 40, 120, 22)
        let menu = Fake("AXApplication", [Fake("AXWindow", "Main", [
            Fake("AXMenu", [Fake("AXMenuItem", "All Photos", frame: item)]),
            Fake("AXMenu", [Fake("AXMenuItem", "All Photos", frame: item), Fake("AXMenuItem", "All Photos", frame: rect(10, 62, 120, 22))]),
            Fake("AXButton", "All Photos", frame: item),
        ])])
        let found = elements(showing: "All Photos", role: nil, under: menu).map(\.2.description)
        #expect(found == [
            "window:Main[0]/menu[0]/menuitem:All Photos[0]",
            "window:Main[0]/menu[1]/menuitem:All Photos[1]",
            "window:Main[0]/button:All Photos[0]",
        ])
    }
}

@Suite struct PathTests {
    let save = Fake("AXButton", "Save", frame: rect(10, 40, 80, 28))
    var group: Fake { Fake("AXGroup", [Fake("AXButton", "Cancel"), save]) }
    var window: Fake { Fake("AXWindow", "Main", frame: rect(0, 25, 800, 600), [Fake("AXButton", "Save"), group]) }
    var app: Fake { Fake("AXApplication", "Demo", [window]) }

    func shown(_ lineage: [Fake], refs: inout RefMap) -> String {
        let nodes = path(to: lineage, same: { $0.a == $1.a && $0.kids.count == $1.kids.count }, scale: PixelScale(1), refs: &refs)
        return AppSnapshot(app: AppIdentity(name: "Demo", id: nil, pid: 7), scale: 1, elements: nodes).text
    }

    @Test func showsTheWayFromTheWindowWithRefsThatResolve() throws {
        var refs = RefMap()
        #expect(shown([save, group, window, app], refs: &refs) == """
            app Demo pid 7
            - window "Main" [e1] (0,25 800×600)
              - button "Save" [e2] (10,40 80×28)
            """)
        // e2 is the Save inside the folded group, not the window's own Save.
        let locator = try #require(refs.locator(for: 2))
        #expect(locator.description == "window:Main[0]/group[0]/button:Save[0]")
        #expect(locator.resolve(from: app)?.a == save.a)
    }

    @Test func anElementItsParentDoesntListHasNoRef() {
        var refs = RefMap()
        let stray = Fake("AXButton", "Stray")
        #expect(shown([stray, window, app], refs: &refs) == """
            app Demo pid 7
            - window "Main" [e1] (0,25 800×600)
              - button "Stray"
            """)
    }

    @Test func anUnnamedGroupAtThePointIsShown() {
        var refs = RefMap()
        #expect(shown([group, window, app], refs: &refs).hasSuffix("\n  - group [e2]"))
    }
}

@Suite struct KeyTests {
    @Test func parsesModifiersAndNamedKeys() throws {
        #expect(try KeySpec.parse("cmd+shift+k") == KeySpec(modifiers: [.command, .shift], key: "k"))
        #expect(try KeySpec.parse("cmd+shift+k").keyCode == 0x28)
        #expect(try KeySpec.parse("return") == KeySpec(modifiers: [], key: "return"))
        #expect(try KeySpec.parse("enter").keyCode == 0x24)
        #expect(try KeySpec.parse("ctrl+F2") == KeySpec(modifiers: [.control], key: "f2"))
        #expect(try KeySpec.parse("cmd++") == KeySpec(modifiers: [.command], key: "="))
        #expect(try KeySpec.parse("cmd+minus") == KeySpec(modifiers: [.command], key: "-"))
        #expect(try KeySpec.parse("cmd+plus") == KeySpec.parse("cmd++"))
        #expect(try KeySpec.parse("cmd+minus") == KeySpec.parse("cmd+-"))
        #expect(try KeySpec.parse("cmd+Comma") == KeySpec.parse("cmd+,"))
    }

    @Test func rejectsWhatItDoesNotKnow() {
        func message(_ parse: () throws -> Any) -> String? {
            do { _ = try parse() } catch { return (error as? ValidationError)?.message }
            return nil
        }
        #expect(message { try KeySpec.parse("hyper+k") } == KeyError.unknownModifier("hyper").description)
        #expect(message { try KeySpec.parse("cmd+blah") } == KeyError.unknownKey("blah").description)
        #expect(message { try KeySpec.parse("cmd+") } == KeyError.noKey("cmd+").description)
        #expect(message { try Modifier.parseList("cmd,meta") } == KeyError.unknownModifier("meta").description)
    }
}

@Suite struct CommandTests {
    @Test func parsesEachCommand() throws {
        #expect(try HoboUI.parseAsRoot(["click", "e12", "--mods", "cmd,shift"]) is HoboUI.Click)
        #expect(try HoboUI.parseAsRoot(["click", "--text", "Remove", "--role", "menuitem", "--press"]) is HoboUI.Click)
        #expect(try HoboUI.parseAsRoot(["click", "--text", "IMG_0001", "--contains"]) is HoboUI.Click)
        #expect((try HoboUI.parseAsRoot(["click", "--text", "IMG_0001.jpg", "--in", "e30"]) as? HoboUI.Click)?.in == "e30")
        #expect(try HoboUI.parseAsRoot(["scroll", "e5", "down", "10"]) is HoboUI.Scroll)
        #expect(try HoboUI.parseAsRoot(["scroll", "--to", "e40"]) is HoboUI.Scroll)
        #expect(try HoboUI.parseAsRoot(["menu", "File > Save"]) is HoboUI.Menu)
        #expect(try HoboUI.parseAsRoot(["at", "840,412", "--json"]) is HoboUI.At)
        #expect(try HoboUI.parseAsRoot(["wait", "--app", "TextEdit"]) is HoboUI.Wait)
        #expect(try HoboUI.parseAsRoot(["choose", "~/Pictures", "--app", "Candela"]) is HoboUI.Choose)
        #expect(try HoboUI.parseAsRoot(["choose", #"C:\Users\hobo\a.txt"#, "--app", "notepad"]) is HoboUI.Choose)
        #expect(try HoboUI.parseAsRoot(["type", "hello", "--into", "e3"]) is HoboUI.TypeText)
        #expect((try HoboUI.parseAsRoot(["type", "", "--into", "e3", "--replace"]) as? HoboUI.TypeText)?.replace == true)
    }

    @Test(arguments: [
        ["click", "nowhere"], ["click", "1,2", "--press"], ["at", "e12"], ["at"], ["click"], ["click", "e1", "--text", "OK"], ["click", "e1", "--role", "button"], ["click", "e1", "--contains"], ["click", "e1", "--in", "e2"], ["click", "--text", "OK", "--in", "list"],
        ["click", "--text", ""], ["wait", "--text", ""], ["scroll", "e5"], ["wait"], ["wait", "--ref", "e1", "--text", "x"],
        ["key", "cmd+blah"], ["choose", "Pictures/a.png"], ["snapshot", "--depth", "0"], ["menu", " > "],
        ["wait", "--app", "X", "--timeout", "0"], ["wait", "--app", "X", "--timeout", "nan"], ["wait", "--app", "X", "--timeout", "inf"],
    ])
    func rejectsUsageErrors(_ arguments: [String]) {
        #expect(throws: (any Error).self) { try HoboUI.parseAsRoot(arguments) }
    }

    // `click "$ref"` with nothing found says so, rather than ending on an empty "not ".
    @Test func saysARefIsEmpty() {
        for arguments in [["click", ""], ["drag", " ", "1,2"], ["scroll", "", "down"]] {
            let error = #expect(throws: (any Error).self) { try HoboUI.parseAsRoot(arguments) }
            #expect(error.map(HoboUI.message(for:))?.contains("the ref or point is empty") == true, "\(arguments)")
        }
    }

    // A direction given as an option is put right with the positional form.
    @Test func hintsAtAScrollDirectionGivenAsAnOption() {
        let hint = { HoboUI.scrollHint(for: $0)?.components(separatedBy: ": ").last }
        #expect(hint(["scroll", "e99", "--down", "600"]) == "scroll e99 down 600")
        #expect(hint(["scroll", "--app", "Candela", "e99", "--down=6"]) == "scroll e99 down 6")
        #expect(hint(["scroll", "840,412", "--left"]) == "scroll 840,412 left")
        #expect(hint(["scroll", "--up", "3"]) == "scroll <ref|x,y> up 3")
        #expect(HoboUI.scrollHint(for: ["scroll", "e99", "sideways"]) == nil)
        #expect(HoboUI.scrollHint(for: ["click", "--down"]) == nil)
    }

    // A ref given as --ref is put right with the positional form, only for commands that take one.
    @Test func hintsAtARefGivenAsAnOption() {
        let hint = { HoboUI.refOptionHint(for: $0)?.components(separatedBy: ": ").last }
        #expect(hint(["click", "--ref", "e47"]) == "click e47")
        #expect(hint(["--app", "Photos", "click", "--ref=e47"]) == "click e47")
        #expect(hint(["click", "--ref"]) == "click e12")
        #expect(HoboUI.refOptionHint(for: ["wait", "--ref", "e47", "--gone"]) == nil)
        #expect(HoboUI.refOptionHint(for: ["type", "--ref", "e47", "hi"]) == nil)
        #expect(HoboUI.refOptionHint(for: ["snapshot", "--ref", "e47"]) == nil)
        #expect(HoboUI.refOptionHint(for: ["click", "e47"]) == nil)
    }

    @Test(arguments: [["click", "840", "412"], ["drag", "840", "412", "e2"]])
    func aPointSplitAtASpaceIsToldToUseAComma(_ arguments: [String]) {
        do {
            _ = try HoboUI.parseAsRoot(arguments)
            Issue.record("parsed \(arguments)")
        } catch {
            let message = HoboUI.fullMessage(for: error)
            #expect(message.contains("x,y with a comma: 840,<y>"), "\(message)")
        }
    }

    /// What `hobo ui` prints for a usage error: the failing command's usage, not the root's.
    @Test(arguments: [
        (["key", "cmd+blah"], "key"), (["click"], "click"), (["choose", "Pictures/a.png"], "choose"),
        (["click", "e1", "--mods", "foo"], "click"), (["drag", "e1", "e2", "--mods", "foo"], "drag"),
    ])
    func aUsageErrorComesWithItsCommandsUsage(_ arguments: [String], _ command: String) {
        do {
            _ = try HoboUI.parseAsRoot(arguments)
            Issue.record("parsed \(arguments)")
        } catch {
            let message = HoboUI.fullMessage(for: error)
            #expect(message.contains("Usage:") && message.contains(" \(command) "), "\(message)")
        }
    }

    @Test func targetsAreRefsOrPoints() throws {
        #expect(try UITarget(parsing: "e3") == .ref(3))
        #expect(try UITarget(parsing: "840,412") == .point(PixelPoint(x: 840, y: 412)))
    }

    @Test func menuTitlesMatchWithEitherEllipsis() {
        #expect(MenuPath.parse("File > Save As…") == ["File", "Save As…"])
        #expect(MenuPath.matches("Save As…", "Save As..."))
        #expect(!MenuPath.matches("Save", "Save As…"))
    }
}

@Suite struct ScrollVisibilityTests {
    let outer = rect(0, 0, 400, 300)

    @Test func aPointInsideEveryAreaIsInView() {
        #expect(ScrollVisibility.obstruction(of: CGPoint(x: 50, y: 50), areas: []) == nil)
        #expect(ScrollVisibility.obstruction(of: CGPoint(x: 50, y: 50), areas: [outer, rect(0, 0, 200, 100)]) == nil)
    }

    @Test func pointsOutsideAnAreaScrollTowardThem() {
        let below = ScrollVisibility.obstruction(of: CGPoint(x: 50, y: 350), areas: [outer])
        #expect(below == .init(area: 0, visible: outer, direction: .down))
        #expect(ScrollVisibility.obstruction(of: CGPoint(x: 50, y: -10), areas: [outer])?.direction == .up)
        #expect(ScrollVisibility.obstruction(of: CGPoint(x: 450, y: 50), areas: [outer])?.direction == .right)
        #expect(ScrollVisibility.obstruction(of: CGPoint(x: -10, y: 50), areas: [outer])?.direction == .left)
    }

    // A horizontal list in a vertical scroll view, the list's row far down: the point is inside
    // the list's own frame, but the scroll view around it has to bring it in.
    @Test func anOuterAreaComesFirst() {
        let list = rect(0, 500, 2000, 100)
        let obstruction = ScrollVisibility.obstruction(of: CGPoint(x: 50, y: 550), areas: [outer, list])
        #expect(obstruction?.area == 0)
        #expect(obstruction?.direction == .down)
    }

    // Once the list shows, a cell scrolled off its right is the list's to bring in, though it's
    // past the scroll view's edge too, with the wheel over the part of the list the view shows.
    @Test func anInnerAreaScrollsWithinWhatTheOuterShows() {
        let list = rect(0, 250, 400, 100)
        let obstruction = ScrollVisibility.obstruction(of: CGPoint(x: 600, y: 270), areas: [outer, list])
        #expect(obstruction == .init(area: 1, visible: rect(0, 250, 400, 50), direction: .right))
    }

    // A cell off the list's right while the list is below the scroll view's: the view brings the
    // list in first.
    @Test func anInnerAreaOutOfViewIsTheOutersToBringIn() {
        let list = rect(0, 400, 400, 100)
        let obstruction = ScrollVisibility.obstruction(of: CGPoint(x: 600, y: 450), areas: [outer, list])
        #expect(obstruction == .init(area: 0, visible: outer, direction: .down))
    }

    // Three deep: a list below the part of a panel the scroll view shows, the panel partly in
    // view. The panel, not the outermost view, brings the list in, with the wheel over its shown part.
    @Test func theAreaThatBringsAnOutOfViewAreaInIsTheInnermostThatCan() {
        let panel = rect(0, 200, 400, 400)
        let list = rect(0, 700, 400, 100)
        let obstruction = ScrollVisibility.obstruction(of: CGPoint(x: 600, y: 750), areas: [outer, panel, list])
        #expect(obstruction == .init(area: 1, visible: rect(0, 200, 400, 100), direction: .down))
    }

    // A collapsed area shows nothing, though its centre is inside the area around it.
    @Test func aPointInAnEmptyAreaIsntInView() {
        let collapsed = rect(0, 100, 400, 0)
        let obstruction = ScrollVisibility.obstruction(of: CGPoint(x: 50, y: 100), areas: [outer, collapsed])
        #expect(obstruction?.area == 1)
        // Nothing of it on show for a wheel to reach, which scroll --to refuses rather than scroll the outer area.
        #expect(obstruction?.visible.isEmpty == true)
    }
}

@Suite struct RoleTests {
    @Test func mapsEachPlatformsRolesToTheSameARIAName() {
        #expect(UIRole.aria(.macOS, role: "AXButton") == "button")
        #expect(UIRole.aria(.linux, role: "push button") == "button")
        #expect(UIRole.aria(.windows, role: "Button") == "button")
        #expect(UIRole.aria(.macOS, role: "AXTextField") == "textbox")
        #expect(UIRole.aria(.linux, role: "entry") == "textbox")
        #expect(UIRole.aria(.windows, role: "Edit") == "textbox")
        #expect(UIRole.aria(.macOS, role: "AXStaticText") == "text")
        #expect(UIRole.aria(.linux, role: "label") == "text")
        #expect(UIRole.aria(.windows, role: "Text") == "text")
    }

    @Test func aSubroleCanSayMoreThanItsRole() {
        #expect(UIRole.aria(.macOS, role: "AXCheckBox", subrole: "AXSwitch") == "switch")
        #expect(UIRole.aria(.macOS, role: "AXTextField", subrole: "AXSearchField") == "searchbox")
        #expect(UIRole.aria(.macOS, role: "AXButton", subrole: "AXCloseButton") == "button")
    }

    @Test func anUnmappedRoleShowsAsItself() {
        #expect(UIRole.aria(.macOS, role: "AXDateField") == "datefield")
        #expect(UIRole.aria(.linux, role: "desktop frame") == "desktopframe")
    }

    @Test func checkedComesFromTheValueOnMacOSAndTheStateElsewhere() {
        #expect(ElementAttributes(role: "AXCheckBox", value: "1").checked == true)
        #expect(ElementAttributes(platform: .linux, role: "check box").checked == false)
        #expect(ElementAttributes(platform: .windows, role: "CheckBox", checked: true).checked == true)
        #expect(ElementAttributes(platform: .windows, role: "Button", checked: true).checked == nil)
    }

    @Test func snapshotsKeepTheNativeRole() {
        let node = SnapshotNode(ref: 1, attributes: ElementAttributes(platform: .linux, role: "push button", title: "OK"), scale: PixelScale(1))
        #expect(node.role == "button")
        #expect(node.nativeRole == "push button")
    }
}

@Suite struct AppMatchingTests {
    let notepad = RunningApp(identity: AppIdentity(name: "Notepad", id: "Microsoft.WindowsNotepad_8wekyb3d8bbwe!App", pid: 10), aliases: ["notepad"])
    let editor = RunningApp(identity: AppIdentity(name: "Text Editor", id: "org.gnome.TextEditor", pid: 11))
    let files = RunningApp(identity: AppIdentity(name: "Files", id: "org.gnome.Nautilus", pid: 12))
    let otherFiles = RunningApp(identity: AppIdentity(name: "Files", id: "com.example.Files", pid: 13))

    func find(_ spec: String?, frontmost: RunningApp? = nil) throws -> Int32 {
        try RunningApp.find(spec, in: [notepad, editor, files, otherFiles], frontmost: frontmost).identity.pid
    }

    @Test func byIDAliasNameOrPidIgnoringCase() throws {
        #expect(try find("org.gnome.texteditor") == 11)
        #expect(try find("NOTEPAD") == 10)
        #expect(try find("text editor") == 11)
        #expect(try find("pid:12") == 12)
        #expect(try find(nil, frontmost: editor) == 11)
    }

    @Test func anAmbiguousNameFailsListingEach() {
        #expect {
            try find("Files")
        } throws: { error in
            let message = String(describing: error)
            return message.contains("org.gnome.Nautilus") && message.contains("com.example.Files") && message.contains("pid:<n>")
        }
    }

    @Test func nothingMatchingFails() {
        #expect(throws: UIError.self) { try find("Paint") }
        #expect(throws: UIError.self) { try find("pid:99") }
        #expect(throws: UIError.self) { try find(nil) }
    }
}

/// A Linux guest's backend, answering from a fixed tree, that records what it was asked.
final class FakeGuest: UITransport {
    var calls: [[String: Any]] = []
    let tree: [String: Any] = [
        "id": 1, "role": "application", "title": "Text Editor", "children": [
            ["id": 2, "role": "frame", "title": "Untitled", "frame": [0, 0, 800, 600], "children": [
                ["id": 3, "role": "panel", "children": [
                    ["id": 4, "role": "push button", "title": "Save", "frame": [10, 10, 80, 30], "children": []],
                ]],
                ["id": 5, "role": "check box", "title": "Wrap", "checked": true, "frame": [10, 50, 80, 30], "children": []],
            ]],
        ],
    ]

    func send(_ line: Data) throws -> Data {
        let request = try JSONSerialization.jsonObject(with: line) as! [String: Any]
        calls.append(request)
        let ok: Any = switch request["op"] as! String {
        case "hello": ["platform": "linux", "scale": 2.0, "screen": [0, 0, 800, 600]]
        case "apps": ["apps": [["name": "Text Editor", "id": "org.gnome.TextEditor", "pid": 42]], "focused": 42]
        case "tree": tree
        case "node": ["id": 4, "role": "push button", "title": "Save", "frame": [10, 10, 80, 30]]
        case "at": ["id": 4, "role": "push button", "title": "Save", "frame": [10, 10, 80, 30]]
        case "parent": NSNull()
        case "windows": [[String: Any]]()
        default: NSNull()
        }
        return try JSONSerialization.data(withJSONObject: ["ok": ok])
    }

    var ops: [String] { calls.map { $0["op"] as! String } }
}

@Suite struct RemoteBackendTests {
    func driver(_ guest: FakeGuest) throws -> UIDriver<RemoteBackend> {
        let directory = FileManager.default.temporaryDirectory.appending(path: "hobo-ui-tests-\(UUID().uuidString)")
        return UIDriver(backend: try RemoteBackend(transport: guest), store: RefStore(directory: directory))
    }

    @Test func snapshotsAGuestsTreeInARIARolesAndScreenshotPixels() throws {
        let guest = FakeGuest()
        let outcome = try driver(guest).run(try HoboUI.parseAsRoot(["snapshot", "--app", "org.gnome.TextEditor"]))
        #expect(outcome.text == """
            app Text Editor (org.gnome.TextEditor) pid 42
            scale 2
            - window "Untitled" [e1] (0,0 1600×1200)
              - button "Save" [e2] (20,20 160×60)
              - checkbox "Wrap" [e3] (20,100 160×60) checked
            """)
        #expect(guest.ops.filter { $0 == "tree" }.count == 1)
    }

    @Test func clicksTheElementsCentreWhenItsWhatsThere() throws {
        let guest = FakeGuest()
        let outcome = try driver(guest).run(try HoboUI.parseAsRoot(["click", "--text", "Save"]))
        #expect(outcome.text == #"clicked button "Save" [e1] (20,20 160×60)"#)
        let click = try #require(guest.calls.first { $0["op"] as? String == "click" })
        #expect(click["x"] as? Double == 50)
        #expect(click["y"] as? Double == 25)
        #expect(guest.ops.contains("raise"))
    }

    @Test func clickTextInARefLooksOnlyInsideThatElement() throws {
        /// Two windows each with a Save button, answering `parent` from the tree.
        final class TwoSaves: UITransport {
            let tree: [String: Any] = [
                "id": 1, "role": "application", "title": "Text Editor", "children": [
                    ["id": 2, "role": "frame", "title": "Draft", "frame": [0, 0, 400, 300], "children": [
                        ["id": 3, "role": "push button", "title": "Save", "frame": [10, 10, 80, 30], "children": []],
                    ]],
                    ["id": 4, "role": "frame", "title": "Final", "frame": [400, 0, 400, 300], "children": [
                        ["id": 5, "role": "push button", "title": "Save", "frame": [410, 10, 80, 30], "children": []],
                    ]],
                ],
            ]
            var pressed: [Int] = []
            func nodes(_ node: [String: Any], parent: [String: Any]?) -> [(node: [String: Any], parent: [String: Any]?)] {
                [(node, parent)] + (node["children"] as! [[String: Any]]).flatMap { nodes($0, parent: node) }
            }
            func send(_ line: Data) throws -> Data {
                let request = try JSONSerialization.jsonObject(with: line) as! [String: Any]
                let entry = nodes(tree, parent: nil).first { $0.node["id"] as? Int == request["id"] as? Int }
                let ok: Any = switch request["op"] as! String {
                case "hello": ["platform": "linux", "scale": 1.0, "screen": [0, 0, 800, 600]]
                case "apps": ["apps": [["name": "Text Editor", "id": "org.gnome.TextEditor", "pid": 42]], "focused": 42]
                case "tree": tree
                case "node": entry?.node ?? NSNull()
                case "parent": entry?.parent ?? NSNull()
                case "press": { pressed.append(request["id"] as! Int); return NSNull() }()
                default: NSNull()
                }
                return try JSONSerialization.data(withJSONObject: ["ok": ok])
            }
        }
        let guest = TwoSaves()
        let directory = FileManager.default.temporaryDirectory.appending(path: "hobo-ui-tests-\(UUID().uuidString)")
        let driver = UIDriver(backend: try RemoteBackend(transport: guest), store: RefStore(directory: directory))
        // e1 window Draft, e2 its Save, e3 window Final, e4 its Save.
        _ = try driver.run(try HoboUI.parseAsRoot(["snapshot"]))
        #expect {
            try driver.run(try HoboUI.parseAsRoot(["click", "--text", "Save", "--press"]))
        } throws: { error in
            String(describing: error).contains("click one by its ref, as in click e2, or narrow with --role or --in <ref>")
        }
        let outcome = try driver.run(try HoboUI.parseAsRoot(["click", "--text", "Save", "--in", "e3", "--press"]))
        #expect(outcome.text.hasPrefix(#"pressed button "Save" [e4]"#))
        #expect(guest.pressed == [5])
        #expect {
            try driver.run(try HoboUI.parseAsRoot(["click", "--text", "Open", "--in", "e3", "--press"]))
        } throws: { error in
            String(describing: error).contains("no element in e3 in Text Editor shows exactly")
        }
    }

    @Test func aGuestErrorBecomesTheCommandsFailure() throws {
        final class Refusing: UITransport {
            func send(_ line: Data) throws -> Data {
                let op = (try JSONSerialization.jsonObject(with: line) as! [String: Any])["op"] as! String
                if op == "hello" { return Data(#"{"ok":{"platform":"windows","access":"the desktop isn't up"}}"#.utf8) }
                return Data(#"{"error":"no"}"#.utf8)
            }
        }
        let driver = UIDriver(backend: try RemoteBackend(transport: Refusing()), store: RefStore(directory: URL(filePath: "/tmp/unused")))
        #expect(throws: UIError.self) { try driver.run(try HoboUI.parseAsRoot(["key", "return"])) }
    }

    @Test func aPidOutOfRangeIsLeftOutRatherThanTrapping() throws {
        final class Overflowing: UITransport {
            func send(_ line: Data) throws -> Data {
                let op = (try JSONSerialization.jsonObject(with: line) as! [String: Any])["op"] as! String
                if op == "hello" { return Data(#"{"ok":{"platform":"linux"}}"#.utf8) }
                return Data(#"{"ok":{"apps":[{"name":"Big","pid":4294967296},{"name":"Files","pid":7}],"focused":4294967296}}"#.utf8)
            }
        }
        let backend = try RemoteBackend(transport: Overflowing())
        #expect(try backend.apps().map(\.identity.name) == ["Files"])
        #expect(try backend.frontmostApp() == nil)
    }
}
