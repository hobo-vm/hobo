import Foundation
import Testing
@testable import HoboAppModel
import HoboCore

@MainActor @Suite struct LibraryTests {
    let store: VMStore
    let config = VMConfig(
        os: .linux, cpus: 4, memory: 4 << 30, disk: 32 << 30, macAddress: "5a:00:00:00:00:01",
        guestOSVersion: "Ubuntu 26.04", created: Date(timeIntervalSince1970: 1_800_000_000),
        recipeSHA256: String(repeating: "a", count: 64), sourceSHA256: String(repeating: "b", count: 64)
    )

    init() {
        let temp = FileManager.default.temporaryDirectory
        store = VMStore(
            directory: temp.appending(path: "hobo-app-vms-\(UUID().uuidString)"),
            home: HoboHome(root: temp.appending(path: "hobo-app-home-\(UUID().uuidString)"))
        )
    }

    private func made(_ name: String) throws {
        _ = try store.beginCreate(name)
        try store.finishCreate(name, config: config, recipe: Data("cpus = 4\n".utf8))
    }

    /// Waits up to 10 s for `condition`, as the window would see it.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    @Test func listsTheStoreAndFollowsItsChanges() async throws {
        try made("alpha")
        let library = Library(store: store)
        library.startWatching()
        #expect(await eventually { library.loaded })
        #expect(library.vms.map(\.name) == ["alpha"])
        // Seen through FSEvents, well before the 5 s poll.
        try made("beta")
        #expect(await eventually { library.vms.map(\.name) == ["alpha", "beta"] })
        try store.rename("alpha", to: "gamma")
        #expect(await eventually { library.vms.map(\.name) == ["beta", "gamma"] })
    }

    @Test func settingsAreSavedAsSetSavesThem() async throws {
        try made("dev")
        let library = Library(store: store)
        library.startWatching()
        #expect(await eventually { library.summary(named: "dev") != nil })
        var form = SettingsForm(config)
        form.cpus = 2
        library.apply(form, to: "dev")
        #expect(await eventually { library.summary(named: "dev")?.config?.cpus == 2 && library.busy.isEmpty })
        #expect(try VMConfig.load(from: store.bundle(for: "dev").appending(path: VMStore.configFile)).cpus == 2)
        #expect(library.failure == nil)
    }

    @Test func aRefusedActionIsReported() async throws {
        let library = Library(store: store)
        library.start("missing")
        #expect(await eventually { library.failure != nil })
        #expect(library.failure?.contains("missing") == true)
    }
}
