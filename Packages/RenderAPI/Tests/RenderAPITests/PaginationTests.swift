import Foundation
import Testing

@testable import RenderAPI

@Suite("CursorPaginator")
struct PaginationTests {
    /// Stands in for the generated `*WithCursor` envelopes, which share a shape but no protocol.
    private struct Envelope: Sendable {
        let value: Int
        let cursor: String
    }

    /// Serves `total` elements in pages of `pageSize`, recording the cursors it was asked for.
    private actor Source {
        let total: Int
        private(set) var requestedCursors: [String?] = []

        init(total: Int) { self.total = total }

        func page(after cursor: String?, limit: Int) -> [Envelope] {
            requestedCursors.append(cursor)
            let start = cursor.flatMap(Int.init).map { $0 + 1 } ?? 0
            let end = min(start + limit, total)
            guard start < end else { return [] }
            return (start..<end).map { Envelope(value: $0, cursor: String($0)) }
        }
    }

    private func paginator(over source: Source, pageSize: Int) -> CursorPaginator<Envelope, Int> {
        CursorPaginator(pageSize: pageSize) { cursor, limit in
            await source.page(after: cursor, limit: limit)
        } unwrap: { envelope in
            (envelope.value, envelope.cursor)
        }
    }

    @Test("a short final page ends iteration")
    func shortPageTerminates() async throws {
        let source = Source(total: 7)
        let all = try await paginator(over: source, pageSize: 3).collect()
        #expect(all == Array(0..<7))
        // 3 + 3 + 1: the short third page ends it, so there is no wasted fourth request.
        #expect(await source.requestedCursors == [nil, "2", "5"])
    }

    /// The case a `hasMore` flag would handle for free, and a cursor API doesn't: the total is an
    /// exact multiple of the page size, so the last full page looks like there's more to come.
    @Test("an exact multiple of pageSize requires one extra empty page")
    func exactMultipleTerminates() async throws {
        let source = Source(total: 6)
        let all = try await paginator(over: source, pageSize: 3).collect()
        #expect(all == Array(0..<6))
        #expect(await source.requestedCursors == [nil, "2", "5"])
    }

    @Test("an empty collection yields nothing")
    func emptyCollection() async throws {
        let source = Source(total: 0)
        let all = try await paginator(over: source, pageSize: 3).collect()
        #expect(all.isEmpty)
        #expect(await source.requestedCursors == [nil])
    }

    @Test("a single page shorter than the limit makes exactly one request")
    func singlePage() async throws {
        let source = Source(total: 2)
        let all = try await paginator(over: source, pageSize: 50).collect()
        #expect(all == [0, 1])
        #expect(await source.requestedCursors == [nil])
    }

    @Test("collect(limit:) stops early")
    func collectRespectsLimit() async throws {
        let source = Source(total: 1000)
        let all = try await paginator(over: source, pageSize: 10).collect(limit: 25)
        #expect(all.count == 25)
    }

    @Test("firstPage returns a resumable cursor, and nil at the end")
    func firstPageCursor() async throws {
        let source = Source(total: 7)
        let paginator = paginator(over: source, pageSize: 3)

        let first = try await paginator.firstPage()
        #expect(first.elements == [0, 1, 2])
        #expect(first.nextCursor == "2")

        let second = try await paginator.firstPage(after: first.nextCursor)
        #expect(second.elements == [3, 4, 5])
        #expect(second.nextCursor == "5")

        let third = try await paginator.firstPage(after: second.nextCursor)
        #expect(third.elements == [6])
        // Short page — withholding the cursor tells the UI to stop paging.
        #expect(third.nextCursor == nil)
    }

    @Test("fetch errors are surfaced as RenderError")
    func errorsAreWrapped() async throws {
        struct Boom: Error {}
        let paginator = CursorPaginator<Envelope, Int>(pageSize: 10) { _, _ in
            throw Boom()
        } unwrap: { ($0.value, $0.cursor) }

        await #expect(throws: RenderError.self) {
            _ = try await paginator.collect()
        }
    }
}
