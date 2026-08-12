import Foundation

/// A throwaway `UserDefaults` suite, so persistence assertions can't leak between tests or into the
/// app's own defaults.
func makeTestDefaults(_ name: String = UUID().uuidString) -> UserDefaults {
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}
