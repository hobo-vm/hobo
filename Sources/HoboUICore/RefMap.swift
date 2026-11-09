import Foundation

/// The refs (`e12`) an app's elements have been given, kept in a file between `hobo-ui` runs.
/// A locator keeps its number for as long as the file lasts (a boot: it lives under the agent's
/// run directory), so `e12` from an older snapshot still means the same element, and a number
/// never moves to another locator.
public struct RefMap: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var ref: Int
        public var locator: Locator
    }

    public private(set) var entries: [Entry] = []
    private var byLocator: [Locator: Int] = [:]
    private var byRef: [Int: Locator] = [:]

    public init() {}

    /// The ref for `locator`, giving it the next number if it has none.
    public mutating func ref(for locator: Locator) -> Int {
        if let ref = byLocator[locator] { return ref }
        let ref = (entries.last?.ref ?? 0) + 1
        entries.append(Entry(ref: ref, locator: locator))
        byLocator[locator] = ref
        byRef[ref] = locator
        return ref
    }

    public func locator(for ref: Int) -> Locator? { byRef[ref] }

    private enum CodingKeys: CodingKey { case entries }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        for entry in try container.decode([Entry].self, forKey: .entries) {
            entries.append(entry)
            byLocator[entry.locator] = entry.ref
            byRef[entry.ref] = entry.locator
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entries, forKey: .entries)
    }

    /// Parses `e12` into 12.
    public static func parse(_ text: String) -> Int? {
        guard text.first == "e", let number = Int(text.dropFirst()), number > 0 else { return nil }
        return number
    }

    public static func format(_ ref: Int) -> String { "e\(ref)" }
}

/// Where an app's `RefMap` is kept: one file per app, in a directory the agent makes for the
/// guest user (`HOBO_UI_STATE`), or a temporary one when `hobo-ui` runs on its own.
public struct RefStore: Sendable {
    public var directory: URL

    public init(directory: URL) { self.directory = directory }

    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> RefStore {
        if let path = environment["HOBO_UI_STATE"], !path.isEmpty { return RefStore(directory: URL(filePath: path)) }
        return RefStore(directory: FileManager.default.temporaryDirectory.appending(path: "hobo-ui"))
    }

    /// The file for an app, by its key (`AppIdentity.storeKey`).
    func file(for key: String) -> URL {
        let safe = key.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" }
        return directory.appending(path: String(safe) + ".json")
    }

    public func load(_ key: String) -> RefMap {
        guard let data = try? Data(contentsOf: file(for: key)) else { return RefMap() }
        return (try? JSONDecoder().decode(RefMap.self, from: data)) ?? RefMap()
    }

    public func save(_ map: RefMap, for key: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(map).write(to: file(for: key), options: .atomic)
    }

    /// Loads the app's map, lets `body` give out refs, and saves it, holding a lock throughout:
    /// two `hobo-ui` runs against one app each adding to their own copy would otherwise give one
    /// number to two locators, the last save winning.
    public func update<T>(_ key: String, _ body: (inout RefMap) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockPath = file(for: key).path + ".lock"
        let descriptor = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: lockPath]) }
        defer { close(descriptor) }
        flock(descriptor, LOCK_EX)
        var map = load(key)
        let result = try body(&map)
        try save(map, for: key)
        return result
    }
}
