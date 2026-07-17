//
//  APIError.swift
//  ThrdSpaces — Core/Networking
//
//  Minimal Phase-1 error surface for the networking layer. Repository-level
//  consumers arrive in T5+; this stays small until they define what they
//  actually need to distinguish. Errors carry no server-supplied message
//  text, so a backend response can't leak schema into the UI.
//

import Foundation

enum APIError: Error {
    /// Configuration.plist missing or malformed — a build/packaging fault.
    case invalidConfiguration
    /// Transport failure (no connectivity, timeout, TLS).
    case network(underlying: Error)
    /// Authentication/authorization failure.
    case auth
    /// Response body did not match the expected shape.
    case decoding
    /// Server returned a non-success HTTP status.
    case server(status: Int)
}
