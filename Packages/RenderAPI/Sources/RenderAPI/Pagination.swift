import Foundation

/// Walks a Render cursor-paginated collection.
///
/// Every list endpoint in the spec follows the same shape: the response is an array of
/// `{resource, cursor}` envelopes, and you resume by passing the *last* element's cursor. There is
/// no "hasMore" flag — a page shorter than the requested limit means you've reached the end.
///
/// This is generic over the envelope because the generator emits a distinct type per resource
/// (`ServiceWithCursor`, `DeployWithCursor`, …) with no shared protocol between them. Call sites
/// supply two closures to bridge: one to fetch a page, one to unwrap an envelope.
///
/// ```swift
/// let services = CursorPaginator(pageSize: 50) { cursor, limit in
///     try await client.api.listServices(query: .init(cursor: cursor, limit: limit))
///         .ok.body.json
/// } unwrap: { (element: Components.Schemas.ServiceWithCursor) in
///     (element.service, element.cursor)
/// }
/// for try await service in services { … }
/// ```
public struct CursorPaginator<Envelope: Sendable, Element: Sendable>: AsyncSequence, Sendable {
    public typealias FetchPage = @Sendable (_ cursor: String?, _ limit: Int) async throws -> [Envelope]
    public typealias Unwrap = @Sendable (Envelope) -> (element: Element, cursor: String)

    private let pageSize: Int
    private let fetchPage: FetchPage
    private let unwrap: Unwrap

    /// - Parameter pageSize: Sent as `limit`. Render caps this per endpoint; 100 is the common max.
    public init(
        pageSize: Int = 50,
        fetchPage: @escaping FetchPage,
        unwrap: @escaping Unwrap
    ) {
        self.pageSize = pageSize
        self.fetchPage = fetchPage
        self.unwrap = unwrap
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let pageSize: Int
        private let fetchPage: FetchPage
        private let unwrap: Unwrap

        private var buffer: [Element] = []
        private var bufferIndex = 0
        private var nextCursor: String?
        private var isExhausted = false

        init(pageSize: Int, fetchPage: @escaping FetchPage, unwrap: @escaping Unwrap) {
            self.pageSize = pageSize
            self.fetchPage = fetchPage
            self.unwrap = unwrap
        }

        public mutating func next() async throws -> Element? {
            while bufferIndex >= buffer.count {
                guard !isExhausted else { return nil }
                try Task.checkCancellation()

                let page: [Envelope]
                do {
                    page = try await fetchPage(nextCursor, pageSize)
                } catch {
                    throw RenderError.wrapping(error)
                }

                // A short page is the only end-of-collection signal Render gives us. An empty page
                // also ends iteration, which covers the case where the total is an exact multiple
                // of `pageSize`.
                if page.count < pageSize { isExhausted = true }
                guard !page.isEmpty else { return nil }

                let unwrapped = page.map(unwrap)
                buffer = unwrapped.map(\.element)
                bufferIndex = 0
                nextCursor = unwrapped.last?.cursor
            }

            defer { bufferIndex += 1 }
            return buffer[bufferIndex]
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(pageSize: pageSize, fetchPage: fetchPage, unwrap: unwrap)
    }
}

extension CursorPaginator {
    /// Collects the whole collection.
    ///
    /// - Parameter limit: Hard stop on total elements. Defaults to 1000 so a bug upstream — or a
    ///   workspace with far more resources than expected — can't spin forever.
    public func collect(limit: Int = 1000) async throws -> [Element] {
        var results: [Element] = []
        for try await element in self {
            results.append(element)
            if results.count >= limit { break }
        }
        return results
    }

    /// Fetches a single page and returns the cursor to resume from, for UI that pages on scroll
    /// rather than draining the whole collection up front.
    public func firstPage(after cursor: String? = nil) async throws -> (elements: [Element], nextCursor: String?) {
        let page: [Envelope]
        do {
            page = try await fetchPage(cursor, pageSize)
        } catch {
            throw RenderError.wrapping(error)
        }
        let unwrapped = page.map(unwrap)
        // Withhold the cursor on a short page so callers have the same end-of-collection signal
        // the iterator uses.
        let next = page.count < pageSize ? nil : unwrapped.last?.cursor
        return (unwrapped.map(\.element), next)
    }
}
