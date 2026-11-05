/// How an agent should work with hobo: the workflow and rules, not the reference (that is
/// `hobo usage`). One text serves both agent frontends so they can't drift: the Claude Code skill
/// (`hobo claude install` writes `skillBody` under `skillDescription`) and the `hobo mcp` server's
/// `instructions`. Commands are written as hobo subcommands (`start --ephemeral`); each frontend's
/// opening says how to read them, since MCP tools mirror the CLI.
public enum AgentGuidance {
    public static let skillName = "hobo"

    /// The skill's trigger: when Claude should load it.
    public static let skillDescription = """
        Test software in a clean macOS or Linux VM with hobo: run a build, a test suite or a UI test \
        in a throwaway clone of a prepared VM and screenshot the guest's desktop. Use when asked to \
        test, UI-test or reproduce something in a clean VM or on a fresh macOS install, or to use \
        hobo VMs.
        """

    /// The skill's Markdown body, after its frontmatter.
    public static var skillBody: String {
        """
        # Hobo

        Hobo runs named macOS and Linux VMs on this Mac. The commands below are `hobo` subcommands. \
        This skill covers how to work with them; for every command's flags, `--json` output and \
        errors, run `hobo usage` once and read it.

        \(rules)
        """
    }

    /// The MCP server's `instructions`.
    public static var mcpInstructions: String {
        """
        This server runs named macOS and Linux VMs on this Mac. Its tools mirror the hobo CLI, so a \
        command below such as `start --ephemeral` is the `start` tool with `ephemeral` set, and \
        `exec --gui` is `exec` with `gui`. The server stops the ephemeral VMs it started when the \
        session ends.

        \(rules)
        """
    }

    static let rules = """
        ## Work in an ephemeral session

        Never test in a prepared VM itself: it is the clean state every session starts from.

        1. `list` shows the VMs. Pick a stopped one to start from (cloning needs it stopped).
        2. `start <vm> --ephemeral` clones it to a new, auto-named VM and boots that. Use the name it \
        reports for everything after.
        3. Work with as many `exec`, `cp` and `screenshot` calls as you need. There is no one-shot \
        `run`: a session is start, work, stop.
        4. `stop <clone>` when done, which deletes it. A clone you forget stops and deletes itself \
        after \(IdleTimeout.standard) idle (`start --idle-timeout` changes that). Every command on it \
        except `list` resets the clock, and a running `exec` holds it; raw SSH doesn't count. If a \
        clone isn't found mid-session it has probably expired, along with anything in it: start \
        another.

        ## Test inside the guest, never through the host

        - Everything runs in the guest over SSH, as the `vagrant` user with passwordless sudo: \
        `exec` runs a command, `cp` copies files in and out.
        - Never drive the VM's window from the host: don't click, type or take host screenshots of \
        it, or script it with AppleScript or computer use. `view` and `start --gui` are for a person \
        to watch. To drive the guest's UI, run the automation inside the guest (AppleScript and \
        System Events, XCUITest) and look with `screenshot`.
        - On a macOS guest, plain `exec` runs outside the logged-in desktop, so GUI apps, `open`, UI \
        scripting and `screencapture` don't work from it. `exec --gui` runs the command in the \
        `vagrant` user's desktop session instead. UI scripting also needs the VM to be built from a \
        recipe with `[gui_testing]`, which grants Accessibility and Screen Recording.

        ## Capacity

        macOS allows at most 2 running macOS guests per host, counting VMs the user or other agents \
        have running. Linux guests are uncapped. Stop your session as soon as you are done. If \
        `start` fails because two are running, say so; never stop a VM you didn't start.
        """
}
