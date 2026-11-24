import Testing
@testable import hobo

@Suite struct CopyTextTests {
    @Test func aCopyThatWorkedNamesItsPathsAsGiven() {
        #expect(Copy.text(paths: ["./App.app", "dev:/Applications/"], replace: false) == "Copied ./App.app to dev:/Applications/")
        #expect(Copy.text(paths: ["dev:a", "dev:b", "out"], replace: false) == "Copied 2 items to out")
    }

    @Test func aReplacingCopySaysSo() {
        #expect(Copy.text(paths: ["App.app", "dev:App.app"], replace: true) == "Copied App.app to dev:App.app, replacing what was there")
    }
}
