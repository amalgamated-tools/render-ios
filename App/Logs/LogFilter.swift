import Foundation
import RenderAPI

/// The server-side filters the log screen exposes, as editable state.
///
/// Kept separate from ``LogQuery`` because the two answer different questions: this one is what the
/// sheet binds to and what "3 filters active" counts, while `LogQuery` is what goes on the wire. The
/// resource and owner aren't here at all — they're fixed by the screen you opened logs *from*, and
/// making them editable would let someone filter themselves out of their own service's logs.
struct LogFilter: Hashable, Sendable {
    /// Matched against the message body. Render supports wildcards and regex here.
    var text: String = ""
    var levels: Set<String> = []
    var types: Set<String> = []
    var statusCodes: Set<String> = []
    var methods: Set<String> = []
    var instances: Set<String> = []
    var hosts: Set<String> = []
    /// Request-log path, wildcards allowed (`/api/*`).
    var path: String = ""

    /// Each multi-select label a sheet can offer, paired with the `/logs/values` label that fills it.
    /// One list so the sheet, the reset, and the active count can't drift apart.
    enum Facet: String, CaseIterable, Identifiable, Sendable {
        case level, type, statusCode, method, instance, host

        var id: String { rawValue }

        var title: String {
            switch self {
            case .level: "Level"
            case .type: "Type"
            case .statusCode: "Status Code"
            case .method: "Method"
            case .instance: "Instance"
            case .host: "Host"
            }
        }

        /// The `/logs/values` vocabulary to populate this facet from.
        var label: Operations.ListLogsValues.Input.Query.LabelPayload {
            switch self {
            case .level: .level
            case .type: ._type
            case .statusCode: .statusCode
            case .method: .method
            case .instance: .instance
            case .host: .host
            }
        }
    }

    subscript(facet: Facet) -> Set<String> {
        get {
            switch facet {
            case .level: levels
            case .type: types
            case .statusCode: statusCodes
            case .method: methods
            case .instance: instances
            case .host: hosts
            }
        }
        set {
            switch facet {
            case .level: levels = newValue
            case .type: types = newValue
            case .statusCode: statusCodes = newValue
            case .method: methods = newValue
            case .instance: instances = newValue
            case .host: hosts = newValue
            }
        }
    }

    var isEmpty: Bool { activeCount == 0 }

    /// How many filters are narrowing the results, for the toolbar badge. Counts *filters*, not
    /// selected values: "level: error, warning" is one thing the user has to remember to undo.
    var activeCount: Int {
        var count = Facet.allCases.filter { !self[$0].isEmpty }.count
        if !text.isEmpty { count += 1 }
        if !path.isEmpty { count += 1 }
        return count
    }

    mutating func reset() {
        self = LogFilter()
    }

    func query(ownerID: String, resourceIDs: [String]) -> LogQuery {
        LogQuery(
            ownerID: ownerID,
            resourceIDs: resourceIDs,
            // Render treats repeated values as "any of", so a single-element array is the natural
            // encoding for the two free-text fields.
            text: text.isEmpty ? [] : [text],
            level: levels.sorted(),
            type: types.sorted(),
            instance: instances.sorted(),
            host: hosts.sorted(),
            statusCode: statusCodes.sorted(),
            method: methods.sorted(),
            path: path.isEmpty ? [] : [path]
        )
    }
}
