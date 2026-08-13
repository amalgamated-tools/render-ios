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

    /// A `/metrics/*` response. All fourteen metrics endpoints share this shape, which is the whole
    /// reason `MetricSeries` exists.
    static func metricSeries(
        _ series: [(labels: [(String, String)], points: [(String, Double)])],
        unit: String
    ) -> String {
        let elements = series.map { one in
            let labels = one.labels.map { #"{"field":"\#($0.0)","value":"\#($0.1)"}"# }
            let points = one.points.map { #"{"timestamp":"\#($0.0)","value":\#($0.1)}"# }
            return """
                {"labels":[\(labels.joined(separator: ","))],\
                "values":[\(points.joined(separator: ","))],"unit":"\(unit)"}
                """
        }
        return "[\(elements.joined(separator: ","))]"
    }

    /// A single-series metrics response with one point, for tests that only care that a request was
    /// answered.
    static func metricSeries(unit: String, value: Double = 1) -> String {
        metricSeries([(labels: [("instance", "srv-1-abc")], points: [("2026-08-12T10:00:00Z", value)])], unit: unit)
    }

    /// A whole `service` payload, for building a `ServiceDetailModel`. `serviceDetails` is supplied
    /// per type because that's the field whose shape depends on it.
    static func serviceJSON(id: String = "srv-1", type: String, details: String) -> String {
        """
        {"id":"\(id)","name":"api","autoDeploy":"yes","createdAt":"2026-01-01T00:00:00Z",\
        "updatedAt":"2026-01-02T00:00:00Z","ownerId":"\(ownerID)","slug":"api",\
        "suspended":"not_suspended","suspenders":[],"notifyOnFail":"default","rootDir":"./",\
        "type":"\(type)","dashboardUrl":"https://dashboard.render.com/web/\(id)",\
        "serviceDetails":\(details)}
        """
    }

    /// `serviceDetails` per service type. Only the required set plus whatever a test reads.
    static func serviceDetailsJSON(for type: String, diskSizeGB: Int? = nil) -> String {
        let disk = diskSizeGB.map {
            #","disk":{"id":"dsk-1","name":"data","mountPath":"/data","sizeGB":\#($0)}"#
        } ?? ""
        let compute = """
            "env":"node","runtime":"node",\
            "envSpecificDetails":{"buildCommand":"npm ci","startCommand":"npm start"},\
            "plan":"starter","region":"oregon","buildPlan":"starter"
            """
        switch type {
        case "static_site":
            return #"{"buildCommand":"npm run build","publishPath":"dist","url":"https://x.onrender.com","buildPlan":"starter"}"#
        case "web_service":
            return """
                {\(compute),"numInstances":1,"healthCheckPath":"","url":"https://x.onrender.com"\(disk)}
                """
        case "private_service":
            return #"{\#(compute),"numInstances":1,"url":"https://x.onrender.com"\#(disk)}"#
        case "background_worker":
            return "{\(compute),\"numInstances\":1\(disk)}"
        case "cron_job":
            return #"{\#(compute),"schedule":"0 * * * *"\#(disk)}"#
        default:
            fatalError("unhandled service type \(type)")
        }
    }

    /// One page of `GET /services/{id}/env-vars`.
    static func envVarsPage(_ vars: [(key: String, value: String)]) -> String {
        let elements = vars.map { one in
            #"{"envVar":{"key":"\#(one.key)","value":"\#(one.value)"},"cursor":"cursor-\#(one.key)"}"#
        }
        return "[\(elements.joined(separator: ","))]"
    }

    /// A single `envVar`, as `PUT /services/{id}/env-vars/{key}` answers with.
    static func envVar(key: String, value: String) -> String {
        #"{"key":"\#(key)","value":"\#(value)"}"#
    }

    /// One page of `GET /services/{id}/secret-files`.
    static func secretFilesPage(_ files: [(name: String, content: String)]) -> String {
        let elements = files.map { one in
            #"{"secretFile":{"name":"\#(one.name)","content":"\#(one.content)"},"cursor":"cursor-\#(one.name)"}"#
        }
        return "[\(elements.joined(separator: ","))]"
    }

    /// A single `secretFile`, as `PUT /services/{id}/secret-files/{name}` answers with.
    static func secretFile(name: String, content: String) -> String {
        #"{"name":"\#(name)","content":"\#(content)"}"#
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
