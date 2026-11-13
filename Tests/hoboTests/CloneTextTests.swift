import Testing
@testable import hobo

@Suite struct CloneTextTests {
    @Test func aCloneSaysHowToBootIt() {
        #expect(Clone.text(source: "dev", clone: "exp", ephemeral: false) == "Cloned dev to exp; hobo start exp boots it")
    }

    @Test func anEphemeralCloneAlsoNamesTheOneStepForm() {
        let text = Clone.text(source: "dev", clone: "tmp", ephemeral: true)
        #expect(text.hasPrefix("Cloned dev to tmp (ephemeral: deleted when it stops); hobo start tmp boots it\n"))
        #expect(text.hasSuffix("(hobo start dev --ephemeral clones and boots in one step)"))
    }
}
