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
        let locator = Locator([.init(role: "AXWindow", name: "Main", index: 0), .init(role: "AXButton", name: nil, index: 1)])
        #expect(locator.resolve(from: app)?.a == app.kids[1].kids[2].a)
    }

    @Test func aNamedElementSurvivesASiblingInsertedBeforeIt() {
        let locator = Locator([.init(role: "AXWindow", name: "Main", index: 0), .init(role: "AXButton", name: "OK", index: 1)])
        var changed = app
        changed.kids[1].kids.insert(Fake("AXButton", "Cancel"), at: 0)
        #expect(locator.resolve(from: changed)?.a.title == "OK")
        #expect(locator.resolve(from: changed) != nil)
    }

    @Test func isStaleOnceTheElementIsGoneOrRenamed() {
        let locator = Locator([.init(role: "AXWindow", name: "Main", index: 0), .init(role: "AXButton", name: "OK", index: 1)])
        var renamed = app
        renamed.kids[1].kids[3] = Fake("AXButton", "Done")
        #expect(locator.resolve(from: renamed) == nil)
        var retitled = app
        retitled.kids[1].a.title = "Other"
        #expect(locator.resolve(from: retitled) == nil)
    }

    @Test func namesByIdentifierBeforeTitleAndNeverByValue() {
        #expect(ElementAttributes(role: "AXButton", title: "Save", identifier: "save").name == "save")
        #expect(ElementAttributes(role: "AXStaticText", value: "14 photos").name == nil)
    }
}

@Suite struct RefMapTests {
    @Test func keepsANumberPerLocatorAndNeverReusesOne() {
        var map = RefMap()
        let a = Locator([.init(role: "AXButton", name: "A", index: 0)])
        let b = Locator([.init(role: "AXButton", name: "B", index: 0)])
        #expect(map.ref(for: a) == 1)
        #expect(map.ref(for: b) == 2)
        #expect(map.ref(for: a) == 1)
        #expect(map.locator(for: 2) == b)
    }

    @Test func survivesTheFile() throws {
        var map = RefMap()
        _ = map.ref(for: Locator([.init(role: "AXWindow", name: "W", index: 0)]))
        let directory = FileManager.default.temporaryDirectory.appending(path: "hobo-ui-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RefStore(directory: directory)
        try store.save(map, for: "com.example.App")
        var loaded = store.load("com.example.App")
        #expect(loaded == map)
        #expect(loaded.ref(for: Locator([.init(role: "AXButton", name: nil, index: 0)])) == 2)
        #expect(store.load("com.example.Other") == RefMap())
    }

    // Runs against one app at once mustn't each number their own copy, giving a ref two meanings.
    @Test func concurrentUpdatesNeverShareANumber() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "hobo-ui-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RefStore(directory: directory)
        DispatchQueue.concurrentPerform(iterations: 16) { index in
            _ = try? store.update("com.example.App") { $0.ref(for: Locator([.init(role: "AXButton", name: "\(index)", index: 0)])) }
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
        return AppSnapshot(app: AppIdentity(name: "Demo", bundleID: "com.example.Demo", pid: 7), scale: 1, elements: elements)
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
              - statictext [e3] = "14 photos"
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
        #expect(AppSnapshot.line(node) == #"textarea [e6] = "a \"b\"\nc""#)
        node = SnapshotNode(ref: 7, attributes: ElementAttributes(role: "AXTextArea", value: "a\r\nb\rc"), scale: PixelScale(1))
        #expect(AppSnapshot.line(node) == #"textarea [e7] = "a\r\nb\rc""#)
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
        #expect(AppSnapshot(app: AppIdentity(name: "Demo", bundleID: nil, pid: 7), scale: 2, elements: shown).text == """
            app Demo pid 7
            scale 2
            - window "Main" [e1]
            """)
    }

    @Test func findsTextAnywhere() {
        let app = Fake("AXApplication", [Fake("AXWindow", "Main", [Fake("AXGroup", [Fake("AXStaticText", value: "14 photos")])])])
        let found = allElements(under: app, locator: Locator()).filter { $0.1.contains("photos") }
        #expect(found.map(\.2.description) == ["AXWindow:Main[0]/AXGroup[0]/AXStaticText[0]"])
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

    @Test func matchesTheWholeTextOutsideTheMenuBar() {
        #expect(found("Remove") == ["AXWindow:Main[0]/AXButton:Remove[0]", "AXWindow:Main[0]/AXMenu[0]/AXMenuItem:Remove[0]"])
        #expect(found("Remov").isEmpty)
        #expect(found("Save...") == ["AXWindow:Main[0]/AXButton:Save…[0]"])
    }

    @Test func aCheckboxStateIsNotTextItShows() {
        #expect(found("1") == ["AXWindow:Main[0]/AXStaticText[0]"])
    }

    @Test func aRoleNarrowsToWhatSnapshotCallsIt() {
        #expect(found("Remove", role: "menuitem") == ["AXWindow:Main[0]/AXMenu[0]/AXMenuItem:Remove[0]"])
        #expect(found("Remove", role: "MenuItem").count == 1)
        #expect(found("Remove", role: "checkbox").isEmpty)
    }

    @Test func anElementInsideAnotherMatchIsLeftToTheOuterOne() {
        #expect(found("NAS") == ["AXWindow:Main[0]/AXCell:NAS[0]"])
        #expect(found("NAS", role: "statictext") == ["AXWindow:Main[0]/AXCell:NAS[0]/AXStaticText[0]"])
    }
}

@Suite struct KeyTests {
    @Test func parsesModifiersAndNamedKeys() throws {
        #expect(try KeySpec.parse("cmd+shift+k") == KeySpec(modifiers: [.command, .shift], keyCode: 0x28))
        #expect(try KeySpec.parse("return") == KeySpec(modifiers: [], keyCode: 0x24))
        #expect(try KeySpec.parse("ctrl+F2") == KeySpec(modifiers: [.control], keyCode: 0x78))
        #expect(try KeySpec.parse("cmd++") == KeySpec(modifiers: [.command], keyCode: 0x18))
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
        #expect(try HoboUI.parseAsRoot(["scroll", "e5", "down", "10"]) is HoboUI.Scroll)
        #expect(try HoboUI.parseAsRoot(["scroll", "--to", "e40"]) is HoboUI.Scroll)
        #expect(try HoboUI.parseAsRoot(["menu", "File > Save"]) is HoboUI.Menu)
        #expect(try HoboUI.parseAsRoot(["wait", "--app", "TextEdit"]) is HoboUI.Wait)
        #expect(try HoboUI.parseAsRoot(["choose", "~/Pictures", "--app", "Candela"]) is HoboUI.Choose)
        #expect(try HoboUI.parseAsRoot(["type", "hello", "--into", "e3"]) is HoboUI.TypeText)
        #expect((try HoboUI.parseAsRoot(["type", "", "--into", "e3", "--replace"]) as? HoboUI.TypeText)?.replace == true)
    }

    @Test(arguments: [
        ["click", "nowhere"], ["click", "1,2", "--press"], ["click"], ["click", "e1", "--text", "OK"], ["click", "e1", "--role", "button"],
        ["click", "--text", ""], ["scroll", "e5"], ["wait"], ["wait", "--ref", "e1", "--text", "x"],
        ["key", "cmd+blah"], ["choose", "Pictures/a.png"], ["snapshot", "--depth", "0"], ["menu", " > "],
        ["wait", "--app", "X", "--timeout", "0"], ["wait", "--app", "X", "--timeout", "nan"], ["wait", "--app", "X", "--timeout", "inf"],
    ])
    func rejectsUsageErrors(_ arguments: [String]) {
        #expect(throws: (any Error).self) { try HoboUI.parseAsRoot(arguments) }
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

