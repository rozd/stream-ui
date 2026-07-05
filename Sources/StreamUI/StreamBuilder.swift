import SwiftUI

/// Renders a `StreamValue` and drives its subscription.
///
/// The switch over `state` keeps the three cases explicit; the `.task(id:
/// runID)` ties the stream's lifetime to this view's identity — it starts on
/// appearance, is cancelled by SwiftUI on disappearance, and restarts when
/// `refresh()` bumps `runID` or a different `StreamValue` instance is passed.
///
/// The stream must be owned elsewhere (`@State` in a screen, or the
/// environment) — constructing one inline in a parent's `body` would restart
/// it on every render.
public struct StreamBuilder<
    ID: Equatable & Sendable,
    Data: Sendable,
    Empty: View,
    Value: View,
    Failure: View
>: View {

    private enum Source {
        case stream(StreamValue<Data>)
        case sequence(id: ID, make: (ID) -> any AsyncSequence<Data, any Error>)
    }

    private let source: Source

    private let empty: () -> Empty
    private let value: (Data) -> Value
    private let failure: (Error) -> Failure

    @State private var sequenceState: StreamState<Data> = .empty

    public init(
        _ stream: StreamValue<Data>,
        @ViewBuilder value: @escaping (Data) -> Value,
        @ViewBuilder empty: @escaping () -> Empty,
        @ViewBuilder error: @escaping (Error) -> Failure
    ) where ID == EmptyEquatable {
        self.source = .stream(stream)
        self.empty = empty
        self.value = value
        self.failure = error
    }

    /// Store-less rendering of a bare `AsyncSequence`, keyed by an `Equatable`
    /// id. `.task(id:)` restarts the sequence when the id changes. Use it when
    /// nothing needs to own or share the state and there is no retry/refresh
    /// requirement; use `StreamValue` when the store has a name, composition,
    /// helpers, or multiple observers.
    public init(
        id: ID,
        stream: @escaping (ID) -> any AsyncSequence<Data, any Error>,
        @ViewBuilder value: @escaping (Data) -> Value,
        @ViewBuilder empty: @escaping () -> Empty,
        @ViewBuilder error: @escaping (Error) -> Failure
    ) {
        self.source = .sequence(id: id, make: stream)
        self.empty = empty
        self.value = value
        self.failure = error
    }

    public var body: some View {
        switch source {
        case .stream(let stream):
            Group {
                switch stream.state {
                case .empty:
                    empty()
                case .value(let data):
                    value(data)
                case .error(let error):
                    failure(error)
                }
            }
            .observing(stream)
        case .sequence(let id, let make):
            Group {
                switch sequenceState {
                case .empty:
                    empty()
                case .value(let data):
                    value(data)
                case .error(let error):
                    failure(error)
                }
            }
            .task(id: id) {
                sequenceState = .empty
                await consumeSequence(from: { make(id) }) { sequenceState = $0 }
            }
        }
    }
}

extension StreamBuilder where ID == EmptyEquatable {

    public init(
        _ stream: @autoclosure @escaping () -> any AsyncSequence<Data, any Error>,
        @ViewBuilder value: @escaping (Data) -> Value,
        @ViewBuilder empty: @escaping () -> Empty,
        @ViewBuilder error: @escaping (Error) -> Failure,
    ) {
        self.init(id: EmptyEquatable(), stream: { _ in stream() }, value: value, empty: empty, error: error)
    }
}

public nonisolated struct EmptyEquatable: Equatable, Sendable {
    public init() {}
}

/// Consumes one sequence until it ends, fails, or the surrounding task is
/// cancelled, reporting each transition through `update`. The `StreamBuilder`
/// `.sequence` counterpart of `StreamValue.run()`.
@MainActor
func consumeSequence<T: Sendable>(
    from make: () -> any AsyncSequence<T, any Error>,
    update: (StreamState<T>) -> Void
) async {
    let stream = make()
    // Class-backed sequences (Firestore's ListenerStream) clean up in
    // deinit, and nothing retains them once the iterator is taken — pin
    // the sequence for the whole loop or the listener dies before the
    // first snapshot.
    defer { withExtendedLifetime(stream) {} }
    do {
        for try await item in stream {
            update(.value(item))
        }
    } catch {
        if !(error is CancellationError) {
            update(.error(error))
        }
    }
}

extension View {

    /// Keeps `stream` running while this view is on screen: sugar for
    /// `.task(id: stream.runID) { await stream.run() }`. Use it when a view
    /// reads `stream.state` directly instead of going through `StreamBuilder`.
    /// Accepts `nil` for streams created lazily after the first appearance.
    public func observing<T: Sendable>(_ stream: StreamValue<T>?) -> some View {
        task(id: stream?.runID) {
            await stream?.run()
        }
    }
}
