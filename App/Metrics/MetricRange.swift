import Foundation

/// The time windows the metrics screen offers, each with the resolution to ask for.
///
/// Resolution is part of the range rather than a separate control: the only reason to care about it
/// is to keep the number of points sane, and that follows from the window. Each pairing lands between
/// 60 and 170 points — enough that a spike is visible on a phone-width chart, few enough that four
/// charts don't cost megabytes or make Render aggregate for a second.
enum MetricRange: String, CaseIterable, Identifiable, Sendable {
    case hour
    case sixHours
    case day
    case week

    var id: String { rawValue }

    /// Deliberately terse — this is a segmented control on a phone.
    var title: String {
        switch self {
        case .hour: "1H"
        case .sixHours: "6H"
        case .day: "24H"
        case .week: "7D"
        }
    }

    /// Spelled out for VoiceOver and for the "last …" caption.
    var accessibilityTitle: String {
        switch self {
        case .hour: "Last hour"
        case .sixHours: "Last 6 hours"
        case .day: "Last 24 hours"
        case .week: "Last 7 days"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .hour: 3600
        case .sixHours: 6 * 3600
        case .day: 24 * 3600
        case .week: 7 * 24 * 3600
        }
    }

    /// Seconds per point. Never below Render's floor of 30, and an integer because Render parses it
    /// as one — it rejects `resolutionSeconds=60.0`.
    var resolutionSeconds: Int {
        switch self {
        case .hour: 60      // 60 points
        case .sixHours: 300 // 72
        case .day: 900      // 96
        case .week: 3600    // 168
        }
    }

    /// How many points a full window yields, for tests and for sanity.
    var approximatePointCount: Int {
        Int(duration) / resolutionSeconds
    }

    /// The x-axis stride that reads well for this window.
    var axisStride: (component: Calendar.Component, count: Int) {
        switch self {
        case .hour: (.minute, 15)
        case .sixHours: (.hour, 1)
        case .day: (.hour, 6)
        case .week: (.day, 1)
        }
    }

    /// Whether to label the axis with a date rather than a clock time.
    var axisShowsDate: Bool {
        self == .week
    }

    func window(endingAt end: Date) -> (start: Date, end: Date) {
        (end.addingTimeInterval(-duration), end)
    }
}
