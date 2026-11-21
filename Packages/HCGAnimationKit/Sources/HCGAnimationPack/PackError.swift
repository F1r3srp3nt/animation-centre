//
//  PackError.swift
//  HCGAnimationPack — Hakmi Capital Group
//
//  Codes 1–7 are HCGBackgroundKit's HCGBackgroundError values, so an error means the same thing on iOS and macOS.
//

import Foundation

public struct PackError: Error, Equatable, LocalizedError, CustomStringConvertible {
    public enum Code: Int, Sendable {
        case notAPreset = 1         // wrong "format", not a JSON object
        case unsupportedVersion = 2 // formatVersion newer than this reader (never guessed at)
        case missingValue = 3
        case invalidValue = 4
        case unsafeFileName = 5
        case unreadable = 6
        case mediaUnplayable = 7
        // Pack / catalog additions
        case checksumMismatch = 20
        case sizeMismatch = 21
        case insecureURL = 22
        case network = 23
    }

    public let code: Code
    public let message: String

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }
    public var description: String { "[\(code.rawValue)] \(message)" }
}
