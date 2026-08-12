import Foundation
import Testing

@testable import RenderiOS

/// Unit rendering. Every case here starts from a string Render actually sends, because the whole
/// design of `MetricUnit` is that the unit is read rather than assumed — so what matters is that a
/// plausible vocabulary maps somewhere sensible, and that an unknown one still renders.
@Suite("Metric units")
struct MetricUnitTests {
    @Test("known units map to their formatters", arguments: [
        ("%", MetricUnit.percent),
        ("percent", .percent),
        ("bytes", .bytes),
        ("seconds", .seconds),
        ("ms", .milliseconds),
        ("count", .count(nil)),
        ("", .count(nil)),
        ("requests", .count("requests")),
        ("GB", .scaled("GB")),
    ])
    func mapsUnits(raw: String, expected: MetricUnit) {
        #expect(MetricUnit(apiUnit: raw) == expected)
    }

    @Test("an unrecognized unit is rendered verbatim rather than guessed at")
    func fallsBackToTheRawUnit() {
        // The failure mode this avoids: treating "MB/s" as bytes and reporting 4 MB/s as "4 bytes".
        let unit = MetricUnit(apiUnit: "MB/s")
        #expect(unit == .scaled("MB/s"))
        #expect(unit.formatted(4.25) == "4.25 MB/s")
    }

    @Test("a percentage keeps a decimal only while it's small enough to need one")
    func formatsPercent() {
        #expect(MetricUnit.percent.formatted(42.37) == "42%")
        #expect(MetricUnit.percent.formatted(4.2) == "4.2%")
    }

    @Test("sub-second latency reads as milliseconds")
    func formatsSeconds() {
        // A p50 in seconds is usually 0.00x, and "0 s" would be useless on the one chart where the
        // small numbers are the point.
        #expect(MetricUnit.seconds.formatted(0.004) == "4 ms")
        #expect(MetricUnit.seconds.formatted(0.25) == "250 ms")
        #expect(MetricUnit.seconds.formatted(2.5) == "2.5 s")
        #expect(MetricUnit.seconds.formatted(1.126) == "1.13 s")
    }

    @Test("a counted noun is included in the headline but not on the axis")
    func formatsCounts() {
        #expect(MetricUnit.count("requests").formatted(1234) == "1,234 requests")
        #expect(MetricUnit.count("requests").axisLabel(1234) == "1.2K")
        #expect(MetricUnit.count(nil).formatted(3) == "3")
    }

    @Test("axis labels stay short")
    func abbreviatesAxisLabels() {
        // About four characters is what a y-axis tick has room for on a phone.
        #expect(MetricUnit.count(nil).axisLabel(2_400_000) == "2.4M")
        #expect(MetricUnit.percent.axisLabel(42.6) == "43%")
        #expect(MetricUnit.seconds.axisLabel(0.004) == "4ms")
        #expect(MetricUnit.scaled("GB").axisLabel(1500) == "1.5K GB")
    }

    @Test("bytes are scaled by the system formatter")
    func formatsBytes() {
        #expect(MetricUnit.bytes.formatted(1_048_576).contains("MB"))
    }
}

/// Ranges. The pairing of window and resolution is the only real decision here, and the constraint it
/// has to satisfy — Render's 30-second floor, and a point count a phone can draw — is worth pinning.
@Suite("Metric ranges")
struct MetricRangeTests {
    @Test("every range asks for a resolution Render will accept")
    func respectsResolutionFloor() {
        for range in MetricRange.allCases {
            #expect(range.resolutionSeconds >= 30, "\(range.title)")
        }
    }

    @Test("every range lands on a drawable number of points")
    func keepsPointCountsSane() {
        for range in MetricRange.allCases {
            let points = range.approximatePointCount
            #expect(points >= 60 && points <= 200, "\(range.title) yields \(points)")
        }
    }

    @Test("the window ends where it's told to")
    func windowsEndAtTheGivenTime() {
        let end = Date(timeIntervalSince1970: 1_786_000_000)
        let window = MetricRange.day.window(endingAt: end)
        #expect(window.end == end)
        #expect(window.start == end.addingTimeInterval(-24 * 3600))
    }
}
