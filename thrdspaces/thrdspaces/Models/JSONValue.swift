//
//  JSONValue.swift
//  ThrdSpaces — Models
//
//  Minimal permissive JSON value, used only for `spaces.hours` (a jsonb
//  column with no fixed shape pinned by the PRD or migration 0001). A
//  recursive enum is the simpler option here versus a `Data`-backed
//  passthrough: the `Data` route would need a hand-written
//  encode(to:)/init(from:) that re-serializes the container's contents via
//  `JSONSerialization`, which is more code and can't be asserted field-by-
//  field in a test. This enum decodes automatically via the cases below and
//  every case is a one-line assertion in ModelsTests.
//
//  Decodable only — matching every Models/ type T11 adds, nothing writes
//  `hours` from the client yet.
//

import Foundation

enum JSONValue: Decodable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Order matters: Bool/Double/String are distinct JSON token types, so
        // trying them in this order never misclassifies a value — but
        // container/array must come last since they're the "give up on
        // scalars" fallback.
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value for JSONValue"
            )
        }
    }
}
