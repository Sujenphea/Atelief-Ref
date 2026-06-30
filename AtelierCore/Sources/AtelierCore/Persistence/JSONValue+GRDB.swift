// AtelierCore — JSONValue GRDB storage (chunk 4, decisions A1/C5)
//
// `Source.rawMetadata` is a `JSONValue`. GRDB's automatic nested-Codable
// handling misreads a single-value-container enum like `JSONValue` (it probes
// the column as a scalar and an object can come back decoded as `.bool(false)`).
//
// We instead make `JSONValue` an explicit database SCALAR: it stores as a JSON
// TEXT string in the `raw_metadata` column and reads back by decoding that
// string. `DatabaseValueConvertible` takes precedence over Codable recursion in
// GRDB's row coder, so this is exactly what lands in the column — agent-readable
// JSON text (C5). The conformance lives here, in the Persistence layer, so the
// domain `JSONValue` stays GRDB-free (A1).

import Foundation
import GRDB

extension JSONValue: DatabaseValueConvertible {
    /// Encodes to a JSON TEXT database value (`.null` only if encoding fails,
    /// which it cannot for a well-formed `JSONValue`).
    public var databaseValue: DatabaseValue {
        guard
            let data = try? JSONEncoder().encode(self),
            let string = String(data: data, encoding: .utf8)
        else {
            return .null
        }
        return string.databaseValue
    }

    /// Decodes from a JSON TEXT database value. Returns `nil` on a non-text or
    /// malformed value (GRDB then surfaces a decoding error).
    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> JSONValue? {
        guard
            let string = String.fromDatabaseValue(dbValue),
            let data = string.data(using: .utf8),
            let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        else {
            return nil
        }
        return value
    }
}
