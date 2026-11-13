/// A pushed service-detail screen, as a value.
///
/// The list used to push `ServiceDetailView` from inside its `NavigationLink`, which is simpler
/// right up until something other than a tap has to navigate. A tapped failure notification does:
/// it knows a service ID and a name and nothing else, and the service it names may not be in any
/// page the list has loaded. Carrying the destination as a value means the same push works whether
/// it came from a row or from the lock screen.
///
/// The name is part of the route because ``ServiceDetailView`` shows it as the title until the
/// detail request lands — without it the screen opens blank-titled.
struct ServiceRoute: Hashable, Sendable {
    let id: String
    let name: String
}

/// One event, pushed above its service by a tapped failure notification. Only the ID: the event
/// screen fetches the rest, since a notification carries no more than that.
struct EventRoute: Hashable, Sendable {
    let id: String
}
