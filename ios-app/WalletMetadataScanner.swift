import Foundation
import SQLite3

struct WalletMetadataCard: Sendable {
    let id: String
    let name: String?
    let serialNumber: String?
}

enum WalletMetadataError: LocalizedError {
    case open(String)
    case missingPassTable
    case missingUniqueID
    case query(String)

    var errorDescription: String? {
        switch self {
        case .open(let detail): return "Unable to open Wallet database: \(detail)"
        case .missingPassTable: return "Wallet database has no PASS table"
        case .missingUniqueID: return "Wallet PASS table has no UNIQUE_ID column"
        case .query(let detail): return "Wallet database query failed: \(detail)"
        }
    }
}

enum WalletMetadataScanner {
    static func readCards(from databaseURL: URL) throws -> [WalletMetadataCard] {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(databaseURL.path, &db, flags, nil) == SQLITE_OK,
              let db else {
            let message = db.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:)) ?? "unknown SQLite error"
            if let db { sqlite3_close(db) }
            throw WalletMetadataError.open(message)
        }
        defer { sqlite3_close(db) }

        let columns = try tableColumns("PASS", database: db)
        guard !columns.isEmpty else { throw WalletMetadataError.missingPassTable }
        guard columns.contains("UNIQUE_ID") else { throw WalletMetadataError.missingUniqueID }

        let organization = columns.contains("ORGANIZATION_NAME") ? "ORGANIZATION_NAME" : "NULL"
        let localized = columns.contains("LOCALIZED_DESCRIPTION") ? "LOCALIZED_DESCRIPTION" : "NULL"
        let serial = columns.contains("SERIAL_NUMBER") ? "SERIAL_NUMBER" : "NULL"
        let query = "SELECT UNIQUE_ID, \(organization), \(localized), \(serial) FROM PASS WHERE UNIQUE_ID IS NOT NULL"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw WalletMetadataError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        var result: [WalletMetadataCard] = []
        var seen: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rawID = text(statement, column: 0),
                  let id = normalizedDirectoryID(rawID),
                  seen.insert(id).inserted else { continue }
            let organizationName = text(statement, column: 1)?.trimmedNonempty
            let localizedDescription = text(statement, column: 2)?.trimmedNonempty
            let name = organizationName ?? localizedDescription
            result.append(WalletMetadataCard(
                id: id,
                name: name,
                serialNumber: text(statement, column: 3)?.trimmedNonempty
            ))
        }
        return result
    }

    static func passName(from passJSONURL: URL) -> String? {
        guard let data = try? Data(contentsOf: passJSONURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        for key in ["organizationName", "description", "logoText"] {
            if let value = object[key] as? String, let value = value.trimmedNonempty {
                return value
            }
        }
        return nil
    }

    private static func tableColumns(_ table: String, database: OpaquePointer) throws -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw WalletMetadataError.query(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        var columns: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = text(statement, column: 1) {
                columns.insert(name.uppercased())
            }
        }
        return columns
    }

    private static func text(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }

    /// AirCard's card directories are SHA-1-sized identifiers represented as
    /// 28-character padded Base64/Base64URL strings. Rejecting UUIDs and broad
    /// semantic identifiers prevents a successful write to the wrong folder.
    private static func normalizedDirectoryID(_ raw: String) -> String? {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "'\",()<>;[]{}"))
        if cleaned.contains("/") {
            cleaned = (cleaned as NSString).lastPathComponent
        }
        for suffix in [".pkpass", ".cache", ".pkcache"] where cleaned.hasSuffix(suffix) {
            cleaned.removeLast(suffix.count)
        }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "'\",()<>;[]{}. "))
        guard cleaned.utf8.count == 28, cleaned.hasSuffix("=") else { return nil }
        let body = cleaned.dropLast()
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+_-")
        guard body.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return cleaned
    }
}

private extension String {
    var trimmedNonempty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
