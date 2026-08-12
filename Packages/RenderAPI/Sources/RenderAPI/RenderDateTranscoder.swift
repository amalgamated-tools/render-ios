import Foundation
import OpenAPIRuntime

/// Decodes the timestamps Render actually sends.
///
/// Render returns **microsecond** precision (`2026-08-11T19:59:22.275356Z`), and the digit count
/// even varies (`…15.88552Z`). swift-openapi-runtime's default transcoder uses
/// `ISO8601DateFormatter`, whose `.withFractionalSeconds` accepts *exactly* three fractional digits
/// — so every response carrying such a timestamp fails to decode with "Expected date string to be
/// ISO8601-formatted." That's not a spec quirk in one field; it's every `createdAt`/`updatedAt` in
/// the API, so it belongs on the client configuration rather than at a call site.
///
/// Decode strategy: try strict ISO8601 with and without fractional seconds, and if the string has
/// sub-millisecond precision, normalize the fraction to three digits and retry. Encode always emits
/// millisecond precision, which Render accepts.
struct RenderDateTranscoder: DateTranscoder {
    func encode(_ date: Date) throws -> String {
        Self.makeFormatter(fractional: true).string(from: date)
    }

    func decode(_ string: String) throws -> Date {
        if let date = Self.makeFormatter(fractional: true).date(from: string) { return date }
        if let date = Self.makeFormatter(fractional: false).date(from: string) { return date }
        if let normalized = Self.normalizeFractionalSeconds(string),
           let date = Self.makeFormatter(fractional: true).date(from: normalized) {
            return date
        }
        throw DecodingError.dataCorrupted(
            .init(codingPath: [], debugDescription: "Not a recognized ISO8601 date: \(string)")
        )
    }

    /// A fresh formatter per call keeps this `Sendable` without locking; `ISO8601DateFormatter` is a
    /// reference type and isn't documented as concurrency-safe to share.
    private static func makeFormatter(fractional: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractional
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter
    }

    /// Clamps the fractional-seconds group to three digits (padding shorter, truncating longer) so
    /// `ISO8601DateFormatter` will accept it. `…22.275356Z` → `…22.275Z`; `…15.88552Z` → `…15.885Z`.
    static func normalizeFractionalSeconds(_ string: String) -> String? {
        guard let dot = string.firstIndex(of: ".") else { return nil }
        let fractionStart = string.index(after: dot)
        var fractionEnd = fractionStart
        while fractionEnd < string.endIndex, string[fractionEnd].isNumber {
            fractionEnd = string.index(after: fractionEnd)
        }
        let fraction = string[fractionStart..<fractionEnd]
        guard !fraction.isEmpty else { return nil }
        let clamped = fraction.prefix(3).padding(toLength: 3, withPad: "0", startingAt: 0)
        return String(string[..<fractionStart]) + clamped + String(string[fractionEnd...])
    }
}
