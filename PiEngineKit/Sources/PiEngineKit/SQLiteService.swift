import Foundation
import SQLite3

/// Native SQLite behind pi-durable's `SqliteDatabase` facade (engine side: `engine/src/storage.ts`).
///
/// Storage lives in the app process, not in WebKit: if WebKit's content process dies, the database survives and the
/// restarted engine reopens it. Reopening a name closes the previous connection first, which rolls back any
/// transaction the dead engine left open.
///
/// Wire format for values: JSON null/number/string, `{"$bigint": "<decimal>"}` for 64-bit integers beyond JavaScript's
/// safe range, and `{"$blob": "<base64>"}` for blobs.
@MainActor
public final class SQLiteService {
    private let directory: URL
    private var connections: [String: SQLiteConnection] = [:]

    public init(directory: URL) {
        self.directory = directory
    }

    /// Registers the `sqlite` service with the engine.
    public func install(on engine: PiEngine) {
        engine.register(service: "sqlite") { [weak self] method, params in
            guard let self else { throw SQLiteError.closed }
            return try await self.handle(method, params as? [String: Any] ?? [:])
        }
    }

    /// Path of the database file for a storage name.
    public func path(for name: String) -> URL {
        directory.appending(path: "\(name).sqlite")
    }

    private func handle(_ method: String, _ params: [String: Any]) async throws -> Any? {
        let name = params["db"] as? String ?? ""
        switch method {
        case "open":
            if let previous = connections.removeValue(forKey: name) { await previous.close() }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            connections[name] = try SQLiteConnection(path: path(for: name).path)
            return name
        case "close":
            await connections.removeValue(forKey: name)?.close()
            return nil
        default:
            break
        }

        guard let connection = connections[name] else { throw SQLiteError.notOpen(name) }
        let sql = params["sql"] as? String ?? ""
        let values = try (params["params"] as? [Any] ?? []).map(SQLiteValue.init(bridged:))
        switch method {
        case "exec":
            try await connection.exec(sql)
            return nil
        case "run":
            try await connection.query(sql, values, limit: 0)
            return nil
        case "get":
            return try await connection.query(sql, values, limit: 1).first.map(Self.bridge) ?? NSNull()
        case "all":
            return try await connection.query(sql, values, limit: nil).map(Self.bridge)
        default:
            throw EngineError.unknownMethod("sqlite.\(method)")
        }
    }

    private static func bridge(_ row: [String: SQLiteValue]) -> [String: Any] {
        row.mapValues(\.bridged)
    }
}

enum SQLiteValue: Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    private static let maxSafeInteger: Int64 = 9_007_199_254_740_991

    init(bridged value: Any) throws {
        switch value {
        case is NSNull:
            self = .null
        case let string as String:
            self = .text(string)
        case let number as NSNumber:
            let double = number.doubleValue
            self = CFNumberIsFloatType(number) && double.rounded() != double ? .real(double) : .integer(number.int64Value)
        case let tagged as [String: Any]:
            if let decimal = tagged["$bigint"] as? String, let integer = Int64(decimal) {
                self = .integer(integer)
            } else if let base64 = tagged["$blob"] as? String, let data = Data(base64Encoded: base64) {
                self = .blob(data)
            } else {
                throw SQLiteError.unsupportedValue(String(describing: value))
            }
        default:
            throw SQLiteError.unsupportedValue(String(describing: value))
        }
    }

    var bridged: Any {
        switch self {
        case .null: NSNull()
        case .integer(let integer):
            abs(integer) <= Self.maxSafeInteger ? NSNumber(value: integer) : ["$bigint": String(integer)]
        case .real(let double): NSNumber(value: double)
        case .text(let string): string
        case .blob(let data): ["$blob": data.base64EncodedString()]
        }
    }
}

enum SQLiteError: LocalizedError {
    case closed
    case notOpen(String)
    case unsupportedValue(String)
    case sqlite(code: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .closed: "SQLite service closed"
        case .notOpen(let name): "SQLite database not open: \(name)"
        case .unsupportedValue(let value): "Unsupported SQLite value: \(value)"
        case .sqlite(let code, let message): "SQLite error \(code): \(message)"
        }
    }
}

/// One connection; the actor serializes all access to it. Prepared statements are cached by SQL text.
actor SQLiteConnection {
    private var db: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            sqlite3_close_v2(handle)
            throw SQLiteError.sqlite(code: SQLITE_CANTOPEN, message: message)
        }
        db = handle
        sqlite3_busy_timeout(handle, 5_000)
        // Same configuration as pi-durable's Node adapter.
        for pragma in ["PRAGMA journal_mode = WAL", "PRAGMA synchronous = NORMAL", "PRAGMA wal_autocheckpoint = 1000"] {
            guard sqlite3_exec(handle, pragma, nil, nil, nil) == SQLITE_OK else {
                let error = SQLiteError.sqlite(code: sqlite3_errcode(handle), message: String(cString: sqlite3_errmsg(handle)))
                sqlite3_close_v2(handle)
                throw error
            }
        }
    }

    func exec(_ sql: String) throws {
        let db = try open()
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw lastError(db) }
    }

    /// Runs one statement with positional bindings and returns up to `limit` rows (`nil`: all).
    @discardableResult
    func query(_ sql: String, _ params: [SQLiteValue], limit: Int?) throws -> [[String: SQLiteValue]] {
        let db = try open()
        let statement = try prepared(sql, db)
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        for (offset, value) in params.enumerated() {
            let index = Int32(offset + 1)
            let result = switch value {
            case .null: sqlite3_bind_null(statement, index)
            case .integer(let integer): sqlite3_bind_int64(statement, index, integer)
            case .real(let double): sqlite3_bind_double(statement, index, double)
            case .text(let string): sqlite3_bind_text(statement, index, string, -1, Self.transient)
            case .blob(let data): data.withUnsafeBytes {
                sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), Self.transient)
            }
            }
            guard result == SQLITE_OK else { throw lastError(db) }
        }

        var rows: [[String: SQLiteValue]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw lastError(db) }
            // `run` (limit 0) steps to completion; `get` (limit 1) stops at its row, like a Node statement's `get`.
            guard limit != 0 else { continue }
            rows.append(row(of: statement))
            if let limit, rows.count >= limit { break }
        }
        return rows
    }

    func close() {
        guard let db else { return }
        for statement in statements.values { sqlite3_finalize(statement) }
        statements.removeAll()
        sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
        // Closing with a transaction open rolls it back.
        sqlite3_close_v2(db)
        self.db = nil
    }

    private func open() throws -> OpaquePointer {
        guard let db else { throw SQLiteError.closed }
        return db
    }

    private func prepared(_ sql: String, _ db: OpaquePointer) throws -> OpaquePointer {
        if let statement = statements[sql] { return statement }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw lastError(db) }
        statements[sql] = statement
        return statement
    }

    private func row(of statement: OpaquePointer) -> [String: SQLiteValue] {
        var row: [String: SQLiteValue] = [:]
        for column in 0..<sqlite3_column_count(statement) {
            let name = String(cString: sqlite3_column_name(statement, column))
            row[name] = switch sqlite3_column_type(statement, column) {
            case SQLITE_INTEGER: .integer(sqlite3_column_int64(statement, column))
            case SQLITE_FLOAT: .real(sqlite3_column_double(statement, column))
            case SQLITE_TEXT: .text(sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "")
            case SQLITE_BLOB:
                .blob(sqlite3_column_blob(statement, column).map {
                    Data(bytes: $0, count: Int(sqlite3_column_bytes(statement, column)))
                } ?? Data())
            default: .null
            }
        }
        return row
    }

    private func lastError(_ db: OpaquePointer) -> SQLiteError {
        .sqlite(code: sqlite3_errcode(db), message: String(cString: sqlite3_errmsg(db)))
    }
}
