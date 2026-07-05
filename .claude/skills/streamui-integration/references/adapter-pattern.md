# Writing an `AsyncSequence` adapter

StreamUI consumes `any AsyncSequence<T, any Error> & Sendable` — it has no opinion
about where that sequence comes from. Turning a real backend (a listener API, a
delegate callback, a Combine publisher, a poll loop) into one is always application
code. Two shapes cover almost everything.

## Shape 1: a plain callback source — `AsyncThrowingStream.makeStream()`

If the backend hands you values through a callback and has its own explicit
start/stop calls, wrap it directly:

```swift
func notificationsStream(for userId: UserId) -> AsyncThrowingStream<[Notification], Error> {
    let (stream, continuation) = AsyncThrowingStream.makeStream(of: [Notification].self)
    let subscription = NotificationsSDK.subscribe(userId: userId) { result in
        switch result {
        case .success(let value): continuation.yield(value)
        case .failure(let error): continuation.finish(throwing: error)
        }
    }
    continuation.onTermination = { _ in subscription.cancel() }
    return stream
}
```

`onTermination` fires when the consumer stops iterating for any reason (the
surrounding task is cancelled, or the stream finishes) — that's your one guaranteed
teardown hook for this shape. `AsyncThrowingStream` itself is safe to return
directly from a `makeStream()` override or a factory closure; nothing about it
depends on a class deiniting at the right moment.

**One Swift 6 strict-concurrency snag this example glosses over:** `onTermination`
is `@Sendable`, but the token/handle most subscribe-style SDKs hand back (here,
whatever `NotificationsSDK.subscribe` returns) usually isn't `Sendable` — so
capturing it directly in that closure is a compile error under strict
concurrency, not just a warning. Cancelling a subscription handle from an
arbitrary context is normally safe (it's a teardown call, not a data race), so vouch
for that explicitly with a small unchecked box instead of forcing a `Sendable`
conformance onto a type you don't own:

```swift
private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
}
// ...
let box = UncheckedSendableBox(subscription)
continuation.onTermination = { _ in box.value.cancel() }
```

This is a one-time seam, not a pattern to repeat elsewhere — it belongs at the
exact point a non-`Sendable` SDK type crosses into a `@Sendable` closure, and
nowhere else.

## Shape 2: a class-backed listener that tears down in `deinit`

Some SDKs (Firestore's `addSnapshotListener`, a HealthKit `HKAnchoredObjectQuery`,
anything with an explicit "remove observer" call) are more naturally wrapped as a
small class: it starts the subscription in `init`, forwards values through a
continuation, and calls the SDK's teardown in `deinit` — because `deinit` is the one
place guaranteed to run when nothing needs the sequence anymore, regardless of *how*
consumption ends (normal finish, error, or cancellation).

```swift
final class ListenerSequence<T: Sendable>: AsyncSequence, @unchecked Sendable {
    typealias AsyncIterator = AsyncThrowingStream<T, Error>.AsyncIterator

    private let stream: AsyncThrowingStream<T, Error>
    private let continuation: AsyncThrowingStream<T, Error>.Continuation
    private let listenerHandle: ListenerRegistration

    init(query: SomeQuery) {
        let (stream, continuation) = AsyncThrowingStream<T, Error>.makeStream()
        self.stream = stream
        self.continuation = continuation
        self.listenerHandle = query.addListener { result in
            switch result {
            case .success(let value): continuation.yield(value)
            case .failure(let error): continuation.finish(throwing: error)
            }
        }
    }

    deinit { listenerHandle.remove() }   // the guaranteed teardown hook

    func makeAsyncIterator() -> AsyncIterator { stream.makeAsyncIterator() }
}
```

This shape has one sharp edge, and it's the reason DESIGN.md's "Sequence lifetime"
section exists: **iterators do not retain the sequence they came from.** A mapped
chain like `ListenerSequence(query: q).map { ... }` is a *struct* wrapping a class —
once you call `makeAsyncIterator()` on it and stop holding the struct itself,
nothing keeps `ListenerSequence` alive. If the temporary is deallocated right after
the iterator is produced, `deinit` fires, the listener is removed, and the sequence
silently never delivers a first value. It's a real, previously-hit bug in this
package's own history (symptom: infinite loading, zero errors, no listener ever
actually opened) — see DESIGN.md §"Sequence lifetime" for the verified experiment.

**When you consume this shape through `StreamValue`, you don't need to do anything
extra** — `StreamValue.run()` already does:

```swift
let stream = makeStream()
defer { withExtendedLifetime(stream) {} }
for try await value in stream { … }
```

which pins the sequence for the whole loop. This is one more reason to prefer a
`StreamValue`-backed store (Step 4 in `SKILL.md`) over the bare
`StreamBuilder(id:stream:)` initializer whenever your adapter is class-backed:
`StreamBuilder`'s id-keyed variant iterates its sequence directly
(`for try await item in make(id) { ... }`, StreamBuilder.swift) with no equivalent
pin, which reproduces the exact pattern DESIGN.md calls "BROKEN — do not simplify to
this." Until that's addressed upstream, treat `StreamBuilder(id:stream:)` as safe
only for sequences that don't rely on class-based deinit cleanup (plain
`AsyncThrowingStream`s from Shape 1, `URLSession.bytes(for:)`, etc.) — route
anything class-backed through a named `StreamValue` store instead, even if you
don't otherwise need a name, retry, or sharing.

## A smaller related fact worth knowing

Breaking out of a `for await` loop early (`break`) does **not** terminate the
underlying `AsyncStream`/`AsyncThrowingStream` — a later iteration of the *same*
stream value would still receive new elements. Only **cancelling the task** that's
parked on the loop terminates it (and fires `onTermination`/triggers your `deinit`).
If you're tempted to write your own retry/resubscribe loop instead of using
`refresh()`, this is the trap that bit StreamUI's v1: a resubscribe loop parked on a
stream that had already been silently killed by a cancellation degenerates into a
tight, UI-invisible spin. `refresh()` sidesteps this entirely by not looping at all
— it just changes `runID` and lets SwiftUI's structured `.task(id:)` do a clean
cancel-and-restart.
