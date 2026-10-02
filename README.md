# StreamUI

**Connect any `AsyncSequence` to SwiftUI, with no subscription code to manage.**

```swift
StreamBuilder(memberships) { memberships in
    List(memberships) { MembershipCard(membership: $0) }
} empty: {
    ProgressView()
} error: { error in
    ErrorView(error) { memberships.refresh() }
}
```

The subscription starts when the view appears and is cancelled when it disappears.
It restarts when you call `refresh()`. There is nothing to cancel by hand and no
`Task` that can leak.

iOS 18+ · macOS 15+ · Swift 6 strict concurrency · no dependencies

---

## Why this exists

SwiftUI is reactive, and `AsyncSequence` is a stream, so you would expect a built-in
way to join them. Apple's recommended approach is
[`.task` with a `for await` loop](https://developer.apple.com/videos/play/wwdc2021/10019/):

```swift
struct MembershipsScreen: View {
    let user: User
    @State private var memberships: [Membership]?
    @State private var error: Error?

    var body: some View {
        Group {
            if let error { ErrorView(error) { /* retry how? */ } }
            else if let memberships { List(memberships) { MembershipCard(membership: $0) } }
            else { ProgressView() }
        }
        .task(id: user.id) {
            do {
                for try await value in user.membershipsStream() {
                    memberships = value
                }
            } catch is CancellationError {
            } catch {
                self.error = error
            }
        }
    }
}
```

That works, but you have to make the same decisions again in every screen:

- **What does "not loaded yet" look like?** Using an optional plus a separate error
  property allows impossible combinations, such as a value and an error at the same time.
- **How do you retry?** `.task(id:)` restarts only when its id changes, so a Retry
  button needs an extra counter in its id.
- **Which run is allowed to write?** A cancelled or superseded loop can still assign a
  value after a newer loop has started.
- **What happens on re-appear?** Should the old value stay on screen, or should a
  spinner show? Should an old error be retried?
- **Where does the stream come from?** An `AsyncSequence` is not `Equatable`, so SwiftUI
  cannot tell whether it is "the same stream". You must key the task on a separate id.

StreamUI makes these decisions once, and the test suite checks them.
**It adds nothing that `.task(id:)` cannot do.** It is that primitive plus a small
state machine, with the edge cases handled.

---

## Installation

Add the package in Xcode (**File ▸ Add Package Dependencies…**) or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/rozd/stream-ui.git", branch: "main"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "StreamUI", package: "stream-ui"),
    ]),
]
```

---

## Quick start

### 1. Describe the data as a store

A store is an `@Observable` class that holds the latest element of a stream. Name it
after the data it holds.

```swift
import StreamUI

@Observable
final class Memberships: StreamValue<[Membership]> {
    init(user: User) {
        super.init {
            // Called again on every run, so it must return a new sequence each time.
            user.membershipsStream()
        }
    }
}
```

### 2. Render it

```swift
struct MembershipsScreen: View {
    @State private var memberships: Memberships   // the view owns the store

    init(user: User) {
        _memberships = State(initialValue: Memberships(user: user))
    }

    var body: some View {
        StreamBuilder(memberships) { memberships in
            List(memberships) { MembershipCard(membership: $0) }
        } empty: {
            ProgressView()
        } error: { error in
            ErrorView(error) { memberships.refresh() }
        }
    }
}
```

You don't write `onAppear`, `onDisappear`, `Task { }` or a `cancel()` call.

---

## The mental model

Every StreamUI API maps to plain SwiftUI code you could write yourself:

| You write | What it amounts to |
|---|---|
| `StreamBuilder(store) { … } empty: { … } error: { … }` | `switch store.state { … }` **+** `.observing(store)` |
| `.observing(store)` | `.task(id: store.runID) { await store.run() }` |
| `store.run()` | `for try await element in makeStream() { state = .value(element) }`, where only the current run is allowed to write |
| `store.refresh()` | `state = .empty; generation += 1`, which changes `runID` so `.task(id:)` restarts |
| `store.state` | `enum StreamState { case empty, value(T), error(Error) }` |

SwiftUI still does all the lifecycle work. StreamUI never creates a `Task` of its own.

### Three rules the design follows

1. **Views stay declarative.** A view renders an exhaustive `switch` over
   `empty | value | error`. It never manages a subscription.
2. **Lifecycle is structured.** Every subscription runs inside SwiftUI's
   `.task(id:)`. It starts when the view appears, is cancelled when the view
   disappears, and restarts when its identity changes.
3. **One writer per state.** Only the stream writes streamed state. There is one
   intentionally temporary way to change it locally (`patch`). State that must survive
   new emissions is kept *next to* the streamed state, not inside it. Bind controls
   (alerts, sheets, text fields) to those properties with `@Bindable`. StreamUI
   deliberately offers no `Binding` into the streamed value.

---

## Which tool should I use?

| Situation | Use |
|---|---|
| Live data that keeps changing (listeners, sockets, sensors) with a name, helpers, retry or several observers | `StreamValue` + `StreamBuilder` |
| A one-off stream keyed by an id, with no retry and no shared state | `StreamBuilder(id:stream:)` |
| A view that reads `store.state` itself instead of using `StreamBuilder` | `.observing(store)` |
| A one-shot operation: save, purchase, delete | `FutureValue` |
| An async operation that tests should be able to replace | A plain closure property (see [Injecting operations](#injecting-operations-for-tests)) |
| One screen, one stream, and no need for a dependency | Honestly, plain `.task(id:)` is fine |

---

## API reference

### `StreamValue<T>`

A `@MainActor @Observable` class that holds the latest element of an
`AsyncSequence<T, any Error>`.

| Member | What it does |
|---|---|
| `init(_ factory:)` | `factory` must return a **new** sequence on every call. Pass `nil` and override `makeStream()` instead when the query depends on mutable properties. |
| `state: StreamState<T>` | `.empty` until the first element, then `.value(T)` or `.error(Error)`. Only the stream writes it, except through `patch`. |
| `makeStream()` | Builds the sequence for a run. Override it when the query depends on current property values. |
| `runID` | Identifies the current run: the store's identity plus a generation counter. Use it as the `.task(id:)` key. |
| `run() async` | Consumes one stream. Call it **only** from `.task(id: runID)`, as `StreamBuilder` and `.observing` do. Never call it from a free-running `Task`. |
| `refresh()` | The one way to restart: sets the state to `.empty` and restarts every observing task. Safe to call at any time, even when nothing observes the store. |
| `patch(_:)` | Changes the current value temporarily, for optimistic UI. **The next emission replaces it.** Does nothing before the first value. |

**`StreamState` helpers:** `data` (the value or `nil`), `when(value:error:empty:)`
(handles every case), `maybeWhen(…orElse:)` (handles some cases, with a fallback),
`whenValue(_:)` (transforms only the value).

### `StreamBuilder`

```swift
StreamBuilder(store) { value in … } empty: { … } error: { error in … }
```

Renders `store.state` and attaches `.observing(store)`.

> ⚠️ Something else must **own** the store: `@State` in the screen, or the environment.
> If you create it inline in a parent's `body`, you get a new store on every render,
> and the subscription restarts each time.

### `StreamBuilder(id:stream:)`: no store

```swift
StreamBuilder(id: workoutId, stream: { id in workoutStream(id) }) { workout in
    WorkoutDetail(workout)
} empty: { ProgressView() } error: { ErrorView($0) }
```

Restarts when `id` changes. Use it when nothing needs to own, share or refresh the state.

### `View.observing(_:)`

```swift
List { /* reads store.state directly */ }
    .observing(store)
```

It also accepts `nil`, which lets you create a store lazily:

```swift
@State private var upcoming: UpcomingWorkout?

var body: some View {
    content
        .task { if upcoming == nil { upcoming = UpcomingWorkout(user: user) } }
        .observing(upcoming)    // when the id changes from nil to a runID, the run starts
}
```

### `FutureValue<Params, Result>`

A one-shot async operation with the states `.initial → .loading → .success / .failure`.
`execute(_:)` cancels any run that is still in progress. `reset()` returns to
`.initial`. It has the helpers `isLoading` and `data`. **Use it for writes, and keep
writes out of `StreamValue`.**

---

## Patterns

### Keep the shape and the plumbing apart

```swift
// Showcase.swift: the state shape and domain helpers
@Observable final class Showcase: StreamValue<Showcase.State> { }
extension Showcase { struct State { var studio: Studio; var plans: [Plan] } }

// Showcase+Firestore.swift: how the stream is built
extension Showcase {
    convenience init(studioId: StudioId) {
        self.init {
            combineLatest(studio(id: studioId), plans(studioId: studioId))
                .map { Showcase.State(studio: $0, plans: $1) }
        }
    }
}
```

All composition, such as `combineLatest`, `flatMap` over an auth stream, or async
`map`s, goes inside the factory. This is where `AsyncSequence` pays off.

### Queries with parameters: override `makeStream()`

A factory closure captures its parameters **once**. When the query depends on a
property that can change, read the property in `makeStream()` and call `refresh()`
when it changes:

```swift
@Observable
final class Scheduler: StreamValue<[Session]> {
    let studioId: StudioId
    var date: Date {
        didSet { if !Calendar.current.isDate(date, inSameDayAs: oldValue) { refresh() } }
    }

    init(studioId: StudioId, date: Date) {
        self.studioId = studioId
        self.date = date
        super.init()               // no factory: makeStream() builds the sequence
    }

    override func makeStream() -> S {
        sessionsStream(studioId: studioId, from: date.startOfDay)   // reads the current date
    }
}

// In the view:
DatePicker("Date", selection: $scheduler.date)
```

### Keep flow state next to the stream, not inside it

State that must survive new emissions, such as purchase progress, belongs in separate
properties:

```swift
@Observable
final class PurchasingMembership: StreamValue<PurchasingMembership.State> {
    private(set) var status: Status = .idle     // not overwritten by emissions

    func purchase() async {
        guard status == .idle else { return }
        status = .purchasing
        do    { try await submitPurchase(); status = .purchased }
        catch { status = .idle }
    }
}
```

This prevents a real bug: the backend writes the membership document *during* the
purchase, the stream emits, and a `status` stored inside the streamed state would reset
to idle while the purchase was still running.

### Optimistic edits: `patch` plus a durable write

```swift
func select(studio: Studio) {
    patch { $0.copyWith(selectedStudio: studio) }               // the UI updates at once
    UserDefaults.standard.lastSelectedStudioId = studio.id      // the stream picks this up
}
```

When the stream emits again, it replaces the patch with the stored value, and the two
match. A patch without a durable write disappears on the next emission. That is by
design.

### Injecting operations for tests

StreamUI has no special type for this. A closure property on the store is enough:

```swift
@Observable
final class PurchasingMembership: StreamValue<PurchasingMembership.State> {
    var submitPurchase: @MainActor () async throws -> Void = { try await BillingAPI.purchase() }

    func purchase() async {
        try? await submitPurchase()
    }
}

// In a test:
store.submitPurchase = { throw TestError() }
```

Give the closure a name that differs from the store's methods. If a method
`func purchase()` and a property `var purchase` share a name, `purchase()` inside
the store calls the *method*, which compiles without warnings and recurses forever.

### Shared stores

A store can be **read** by any number of views, but it should be **observed** by
exactly one. Attach `StreamBuilder` or `.observing(store)` once, near where the store
is owned, and pass the store itself (via `.environment(…)` or an init parameter) to
child views that only read `store.state`:

```swift
struct MembershipsScreen: View {
    @State private var memberships = MembershipsStore()

    var body: some View {
        TabView {
            ActiveTab()      // reads memberships.state
            HistoryTab()     // reads memberships.state
        }
        .environment(memberships)
        .observing(memberships)   // the one subscription
    }
}
```

Every observer runs its own subscription, so two observers would mean two listeners
racing to write `state`. Debug builds catch this: a second concurrent run of the same
store hits an `assertionFailure`. Runs that were already cancelled (a view that just
disappeared, or a `refresh()` restart) don't count.

---

## Lifecycle at a glance

| Event | What happens |
|---|---|
| View appears | `.task(id: runID)` starts: `run()` calls `makeStream()` and subscribes |
| View disappears | SwiftUI cancels the task, the sequence ends and the listener is removed |
| View re-appears | A new run starts. **The last value stays on screen** (no loading flash). An old error is cleared back to `.empty` |
| `refresh()` | `state = .empty`, the generation increases, and every observing task restarts |
| A different store is passed in | The `runID` changes and the subscription restarts |
| The stream ends normally | The last value stays |
| The stream throws | `state = .error`. Cancelled runs and runs from an old generation cannot write |

---

## Testing

A store is a plain class, so tests can drive it directly, without UI.
`Tests/StreamUITests/StreamValueTests.swift` is the reference suite. It uses these
fixtures:

```swift
// Returns a new stream per factory call and keeps each continuation, so a test can push values.
@MainActor final class Feed<T: Sendable> { … }

// Polls until a condition is true (everything runs cooperatively on the MainActor).
func eventually(timeout: Duration = .seconds(2), _ condition: @MainActor () -> Bool) async throws

// A class-backed sequence that finishes in deinit: the worst case for sequence lifetime.
final class DeinitFinishingSequence: AsyncSequence, @unchecked Sendable { … }
```

To test a write path, replace the store's operation closure:

```swift
store.submitPurchase = { throw TestError() }
```

> **Note:** If your app target uses MainActor isolation by default, mark test suites
> that touch app types `@MainActor`. Otherwise Swift Testing runs them on a background
> thread, the isolation check traps, and the whole test process stops.

---

## Project layout

| File | Contents |
|---|---|
| `StreamValue.swift` | `StreamValue`, `StreamRunID`, `StreamState` with its helpers |
| `StreamBuilder.swift` | `StreamBuilder` (store-based and id-based), `View.observing(_:)` |
| `FutureValue.swift` | `FutureValue`, the one-shot async operation |
| `DESIGN.md` | Design reasons: sequence lifetime, why factories capture their values, single-writer rules |

StreamUI does not depend on any backend. Firestore, HealthKit, CloudKit, URLSession
and WebSockets work once they are wrapped in an `AsyncSequence`.
