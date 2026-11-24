public enum Hobo {
    /// The release this build is of (`0.2.0`), or how far past one it is (`0.2.0-3-g1a2b3c4`).
    /// HoboVersionPlugin generates it from the checkout's `v<version>` tags at build time.
    public static let version = generatedVersion
}
