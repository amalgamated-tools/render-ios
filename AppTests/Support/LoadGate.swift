import Foundation

/// Holds requests until it opens, so a test can act while they're in flight.
actor LoadGate {
    private var entered = 0
    private var isOpen = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var enteredWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func hold() async {
        entered += 1
        enteredWaiters.removeAll { waiter in
            guard entered >= waiter.count else { return false }
            waiter.continuation.resume()
            return true
        }
        guard !isOpen else { return }
        await withCheckedContinuation { held.append($0) }
    }

    func waitUntilEntered(count: Int) async {
        guard entered < count else { return }
        await withCheckedContinuation { enteredWaiters.append((count, $0)) }
    }

    func open() {
        isOpen = true
        held.forEach { $0.resume() }
        held = []
    }
}
