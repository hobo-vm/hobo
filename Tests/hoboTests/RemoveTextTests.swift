import Testing
@testable import hobo

@Suite struct RemoveTextTests {
    @Test func aRemovalThatWorkedNamesItsPathsAsGiven() {
        #expect(Remove.text(paths: ["dev:/tmp/MyApp.app"], force: false) == "Removed dev:/tmp/MyApp.app")
        #expect(Remove.text(paths: ["dev:a", "dev:b"], force: false) == "Removed 2 paths")
    }

    /// The host isn't told whether a forced removal found anything.
    @Test func aForcedRemovalDoesntClaimThePathWasThere() {
        #expect(Remove.text(paths: ["dev:a"], force: true) == "Removed dev:a (or it wasn't there)")
        #expect(Remove.text(paths: ["dev:a", "dev:b"], force: true) == "Removed 2 paths (or they weren't there)")
    }
}
