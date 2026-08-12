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
///
/// The vocabulary below is not a guess. The live pass recorded what Render actually sends:
/// `cpu` (fractions of a core), `bytes`, `seconds`, `unitless`, and `mb` — and three of those needed a
/// case they didn't have. See `Scripts/smoke.sh`, which prints the unit per endpoint.
enum MetricUnit: Hashable, Sendable {
    /// Values are already 0–100.
    case percent
    /// Values are a raw byte count.
    case bytes
    /// Values are seconds; sub-second values read better as milliseconds.
    case seconds
    case milliseconds
    /// Fractions of a CPU core, which is what Render's `cpu` unit means — a `cpuLimit` of `0.5` is
    /// half a core. Its own case because the readings are often tiny (an idle service sits around
    /// 0.0001) and the generic small-number formatter renders that as "0.00".
    case cores
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
        case "cpu", "cores", "core":
            self = .cores
        // `unitless` is what Render sends for HTTP request counts and instance counts. Falling through
        // to `.scaled` rendered an instance count as "1.00 unitless", which is how the live pass found
        // this.
        case "", "count", "number", "unitless":
            self = .count(nil)
        case "requests", "request", "connections", "connection", "instances", "instance":
            self = .count(apiUnit.lowercased())
        case "kb", "mb", "gb", "tb", "pb":
            // Render sends these lowercased; "1.2 mb" reads like a typo.
            self = .scaled(apiUnit.uppercased())
        default:
            // Anything else Render scaled for us — "KB/s" — is used verbatim rather than guessed at.
            // Guessing is how a 4 GB reading becomes "4 bytes".
            self = .scaled(apiUnit)
        }
    }

    /// The headline value under a chart title. Precise enough to act on, short enough to fit.
    func formatted(_ value: Double) -> String {
        switch self {
        case .percent:
            "\(number(value, fractionDigits: value < 10 ? 1 : 0))%"
        case .bytes:
            byteCount(value)
        case .seconds:
            // A p50 of 0.004s is "4 ms"; a p99 of 2.3s is "2.3 s". Same series, both readable.
            value < 1
                ? "\(number(value * 1000, fractionDigits: value * 1000 < 10 ? 1 : 0)) ms"
                : "\(number(value, fractionDigits: 2)) s"
        case .milliseconds:
            "\(number(value, fractionDigits: value < 10 ? 1 : 0)) ms"
        case .cores:
            // An idle service reads around 0.0001 cores, and "0.00 cores" is not a reading. The
            // precision follows the magnitude so both that and a 2-core limit stay legible.
            "\(number(value, fractionDigits: coreFractionDigits(value))) \(abs(value) == 1 ? "core" : "cores")"
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
            byteCount(value)
        case .seconds:
            value < 1 ? "\(number(value * 1000, fractionDigits: 0))ms" : "\(number(value, fractionDigits: 1))s"
        case .milliseconds:
            "\(number(value, fractionDigits: 0))ms"
        case .cores:
            // Full precision, not a shortened form: an idle service's whole axis sits below 0.001, and
            // capping at three digits labelled every gridline "0".
            number(value, fractionDigits: coreFractionDigits(value))
        case .count:
            abbreviated(value)
        case .scaled(let unit):
            "\(abbreviated(value)) \(unit)"
        }
    }

    /// The smallest y-axis upper bound whose gridline labels this unit can still tell apart.
    ///
    /// Without it, a metric whose readings are near zero — bandwidth on a service serving a handful of
    /// requests — gets a domain so small that every tick rounds to the same string, and the chart
    /// reads "0 MB, 0 MB, 0 MB". Flooring the axis instead puts the line at the bottom, which is
    /// where it belongs and what it means.
    var axisFloor: Double {
        switch self {
        case .percent: 1
        case .bytes: 1_000_000
        case .seconds: 0.001
        case .milliseconds: 1
        // Cores keep four decimals, so they need almost no floor — an idle service really does live
        // at 0.0001 and the axis says so.
        case .cores: 0.0005
        case .count: 1
        case .scaled: 1
        }
    }

    /// `ByteCountFormatter`, except that it renders zero as "Zero KB" — which turned a quiet
    /// memory chart's baseline into a puzzle on the first live pass.
    private func byteCount(_ value: Double) -> String {
        guard value >= 1 else { return "0" }
        return ByteCountFormatter.string(fromByteCount: Int64(value.rounded()), countStyle: .memory)
    }

    /// Enough digits to see the reading, not enough to fill the row.
    private func coreFractionDigits(_ value: Double) -> Int {
        switch abs(value) {
        case 1...: 2
        case 0.01..<1: 3
        default: 4
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
