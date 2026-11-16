import Testing
@testable import HoboCore

@Suite struct GuestRemoveTests {
    @Test func takesGuestPathsInOneVM() throws {
        let (vm, remove) = try GuestRemove.parse(["dev:/tmp/MyApp.app", "dev:notes", "dev:C:/Users/hobo/x"], force: true)
        #expect(vm == "dev")
        #expect(remove == GuestRemove(paths: ["/tmp/MyApp.app", "notes", "C:/Users/hobo/x"], force: true))
        #expect(try GuestRemove.parse(["dev:a"]).remove.force == false)
    }

    @Test(arguments: [
        ([], GuestRemoveError.noPaths),
        // A bare name is a VM, which rm never removes.
        (["dev"], .vmName("dev")),
        (["./a:b"], .hostPath("./a:b")),
        (["/tmp/x"], .hostPath("/tmp/x")),
        (["dev:"], .emptyPath("dev:")),
        (["dev:a", "other:b"], .severalGuests),
    ])
    func refusesBadOperands(operands: [String], error: GuestRemoveError) {
        #expect(throws: error) { try GuestRemove.parse(operands) }
    }

    @Test func pointsAVMNameAtDelete() {
        #expect(GuestRemoveError.vmName("dev").description.contains("hobo delete dev"))
    }
}
