import Foundation
import Testing
@testable import HoboCore

struct IdleTimeoutTests {
    @Test(arguments: [("90s", 90), ("30m", 1800), ("2h", 7200), ("1s", 1)])
    func parsesANumberAndAUnit(text: String, seconds: Int) throws {
        #expect(try IdleTimeout(parsing: text) == .after(seconds: seconds))
    }

    @Test func parsesOff() throws {
        #expect(try IdleTimeout(parsing: "off") == .off)
    }

    /// A bare number or zero must not silently turn the cleanup off or expire the VM at once.
    @Test(arguments: ["", "0", "30", "0m", "m", "-5m", "+5m", "1.5h", "5 m", "5M", "1d", "OFF", "٣m", "99999999999999999h"])
    func refusesAnythingElse(text: String) {
        #expect(throws: IdleTimeoutError.invalid(text)) { try IdleTimeout(parsing: text) }
    }

    @Test(arguments: [(IdleTimeout.off, "off"), (.after(seconds: 90), "90s"), (.after(seconds: 1800), "30m"), (.after(seconds: 5400), "90m"), (.after(seconds: 7200), "2h")])
    func describesItselfInTheFormItParses(timeout: IdleTimeout, text: String) throws {
        #expect(timeout.description == text)
        #expect(try IdleTimeout(parsing: text) == timeout)
    }

    @Test func theStandardTimeoutIsThirtyMinutes() {
        #expect(IdleTimeout.standard == .after(seconds: 30 * 60))
    }
}

struct IdleTimerTests {
    private let start = SuspendingClock().now

    private func at(_ seconds: Int) -> IdleTimer.Instant { start.advanced(by: .seconds(seconds)) }

    /// A 100 s timer whose countdown began at `start`.
    private func counting() -> IdleTimer {
        var timer = IdleTimer(timeout: .seconds(100))
        timer.start(at: start)
        return timer
    }

    @Test func nothingCountsBeforeTheBootSequenceEnds() {
        var timer = IdleTimer(timeout: .seconds(100))
        #expect(timer.remaining(at: at(1000)) == nil && !timer.hasExpired(at: at(1000)))
        timer.renew(at: at(1000))
        #expect(timer.remaining(at: at(1000)) == nil, "a renewal doesn't start it")
        timer.start(at: at(2000))
        #expect(timer.remaining(at: at(2010)) == .seconds(90))
    }

    /// `hobo exec` or `hobo view` during boot: the countdown begins with them already holding it.
    @Test func whatBeganDuringBootHoldsItOnceItStarts() {
        var timer = IdleTimer(timeout: .seconds(100))
        timer.requestBegan(at: at(10))
        timer.setWindowShown(true, at: at(20))
        timer.start(at: at(30))
        #expect(timer.remaining(at: at(5000)) == nil && !timer.hasExpired(at: at(5000)))
        timer.requestEnded(at: at(5000))
        #expect(timer.remaining(at: at(5000)) == nil, "the window is still showing")
        timer.setWindowShown(false, at: at(6000))
        #expect(timer.remaining(at: at(6000)) == .seconds(100))
    }

    @Test func expiresOnceTheTimeoutHasPassed() {
        let timer = counting()
        #expect(timer.secondsRemaining(at: at(99)) == 1 && !timer.hasExpired(at: at(99)))
        #expect(timer.secondsRemaining(at: at(100)) == 0 && timer.hasExpired(at: at(100)))
        #expect(timer.remaining(at: at(500)) == .zero && timer.hasExpired(at: at(500)))
    }

    @Test func secondsRemainingRoundsUp() {
        let timer = counting()
        #expect(timer.secondsRemaining(at: start.advanced(by: .milliseconds(99_500))) == 1)
    }

    @Test func aRenewalRestartsTheFullTimeout() {
        var timer = counting()
        timer.renew(at: at(90))
        #expect(timer.remaining(at: at(90)) == .seconds(100))
        #expect(!timer.hasExpired(at: at(189)) && timer.hasExpired(at: at(190)))
    }

    @Test func aRunningRequestHoldsItAndItsEndRestartsIt() {
        var timer = counting()
        timer.requestBegan(at: at(50))
        #expect(timer.remaining(at: at(5000)) == nil && !timer.hasExpired(at: at(5000)))
        timer.requestEnded(at: at(5000))
        #expect(timer.remaining(at: at(5000)) == .seconds(100))
    }

    @Test func everyRunningRequestHoldsIt() {
        var timer = counting()
        timer.requestBegan(at: at(10))
        timer.requestBegan(at: at(20))
        timer.requestEnded(at: at(30))
        #expect(timer.remaining(at: at(40)) == nil, "one is still running")
        timer.requestEnded(at: at(50))
        #expect(timer.remaining(at: at(50)) == .seconds(100))
    }

    @Test func aShowingWindowHoldsItAndHidingRestartsIt() {
        var timer = counting()
        timer.setWindowShown(true, at: at(50))
        #expect(timer.remaining(at: at(5000)) == nil && !timer.hasExpired(at: at(5000)))
        timer.setWindowShown(false, at: at(5000))
        #expect(timer.remaining(at: at(5000)) == .seconds(100))
    }

    /// The VM process reports the window on every tick; only a change may restart the countdown.
    @Test func reportingAnUnchangedWindowDoesntRenew() {
        var timer = counting()
        timer.setWindowShown(false, at: at(50))
        #expect(timer.remaining(at: at(50)) == .seconds(50))
    }

    @Test func theWindowAndARequestHoldItTogether() {
        var timer = counting()
        timer.setWindowShown(true, at: at(10))
        timer.requestBegan(at: at(20))
        timer.setWindowShown(false, at: at(30))
        #expect(timer.remaining(at: at(40)) == nil, "the request is still running")
    }
}
