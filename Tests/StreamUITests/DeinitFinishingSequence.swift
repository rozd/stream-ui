import Foundation

/// Shaped like Firestore's `ListenerStream`: finishing the continuation in
/// `deinit` stands in for removing the snapshot listener.
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
