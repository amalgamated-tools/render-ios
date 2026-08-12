import SwiftUI

/// Workspace switcher, shown in the list toolbar only when the key can act as more than one owner.
/// Selecting a different owner reloads the list against it (the list view is re-created on the id).
struct OwnerPickerView: View {
    @Bindable var authStore: AuthStore

    var body: some View {
        Menu {
            Picker("Workspace", selection: $authStore.selectedOwnerID) {
                ForEach(authStore.owners) { owner in
                    Label(owner.name, systemImage: owner.isTeam ? "person.3" : "person")
                        .tag(String?.some(owner.id))
                }
            }
        } label: {
            Label(selectedName, systemImage: "chevron.up.chevron.down")
                .labelStyle(.titleAndIcon)
                .font(.subheadline)
        }
    }

    private var selectedName: String {
        authStore.owners.first { $0.id == authStore.selectedOwnerID }?.name ?? "Workspace"
    }
}
