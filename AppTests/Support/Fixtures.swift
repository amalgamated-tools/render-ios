import Foundation

/// JSON bodies shaped like the API's, for stubbing responses.
///
/// Hand-written rather than captured, so each fixture carries only the fields the test cares about
/// plus whatever the spec marks required — a captured payload buries the interesting field in 40
/// lines of noise.
enum Fixtures {
    /// One page of `GET /projects`.
    static func projectsPage(_ projects: [(id: String, name: String, environmentIDs: [String])]) -> String {
        let elements = projects.map { project in
            """
            {"project":{"id":"\(project.id)","name":"\(project.name)",\
            "createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-02T00:00:00Z",\
            "owner":\(owner),\
            "environmentIds":[\(project.environmentIDs.map { "\"\($0)\"" }.joined(separator: ","))]},\
            "cursor":"cursor-\(project.id)"}
            """
        }
        return "[\(elements.joined(separator: ","))]"
    }

    /// One page of `GET /services`. Web services only — type-specific fields aren't what the list
    /// projection reads.
    static func servicesPage(_ services: [(id: String, name: String)]) -> String {
        let elements = services.map { service in
            """
            {"service":{"id":"\(service.id)","name":"\(service.name)","autoDeploy":"yes",\
            "branch":"main","repo":"https://github.com/renderinc/\(service.name)",\
            "createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-02T00:00:00Z",\
            "ownerId":"\(ownerID)","slug":"\(service.name)","suspended":"not_suspended",\
            "suspenders":[],"notifyOnFail":"default","rootDir":"./",\
            "type":"web_service","dashboardUrl":"https://dashboard.render.com/web/\(service.id)",\
            "serviceDetails":\(webServiceDetails)},\
            "cursor":"cursor-\(service.id)"}
            """
        }
        return "[\(elements.joined(separator: ","))]"
    }

    /// One page of `GET /logs`.
    ///
    /// Unlike every other list endpoint this one is an *object* with its own paging metadata rather
    /// than an array of cursor envelopes, so the window and `hasMore` are part of the fixture.
    static func logsPage(
        _ logs: [(id: String, message: String)],
        hasMore: Bool,
        nextStartTime: String = "2026-08-12T09:00:00Z",
        nextEndTime: String = "2026-08-12T10:00:00Z",
        level: String = "info",
        instance: String = "srv-1-abc"
    ) -> String {
        let elements = logs.map { logEntry(id: $0.id, message: $0.message, level: level, instance: instance) }
        return """
            {"hasMore":\(hasMore),"nextStartTime":"\(nextStartTime)","nextEndTime":"\(nextEndTime)",\
            "logs":[\(elements.joined(separator: ","))]}
            """
    }

    /// A single frame as `GET /logs/subscribe` sends it — the same shape as one element of a page,
    /// which is exactly why `LogLine` has two initializers.
    static func logFrame(
        id: String,
        message: String,
        level: String = "error",
        timestamp: String = "2026-08-12T09:30:00.123456Z"
    ) -> String {
        logEntry(id: id, message: message, level: level, instance: "srv-1-abc", timestamp: timestamp)
    }

    private static func logEntry(
        id: String,
        message: String,
        level: String,
        instance: String,
        timestamp: String = "2026-08-12T09:30:00.123456Z"
    ) -> String {
        """
        {"id":"\(id)","message":"\(message)","timestamp":"\(timestamp)",\
        "labels":[{"name":"level","value":"\(level)"},{"name":"instance","value":"\(instance)"}]}
        """
    }

    static let ownerID = "tea-000000000000000000"

    /// `serviceDetails` is required on every service, even though the list projection reads none
    /// of it.
    private static let webServiceDetails = """
        {"env":"node","runtime":"node","envSpecificDetails":{"buildCommand":"npm i","startCommand":"npm start"},\
        "plan":"starter","region":"oregon","numInstances":1,"buildPlan":"starter",\
        "healthCheckPath":"","url":"https://example.onrender.com"}
        """

    private static let owner = """
        {"id":"\(ownerID)","name":"Render-Prod","email":"team@render.com","type":"team"}
        """
}
