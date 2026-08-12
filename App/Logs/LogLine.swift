import Foundation
import RenderAPI

/// One log line, as the log view needs it.
///
/// The two log endpoints return the *same* shape through two unrelated generated types — history
/// through `Components.Responses.Logs200Response…LogsPayloadPayload`, the live tail through
/// ``LogEntryPayload`` — so this is where they converge. Labels arrive as an unordered
/// `[{name, value}]` array; the fields worth showing in a row are lifted out here so the view isn't
/// searching an array per row per redraw.
struct LogLine: Identifiable, Hashable, Sendable {
    let id: String
    let timestamp: Date
    let message: String
    let labels: [Label]
    let level: LogLevel
    /// `app`, `request`, `build`, … — whatever the workspace emits.
    let type: String?
    let instance: String?
    let statusCode: String?
    let method: String?
    let path: String?

    struct Label: Hashable, Sendable {
        let name: String
        let value: String
    }

    init(id: String, timestamp: Date, message: String, labels: [(name: String, value: String)]) {
        self.id = id
        self.timestamp = timestamp
        self.message = Self.strippingANSI(message)
        self.labels = labels.map { Label(name: $0.name, value: $0.value) }

        let byName = Dictionary(labels.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first })
        self.type = byName["type"]
        self.instance = byName["instance"]
        self.statusCode = byName["statusCode"]
        self.method = byName["method"]
        self.path = byName["path"]
        self.level = LogLevel(label: byName["level"], statusCode: byName["statusCode"])
    }

    /// A page of `GET /logs`.
    init(_ entry: Components.Responses.Logs200Response.Body.JsonPayload.LogsPayloadPayload) {
        self.init(
            id: entry.id,
            timestamp: entry.timestamp,
            message: entry.message,
            labels: entry.labels.map { (name: $0.name.rawValue, value: $0.value) }
        )
    }

    /// A frame from `GET /logs/subscribe`.
    init(_ entry: LogEntryPayload) {
        self.init(
            id: entry.id,
            timestamp: entry.timestamp,
            message: entry.message,
            labels: entry.labels.map { (name: $0.name.rawValue, value: $0.value) }
        )
    }

    /// The text a "copy" gesture should produce: timestamp and message, nothing else. Labels are
    /// browsable in the row's detail, but pasting them into a ticket is noise.
    var copyText: String {
        "\(timestamp.formatted(.iso8601)) \(message)"
    }

    /// Removes ANSI escape sequences from a message.
    ///
    /// Build logs are colorized for a terminal, and Render passes the escapes through verbatim — so
    /// without this a build line reads `[0;32m[1m==> [0mDetected service running on port 10000[0m`.
    /// Rendering the colors instead of dropping them would mean an `AttributedString` per line and a
    /// palette that fights Dark Mode, for output whose color is already redundant with the level.
    ///
    /// Hand-scanned rather than a regex: this runs on every line of a live tail, and the grammar
    /// (`ESC [` … final byte in `@`–`~`) is small enough that the scanner is the clearer of the two.
    static func strippingANSI(_ message: String) -> String {
        guard message.unicodeScalars.contains("\u{1B}") else { return message }
        var output = String.UnicodeScalarView()
        var scalars = message.unicodeScalars[...]
        while let scalar = scalars.popFirst() {
            guard scalar == "\u{1B}", scalars.first == "[" else {
                output.append(scalar)
                continue
            }
            scalars.removeFirst()
            // Parameter and intermediate bytes, then one final byte that ends the sequence.
            while let next = scalars.popFirst(), !("\u{40}"..."\u{7E}" ~= next) {}
        }
        return String(output)
    }
}

/// Severity, for coloring a wall of monospaced text so the eye lands on the part that matters.
enum LogLevel: Hashable, Sendable, CaseIterable {
    case error
    case warning
    case info
    case debug
    /// No level label and nothing to infer one from — most build output looks like this.
    case unknown

    /// Render's `level` label is free-form per runtime (`error`, `err`, `ERROR`, `fatal`, …), so it
    /// is matched loosely. Request logs often carry no level at all, but their status code says the
    /// same thing — a 502 is an error whether or not anything labelled it one.
    init(label: String?, statusCode: String?) {
        switch label?.lowercased() {
        case "error", "err", "fatal", "critical", "crit", "panic":
            self = .error
            return
        case "warning", "warn":
            self = .warning
            return
        case "info", "information", "notice":
            self = .info
            return
        case "debug", "trace":
            self = .debug
            return
        default:
            break
        }
        switch Int(statusCode ?? "") {
        case .some(500...): self = .error
        case .some(400..<500): self = .warning
        case .some: self = .info
        case nil: self = .unknown
        }
    }

    var displayName: String {
        switch self {
        case .error: "Error"
        case .warning: "Warning"
        case .info: "Info"
        case .debug: "Debug"
        case .unknown: "Other"
        }
    }
}
