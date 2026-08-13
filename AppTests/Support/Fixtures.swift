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
    static func serviceDetailsJSON(
        for type: String,
        diskSizeGB: Int? = nil,
        runtime: String = "node"
    ) -> String {
        let disk = diskSizeGB.map {
            #","disk":{"id":"dsk-1","name":"data","mountPath":"/data","sizeGB":\#($0)}"#
        } ?? ""
        let compute = """
            "env":"node","runtime":"\(runtime)",\
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

    /// A single `deploy`, as `POST /services/{id}/deploys` answers with on a 201.
    static func deploy(id: String = "dep-1", status: String = "build_in_progress") -> String {
        #"{"id":"\#(id)","status":"\#(status)","createdAt":"2026-08-12T10:00:00Z"}"#
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

    /// One `envGroupMeta`.
    static func envGroupMeta(
        id: String,
        name: String,
        links: [(id: String, name: String, type: String)] = [],
        createdAt: String = "2026-01-01T00:00:00Z"
    ) -> String {
        let serviceLinks = links.map {
            #"{"id":"\#($0.id)","name":"\#($0.name)","type":"\#($0.type)"}"#
        }
        return """
            {"id":"\(id)","name":"\(name)","ownerId":"\(ownerID)",\
            "createdAt":"\(createdAt)","updatedAt":"2026-01-02T00:00:00Z",\
            "serviceLinks":[\(serviceLinks.joined(separator: ","))]}
            """
    }

    /// A page of `GET /env-groups`.
    ///
    /// Each group arrives in a `{envGroup, cursor}` envelope — which is what the live API sends and what
    /// `Scripts/envelope-env-groups.py` patches into the spec, since the spec claims a bare array.
    static func envGroupsPage(_ groups: [String]) -> String {
        let elements = groups.map { group in
            // The ID doubles as the cursor value so a paging test can assert on what it sent.
            let id = group.split(separator: "\"").first { $0.hasPrefix("evg-") } ?? "0"
            return #"{"envGroup":\#(group),"cursor":"cursor-\#(id)"}"#
        }
        return "[\(elements.joined(separator: ","))]"
    }

    /// A whole `envGroup` — meta plus contents — which is what **every** group write answers with.
    static func envGroup(
        id: String = "evg-1",
        name: String = "shared",
        links: [(id: String, name: String, type: String)] = [],
        envVars: [(key: String, value: String)] = [],
        secretFiles: [(name: String, content: String)] = []
    ) -> String {
        let meta = envGroupMeta(id: id, name: name, links: links)
        let vars = envVars.map { #"{"key":"\#($0.key)","value":"\#($0.value)"}"# }
        let files = secretFiles.map { #"{"name":"\#($0.name)","content":"\#($0.content)"}"# }
        // `envGroup` is an allOf, so meta and contents are siblings in one flat object.
        return """
            \(meta.dropLast())\
            ,"envVars":[\(vars.joined(separator: ","))],\
            "secretFiles":[\(files.joined(separator: ","))]}
            """
    }

    /// A single `customDomain`.
    static func customDomain(
        id: String,
        name: String,
        domainType: String = "subdomain",
        verificationStatus: String = "unverified",
        redirectForName: String = ""
    ) -> String {
        """
        {"id":"\(id)","name":"\(name)","domainType":"\(domainType)",\
        "publicSuffix":"com","redirectForName":"\(redirectForName)",\
        "verificationStatus":"\(verificationStatus)","createdAt":"2026-01-01T00:00:00Z"}
        """
    }

    /// `POST /custom-domains` answers with an **array** — an apex add returns the apex and its `www`
    /// redirect together.
    static func customDomainsCreated(_ domains: [String]) -> String {
        "[\(domains.joined(separator: ","))]"
    }

    /// A page of `GET /services/{id}/custom-domains`.
    static func customDomainsPage(_ domains: [String]) -> String {
        let elements = domains.enumerated().map { index, domain in
            #"{"customDomain":\#(domain),"cursor":"cursor-\#(index)"}"#
        }
        return "[\(elements.joined(separator: ","))]"
    }

    /// A page of `GET /services/{id}/headers`.
    static func headersPage(_ rules: [(id: String, path: String, name: String, value: String)]) -> String {
        let elements = rules.map { rule in
            """
            {"header":{"id":"\(rule.id)","path":"\(rule.path)","name":"\(rule.name)",\
            "value":"\(rule.value)"},"cursor":"cursor-\(rule.id)"}
            """
        }
        return "[\(elements.joined(separator: ","))]"
    }

    /// `POST /services/{id}/headers` answers with the header under a key called `headers` — singular
    /// payload, plural key, and optional besides.
    static func headerCreated(id: String, path: String, name: String, value: String) -> String {
        #"{"headers":{"id":"\#(id)","path":"\#(path)","name":"\#(name)","value":"\#(value)"}}"#
    }

    /// A page of `GET /services/{id}/routes`.
    static func routesPage(_ routes: [(id: String, type: String, source: String, destination: String, priority: Int)]) -> String {
        let elements = routes.map { route in
            """
            {"route":\(self.route(id: route.id, type: route.type, source: route.source,
                                 destination: route.destination, priority: route.priority)),\
            "cursor":"cursor-\(route.id)"}
            """
        }
        return "[\(elements.joined(separator: ","))]"
    }

    static func route(id: String, type: String, source: String, destination: String, priority: Int) -> String {
        """
        {"id":"\(id)","type":"\(type)","source":"\(source)",\
        "destination":"\(destination)","priority":\(priority)}
        """
    }

    /// `PATCH /services/{id}/routes/{routeId}` answers with the route under a key called `headers` — a
    /// copy-paste slip in the spec that the app has to read around.
    static func routePatched(id: String, type: String, source: String, destination: String, priority: Int) -> String {
        #"{"headers":\#(route(id: id, type: type, source: source, destination: destination, priority: priority))}"#
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
