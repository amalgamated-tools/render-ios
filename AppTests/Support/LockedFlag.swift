import Foundation

/// A Bool a stub transport's route closure can read while the test flips it, to make a later
/// request fail after an earlier one succeeded.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
