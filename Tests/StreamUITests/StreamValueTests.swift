import Testing
import Foundation
import Observation
@testable import StreamUI

@MainActor
@Suite("StreamValue")
struct StreamValueTests {

    struct TestError: Error {}

    /// Produces a fresh stream per factory invocation — like a real factory —
    /// and keeps each run's continuation so tests can drive emissions.
    @MainActor
    final class Feed<T: Sendable> {
        private(set) var continuations: [AsyncThrowingStream<T, any Error>.Continuation] = []

        var latest: AsyncThrowingStream<T, any Error>.Continuation {
            continuations.last!
        }

        func make() -> any AsyncSequence<T, any Error> & Sendable {
            let (stream, continuation) = AsyncThrowingStream<T, any Error>.makeStream()
            continuations.append(continuation)
            return stream
        }
    }

    // MARK: - Delivery

    @Test("delivers values and keeps the last one when the stream ends")
    func deliversValuesAndKeepsLast() async throws {
        let feed = Feed<Int>()
        let value = StreamValue<Int> { feed.make() }

        let run = Task { await value.run() }
        try await eventually { feed.continuations.count == 1 }

        feed.latest.yield(1)
        try await eventually { value.state.data == 1 }

        feed.latest.yield(2)
        try await eventually { value.state.data == 2 }

        feed.latest.finish()
        await run.value
        #expect(value.state.data == 2)
    }

    @Test("a stream failure becomes .error")
    func failureBecomesError() async throws {
        let feed = Feed<Int>()
        let value = StreamValue<Int> { feed.make() }

        let run = Task { await value.run() }
        try await eventually { feed.continuations.count == 1 }

        feed.latest.finish(throwing: TestError())
        await run.value
        #expect(isError(value.state))
    }

    // MARK: - Refresh

    @Test("refresh() clears the state and changes runID")
    func refreshClearsAndChangesRunID() async throws {
        let feed = Feed<Int>()
        let value = StreamValue<Int> { feed.make() }

        let run = Task { await value.run() }
        try await eventually { feed.continuations.count == 1 }
        feed.latest.yield(1)
        try await eventually { value.state.data == 1 }

        let before = value.runID
        value.refresh()

        #expect(value.runID != before)
        #expect(value.state.data == nil)

        run.cancel()
        await run.value
    }

    @Test("a stale run cannot write after refresh()")
    func staleRunCannotWrite() async throws {
        let feed = Feed<Int>()
        let value = StreamValue<Int> { feed.make() }

        let staleRun = Task { await value.run() }
        try await eventually { feed.continuations.count == 1 }
        feed.latest.yield(1)
        try await eventually { value.state.data == 1 }

        value.refresh()

        // The stale run's stream emits before SwiftUI has cancelled it — the
        // generation guard must drop the write and end the run.
        feed.continuations[0].yield(99)
        await staleRun.value
        #expect(value.state.data == nil)
    }

    // MARK: - Re-appearance

    @Test("re-running keeps the last value while resubscribing")
    func rerunKeepsLastValue() async throws {
        let feed = Feed<Int>()
        let value = StreamValue<Int> { feed.make() }

        let firstRun = Task { await value.run() }
        try await eventually { feed.continuations.count == 1 }
        feed.latest.yield(5)
        try await eventually { value.state.data == 5 }

        // View disappears: SwiftUI cancels the task.
        firstRun.cancel()
        await firstRun.value

        // View re-appears: same runID, new run. No loading flash.
        let secondRun = Task { await value.run() }
        try await eventually { feed.continuations.count == 2 }
        #expect(value.state.data == 5)

        feed.latest.yield(6)
        try await eventually { value.state.data == 6 }

        secondRun.cancel()
        await secondRun.value
    }

    @Test("re-running after an error starts from .empty and can recover")
    func rerunAfterErrorRecovers() async throws {
        let feed = Feed<Int>()
        let value = StreamValue<Int> { feed.make() }

        let failedRun = Task { await value.run() }
        try await eventually { feed.continuations.count == 1 }
        feed.latest.finish(throwing: TestError())
        await failedRun.value
        #expect(isError(value.state))

        let retryRun = Task { await value.run() }
        try await eventually { feed.continuations.count == 2 }
        #expect(!isError(value.state))

        feed.latest.yield(7)
        try await eventually { value.state.data == 7 }

        retryRun.cancel()
        await retryRun.value
    }

    // MARK: - Patch

    @Test("patch() transforms the current value and is a no-op before one exists")
    func patchTransformsValue() async throws {
        let feed = Feed<Int>()
        let value = StreamValue<Int> { feed.make() }

        value.patch { $0 + 1 }
        #expect(value.state.data == nil)

        let run = Task { await value.run() }
        try await eventually { feed.continuations.count == 1 }
        feed.latest.yield(1)
        try await eventually { value.state.data == 1 }

        value.patch { $0 + 1 }
        #expect(value.state.data == 2)

        // A patch is ephemeral: the next emission replaces it.
        feed.latest.yield(10)
        try await eventually { value.state.data == 10 }

        run.cancel()
        await run.value
    }

    @Test("a throwing patch becomes .error")
    func throwingPatchBecomesError() async throws {
        let feed = Feed<Int>()
        let value = StreamValue<Int> { feed.make() }

        let run = Task { await value.run() }
        try await eventually { feed.continuations.count == 1 }
        feed.latest.yield(1)
        try await eventually { value.state.data == 1 }

        value.patch { _ in throw TestError() }
        #expect(isError(value.state))

        run.cancel()
        await run.value
    }

    // MARK: - Sequence lifetime

    @Test("keeps a class-backed sequence alive for the whole run")
    func retainsClassBackedSequence() async throws {
        // Mirrors Firestore's ListenerStream: a class wrapper that finishes
        // its stream in deinit. If run() doesn't keep the sequence alive while
        // iterating, the wrapper deallocates right after the iterator is taken
        // and the stream dies before the first value arrives.
        let value = StreamValue<Int> {
            let (stream, continuation) = AsyncThrowingStream<Int, any Error>.makeStream()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                continuation.yield(42)
            }
            return DeinitFinishingSequence(stream: stream, continuation: continuation)
        }

        let run = Task { await value.run() }
        try await eventually { value.state.data == 42 }

        run.cancel()
        await run.value
    }

    // MARK: - Subclass parameters

    @Test("makeStream() subclasses rebuild the stream from current properties")
    func makeStreamReadsCurrentParameters() async throws {
        let value = ParameterizedValue()

        let firstRun = Task { await value.run() }
        try await eventually { value.streamedParameters == [1] }
        try await eventually { value.state.data == 1 }

        value.parameter = 2  // didSet calls refresh()
        await firstRun.value // its short stream has already finished

        let secondRun = Task { await value.run() }
        try await eventually { value.streamedParameters == [1, 2] }
        try await eventually { value.state.data == 2 }

        secondRun.cancel()
        await secondRun.value
    }

    // MARK: - Helpers

    private func eventually(
        timeout: Duration = .seconds(2),
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(condition(), sourceLocation: sourceLocation)
    }

    private func isError<T>(_ state: StreamState<T>) -> Bool {
        if case .error = state { return true }
        return false
    }
}

// MARK: - Parameterized subclass fixture

@MainActor
@Observable
private final class ParameterizedValue: StreamValue<Int> {

    var parameter: Int = 1 {
        didSet { refresh() }
    }

    /// Records the parameter each stream was built with.
    @ObservationIgnored
    private(set) var streamedParameters: [Int] = []

    init() {
        super.init()
    }

    override func makeStream() -> S {
        streamedParameters.append(parameter)
        let (stream, continuation) = AsyncThrowingStream<Int, any Error>.makeStream()
        continuation.yield(parameter)
        continuation.finish()
        return stream
    }
}
