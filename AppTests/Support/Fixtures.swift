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
