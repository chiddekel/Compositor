import Foundation
import CSQLite

/// The UserDefaults surface used by the Linux app, backed by a private SQLite database.
/// Avoids Foundation's property-list writer, which traps on arrays in static Swift builds.
public final class SQLiteUserDefaults: @unchecked Sendable {
    public static let standard: SQLiteUserDefaults = {
        let config = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        let root = config.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return SQLiteUserDefaults(databaseURL: root.appendingPathComponent("Compositor/preferences.sqlite3")) {
            // Read only: never call Foundation's broken Linux persistence path.
            Foundation.UserDefaults.standard.dictionaryRepresentation()
        }
    }()

    // Tagged JSON preserves the types expected by existing `object(forKey:) as? …` calls.
    private indirect enum Value: Codable {
        case bool(Bool), integer(Int), double(Double), string(String), data(Data), date(Date)
        case array([Value]), dictionary([String: Value])

        init(_ object: Any) throws {
            switch object {
            case let value as NSNumber:
                switch String(cString: value.objCType) {
                case "c", "B": self = .bool(value.boolValue)
                case "f", "d": self = .double(value.doubleValue)
                default: self = .integer(value.intValue)
                }
            case let value as String: self = .string(value)
            case let value as Data: self = .data(value)
            case let value as Date: self = .date(value)
            case let value as [Any]: self = .array(try value.map(Value.init))
            case let value as [String: Any]: self = .dictionary(try value.mapValues(Value.init))
            default: throw StorageError(message: "Unsupported preference type: \(type(of: object))")
            }
        }

        var object: Any {
            switch self {
            case .bool(let value): return value
            case .integer(let value): return value
            case .double(let value): return value
            case .string(let value): return value
            case .data(let value): return value
            case .date(let value): return value
            case .array(let value): return value.map(\.object)
            case .dictionary(let value): return value.mapValues(\.object)
            }
        }
    }

    private struct StorageError: Error { let message: String }
    private let lock = NSLock()
    private let databaseURL: URL
    private let legacyValues: () -> [String: Any]
    private var database: OpaquePointer?
    private var values: [String: Value] = [:]
    private var changed: Set<String> = []
    private var lastError: String?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// An explicit URL also lets tests isolate preferences from the user's settings.
    public init(databaseURL: URL, legacyValues: @escaping () -> [String: Any] = { [:] }) {
        self.databaseURL = databaseURL
        self.legacyValues = legacyValues
        synchronize()
    }

    deinit { if let database { sqlite3_close(database) } }

    public func object(forKey key: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        return values[key]?.object
    }

    public func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
    public func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    public func string(forKey key: String) -> String? { object(forKey: key) as? String }
    public func bool(forKey key: String) -> Bool { (object(forKey: key) as? NSNumber)?.boolValue ?? false }
    public func integer(forKey key: String) -> Int { (object(forKey: key) as? NSNumber)?.intValue ?? 0 }
    public func double(forKey key: String) -> Double { (object(forKey: key) as? NSNumber)?.doubleValue ?? 0 }

    public func set(_ value: Any?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        do {
            // Validate encoding before changing the in-memory value (e.g. reject NaN).
            let stored = try value.map(Value.init)
            if let stored { _ = try JSONEncoder().encode(stored) }
            values[key] = stored
            changed.insert(key)
            _ = flush()
        } catch { report(error) }
    }

    public func removeObject(forKey key: String) { set(nil, forKey: key) }

    @discardableResult public func synchronize() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return flush()
    }

    private func check(_ result: Int32) throws {
        guard result == SQLITE_OK || result == SQLITE_DONE else {
            throw StorageError(message: database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite open failed (\(result))")
        }
    }

    private func execute(_ sql: String) throws { try check(sqlite3_exec(database, sql, nil, nil, nil)) }

    private func statement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var prepared: OpaquePointer?
        try check(sqlite3_prepare_v2(database, sql, -1, &prepared, nil))
        guard let prepared else { throw StorageError(message: "Empty SQLite statement") }
        defer { sqlite3_finalize(prepared) }
        return try body(prepared)
    }

    private func write(_ value: Value?, key: String, preserveExisting: Bool = false) throws {
        let sql = value == nil ? "DELETE FROM preferences WHERE key = ?" :
            "INSERT OR \(preserveExisting ? "IGNORE" : "REPLACE") INTO preferences(key, value) VALUES (?, ?)"
        try statement(sql) { stmt in
            try check(sqlite3_bind_text(stmt, 1, key, -1, transient))
            if let value {
                let encoded = try JSONEncoder().encode(value)
                try encoded.withUnsafeBytes { bytes in
                    try check(sqlite3_bind_blob(stmt, 2, bytes.baseAddress, Int32(bytes.count), transient))
                }
            }
            try check(sqlite3_step(stmt))
        }
    }

    private func open() throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try check(sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil))
        // Keep UI stalls bounded. Failed changes remain in memory and are retried by the shell's flush timer.
        try check(sqlite3_busy_timeout(database, 100))
        try execute("PRAGMA synchronous = FULL")
        try execute("CREATE TABLE IF NOT EXISTS preferences (key TEXT PRIMARY KEY NOT NULL, value BLOB NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY NOT NULL)")
        try execute("BEGIN IMMEDIATE")
        do {
            let migrated = try statement("SELECT 1 FROM metadata WHERE key = 'foundation-import-v1'") { stmt in
                let result = sqlite3_step(stmt)
                if result == SQLITE_ROW { return true }
                try check(result)
                return false
            }
            if !migrated {
                for (key, value) in legacyValues() { try write(Value(value), key: key, preserveExisting: true) }
                try execute("INSERT INTO metadata(key) VALUES ('foundation-import-v1')")
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
        var loaded: [String: Value] = [:]
        try statement("SELECT key, value FROM preferences") { stmt in
            while true {
                let result = sqlite3_step(stmt)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW else { try check(result); break }
                let key = String(cString: sqlite3_column_text(stmt, 0))
                let count = Int(sqlite3_column_bytes(stmt, 1))
                guard let bytes = sqlite3_column_blob(stmt, 1), count > 0 else {
                    throw StorageError(message: "Invalid stored preference: \(key)")
                }
                loaded[key] = try JSONDecoder().decode(Value.self, from: Data(bytes: bytes, count: count))
            }
        }
        // Preserve edits made while the database was unavailable, including deletions.
        for key in changed { loaded[key] = values[key] }
        values = loaded
    }

    private func flush() -> Bool {
        do {
            if database == nil {
                do { try open() } catch {
                    if let database { sqlite3_close(database) }
                    database = nil
                    throw error
                }
            }
            if !changed.isEmpty {
                try execute("BEGIN IMMEDIATE")
                do {
                    for key in changed { try write(values[key], key: key) }
                    try execute("COMMIT")
                    changed.removeAll()
                } catch {
                    try? execute("ROLLBACK")
                    throw error
                }
            }
            lastError = nil
            return true
        } catch {
            report(error)
            return false
        }
    }

    private func report(_ error: Error) {
        let message = (error as? StorageError)?.message ?? String(describing: error)
        guard message != lastError else { return }
        lastError = message
        FileHandle.standardError.write(Data("Compositor preferences: \(message)\n".utf8))
    }
}
