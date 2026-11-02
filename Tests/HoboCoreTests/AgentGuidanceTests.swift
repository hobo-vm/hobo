import Testing
@testable import HoboCore

struct AgentGuidanceTests {
    @Test func bothFrontendsCarryTheSameRules() {
        #expect(AgentGuidance.skillBody.hasSuffix(AgentGuidance.rules))
        #expect(AgentGuidance.mcpInstructions.hasSuffix(AgentGuidance.rules))
    }

    /// The skill points at `hobo usage` for flags; MCP clients get them from the tool schemas.
    @Test func onlyTheSkillSendsTheAgentToUsage() {
        #expect(AgentGuidance.skillBody.contains("`hobo usage`"))
        #expect(!AgentGuidance.mcpInstructions.contains("hobo usage"))
    }

    @Test func coversTheDesignedRules() {
        for phrase in ["start <vm> --ephemeral", "exec --gui", "[gui_testing]", "at most 2 running macOS guests",
                       "never drive the VM's window from the host"] {
            #expect(AgentGuidance.rules.localizedCaseInsensitiveContains(phrase), "\(phrase)")
        }
    }

    /// The description becomes a one-line YAML frontmatter value.
    @Test func descriptionIsOneLine() {
        #expect(!AgentGuidance.skillDescription.contains("\n"))
    }
}
