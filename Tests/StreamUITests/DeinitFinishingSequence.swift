import Foundation

/// Exercises the worst-case adapter shape: a class-backed sequence that
/// finishes its continuation in `deinit`, standing in for any listener wrapper
/// that ties teardown (removing a subscription, etc.) to `deinit`. Such
/// sequences must never be composed under `map`/`flatMap` — those operators
/// retain only the iterator they produce, not the sequence value, so the
/// moment nothing else holds the class instance, `deinit` fires and tears
/// down early. This fixture is consumed directly (never composed) to isolate
/// what `run()`'s `withExtendedLifetime` pin does and doesn't guarantee — see
/// DESIGN.md §Sequence lifetime.
nonisolated final class DeinitFinishingSequence: AsyncSequence, @unchecked Sendable {
    typealias AsyncIterator = AsyncThrowingStream<Int, any Error>.AsyncIterator

    private let stream: AsyncThrowingStream<Int, any Error>
    private let continuation: AsyncThrowingStream<Int, any Error>.Continuation

    init(
        stream: AsyncThrowingStream<Int, any Error>,
        continuation: AsyncThrowingStream<Int, any Error>.Continuation
    ) {
        self.stream = stream
        self.continuation = continuation
    }

    deinit {
        continuation.finish()
    }

    func makeAsyncIterator() -> AsyncIterator {
        stream.makeAsyncIterator()
    }
}
