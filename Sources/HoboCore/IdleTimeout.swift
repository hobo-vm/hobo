/// How long an ephemeral VM may sit idle before it stops itself, which deletes it (decision 18), as
/// `start --idle-timeout` takes it: a whole number and a unit (`90s`, `30m`, `2h`), or `off`.
public enum IdleTimeout: Equatable, Sendable {
    case off
    /// Always a positive number of seconds when parsed.
    case after(seconds: Int)

    /// What a run gets without `--idle-timeout`.
    public static let standard = IdleTimeout.after(seconds: 30 * 60)

    /// Largest first, for `description`.
    private static let units: [(suffix: Character, seconds: Int)] = [("h", 3600), ("m", 60), ("s", 1)]

    /// Refuses a bare number, even `0`: a typo mustn't turn the cleanup off, or expire a VM at once.
    public init(parsing text: String) throws {
        if text == "off" {
            self = .off
            return
        }
        guard let suffix = text.last, let unit = Self.units.first(where: { $0.suffix == suffix }),
              text.dropLast().allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(text.dropLast()), value > 0,
              case (let seconds, false) = value.multipliedReportingOverflow(by: unit.seconds)
        else { throw IdleTimeoutError.invalid(text) }
        self = .after(seconds: seconds)
    }
}

extension IdleTimeout: CustomStringConvertible {
    /// The form `init(parsing:)` reads, in the largest unit that divides evenly: `90s`, `30m`, `off`.
    public var description: String {
        guard case .after(let seconds) = self else { return "off" }
        let unit = Self.units.first { seconds % $0.seconds == 0 } ?? (suffix: "s", seconds: 1)
        return "\(seconds / unit.seconds)\(unit.suffix)"
    }
}

public enum IdleTimeoutError: Error, Equatable, CustomStringConvertible {
    case invalid(String)

    public var description: String {
        switch self {
        case .invalid(let text): "invalid idle timeout \(text): give a whole number and a unit (90s, 30m, 2h), or off"
        }
    }
}

/// A VM process's countdown to its idle timeout. It counts only from `start`, once the boot sequence
/// has ended, and only the host's awake time: asleep, the host's agents are frozen along with it.
/// A running request or a showing window holds it, and the full timeout restarts when they end.
public struct IdleTimer: Sendable {
    public typealias Instant = SuspendingClock.Instant

    public let timeout: Duration
    private var lastUse: Instant?
    private var runningRequests = 0
    private var windowShown = false

    public init(timeout: Duration) {
        self.timeout = timeout
    }

    public var timeoutSeconds: Int { Int(timeout.components.seconds) }

    public mutating func start(at now: Instant) {
        lastUse = now
    }

    /// Restarts the countdown, if it has begun.
    public mutating func renew(at now: Instant) {
        if lastUse != nil { lastUse = now }
    }

    public mutating func requestBegan(at now: Instant) {
        runningRequests += 1
        renew(at: now)
    }

    public mutating func requestEnded(at now: Instant) {
        runningRequests -= 1
        renew(at: now)
    }

    /// A window's clicks and keys never reach the control socket, so one showing counts as in use.
    public mutating func setWindowShown(_ shown: Bool, at now: Instant) {
        guard shown != windowShown else { return }
        windowShown = shown
        renew(at: now)
    }

    /// What is left, or nil while nothing is counting: before `start`, and while held.
    public func remaining(at now: Instant) -> Duration? {
        guard let lastUse, runningRequests == 0, !windowShown else { return nil }
        return max(timeout - lastUse.duration(to: now), .zero)
    }

    /// `remaining` in whole seconds, rounded up, so a VM that hasn't expired never reports 0.
    public func secondsRemaining(at now: Instant) -> Int? {
        remaining(at: now).map { remaining in
            let (seconds, attoseconds) = remaining.components
            return Int(seconds) + (attoseconds > 0 ? 1 : 0)
        }
    }

    public func hasExpired(at now: Instant) -> Bool {
        remaining(at: now) == .zero
    }
}
