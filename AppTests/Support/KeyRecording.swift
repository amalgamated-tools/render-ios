import Foundation
import HTTPTypes
import OpenAPIRuntime
import RenderAPI
import RenderAPITestSupport

@testable import RenderiOS

/// The idempotency keys of the runs a store asked to start, in order.
final class KeyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [String] = []
    var values: [String] { lock.withLock { _values } }
    func append(_ key: String) { lock.withLock { _values.append(key) } }
}

func keyRecording(
    _ route: @escaping @Sendable (HTTPRequest.Method) -> (status: Int, body: String)
) -> (client: RenderClient, keys: KeyRecorder) {
    let keys = KeyRecorder()
    let transport = StubTransport { request, body, _ in
        if request.method == .post, let body {
            let data = try await Data(collecting: body, upTo: 1 << 16)
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let key = object["idempotencyKey"] as? String {
                keys.append(key)
            }
        }
        let answer = route(request.method)
        var response = HTTPResponse(status: .init(code: answer.status))
        response.headerFields = [.contentType: "application/json"]
        return (response, HTTPBody(answer.body))
    }
    let client = RenderClient(apiKeyProvider: StaticAPIKeyProvider("test-key"), retryPolicy: .none, transport: transport)
    return (client, keys)
}
