# StreamUI

Reactive `AsyncSequence` → SwiftUI bindings built on structured concurrency.

StreamUI connects long-lived async sequences (Firestore snapshot listeners, HealthKit
streams, any `AsyncSequence`) to SwiftUI views with three guarantees:

1. **Views stay declarative** — a view renders an exhaustive `switch` over
   `empty | value | error`; it never manages subscriptions imperatively.
2. **Lifecycle is structured** — the kit owns **no** free-running `Task`s. Every
   subscription runs inside a SwiftUI `.task(id:)`, so it starts on appearance, is
   cancelled on disappearance, and restarts when its identity changes. There is nothing
   to leak and nothing to forget to cancel.
3. **One writer per state** — streamed state is written only by the stream. Local
   mutation goes through one named, deliberately-ephemeral seam (`patch`). Flow state
   that must survive stream emissions lives *beside* the streamed state, never inside it.

## Files

| File | Contents |
|---|---|
| `StreamValue.swift` | `StreamValue<T>` — the observable store; `StreamRunID`; top-level `StreamState<Value>` enum + helpers; `Binding` projections |
| `StreamBuilder.swift` | `StreamBuilder` — the rendering view (store-driven or id-keyed bare-`AsyncSequence` init); `View.observing(_:)` — the lifecycle modifier; `EmptyEquatable` |
| `FutureValue.swift` | `FutureValue<Params, Result>` — one-shot async operation with `initial/loading/success/failure` |
| `SideEffect.swift` | `SideEffect<Input, Output>` — injectable async operation run via `run(_:)` |

Companion (app-side, not part of this package): a Firestore→`AsyncSequence` adapter
(`.stream` on `Query` / `DocumentReference`) that this kit has no idea exists — the only
coupling is behavioral: the `withExtendedLifetime` pin in `run()` exists *for*
class-backed adapters like that one (see DESIGN.md §Sequence lifetime).

## Quick start

```swift
// 1. A store: name it after the data it streams. The factory closure is re-invoked
//    on every run (first appearance and each refresh()), so it must build a fresh
//    sequence each time.
@Observable
final class Memberships: StreamValue<[Membership]> {
    init(user: User) {
        super.init {
            user.infos
                .compactMap { $0?.id }
                .flatMap { userId in
                    Firestore.firestore()
                        .collection("users/\(userId)/memberships")
                        .stream
                        .map { @MainActor in try $0.documents.map { try $0.data(as: MembershipModel.self) } }
                        .map { @MainActor in try $0.map { try Membership(from: $0) } }
                }
        }
    }
}

// 2. A view: StreamBuilder renders the three states AND drives the subscription.
struct MembershipsScreen: View {
    @State private var memberships: Memberships   // view owns the store

    var body: some View {
        StreamBuilder(memberships) { memberships in
            List(memberships) { MembershipCard(membership: $0) }
        } empty: {
            ProgressView()
        } error: { error in
            NetworkErrorView(error: error) { memberships.refresh() }
        }
    }
}
```

No `observe()`, no `finish()`, no `onDisappear` — `StreamBuilder` attaches
`.task(id: stream.runID) { await stream.run() }` and SwiftUI does the rest.

## API reference

### `StreamValue<T>`

`@MainActor @Observable class` — an observable holder for the latest element of an
`AsyncSequence<T, any Error>`.

| Member | Role |
|---|---|
| `init(_ factory: (@MainActor () -> S)? = nil)` | `S = any AsyncSequence<T, any Error> & Sendable`. Pass a factory that builds a **fresh** sequence per call, or pass nothing and override `makeStream()`. |
| `private(set) var state: StreamState<T>` | `.empty` until the first element, then `.value(T)` / `.error(Error)`. Written by the stream; locally mutable only via `patch`. |
| `func makeStream() -> S` | Builds the sequence consumed by `run()`. Default returns the factory's stream (`preconditionFailure` if neither exists). Override in subclasses whose query depends on mutable properties — the override reads *current* property values on every run. |
| `var runID: StreamRunID` | Identity of the current run: `ObjectIdentifier(self)` + a generation counter. Drives `.task(id:)` restarts. The generation is an **observed** property on purpose — bumping it invalidates observing views. |
| `func run() async` | Consumes one stream until it ends, fails, or the surrounding task is cancelled. Call it **only** from `.task(id: runID)` (`StreamBuilder` / `.observing(_:)` do) — never from a free-running `Task`. Entering with a stale `.error` resets to `.empty` (a fresh appearance retries from scratch). A normally-ending stream keeps its last value. |
| `func refresh()` | The one restart verb: clears `state` to `.empty` and bumps the generation, which makes every observing `.task(id:)` cancel its run and start a new one (re-invoking the factory / `makeStream()`). Use for error-retry buttons and parameter changes. Safe to call any number of times, from any view, even while nothing is observing (the next run picks it up). |
| `func patch(_ transform: (T) throws -> T)` | Ephemeral local override of the current `.value` payload — for optimistic UI pending a durable write that the stream echoes back. No-op until the first value; a thrown error becomes `.error`. **The next emission replaces the patch** — pair it with a durable write. |
| `func binding<R>(_ keyPath: WritableKeyPath<T, R?>) -> Binding<R?>` | Two-way binding into the `.value` payload; writes go through `patch` (ephemeral). Reads return `nil` in `.empty` / `.error`. |
| `func binding<R>(_ keyPath: KeyPath<T, R>) -> Binding<R?>` | Read-only projection; `.constant(nil)` outside `.value`. |

#### `StreamState<Value>` helpers

- `data: Data?` — the payload, or `nil`.
- `when(value:error:empty:)` — exhaustive fold into a single result.
- `maybeWhen(value:error:empty:orElse:)` — partial fold with a fallback.
- `whenValue(_:)` — map the `.value` case (a thrown error becomes `.error`), pass
  `.empty`/`.error` through.

### `StreamBuilder`

```swift
StreamBuilder(stream) { data in … } empty: { … } error: { error in … }
```

Renders the switch over `stream.state` and attaches `.observing(stream)`. The stream
must be **owned elsewhere** (`@State` in a screen, or the environment) — constructing
one inline in a parent's `body` creates a new instance per render and restarts the
subscription every time.

### `View.observing(_:)`

```swift
List { /* reads stream.state directly */ }
    .observing(stream)          // sugar for .task(id: stream.runID) { await stream.run() }
```

For views that render `stream.state` themselves instead of going through
`StreamBuilder`. Accepts `nil`, which enables the lazily-created-store pattern:

```swift
@State private var upcoming: UpcomingWorkout?

var body: some View {
    content
        .task { if upcoming == nil { upcoming = UpcomingWorkout(user: user) } }
        .observing(upcoming)    // id flips nil → RunID when the store appears; run starts
}
```

### `StreamBuilder(id:stream:...)`

Store-less rendering of a bare `AsyncSequence`, keyed by an `Equatable` id:

```swift
StreamBuilder(id: workoutId, stream: { id in workoutStream(id) }) { workout in
    …
} empty: { ProgressView() } error: { NetworkErrorView(error: $0) }
```

`.task(id:)` restarts the sequence when the id changes. Use it when nothing needs to
own or share the state and there is no retry/refresh requirement; use `StreamValue`
when the store has a name, composition, helpers, or multiple observers.

### `FutureValue<Params, Result>`

`@MainActor @Observable` one-shot async operation: `execute(_ params:)` cancels any
in-flight run and moves `state` through `.initial → .loading → .success/.failure`;
`reset()` returns to `.initial`. Helpers: `isLoading`, `data`. This is the designated
write-path primitive — keep writes out of `StreamValue`s.

### `SideEffect<Input, Output>`

```swift
struct SideEffect<Input, Output> {
    let operation: (Input) async throws -> Output
    init(_ operation: @escaping (Input) async throws -> Output)
    func run(_ input: Input) async throws -> Output
}
// extension for Input == Void: func run() async throws -> Output
```

A generic, injectable async side effect. Stores expose them as `lazy var` members so
tests can swap the operation (see `PurchasingMembership.purchase` and its flow tests).

Side effects are invoked with an explicit `.run(_:)` — deliberately NOT
`callAsFunction`. With call syntax, a store method and a same-shaped side-effect var
(`func book()` + `lazy var book`) make `book()` inside the store resolve to the
*method* — silent infinite recursion that compiles cleanly. `book.run()` cannot
collide, which is what lets vars keep their natural bare-verb names.

## Patterns

### 1. Named store + `+Firestore` convenience init

Keep the store class (state shape, domain helpers) in `Feature.swift` and the stream
construction in `Feature+Firestore.swift`:

```swift
// Showcase.swift — pure shape
@Observable final class Showcase: StreamValue<Showcase.State> { }
extension Showcase { struct State { var studio: Studio; var plans: [Plan] = [] … } }

// Showcase+Firestore.swift — pure plumbing
extension Showcase {
    convenience init(studioId: StudioId) {
        self.init {
            combineLatest(studio(id: studioId), plans(studioId: studioId))
                .map { studio, plans in Showcase.State(studio: studio, plans: plans, …) }
        }
    }
}
```

Composition with AsyncAlgorithms (`combineLatest`, `flatMap` over the auth stream,
async `map`s that fan out extra fetches) all lives inside the factory. This is where
the AsyncSequence bet pays off — see `BookingWorkout+Firestore.swift` for a
four-stream `combineLatest`.

### 2. Parameterized store — override `makeStream()`

When the query depends on a mutable property, **do not** capture it in a factory
closure (init-parameter capture freezes the value forever — see DESIGN.md). Override
`makeStream()` so every run reads current values, and `refresh()` on change:

```swift
@Observable
final class Scheduler: StreamValue<[Session]> {
    let studioId: StudioId
    var date: Date {
        didSet {
            guard !Calendar.current.isDate(date, inSameDayAs: oldValue) else { return }
            refresh()          // task restarts → makeStream() reads the new date
        }
    }

    init(studioId: StudioId, date: Date) {
        self.studioId = studioId
        self.date = date
        super.init()           // no factory — makeStream() is the source
    }

    override func makeStream() -> S {
        Firestore.firestore()
            .collection("studios/\(studioId)/sessions")
            .whereField("date", isGreaterThanOrEqualTo: date.startOfDay)
            …
    }
}
```

The view just binds: `DatePicker("Date", selection: $scheduler.date)`. No dispatch
hacks; `didSet` runs in an action context.

### 3. Flow state beside the stream — the single-writer contract

State that must survive stream emissions (purchase progress, transient banners tied to
a flow) must **not** live inside the streamed payload — an emission would clobber it
mid-flow. Put it in separate observed properties on the store:

```swift
@Observable
final class PurchasingMembership: StreamValue<PurchasingMembership.State> {
    private(set) var status: Status = .idle     // survives emissions
    private(set) var feedback: Feedback?

    func purchase() async {
        guard status == .idle else { return }
        status = .purchasing
        do { try await purchase(); status = .purchased; feedback = .success(…) }
        catch is CancellationError { status = .idle }
        catch { status = .idle; feedback = .error(…) }
    }
}
```

Real failure this prevents: the backend writes the membership document *during* the
purchase, the memberships stream emits, and a streamed `status` would reset to idle
mid-flight. There is a regression test for exactly this
(`PurchasingMembershipFlowTests/streamEmissionDoesNotClobberStatus`).

### 4. Optimistic edits — `patch` + durable echo

`patch` is for local overrides that a durable write will echo back through the stream:

```swift
func select(studio: Studio) {
    patch { $0.copyWith(selectedStudio: studio) }               // instant UI
    UserDefaults.standard.lastSelectedStudioId = studio.id.description  // durable
}
```

The next Firestore emission rebuilds the state from the persisted preference, so the
patch and the echo agree. A patch **without** a durable echo silently disappears on
the next emission — that is by design.

### 5. Shared stores

A store injected via `.environment(…)` can be observed by several views
(`StreamBuilder` in each). Semantics: each observer runs its **own** subscription;
writes are identical and last-writer-wins. This is fine for idempotent sources
(Firestore shares the underlying watch channel across identical listeners), but prefer
one owner per store instance. Only the currently-visible observer keeps the
subscription alive — when all disappear, all runs are cancelled.

## Lifecycle cheat-sheet

| Event | What happens |
|---|---|
| View appears | `.task(id: runID)` fires → `run()` → factory/`makeStream()` → subscribe |
| View disappears | SwiftUI cancels the task → sequence terminates → listener removed |
| View re-appears | New run; **last value kept** (no loading flash); stale `.error` cleared to `.empty` |
| `refresh()` | `state = .empty`, generation += 1 → every observing task restarts |
| Different store instance passed to `StreamBuilder` | `ObjectIdentifier` part of `runID` changes → restart |
| Stream ends normally | `run()` returns; last value kept |
| Stream throws | `state = .error` (guarded: stale-generation and cancelled runs cannot write) |

## Testing

`Tests/StreamUITests/StreamValueTests.swift` is the reference suite. The three
reusable fixtures:

```swift
// Fresh stream per factory call, continuations kept for driving emissions.
@MainActor final class Feed<T: Sendable> {
    private(set) var continuations: [AsyncThrowingStream<T, any Error>.Continuation] = []
    var latest: … { continuations.last! }
    func make() -> any AsyncSequence<T, any Error> & Sendable { … }
}

// Poll-until helper (everything is MainActor-cooperative).
func eventually(timeout: Duration = .seconds(2), _ condition: @MainActor () -> Bool) async throws

// Mimics Firestore's ListenerStream: finishes its stream in deinit.
// Guards the withExtendedLifetime pin in run() — see DESIGN.md §Sequence lifetime.
final class DeinitFinishingSequence: AsyncSequence, @unchecked Sendable { … }
```

Covered behaviors: delivery + keep-last-on-end, failure → `.error`, `refresh()` resets
state and changes `runID`, stale-generation writes dropped, keep-last-value across
re-runs, error → `.empty` on re-run + recovery, `patch` semantics (no-op when empty,
ephemeral, throwing → `.error`), `makeStream()` reads current subclass properties, and
class-backed sequence lifetime.

Note: the app target uses MainActor-by-default isolation, so **test suites touching
app types must be annotated `@MainActor`** — otherwise Swift Testing runs them on a
background worker and the isolation assertion traps, killing the whole test process.
