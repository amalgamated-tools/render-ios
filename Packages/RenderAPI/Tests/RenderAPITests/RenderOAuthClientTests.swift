import Foundation
import RenderAPITestSupport
import Testing

@testable import RenderAPI

/// Pins the client to the semantics mirrored from Render's open-source CLI. These endpoints are
/// undocumented, so the tests are the contract — especially the content-type quirk, which looks
/// like a bug and must not be "fixed".
@Suite("RenderOAuthClient")
struct RenderOAuthClientTests {
    private static let grantJSON = """
        {"device_code":"dev-123","user_code":"WXYZ-9876",
         "verification_uri":"https://render.com/device",
         "verification_uri_complete":"https://render.com/device?code=WXYZ-9876",
         "expires_in":600,"interval":5}
        """
    private static let tokenJSON = """
        {"access_token":"acc-1","token_type":"bearer","expires_in":3600,"refresh_token":"ref-1"}
        """

    private func makeClient(
        transport: StubOAuthTransport,
        baseURL: URL = URL(string: "https://api.render.com/v1")!,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { _ in },
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 0) }
    ) -> RenderOAuthClient {
        RenderOAuthClient(baseURL: baseURL, clientID: "client-abc", transport: transport, sleep: sleep, now: now)
    }

    private func grant(expiresIn: TimeInterval = 600, interval: TimeInterval = 5) -> DeviceGrant {
        DeviceGrant(
            deviceCode: "dev-123",
            userCode: "WXYZ-9876",
            verificationURI: URL(string: "https://render.com/device")!,
            verificationURIComplete: URL(string: "https://render.com/device?code=WXYZ-9876")!,
            expiresIn: expiresIn,
            interval: interval
        )
    }

    // MARK: - createGrant

    @Test("createGrant decodes every field and hits /device-grant")
    func createGrantDecodes() async throws {
        let transport = StubOAuthTransport(responses: [(200, Self.grantJSON)])
        let grant = try await makeClient(transport: transport).createGrant()

        #expect(grant == self.grant())
        #expect(transport.requests.first?.url?.absoluteString == "https://api.render.com/v1/device-grant")
    }

    @Test("requests carry a JSON body with a form-urlencoded content type — the CLI's quirk")
    func contentTypeQuirkIsPreserved() async throws {
        let transport = StubOAuthTransport(responses: [(200, Self.grantJSON)])
        _ = try await makeClient(transport: transport).createGrant()

        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let body = try #require(request.httpBody)
        let decoded = try JSONDecoder().decode([String: String].self, from: body)
        #expect(decoded == ["client_id": "client-abc"])
    }

    // MARK: - Polling

    @Test("pollForToken sleeps the grant interval between attempts and returns the token")
    func pollingCadence() async throws {
        let pending = #"{"error":"authorization_pending"}"#
        let transport = StubOAuthTransport(responses: [
            (400, pending), (400, pending), (200, Self.tokenJSON),
        ])
        let recorder = SleepRecorder()
        let client = makeClient(transport: transport) { await recorder.record($0) }

        let token = try await client.pollForToken(grant: grant(interval: 5))

        #expect(token.accessToken == "acc-1")
        #expect(token.refreshToken == "ref-1")
        #expect(transport.callCount == 3)
        #expect(await recorder.sleeps == [5, 5, 5])
    }

    @Test("the device-token exchange sends the RFC 8628 grant_type")
    func deviceTokenBody() async throws {
        let transport = StubOAuthTransport(responses: [(200, Self.tokenJSON)])
        _ = try await makeClient(transport: transport).fetchDeviceToken(for: grant())

        let body = try #require(transport.requests.first?.httpBody)
        let decoded = try JSONDecoder().decode([String: String].self, from: body)
        #expect(decoded == [
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "client_id": "client-abc",
            "device_code": "dev-123",
        ])
    }

    @Test("polling stops with grantExpired once expires_in elapses")
    func pollingExpires() async throws {
        let transport = StubOAuthTransport(responses: [(400, #"{"error":"authorization_pending"}"#)])
        // Each sleep advances the injected clock by its duration; the grant allows 2 polls.
        let clock = TestClock()
        let client = makeClient(transport: transport, sleep: { clock.advance(by: $0) }, now: { clock.now })

        await #expect(throws: OAuthError.grantExpired) {
            _ = try await client.pollForToken(grant: grant(expiresIn: 11, interval: 5))
        }
        #expect(transport.callCount == 2)
    }

    @Test("a failed poll while the app is suspended keeps polling instead of ending sign-in")
    func pollingSurvivesTransportFailure() async throws {
        let transport = StubOAuthTransport { request, call in
            if call == 1 { throw URLError(.networkConnectionLost) }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(Self.tokenJSON.utf8), response)
        }
        let client = makeClient(transport: transport)

        _ = try await client.pollForToken(grant: grant())
        #expect(transport.callCount == 2)
    }

    @Test("repeated transport failures still stop at the grant's expiry")
    func pollingTransportFailuresExpire() async throws {
        let transport = StubOAuthTransport { _, _ in throw URLError(.notConnectedToInternet) }
        let clock = TestClock()
        let client = makeClient(transport: transport, sleep: { clock.advance(by: $0) }, now: { clock.now })

        await #expect(throws: OAuthError.grantExpired) {
            _ = try await client.pollForToken(grant: grant(expiresIn: 11, interval: 5))
        }
        #expect(transport.callCount == 2)
    }

    @Test("a zero interval is floored to one second, not a request flood")
    func intervalFloor() async throws {
        let transport = StubOAuthTransport(responses: [(200, Self.tokenJSON)])
        let recorder = SleepRecorder()
        let client = makeClient(transport: transport) { await recorder.record($0) }

        _ = try await client.pollForToken(grant: grant(interval: 0))
        #expect(await recorder.sleeps == [1])
    }

    @Test("cancellation propagates out of the polling sleep")
    func pollingCancels() async throws {
        let transport = StubOAuthTransport(responses: [(400, #"{"error":"authorization_pending"}"#)])
        let client = makeClient(transport: transport) { _ in throw CancellationError() }

        await #expect(throws: CancellationError.self) {
            _ = try await client.pollForToken(grant: grant())
        }
    }

    // MARK: - Refresh

    @Test("refresh posts to /token/refresh/ — trailing slash preserved — and returns the new pair")
    func refreshHappyPath() async throws {
        let transport = StubOAuthTransport(responses: [(200, Self.tokenJSON)])
        let token = try await makeClient(transport: transport).refresh(refreshToken: "old-ref")

        #expect(transport.requests.first?.url?.absoluteString == "https://api.render.com/v1/token/refresh/")
        #expect(token.accessToken == "acc-1")
        #expect(token.refreshToken == "ref-1")
        #expect(token.expiresAt == Date(timeIntervalSince1970: 3600))
    }

    @Test("a refresh response without a rotated refresh token keeps the old one")
    func refreshKeepsUnrotatedToken() async throws {
        let body = #"{"access_token":"acc-2","token_type":"bearer","expires_in":3600}"#
        let transport = StubOAuthTransport(responses: [(200, body)])
        let token = try await makeClient(transport: transport).refresh(refreshToken: "old-ref")

        #expect(token.refreshToken == "old-ref")
    }

    @Test("invalid_grant on refresh maps to the terminal refreshTokenRejected")
    func refreshRejection() async throws {
        let transport = StubOAuthTransport(responses: [(400, #"{"error":"invalid_grant"}"#)])

        await #expect(throws: OAuthError.refreshTokenRejected) {
            _ = try await makeClient(transport: transport).refresh(refreshToken: "old-ref")
        }
    }

    // MARK: - Errors

    @Test("a non-200 with an unrecognised error body surfaces as .server with the message")
    func serverErrorMessage() async throws {
        let transport = StubOAuthTransport(responses: [(429, #"{"error":"slow_down"}"#)])

        await #expect(throws: OAuthError.server(status: 429, message: "slow_down")) {
            _ = try await makeClient(transport: transport).createGrant()
        }
    }

    @Test("a non-200 with a non-JSON body falls back to the raw text")
    func serverErrorRawBody() async throws {
        let transport = StubOAuthTransport(responses: [(502, "Bad Gateway")])

        await #expect(throws: OAuthError.server(status: 502, message: "Bad Gateway")) {
            _ = try await makeClient(transport: transport).createGrant()
        }
    }

    @Test("transport failures map to .transport, not a crash or a generic error")
    func transportFailure() async throws {
        let transport = StubOAuthTransport { _, _ in throw URLError(.notConnectedToInternet) }

        do {
            _ = try await makeClient(transport: transport).createGrant()
            Issue.record("expected a throw")
        } catch let error as OAuthError {
            guard case .transport = error else {
                Issue.record("expected .transport, got \(error)")
                return
            }
        }
    }

    // MARK: - Trusted hosts

    @Test("a non-Render base URL is refused before the transport is touched", arguments: [
        "https://render.com.evil.example/v1",
        "http://api.render.com/v1",
        "https://api.example.com/v1",
    ])
    func untrustedHostsRefused(base: String) async throws {
        let transport = StubOAuthTransport(responses: [(200, Self.grantJSON)])
        let client = makeClient(transport: transport, baseURL: URL(string: base)!)

        do {
            _ = try await client.createGrant()
            Issue.record("expected a throw")
        } catch let error as OAuthError {
            guard case .untrustedHost = error else {
                Issue.record("expected .untrustedHost, got \(error)")
                return
            }
        }
        #expect(transport.callCount == 0)
    }

    @Test("localhost over plain http is allowed, for tests against a local stub server")
    func localhostAllowed() async throws {
        let transport = StubOAuthTransport(responses: [(200, Self.grantJSON)])
        let client = makeClient(transport: transport, baseURL: URL(string: "http://localhost:8080/v1")!)

        _ = try await client.createGrant()
        #expect(transport.callCount == 1)
    }

    // MARK: - Revoke

    @Test("revoke sends the Bearer header and treats 204 as success")
    func revokeSucceeds() async throws {
        let transport = StubOAuthTransport(responses: [(204, "")])
        try await makeClient(transport: transport).revoke(accessToken: "acc-1")

        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.render.com/v1/oauth/revoke")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer acc-1")
    }

    @Test("revoke treats anything but 204 as an error")
    func revokeRejectsOtherStatuses() async throws {
        let transport = StubOAuthTransport(responses: [(200, "")])

        await #expect(throws: OAuthError.server(status: 200, message: "Revoke failed.")) {
            try await makeClient(transport: transport).revoke(accessToken: "acc-1")
        }
    }
}

/// Captures requested sleep durations instead of waiting.
private actor SleepRecorder {
    private(set) var sleeps: [TimeInterval] = []

    func record(_ seconds: TimeInterval) {
        sleeps.append(seconds)
    }
}

/// A fake clock the polling sleep advances, so expiry-window tests don't wait in real time.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 0)

    var now: Date {
        lock.withLock { current }
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}
