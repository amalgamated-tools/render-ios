import Foundation

/// The filter set shared by every log request, whatever transport carries it.
///
/// `GET /logs` and `GET /logs/subscribe` take an identical parameter list — the only difference is
/// that one returns a page and the other upgrades to a WebSocket. The generator gives them two
/// unrelated `Input.Query` types and can't express the socket at all, so a query built for the
/// history pane and a query built for the live tail would otherwise be assembled twice, by hand,
/// from two different type vocabularies. This is the one description; ``listLogsQuery(startTime:endTime:direction:limit:)``
/// projects it onto the generated operation and ``queryItems`` onto the socket URL.
///
/// Every filter but `resourceIDs` is optional and omitted when empty. Render treats a repeated
/// parameter as a disjunction (`level=error&level=warning` means either), and separate parameters as
/// a conjunction.
public struct LogQuery: Sendable, Hashable {
    /// The workspace to search. Required by the API — logs are not addressable by service alone.
    public var ownerID: String
    /// Service, job, datastore, or workflow IDs. Required, and the reason a log view is always
    /// opened *from* something.
    public var resourceIDs: [String]
    /// Substring or regex match against the message body.
    public var text: [String]
    public var level: [String]
    /// `app`, `request`, `build` — the vocabulary is per workspace, so read it from `/logs/values`
    /// rather than hard-coding it.
    public var type: [String]
    public var instance: [String]
    public var host: [String]
    public var statusCode: [String]
    public var method: [String]
    public var path: [String]

    public init(
        ownerID: String,
        resourceIDs: [String],
        text: [String] = [],
        level: [String] = [],
        type: [String] = [],
        instance: [String] = [],
        host: [String] = [],
        statusCode: [String] = [],
        method: [String] = [],
        path: [String] = []
    ) {
        self.ownerID = ownerID
        self.resourceIDs = resourceIDs
        self.text = text
        self.level = level
        self.type = type
        self.instance = instance
        self.host = host
        self.statusCode = statusCode
        self.method = method
        self.path = path
    }

    /// The generated query for `GET /logs`.
    ///
    /// - Parameters:
    ///   - startTime: Oldest log to return. `nil` means Render's default of one hour ago.
    ///   - endTime: Newest log to return. `nil` means now.
    ///   - direction: `.backward` (newest first) is what a triage view wants.
    ///   - limit: Render caps this at 100.
    public func listLogsQuery(
        startTime: Date? = nil,
        endTime: Date? = nil,
        direction: Operations.ListLogs.Input.Query.DirectionPayload = .backward,
        limit: Int = 100
    ) -> Operations.ListLogs.Input.Query {
        .init(
            ownerId: ownerID,
            startTime: startTime,
            endTime: endTime,
            direction: direction,
            resource: resourceIDs,
            instance: nilIfEmpty(instance),
            host: nilIfEmpty(host),
            statusCode: nilIfEmpty(statusCode),
            method: nilIfEmpty(method),
            level: nilIfEmpty(level),
            _type: nilIfEmpty(type),
            text: nilIfEmpty(text),
            path: nilIfEmpty(path),
            limit: limit
        )
    }

    /// The same filters as URL query items, for the WebSocket handshake.
    ///
    /// Matches the generated serialization exactly — `style: .form, explode: true`, which repeats
    /// the parameter once per value rather than joining with commas.
    public var queryItems: [URLQueryItem] {
        var items = [URLQueryItem(name: "ownerId", value: ownerID)]
        func append(_ name: String, _ values: [String]) {
            items.append(contentsOf: values.map { URLQueryItem(name: name, value: $0) })
        }
        append("resource", resourceIDs)
        append("instance", instance)
        append("host", host)
        append("statusCode", statusCode)
        append("method", method)
        append("level", level)
        append("type", type)
        append("text", text)
        append("path", path)
        return items
    }

    private func nilIfEmpty(_ values: [String]) -> [String]? {
        values.isEmpty ? nil : values
    }
}
