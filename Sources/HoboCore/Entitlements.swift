import Foundation
import Security

/// Code-signing entitlements of the running binary.
public enum Entitlements {
    public static let virtualization = "com.apple.security.virtualization"

    /// Whether this process was signed with `entitlement` set to true. VM processes run this same
    /// binary, so `start` checks it before handing the binary to launchd.
    public static func has(_ entitlement: String) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil) as? Bool == true
    }
}
