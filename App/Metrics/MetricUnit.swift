import Foundation

/// How to render a metric's values, inferred from the unit **Render reports** on the series.
///
/// Phase 0 predicted that Phase 4 would have to hard-code a unit per series, because the spec
/// declares `unit` required on each datapoint and then never defines the property, so the generator
/// drops it. That's true of the datapoint — and beside the point: the sibling `unit` on the *series*
/// is well-formed and is the one that describes the numbers. So nothing here hard-codes CPU as a
/// percentage or memory as gigabytes; the API says, and this maps what it says onto a formatter.
///
/// The fallback case is why that's safe: an unrecognized unit is still rendered, with the raw string
/// appended, so a new unit vocabulary shows up as slightly plain axis labels rather than as a wrong
/// number or a crash.
enum MetricUnit: Hashable, Sendable {
    /// Values are already 0–100.
    case percent
    /// Values are a raw byte count.
    case bytes
    /// Values are seconds; sub-second values read better as milliseconds.
    case seconds
    case milliseconds
    /// A plain quantity. The string, if any, is the thing being counted.
    case count(String?)
    /// A unit already scaled by Render — "GB", "MB/s". The value is in that unit as-is.
    case scaled(String)

    init(apiUnit: String) {
        switch apiUnit.trimmingCharacters(in: .whitespaces).lowercased() {
        case "%", "percent", "percentage":
            self = .percent
        case "b", "byte", "bytes":
            self = .bytes
        case "s", "sec", "secs", "second", "seconds":
            self = .seconds
        case "ms", "millisecond", "milliseconds":
            self = .milliseconds
        case "", "count", "number":
            self = .count(nil)
        case "requests", "request", "connections", "connection", "instances", "instance":
            self = .count(apiUnit.lowercased())
        default:
            // Anything Render scaled for us — "GB", "MB", "KB/s" — is used verbatim rather than
            // guessed at. Guessing is how a 4 GB reading becomes "4 bytes".
            self = .scaled(apiUnit)
        }
    }

    /// The headline value under a chart title. Precise enough to act on, short enough to fit.
    func formatted(_ value: Double) -> String {
        switch self {
        case .percent:
            "\(number(value, fractionDigits: value < 10 ? 1 : 0))%"
        case .bytes:
            ByteCountFormatter.string(fromByteCount: Int64(value.rounded()), countStyle: .memory)
        case .seconds:
            // A p50 of 0.004s is "4 ms"; a p99 of 2.3s is "2.3 s". Same series, both readable.
            value < 1
                ? "\(number(value * 1000, fractionDigits: value * 1000 < 10 ? 1 : 0)) ms"
                : "\(number(value, fractionDigits: 2)) s"
        case .milliseconds:
            "\(number(value, fractionDigits: value < 10 ? 1 : 0)) ms"
        case .count(let noun):
            [number(value, fractionDigits: value < 10 && value != value.rounded() ? 1 : 0), noun]
                .compactMap { $0 }
                .joined(separator: " ")
        case .scaled(let unit):
            "\(number(value, fractionDigits: value < 10 ? 2 : 1)) \(unit)"
        }
    }

    /// The short form for an axis tick, where there's room for about four characters.
    func axisLabel(_ value: Double) -> String {
        switch self {
        case .percent:
            "\(number(value, fractionDigits: 0))%"
        case .bytes:
            ByteCountFormatter.string(fromByteCount: Int64(value.rounded()), countStyle: .memory)
        case .seconds:
            value < 1 ? "\(number(value * 1000, fractionDigits: 0))ms" : "\(number(value, fractionDigits: 1))s"
        case .milliseconds:
            "\(number(value, fractionDigits: 0))ms"
        case .count:
            abbreviated(value)
        case .scaled(let unit):
            "\(abbreviated(value)) \(unit)"
        }
    }

    private func number(_ value: Double, fractionDigits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(0...fractionDigits)).grouping(.automatic))
    }

    /// `1.2K`, `3.4M` — an axis has no room for grouped digits.
    private func abbreviated(_ value: Double) -> String {
        let magnitude = abs(value)
        switch magnitude {
        case 1_000_000...:
            return "\(number(value / 1_000_000, fractionDigits: 1))M"
        case 1_000...:
            return "\(number(value / 1_000, fractionDigits: 1))K"
        default:
            return number(value, fractionDigits: magnitude < 10 && value != value.rounded() ? 1 : 0)
        }
    }
}
