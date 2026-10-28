import Foundation
import Testing
@testable import HoboVM

/// Integration tests boot real VMs and only run with HOBO_INTEGRATION=1.
let integrationEnabled = ProcessInfo.processInfo.environment["HOBO_INTEGRATION"] == "1"

@Suite(.enabled(if: integrationEnabled)) struct HoboVMIntegrationTests {
    @Test func placeholder() {}
}
