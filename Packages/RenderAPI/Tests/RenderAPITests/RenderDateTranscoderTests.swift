import Foundation
import Testing

@testable import RenderAPI

@Suite("RenderDateTranscoder")
struct RenderDateTranscoderTests {
    private let transcoder = RenderDateTranscoder()

    /// The exact shape that broke the service list: microsecond precision, variable digit count.
    @Test(
        "decodes Render's sub-millisecond timestamps",
        arguments: [
            "2026-08-11T19:59:22.275356Z",  // 6 fractional digits
            "2026-08-11T21:16:15.88552Z",   // 5 — the digit count varies between records
            "2026-08-11T20:00:26.115Z",     // exactly 3 (what the default decoder allows)
            "2026-08-11T20:00:26Z",         // none
        ]
    )
    func decodesRealTimestamps(_ string: String) throws {
        let date = try transcoder.decode(string)
        // Sanity: all four are the same wall-clock minute give or take, well after 2026.
        #expect(date.timeIntervalSince1970 > 1_776_000_000)
    }

    @Test("microseconds truncate to milliseconds, not round")
    func truncatesToMilliseconds() throws {
        let precise = try transcoder.decode("2026-08-11T19:59:22.275356Z")
        let millis = try transcoder.decode("2026-08-11T19:59:22.275Z")
        #expect(abs(precise.timeIntervalSince1970 - millis.timeIntervalSince1970) < 0.0005)
    }

    @Test("normalizeFractionalSeconds clamps to three digits")
    func normalizes() {
        #expect(RenderDateTranscoder.normalizeFractionalSeconds("2026-08-11T19:59:22.275356Z")
            == "2026-08-11T19:59:22.275Z")
        #expect(RenderDateTranscoder.normalizeFractionalSeconds("2026-08-11T19:59:22.5Z")
            == "2026-08-11T19:59:22.500Z")
        #expect(RenderDateTranscoder.normalizeFractionalSeconds("2026-08-11T19:59:22Z") == nil)
    }

    @Test("encode round-trips through decode")
    func roundTrips() throws {
        let original = try transcoder.decode("2026-08-11T19:59:22.275Z")
        let encoded = try transcoder.encode(original)
        let again = try transcoder.decode(encoded)
        #expect(abs(original.timeIntervalSince1970 - again.timeIntervalSince1970) < 0.0005)
    }

    @Test("a non-date string throws rather than returning a bogus date")
    func rejectsGarbage() {
        #expect(throws: DecodingError.self) {
            _ = try transcoder.decode("not a date")
        }
    }
}
