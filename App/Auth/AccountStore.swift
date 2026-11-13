import Foundation
import Observation
import RenderAPI

/// Who the API key belongs to, from `GET /users` — shown at the top of the account menu so it's
/// clear which login is signed in before tapping Sign Out, or when a key from a teammate's
/// account behaves unexpectedly.
///
/// Best-effort by design. Nothing else depends on it, so a failed fetch leaves ``user`` `nil` and the
/// menu simply doesn't show it; there is no error state worth interrupting anyone with.
@MainActor
@Observable
final class AccountStore {
    struct Account: Hashable, Sendable {
        let id: String
        let name: String
        let email: String
    }

    private(set) var user: Account?

    private let client: RenderClient

    init(client: RenderClient) {
        self.client = client
    }

    func load() async {
        guard let user = try? await client.api.getUser().ok.body.json else { return }
        self.user = Account(id: user.id, name: user.name, email: user.email)
    }
}
