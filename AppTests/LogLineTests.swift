import Foundation
import Testing

@testable import RenderiOS

@Suite("LogLine")
struct LogLineTests {
    private func line(message: String = "hello", labels: [(name: String, value: String)]) -> LogLine {
        LogLine(id: "log-1", timestamp: .now, message: message, labels: labels)
    }

    @Test("labels are lifted into the fields a row shows")
    func liftsLabels() {
        let line = line(labels: [
            (name: "type", value: "request"),
            (name: "method", value: "POST"),
            (name: "statusCode", value: "500"),
            (name: "path", value: "/api/orders"),
            (name: "instance", value: "srv-1-abc"),
        ])

        #expect(line.type == "request")
        #expect(line.method == "POST")
        #expect(line.statusCode == "500")
        #expect(line.path == "/api/orders")
        #expect(line.instance == "srv-1-abc")
        // Still browsable in full — lifting is for the row, not a replacement.
        #expect(line.labels.count == 5)
    }

    @Test("level labels are matched loosely", arguments: [
        ("error", LogLevel.error),
        ("ERR", LogLevel.error),
        ("Fatal", LogLevel.error),
        ("warn", LogLevel.warning),
        ("info", LogLevel.info),
        ("debug", LogLevel.debug),
        ("chatty", LogLevel.unknown),
    ])
    func parsesLevels(label: String, expected: LogLevel) {
        // Every runtime spells severity differently and Render passes the label through verbatim.
        #expect(line(labels: [(name: "level", value: label)]).level == expected)
    }

    @Test("a request log with no level takes its severity from the status code")
    func infersLevelFromStatusCode() {
        #expect(line(labels: [(name: "statusCode", value: "502")]).level == .error)
        #expect(line(labels: [(name: "statusCode", value: "404")]).level == .warning)
        #expect(line(labels: [(name: "statusCode", value: "200")]).level == .info)
        // Build output has neither, and pretending it's info would color the whole screen blue.
        #expect(line(labels: []).level == .unknown)
    }

    @Test("an explicit level wins over the status code")
    func levelLabelBeatsStatusCode() {
        let line = line(labels: [(name: "level", value: "info"), (name: "statusCode", value: "500")])
        #expect(line.level == .info)
    }

    @Test("ANSI escape sequences are stripped from build output")
    func stripsANSI() {
        // Verbatim from a live tail — Render passes a build's terminal colors straight through.
        let raw = "\u{1B}[0;32m\u{1B}[1m==> \u{1B}[0m\u{1B}[1mDetected service running on port 10000\u{1B}[0m"
        #expect(line(message: raw, labels: []).message == "==> Detected service running on port 10000")

        // Cursor and erase sequences use other final bytes; the scanner is keyed on the grammar,
        // not on a list of color codes.
        #expect(LogLine.strippingANSI("a\u{1B}[2Kb\u{1B}[1;3Hc") == "abc")
        // A message with no escapes comes back untouched, including any bare brackets.
        #expect(LogLine.strippingANSI("plain [not an escape] text") == "plain [not an escape] text")
        // A truncated sequence at the end of a line can't consume anything that follows it.
        #expect(LogLine.strippingANSI("tail\u{1B}[0;3") == "tail")
    }

    @Test("copy text is the timestamp and the cleaned message")
    func copyTextIsPasteable() {
        let line = LogLine(
            id: "log-1",
            timestamp: Date(timeIntervalSince1970: 1_786_528_800),
            message: "\u{1B}[31mboom\u{1B}[0m",
            labels: [(name: "level", value: "error")]
        )
        #expect(line.copyText.hasSuffix(" boom"))
        #expect(!line.copyText.contains("\u{1B}"))
    }
}
