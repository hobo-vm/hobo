import AppKit

/// Hobo's icon for the Dock and ⌘Tab. The binary isn't an app bundle, so nothing else gives it one.
/// `assets/render.swift` generates the PNG from `assets/icon.svg`.
public enum AppIcon {
    @MainActor public static let image = NSImage(data: Data(PackageResources.AppIcon_png))
}
