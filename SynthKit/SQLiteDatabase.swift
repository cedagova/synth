import Foundation
import SQLite3

/// A value bindable to a SQL statement parameter.
public enum SQLiteValue: Equatable, Sendable {
    case integer(Int64)
    case text(String)
    case null
}

/// A minimal, dependency-free wrapper over the system SQLite library.
///
/// Deliberately small: open/close, multi-statement scripts, single
/// parameterised statements, scalar reads, and transactions. That is
/// everything the store bootstrap and its migrations need; later leaves grow
/// it as their queries require.
///
/// All handle access is serialised by an internal lock, so an instance may be
/// shared across tasks.
public final class SQLiteDatabase: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: OpaquePointer?

    public let url: URL

    private init(handle: OpaquePointer, url: URL) {
        self.handle = handle
        self.url = url
    }

    deinit {
        if let handle {
            sqlite3_close_v2(handle)
        }
    }

    /// Opens (creating if needed) the database at `url`.
    public static func open(at url: URL) throws -> SQLiteDatabase {
        var handle: OpaquePointer?
        let path = url.path(percentEncoded: false)
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(path, &handle, flags, nil)

        guard status == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) }
                ?? String(cString: sqlite3_errstr(status))
            if let handle {
                sqlite3_close_v2(handle)
            }
            throw StoreError.databaseOpenFailed(path: path, code: status, message: message)
        }

        return SQLiteDatabase(handle: handle, url: url)
    }

    /// Closes the handle. Safe to call more than once.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        if let handle {
            sqlite3_close_v2(handle)
            self.handle = nil
        }
    }

    /// Runs one or more statements with no parameters (DDL, pragmas).
    public func executeScript(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try executeScriptLocked(sql)
    }

    /// Runs exactly one statement, binding `parameters` positionally.
    public func execute(_ sql: String, _ parameters: [SQLiteValue] = []) throws {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepareLocked(sql, parameters)
        defer { sqlite3_finalize(statement) }

        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else {
            throw statementError(sql: sql, code: status)
        }
    }

    /// Reads the first column of the first row as an integer, or `nil` when the
    /// statement returns no row or a NULL.
    public func scalarInt(_ sql: String, _ parameters: [SQLiteValue] = []) throws -> Int? {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepareLocked(sql, parameters)
        defer { sqlite3_finalize(statement) }

        let status = sqlite3_step(statement)
        switch status {
        case SQLITE_ROW:
            guard sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
            return Int(sqlite3_column_int64(statement, 0))
        case SQLITE_DONE:
            return nil
        default:
            throw statementError(sql: sql, code: status)
        }
    }

    /// Reads the first column of the first row as text, or `nil` when the
    /// statement returns no row or a NULL.
    public func scalarText(_ sql: String, _ parameters: [SQLiteValue] = []) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        let statement = try prepareLocked(sql, parameters)
        defer { sqlite3_finalize(statement) }

        let status = sqlite3_step(statement)
        switch status {
        case SQLITE_ROW:
            guard let bytes = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: bytes)
        case SQLITE_DONE:
            return nil
        default:
            throw statementError(sql: sql, code: status)
        }
    }

    /// Runs `body` inside a write transaction, committing on success and
    /// rolling back on any thrown error.
    ///
    /// `body` receives this same database. The lock is reentrant-safe here
    /// because it is released before `body` runs.
    @discardableResult
    public func withTransaction<T>(_ body: (SQLiteDatabase) throws -> T) throws -> T {
        try executeScript("BEGIN IMMEDIATE;")
        do {
            let result = try body(self)
            try executeScript("COMMIT;")
            return result
        } catch {
            // Roll back to the pre-transaction state. If the rollback itself
            // fails the original error is still the one worth reporting, but
            // the failure is logged rather than dropped.
            do {
                try executeScript("ROLLBACK;")
            } catch let rollbackError {
                NSLog("Synth: rollback after a failed transaction did not complete: %@",
                      String(describing: rollbackError))
            }
            throw error
        }
    }

    /// True when a table with this name exists.
    public func tableExists(_ name: String) throws -> Bool {
        let count = try scalarInt(
            "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = ?;",
            [.text(name)]
        )
        return (count ?? 0) > 0
    }

    // MARK: - Locked helpers

    private func executeScriptLocked(_ sql: String) throws {
        guard let handle else {
            throw StoreError.statementFailed(sql: sql, code: SQLITE_MISUSE, message: "database is closed")
        }
        var rawMessage: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, sql, nil, nil, &rawMessage)
        guard status == SQLITE_OK else {
            let message = rawMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(rawMessage)
            throw StoreError.statementFailed(sql: sql, code: status, message: message)
        }
        sqlite3_free(rawMessage)
    }

    private func prepareLocked(_ sql: String, _ parameters: [SQLiteValue]) throws -> OpaquePointer {
        guard let handle else {
            throw StoreError.statementFailed(sql: sql, code: SQLITE_MISUSE, message: "database is closed")
        }

        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else {
            let message = String(cString: sqlite3_errmsg(handle))
            if let statement { sqlite3_finalize(statement) }
            throw StoreError.statementFailed(sql: sql, code: status, message: message)
        }

        for (offset, value) in parameters.enumerated() {
            let index = Int32(offset + 1)
            let bindStatus: Int32
            switch value {
            case .integer(let number):
                bindStatus = sqlite3_bind_int64(statement, index, number)
            case .text(let string):
                // SQLITE_TRANSIENT: SQLite copies the bytes, so the Swift
                // string does not need to outlive this call.
                bindStatus = sqlite3_bind_text(statement, index, string, -1, Self.transientDestructor)
            case .null:
                bindStatus = sqlite3_bind_null(statement, index)
            }
            guard bindStatus == SQLITE_OK else {
                let message = String(cString: sqlite3_errmsg(handle))
                sqlite3_finalize(statement)
                throw StoreError.statementFailed(sql: sql, code: bindStatus, message: message)
            }
        }

        return statement
    }

    private func statementError(sql: String, code: Int32) -> StoreError {
        let message = handle.map { String(cString: sqlite3_errmsg($0)) }
            ?? String(cString: sqlite3_errstr(code))
        return StoreError.statementFailed(sql: sql, code: code, message: message)
    }

    private static let transientDestructor = unsafeBitCast(
        -1,
        to: sqlite3_destructor_type.self
    )
}
