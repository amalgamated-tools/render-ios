import RenderAPI
import SwiftUI

/// Phase 0 placeholder.
///
/// Its only job is to prove the app target links `RenderAPI` and can construct a client — the
/// onboarding and service-list screens that replace it land in Phase 1. See PLAN.md.
struct RootView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Render", systemImage: "server.rack")
            } description: {
                Text("Phase 0 — API client wired up.\nSign-in and services land in Phase 1.")
            }
            .navigationTitle("Render")
        }
    }
}

#Preview {
    RootView()
}
