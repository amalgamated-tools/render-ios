import Foundation

/// The response from starting a device-authorization flow: the code the user reads, the URL they
/// approve at, and the polling contract.
public struct DeviceGrant: Sendable, Equatable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURI: URL
    /// `verificationURI` with the user code pre-filled — open this so the user only has to tap
    /// Authorize.
    public let verificationURIComplete: URL
    /// How long the grant stays redeemable.
    public let expiresIn: TimeInterval
    /// How often the token endpoint may be polled.
    public let interval: TimeInterval

    public init(
        deviceCode: String,
        userCode: String,
        verificationURI: URL,
        verificationURIComplete: URL,
        expiresIn: TimeInterval,
        interval: TimeInterval
    ) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURI = verificationURI
        self.verificationURIComplete = verificationURIComplete
        self.expiresIn = expiresIn
        self.interval = interval
    }
}

/// Failures from Render's OAuth endpoints, separated by what the caller should do next.
public enum OAuthError: Error, Sendable, Equatable {
    /// The user hasn't tapped Authorize yet — keep polling. Internal to `pollForToken` unless the
    /// caller drives `fetchDeviceToken` manually.
    case authorizationPending
    /// The grant's `expires_in` window elapsed before the user authorized. Start over.
    case grantExpired
    /// Render explicitly rejected the refresh token. Terminal: discard the stored pair and
    /// re-onboard. Transport failures and server errors deliberately do *not* map here.
    case refreshTokenRejected
    /// The client refused to send a request to a non-Render host.
    case untrustedHost(String)
    /// Any other non-200, with the server's `{"error": ...}` message when one was parseable.
    case server(status: Int, message: String?)
    case transport(String)
    case decoding(String)
}

extension OAuthError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .authorizationPending:
            "Waiting for you to approve in the browser."
        case .grantExpired:
            "The sign-in code expired before it was approved. Try again."
        case .refreshTokenRejected:
            "Your session expired. Sign in again."
        case .untrustedHost:
            "Refusing to send credentials to an unrecognized server."
        case .server(_, let message):
            message ?? "Render returned an error during sign-in."
        case .transport(let description):
            "Couldn't reach Render: \(description)"
        case .decoding:
            "Render returned data this version of the app doesn't understand."
        }
    }
}

/// Render's OAuth 2.0 device-authorization flow (RFC 8628) — the same "click Authorize in the
/// browser" flow `render login` uses.
///
/// Endpoint paths and request/response shapes are mirrored from Render's open-source CLI
/// (github.com/render-oss/cli, pkg/client/oauth) rather than guessed, since none of this is in
/// Render's public API reference. The endpoints hang off the same host as the REST API.
public struct RenderOAuthClient: Sendable {
    /// Render issues one `client_id` per integration; the app's lives in `OAuthEnvironment`.
    private let clientID: String
    private let baseURL: URL
    private let transport: any OAuthHTTPTransport
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - sleep: Injectable so tests can assert on the polling cadence without waiting.
    ///   - now: Injectable so tests can drive grant expiry.
    public init(
        baseURL: URL = RenderClient.productionBaseURL,
        clientID: String,
        transport: any OAuthHTTPTransport = URLSessionOAuthTransport(),
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.baseURL = baseURL
        self.clientID = clientID
        self.transport = transport
        self.sleep = sleep
        self.now = now
    }

    // MARK: - Flow

    /// Starts a new device-authorization flow.
    public func createGrant() async throws -> DeviceGrant {
        let wire: DeviceGrantWire = try await post("/device-grant", body: ["client_id": clientID])
        guard
            let verificationURI = URL(string: wire.verificationUri),
            let verificationURIComplete = URL(string: wire.verificationUriComplete)
        else {
            throw OAuthError.decoding("Grant carried an unparseable verification URL.")
        }
        return DeviceGrant(
            deviceCode: wire.deviceCode,
            userCode: wire.userCode,
            verificationURI: verificationURI,
            verificationURIComplete: verificationURIComplete,
            expiresIn: TimeInterval(wire.expiresIn),
            interval: TimeInterval(wire.interval)
        )
    }

    /// One attempt to exchange a grant for a token; throws ``OAuthError/authorizationPending``
    /// until the user approves in the browser.
    public func fetchDeviceToken(for grant: DeviceGrant) async throws -> OAuthToken {
        let wire: TokenWire = try await post("/device-token", body: [
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "client_id": clientID,
            "device_code": grant.deviceCode,
        ])
        return token(from: wire)
    }

    /// Polls the token endpoint every `grant.interval` until the user authorizes, the grant
    /// expires (``OAuthError/grantExpired``), or the surrounding task is cancelled
    /// (`CancellationError` propagates from the sleep).
    public func pollForToken(grant: DeviceGrant) async throws -> OAuthToken {
        let deadline = now().addingTimeInterval(grant.expiresIn)
        // A server bug sending interval=0 must not turn this loop into a request flood.
        let interval = max(grant.interval, 1)

        while true {
            try await sleep(interval)
            // The real sleep throws on cancellation, but `sleep` is injectable — this keeps
            // "cancelling stops the loop" true regardless of what was injected.
            try Task.checkCancellation()
            // Checked after the sleep (matching the Go client's deadline timer racing its ticker)
            // so a grant that expires mid-wait isn't redeemed late.
            if now() >= deadline { throw OAuthError.grantExpired }
            do {
                return try await fetchDeviceToken(for: grant)
            } catch OAuthError.authorizationPending {
                continue
            }
        }
    }

    /// Exchanges a refresh token for a new pair. ``OAuthError/refreshTokenRejected`` is terminal;
    /// anything else is worth retrying later with the same refresh token.
    public func refresh(refreshToken: String) async throws -> OAuthToken {
        do {
            let wire: TokenWire = try await post("/token/refresh/", body: [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
            ])
            // Some servers don't rotate the refresh token on renewal; keep the old one then.
            return token(from: wire, fallbackRefreshToken: refreshToken)
        } catch OAuthError.server(_, let message) where message == "invalid_grant" {
            throw OAuthError.refreshTokenRejected
        }
    }

    /// Revokes an access token, e.g. on sign-out. Expects a 204.
    public func revoke(accessToken: String) async throws {
        let url = endpoint("/oauth/revoke")
        try requireTrusted(url)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await send(request)
        guard response.statusCode == 204 else {
            throw OAuthError.server(status: response.statusCode, message: "Revoke failed.")
        }
    }

    // MARK: - Wire types

    private struct DeviceGrantWire: Decodable {
        let deviceCode: String
        let userCode: String
        let verificationUri: String
        let verificationUriComplete: String
        let expiresIn: Int
        let interval: Int

        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code"
            case userCode = "user_code"
            case verificationUri = "verification_uri"
            case verificationUriComplete = "verification_uri_complete"
            case expiresIn = "expires_in"
            case interval
        }
    }

    private struct TokenWire: Decodable {
        let accessToken: String
        let expiresIn: Int
        let refreshToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
        }
    }

    private struct ErrorWire: Decodable {
        let error: String
    }

    private func token(from wire: TokenWire, fallbackRefreshToken: String = "") -> OAuthToken {
        OAuthToken(
            accessToken: wire.accessToken,
            refreshToken: wire.refreshToken?.isEmpty == false ? wire.refreshToken! : fallbackRefreshToken,
            expiresAt: now().addingTimeInterval(TimeInterval(wire.expiresIn))
        )
    }

    // MARK: - Plumbing

    private func endpoint(_ path: String) -> URL {
        // String concatenation rather than appending(path:) so "/token/refresh/" keeps its
        // trailing slash — the CLI sends it that way and the endpoint is not ours to probe.
        URL(string: baseURL.absoluteString.hasSuffix("/")
            ? String(baseURL.absoluteString.dropLast()) + path
            : baseURL.absoluteString + path) ?? baseURL
    }

    private func post<Response: Decodable>(_ path: String, body: [String: String]) async throws -> Response {
        let url = endpoint(path)
        try requireTrusted(url)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        // Matches the official Render CLI's oauth client exactly (JSON body, form-urlencoded
        // content-type) — an apparent quirk of Render's endpoint, preserved rather than "fixed"
        // against an auth endpoint we can't test.
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await send(request)

        guard response.statusCode == 200 else {
            if let errorBody = try? JSONDecoder().decode(ErrorWire.self, from: data) {
                if errorBody.error == "authorization_pending" {
                    throw OAuthError.authorizationPending
                }
                throw OAuthError.server(status: response.statusCode, message: errorBody.error)
            }
            let raw = String(data: data, encoding: .utf8)
            throw OAuthError.server(status: response.statusCode, message: raw?.isEmpty == false ? raw : nil)
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw OAuthError.decoding(String(describing: error))
        }
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.send(request)
        } catch let error as OAuthError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw OAuthError.transport(error.localizedDescription)
        }
    }

    /// Only Render domains may receive OAuth requests (plus localhost, for tests). Tokens and
    /// device codes must never be POSTed to a mistyped or injected host.
    private func requireTrusted(_ url: URL) throws {
        guard let host = url.host()?.lowercased(), !host.isEmpty else {
            throw OAuthError.untrustedHost(url.absoluteString)
        }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" {
            guard url.scheme == "http" || url.scheme == "https" else {
                throw OAuthError.untrustedHost(url.absoluteString)
            }
            return
        }
        guard url.scheme == "https", host == "render.com" || host.hasSuffix(".render.com") else {
            throw OAuthError.untrustedHost(url.absoluteString)
        }
    }
}
