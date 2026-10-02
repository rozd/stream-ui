import Observation
import Synchronization

/// Identity of one stream run: which `StreamValue` instance, and which
/// generation of it. Used as the `id` of the `.task(id:)` that drives the run,
/// so SwiftUI restarts the subscription when either changes.
public nonisolated struct StreamRunID: Hashable, Sendable {
    fileprivate let object: ObjectIdentifier
    fileprivate let generation: Int
}

/// A snapshot of a stream's latest element: `.empty` until the first value,
/// then `.value` / `.error`.
public enum StreamState<Value: Sendable>: Sendable {
    case empty
    case value(Value)
    case error(Error)
}

extension StreamState {

    public var data: Value? {
        if case .value(let data) = self {
            return data
        }
        return nil
    }
}

extension StreamState {

    public func when<R>(
        value: (Value) -> R,
        error: (Error) -> R,
        empty: () -> R,
    ) -> R {
        switch self {
        case .value(let data):
            return value(data)
        case .error(let e):
            return error(e)
        case .empty:
            return empty()
        }
    }

    public func maybeWhen<R>(
        value: ((Value) -> R)?,
        error: ((Error) -> R)?,
        empty: (() -> R)?,
        orElse: @escaping () -> R
    ) -> R {
        return when(
            value: value ?? { _ in orElse() },
            error: error ?? { _ in orElse() },
            empty: empty ?? { orElse() },
        )
    }

    public func whenValue<R>(
        _ convert: (Value) throws -> R,
    ) -> StreamState<R> {
        switch self {
        case .value(let v):
            do {
                return .value(try convert(v))
            } catch {
                return .error(error)
            }
        case .empty:
            return .empty
        case .error(let e):
            return .error(e)
        }
    }
}

/// An observable holder for the latest element of an `AsyncSequence`.
///
/// `StreamValue` owns no tasks. Views drive it with structured concurrency —
/// through `StreamBuilder` or the `View.observing(_:)` modifier — both of which
/// call `run()` from a `.task(id: runID)`. The subscription therefore lives
/// exactly as long as the view is on screen, restarts when `refresh()` bumps
/// `runID`, and is cancelled by SwiftUI when the view disappears.
///
/// Rules of the road:
/// - `state` is written by the stream; the only local escape hatch is
///   `patch(_:)`, and its effect lasts only until the next emission. State that
///   must survive emissions (purchase progress, form status) belongs in
///   separate properties beside `state`, not inside it.
/// - Re-appearing keeps the last value (no loading flash); `refresh()` clears
///   it deliberately.
/// - One observer per instance. Attach `StreamBuilder` / `.observing` once,
///   near the store's owner, and hand child views the store itself. A second
///   concurrent run of the same generation would start a duplicate
///   subscription racing the first for `state`; it trips an
///   `assertionFailure` in debug builds.
@MainActor
@Observable
open class StreamValue<T: Sendable> {

    public typealias S = any AsyncSequence<T, any Error> & Sendable

    /// The latest snapshot of the stream: `.empty` until the first element,
    /// then `.value` / `.error`.
    public private(set) var state: StreamState<T> = .empty

    /// Monotonic run counter; part of `runID`. Observed (not ignored) so that
    /// bumping it invalidates any `.task(id: runID)` and restarts the run.
    private var generation = 0

    /// Runs currently consuming a stream. Used only to detect a second
    /// observer; a run whose task was cancelled (view gone, `refresh()`) may
    /// still be draining and does not count.
    @ObservationIgnored
    private var liveRuns: [RunToken] = []

    /// Called when a second live run of the current generation starts.
    /// Internal so tests can observe the check without crashing.
    @ObservationIgnored
    var onDuplicateObserver: (String) -> Void = { assertionFailure($0) }

    @ObservationIgnored
    private let factory: (@MainActor () -> S)?

    /// Creates a value driven by the given stream factory. The factory is
    /// re-invoked on every run — first appearance and each `refresh()` — so it
    /// must build a fresh sequence each time. Subclasses that build the
    /// sequence from their own properties pass no factory and override
    /// `makeStream()` instead (see the `Scheduler` pattern in DESIGN.md).
    public init(_ factory: (@MainActor () -> S)? = nil) {
        self.factory = factory
    }

    /// Builds the sequence consumed by `run()`. The default implementation
    /// returns the factory's stream; subclasses with mutable parameters
    /// override this and call `refresh()` when a parameter changes.
    open func makeStream() -> S {
        guard let factory else {
            preconditionFailure("Provide a factory stream or override makeStream()")
        }
        return factory()
    }

    /// Identity of the current run. Drives `.task(id:)` restarts.
    public var runID: StreamRunID {
        StreamRunID(object: ObjectIdentifier(self), generation: generation)
    }

    /// Consumes one stream until it ends, fails, or the surrounding task is
    /// cancelled. Call it from `.task(id: runID)` (`StreamBuilder` and
    /// `View.observing(_:)` do), not from free-running `Task`s — cancellation
    /// and restarts are the caller's job, delegated to SwiftUI.
    public func run() async {
        let expected = generation
        let token = RunToken(generation: expected)
        if liveRuns.contains(where: { $0.generation == expected && !$0.isCancelled }) {
            onDuplicateObserver(
                "StreamValue<\(T.self)> is observed by more than one view at once. "
                + "Each observer runs its own subscription and they race for `state`. "
                + "Attach StreamBuilder / .observing(_:) once and pass the store down."
            )
        }
        liveRuns.append(token)
        defer { liveRuns.removeAll { $0 === token } }
        await withTaskCancellationHandler {
            await consume(expected: expected)
        } onCancel: {
            token.cancel()
        }
    }

    private func consume(expected: Int) async {
        if case .error = state {
            // A fresh appearance retries a failed stream from scratch.
            state = .empty
        }
        let stream = makeStream()
        // Defense-in-depth, adapter-agnostic: an AsyncThrowingStream (or any
        // sequence) terminates when the last reference to its shared context —
        // the sequence value and its iterators — is released. Iterators alone
        // do not retain the sequence they came from, so a chain of `map`/
        // `flatMap` around a temporary can drop the last strong reference the
        // moment the iterator is taken. Pinning the sequence for the whole loop
        // keeps it alive regardless of adapter shape. Class-backed sequences
        // that clean up in `deinit` remain fundamentally unsafe once composed
        // under operators — see DESIGN.md §Sequence lifetime.
        defer { withExtendedLifetime(stream) {} }
        do {
            for try await value in stream {
                guard generation == expected, !Task.isCancelled else { return }
                state = .value(value)
            }
            // Stream ended normally: keep the last value.
        } catch is CancellationError {
            // Structured cancellation — the view went away or runID changed.
        } catch {
            guard generation == expected, !Task.isCancelled else { return }
            state = .error(error)
        }
    }

    /// Restarts the stream from scratch: clears the current state and bumps
    /// `runID`, which makes every observing `.task(id:)` cancel its run and
    /// start a new one. Use for error-view retry buttons and parameter changes.
    public func refresh() {
        state = .empty
        generation += 1
    }

    /// Locally overrides the current `.value` payload — for optimistic UI
    /// (selection, transient feedback) pending a durable write that the stream
    /// echoes back. The override is ephemeral: the next emission replaces it.
    /// No-op until the first value arrives; a thrown error becomes `.error`.
    public func patch(_ transform: (T) throws -> T) {
        guard case .value(let current) = state else { return }
        do {
            state = .value(try transform(current))
        } catch {
            state = .error(error)
        }
    }
}

/// Liveness marker for one `run()`. The cancellation flag is set from the
/// task's cancellation handler, which may fire on any thread, hence atomic.
private final class RunToken: Sendable {
    let generation: Int
    private let cancelled = Atomic<Bool>(false)

    init(generation: Int) { self.generation = generation }

    var isCancelled: Bool { cancelled.load(ordering: .acquiring) }
    func cancel() { cancelled.store(true, ordering: .releasing) }
}
