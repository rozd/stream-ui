# API reference

Exact member tables for the four public types. This is denser than the walkthrough
in `SKILL.md` — come here when you need a precise signature or an edge case, not as
a first read.

## `StreamState<Value>`

```swift
public enum StreamState<Value: Sendable>: Sendable {
    case empty
    case value(Value)
    case error(Error)
}
```

| Member | Behavior |
|---|---|
| `data: Value?` | The payload, or `nil` in `.empty`/`.error`. |
| `when(value:error:empty:)` | Exhaustive fold into a single result type. |
| `maybeWhen(value:error:empty:orElse:)` | Partial fold — any case can be `nil`, falls back to `orElse()`. |
| `whenValue(_:)` | Maps the `.value` payload; a thrown transform becomes `.error`; `.empty`/`.error` pass through unchanged. |

These are ergonomics helpers. `StreamBuilder` itself doesn't use them — it switches
over `state` directly — so don't reach for `when`/`maybeWhen` unless you're building
your own rendering path outside `StreamBuilder`.

## `StreamValue<T>`

`@MainActor @Observable open class` — an observable holder for the latest element
of `any AsyncSequence<T, any Error> & Sendable` (aliased as `S`).

| Member | Behavior |
|---|---|
| `init(_ factory: (@MainActor () -> S)? = nil)` | Pass a factory that builds a **fresh** sequence on every call (first run and every `refresh()`), or pass nothing and override `makeStream()`. |
| `private(set) var state: StreamState<T>` | `.empty` until the first element. Written only by the stream; the sole local escape hatch is `patch`. |
| `func makeStream() -> S` | Builds the sequence `run()` consumes. Default returns the factory's stream, `preconditionFailure`s if there's neither a factory nor an override. Override in subclasses whose query depends on mutable properties — it's called fresh on every run, so it always reads current values. |
| `var runID: StreamRunID` | `ObjectIdentifier(self)` + a generation counter. This is the `id:` of the `.task(id:)` that drives `run()` — bumping generation (via `refresh()`) or swapping the store instance both change it and force a restart. |
| `func run() async` | Consumes one stream until it ends, throws, or the surrounding task is cancelled. **Call only from `.task(id: runID)`** — `StreamBuilder` and `.observing(_:)` do this for you; a free-running `Task { await store.run() }` has nothing to cancel it. Entering with a stale `.error` resets to `.empty` first (a fresh appearance visibly retries instead of showing a dead error screen). A normally-ending stream keeps its last value. |
| `func refresh()` | The one restart verb: clears `state` to `.empty`, bumps the generation. Every observing `.task(id:)` cancels and restarts, re-invoking the factory / `makeStream()`. Safe to call repeatedly, from anywhere, even with nothing currently observing — the next run just picks it up. |
| `func patch(_ transform: (T) throws -> T)` | Ephemeral local override of the current `.value` payload, for optimistic UI ahead of a durable write the stream will echo back. No-op in `.empty`/`.error`. A thrown transform becomes `.error`. **The next emission replaces the patch** — always pair with a durable write. |

### Re-appearance semantics (why keep-last, not reset-to-empty)

`run()` does **not** clear `state` on entry (except a stale `.error`). If it did,
every `NavigationStack` push/pop or tab switch — which cancels and restarts the
covered view's `.task` — would flash a loading spinner and force the underlying
listener to reconnect. Keeping the last value while the new subscription warms up is
the deliberate behavior; only a stale `.error` is cleared, so a fresh appearance
visibly retries instead of being stuck.

## `StreamBuilder<ID, Data, Empty, Value, Failure>`

```swift
StreamBuilder(stream) { data in … } empty: { … } error: { error in … }
```

Renders the exhaustive switch over `stream.state` and attaches `.observing(stream)`.
The `stream` argument must be owned elsewhere (`@State` in a screen, or the
environment) — constructing one inline in a parent's `body` builds a new instance
every render and restarts the subscription every time.

### `StreamBuilder(id:stream:...)` — store-less variant

```swift
StreamBuilder(id: orderId, stream: { id in OrdersAPI.stream(for: id) }) { order in
    …
} empty: { ProgressView() } error: { ErrorView(error: $0) }
```

`.task(id:)` restarts the sequence whenever `id` changes. No `StreamValue`
subclass, no `refresh()`, no sharing across views — pure "this id, this sequence,
restart on change." Prefer this over a `StreamValue` subclass when nothing needs a
name, composition, helpers, or more than one observer.

There is also an autoclosure overload, `StreamBuilder(_ stream: @autoclosure...)`,
for a bare sequence with no id at all — it's `StreamBuilder(id:stream:)` under the
hood with a constant id (`EmptyEquatable`), so the sequence only ever runs once per
view lifetime (no restart trigger).

## `View.observing(_:)`

```swift
List { /* reads stream.state directly */ }
    .observing(stream)   // sugar for .task(id: stream.runID) { await stream.run() }
```

Use this instead of `StreamBuilder` when a view renders `stream.state` itself (e.g.
as one section of a larger layout) rather than going through the three-way switch.
Accepts `nil`, enabling a lazily-created store:

```swift
@State private var upcoming: UpcomingWorkout?

var body: some View {
    content
        .task { if upcoming == nil { upcoming = UpcomingWorkout(user: user) } }
        .observing(upcoming)   // id flips nil -> a real RunID once the store exists; run starts
}
```

## `FutureValue<Params, Result>`

`@MainActor @Observable final class` — the write-path primitive: a one-shot async
operation with its own state machine, deliberately separate from `StreamValue`.

```swift
public enum State<Data: Sendable> {
    case initial
    case loading
    case success(Data)
    case failure(Error)
}
```

| Member | Behavior |
|---|---|
| `init(operation: @escaping (Params) async throws -> Result)` | The operation to run. |
| `private(set) var state: State<Result>` | Walks `.initial -> .loading -> .success/.failure`. |
| `func execute(_ params: Params)` | Cancels any in-flight run, sets `.loading`, starts a new `Task`. Not `async` — fire-and-forget from a button action. |
| `func reset()` | Cancels any in-flight run and returns to `.initial`. |
| `var isLoading: Bool` | `true` iff `state == .loading`. |
| `var data: Result?` | The `.success` payload, or `nil`. |

Unlike `StreamValue`, `FutureValue` keeps an **unstructured** `Task` internally, on
purpose: a button-triggered write (an Apple Pay charge, a submit) should not
necessarily die just because the view that started it was dismissed. `[weak self]`
inside the task prevents a retain cycle; `execute` cancelling the previous run
prevents overlapping writes from the same instance.

## Injecting operations (no dedicated type)

StreamUI does not ship a wrapper for injectable operations. Use a closure property:

```swift
@Observable
final class PurchasingMembership: StreamValue<State> {
    var submitPurchase: @MainActor (PurchaseRequest) async throws -> Receipt = { request in
        try await BillingAPI.purchase(request)
    }
}
// In a test: instance.submitPurchase = { _ in Receipt.fake }
```

**Name it differently from any method.** If `func purchase()` and `var purchase`
coexist, `purchase()` inside the store resolves to the method: silent infinite
recursion that compiles cleanly.

**Don't write a `@MainActor` closure literal as a default parameter value** — the
compiler rejects it (`default argument cannot be both main actor-isolated and
nonisolated`). Default to `nil` and construct it in the initializer body:

```swift
init(userId: String, deleteAccount: (@MainActor (String) async throws -> Void)? = nil) {
    self.deleteAccount = deleteAccount ?? { userId in
        try await AccountAPI.deleteAccount(userId: userId)
    }
}
```
