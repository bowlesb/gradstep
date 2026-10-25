import CSQLite
import Darwin
import Foundation

struct DatabaseFailure: Error, Equatable, Sendable { let code: Int32 }
enum SQLValue { case text(String), integer(Int64), blob(Data) }

/// Confined to EncryptedStore's actor after synchronous initialization. SQLite's
/// full mutex mode is additional protection; this is not a shared global handle.
final class SQLiteConnection: @unchecked Sendable {
    private var handle: OpaquePointer?
    var inTransaction: Bool { handle.map { sqlite3_get_autocommit($0) == 0 } ?? false }

    /// `snapshot`: read-only and immutable (`mode=ro&immutable=1`), for a WAL database with no -wal file (everything is
    /// in the main file) on a disk too full for SQLite to create one. Reads only; never use it beside a writer.
    init(url: URL, snapshot: Bool = false) throws {
        // Foundation keeps Darwin's /var alias in some normalized URLs, whereas
        // SQLite NOFOLLOW rejects it. Resolve existing parents with realpath;
        // leave the final component unresolved so SQLite still rejects a link.
        guard let parent = realpath(url.deletingLastPathComponent().path, nil) else { throw ReaderError.storageUnavailable }
        defer { free(parent) }
        var path = String(cString: parent) + "/" + url.lastPathComponent
        var flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
        if snapshot {
            var components = URLComponents()
            components.scheme = "file"; components.path = path
            components.queryItems = [URLQueryItem(name: "mode", value: "ro"), URLQueryItem(name: "immutable", value: "1")]
            guard let uri = components.string else { throw ReaderError.storageUnavailable }
            path = uri; flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW | SQLITE_OPEN_URI
        }
        let result = sqlite3_open_v2(path, &handle, flags, nil)
        guard result == SQLITE_OK else { if let handle { sqlite3_close_v2(handle) }; handle = nil; throw DatabaseFailure(code: result) }
        sqlite3_extended_result_codes(handle, 1)
        sqlite3_busy_timeout(handle, 5_000)
    }

    deinit { close() }

    func close() {
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    /// Keeps the -wal and -shm files after the last connection closes (SQLITE_FCNTL_PERSIST_WAL): a later launch on a
    /// full disk then reads what's saved without having to create them (docs/reviews/OFFLINE_AND_STORAGE_20261025.md).
    func keepWALFiles() {
        var on: Int32 = 1
        _ = sqlite3_file_control(handle, "main", SQLITE_FCNTL_PERSIST_WAL, &on)
    }

    /// SQLite couldn't make room for its journal or shared-memory index: the disk is full.
    static func isOutOfRoom(_ failure: DatabaseFailure) -> Bool {
        // SQLITE_IOERR_SHMOPEN, _SHMSIZE and _SHMMAP (the extended codes aren't imported into Swift).
        [SQLITE_FULL, SQLITE_IOERR | (18 << 8), SQLITE_IOERR | (19 << 8), SQLITE_IOERR | (21 << 8)].contains(failure.code)
            // …or couldn't even create its empty -wal file.
            || failure.code & 0xff == SQLITE_CANTOPEN
    }

    func execute(_ sql: String) throws {
        let result = sqlite3_exec(handle, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw DatabaseFailure(code: result) }
    }

    func statement<T>(_ sql: String, values: [SQLValue] = [], body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else { throw DatabaseFailure(code: prepared) }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let text): result = sqlite3_bind_text(statement, index, text, -1, transient)
            case .integer(let integer): result = sqlite3_bind_int64(statement, index, integer)
            case .blob(let data): result = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
            }
            guard result == SQLITE_OK else { throw DatabaseFailure(code: result) }
        }
        return try body(statement)
    }

    func update(_ sql: String, values: [SQLValue] = []) throws {
        try statement(sql, values: values) { statement in
            let result = sqlite3_step(statement)
            guard result == SQLITE_DONE else { throw DatabaseFailure(code: result) }
        }
    }

    static func blob(_ statement: OpaquePointer, _ column: Int32, maximumBytes: Int = Int.max) throws -> Data {
        guard sqlite3_column_type(statement, column) == SQLITE_BLOB,
              Int(sqlite3_column_bytes(statement, column)) <= maximumBytes,
              let bytes = sqlite3_column_blob(statement, column) else { throw ReaderError.corruptData }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }

    static func text(_ statement: OpaquePointer, _ column: Int32, maximumBytes: Int = Int.max) throws -> String {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
              Int(sqlite3_column_bytes(statement, column)) <= maximumBytes,
              let text = sqlite3_column_text(statement, column) else { throw ReaderError.corruptData }
        return String(cString: text)
    }
}
