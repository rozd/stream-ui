import Testing
import Foundation
@testable import StreamUI

@MainActor
@Suite("StreamBuilder")
struct StreamBuilderTests {

    struct TestError: Error {}

    // MARK: - Sequence lifetime

    @Test("keeps a class-backed sequence alive for the whole run")
    func retainsClassBackedSequence() async throws {
        // Mirrors StreamValueTests.retainsClassBackedSequence for the
        // store-less `StreamBuilder(id:stream:)` path: without the pin in
        // `consumeSequence`, the wrapper deallocates right after the iterator
        // is taken, its deinit finishes the stream, and the delayed value
        // never arrives.
        var states: [StreamState<Int>] = []
        await consumeSequence(from: {
            let (stream, continuation) = AsyncThrowingStream<Int, any Error>.makeStream()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                continuation.yield(42)
                continuation.finish()
            }
            return DeinitFinishingSequence(stream: stream, continuation: continuation)
        }) { states.append($0) }
        #expect(states.contains { $0.data == 42 })
    }

    @Test("a failing sequence reports .error, cancellation reports nothing")
    func failureBecomesError() async throws {
        var states: [StreamState<Int>] = []
        await consumeSequence(from: {
            AsyncThrowingStream<Int, any Error> { continuation in
                continuation.yield(1)
                continuation.finish(throwing: TestError())
            }
        }) { states.append($0) }
        #expect(states.first?.data == 1)
        #expect(states.count == 2)
        if case .error = states.last {} else {
            Issue.record("expected .error, got \(String(describing: states.last))")
        }
    }
}
