---
name: streamui-integration
description: Integrate the StreamUI Swift package (reactive AsyncSequence -> SwiftUI bindings, https://github.com/rozd/stream-ui) into a SwiftUI app -- adding the SPM dependency, building a StreamValue-backed store, rendering it through StreamBuilder's exhaustive empty/value/error switch, wiring one-shot writes with FutureValue, and injecting testable operations with SideEffect. Use this whenever a user wants to stream Firestore/HealthKit/CloudKit/URLSession/websocket/any AsyncSequence-shaped data into a SwiftUI view, mentions StreamValue, StreamBuilder, FutureValue, SideEffect, StreamState, or "empty/value/error" rendering, or wants to replace ad-hoc onAppear/onDisappear subscription management, a leaking Task, a Combine publisher, or an ObservableObject view-model with a lifecycle-safe alternative. Also reach for it when reviewing SwiftUI code that manually starts/cancels async subscriptions, or when deciding whether a screen needs a live stream vs. a one-shot async operation.
---

# Integrating StreamUI into a SwiftUI app

StreamUI connects any `AsyncSequence` (a Firestore listener, a HealthKit query, a
polling loop, a websocket) to SwiftUI with three guarantees: views stay a pure
`switch` over `empty | value | error`, the subscription's lifecycle is derived from
view identity (no task the kit owns can leak), and there is exactly one writer of
streamed state. Read this before hand-rolling `Task { for await ... }` inside
`onAppear` — that pattern is exactly what StreamUI replaces, and it fails in ways
that are easy to miss (see `references/adapter-pattern.md` for the specific hazards).

This skill walks through adding the package and wiring it into a real screen. For
exact signatures, jump straight to `references/api-reference.md` instead of
re-deriving them from memory — the package is small but has a few sharp edges
(private setters, override points) worth reading precisely.

## 0. Confirm the deployment target

StreamUI requires **iOS 18 / macOS 15** and **Swift tools 6.1** (Xcode 16.3+). It
leans on `@Observable` and typed throwing `AsyncSequence` — there is no back-deploy
path. Check the consuming app's `Package.swift` platforms / Xcode deployment target
before doing anything else; if it's lower, that's a blocking conversation to have
with the user, not something to work around.

## 1. Add the package dependency

The package has no tagged release yet, so pin to the branch rather than a version
requirement (switch to `from: "x.y.z"` once a tag exists — check
`git ls-remote --tags https://github.com/rozd/stream-ui` if unsure):

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/rozd/stream-ui.git", branch: "main")
],
targets: [
    .target(name: "YourTarget", dependencies: ["StreamUI"])
]
```

In Xcode: **File → Add Package Dependencies…** → paste
`https://github.com/rozd/stream-ui` → Dependency Rule **Branch: main** → add the
**StreamUI** library product to the app target.

## 2. Pick the right primitive for the job

StreamUI is small on purpose — four types cover distinct jobs. Don't reach for
`StreamValue` by reflex; picking wrong shows up later as awkward code fighting the
kit instead of using it.

| Need | Use |
|---|---|
| Live data (list, doc, feed) a screen subscribes to, with retry/refresh, shareable across views | `StreamValue<T>` + `StreamBuilder` |
| A one-off subscription with no retry/refresh and nothing to name or share, keyed by an `Equatable` id | `StreamBuilder(id:stream:)` directly — skip `StreamValue` |
| A one-shot async operation triggered by user action (submit, delete, purchase, sign-in) | `FutureValue<Params, Result>` |
| An async operation inside a store that tests need to substitute | `SideEffect<Input, Output>`, exposed as a `lazy var` |

The dividing line between the first two rows: does anything need a *name*, needs to
be *shared* across more than one view, or needs a *retry button*? If yes,
`StreamValue`. If it's purely "this one view shows this one id's data, restart when
the id changes," the bare `StreamBuilder(id:stream:)` avoids ceremony.

The dividing line between rows one and three: `StreamValue` is the **read path** —
its only writer is the stream itself, plus the ephemeral `patch`. Never route a
button-triggered write through it. `FutureValue` is the dedicated **write path**;
keep them separate even when a write and a read live in the same feature.

## 3. Get an `AsyncSequence` for your data source

StreamUI doesn't know or care where the sequence comes from — that adapter is
always application code. If your source is already `AsyncSequence` (URLSession's
`bytes(for:)`, an SDK that returns one directly), skip to step 4. If it's
callback-based, delegate-based, or a Combine publisher, you need a small wrapper
first. Read `references/adapter-pattern.md` before writing one — there is a
specific, easy-to-hit lifetime bug (a class-backed listener deallocating and tearing
down its subscription *before* the first value arrives) that the reference explains.
StreamUI pins the sequence for you on both consumption paths (`StreamValue.run()`
and `StreamBuilder(id:stream:)`), but any hand-rolled `for try await` loop over a
class-backed adapter must apply the same pin itself.

## 4. Define the store

A store is a named `@Observable` subclass of `StreamValue<T>`. Two shapes, chosen by
whether the query depends on a value that can change after `init`:

**Fixed query — pass a factory closure:**

```swift
@Observable
final class RecentOrders: StreamValue<[Order]> {
    init(customerId: CustomerId) {
        super.init {
            OrdersAPI.stream(for: customerId)   // your AsyncSequence adapter
                .map { @MainActor in try $0.map(Order.init) }
        }
    }
}
```

**Query depends on a mutable property — override `makeStream()`, never capture:**

```swift
@Observable
final class Scheduler: StreamValue<[Session]> {
    let studioId: StudioId
    var date: Date {
        didSet {
            guard !Calendar.current.isDate(date, inSameDayAs: oldValue) else { return }
            refresh()   // task restarts -> makeStream() reads the *new* date
        }
    }

    init(studioId: StudioId, date: Date) {
        self.studioId = studioId
        self.date = date
        super.init()   // no factory: makeStream() is the source of truth
    }

    override func makeStream() -> S {
        SessionsAPI.stream(studioId: studioId, on: date)
    }
}
```

Why this split matters, concretely: a factory closure is captured once, at `init`
time. If you instead wrote `super.init { SessionsAPI.stream(studioId: studioId, on:
date) }` inside that same `init`, the closure captures the **init-time** values of
`studioId`/`date` forever — `didSet { refresh() }` will faithfully restart the
subscription, and it will faithfully rebuild the exact same stale query every time.
This is a real bug class (a date picker that silently never changes what's on
screen), not a hypothetical — `override func makeStream()` is a template method, so
it always reads current property values, which is the whole reason it exists as a
separate mechanism instead of "just capture more."

## 5. Render it

```swift
struct RecentOrdersScreen: View {
    @State private var orders: RecentOrders   // the view owns the store

    var body: some View {
        StreamBuilder(orders) { orders in
            List(orders) { OrderRow(order: $0) }
        } empty: {
            ProgressView()
        } error: { error in
            ErrorView(error: error) { orders.refresh() }
        }
    }
}
```

`StreamBuilder` attaches `.observing(stream)` for you — sugar for
`.task(id: stream.runID) { await stream.run() }` — so there is no `onAppear`,
`onDisappear`, `observe()`, or `finish()` to write. Two things this depends on:

- **The store must be owned outside the view that renders it** — `@State` on a
  screen, or injected via `.environment(...)`. Writing
  `StreamBuilder(RecentOrders(customerId: id)) { ... }` inline in a parent's `body`
  builds a new instance, and therefore restarts the subscription, on every render.
- **Nothing should call `stream.run()` directly**, and nothing should wrap it in a
  free-running `Task`. `run()` consumes exactly one stream end-to-end and relies on
  its caller (SwiftUI, via `.task(id:)`) to cancel it — a caller that never cancels
  turns "view disappeared" into "listener still open forever."

For a view that reads `stream.state` itself instead of going through
`StreamBuilder` (e.g. it's one section of a larger layout), use the modifier
directly: `.observing(stream)`. It accepts `nil`, which supports lazily creating the
store after first appearance — see `references/api-reference.md` for that pattern.

Retry is always the same verb: `stream.refresh()` clears `state` back to `.empty`
and bumps the run identity, which cancels and restarts every observing `.task`. Use
it from an error view's retry button and from a parameter's `didSet` — never invent
a second restart mechanism.

## 6. Writes: `FutureValue`, and keeping flow state out of the stream

A button-triggered write doesn't belong in `StreamValue` — use `FutureValue`:

```swift
let purchase = FutureValue<PurchaseRequest, Receipt> { request in
    try await BillingAPI.purchase(request)
}
// purchase.execute(request) -> state walks .initial -> .loading -> .success/.failure
```

If a screen has *both* a live read (e.g. "current membership") and a write that
affects it (e.g. "purchase a membership"), keep any in-flight status (`purchasing`,
a transient success/error banner) in a **separate observed property beside `state`**,
not inside the streamed payload:

```swift
@Observable
final class PurchasingMembership: StreamValue<PurchasingMembership.State> {
    private(set) var status: Status = .idle   // survives stream emissions
    …
}
```

The concrete failure this avoids: the backend writes the record *during* the
purchase, the read stream re-emits mid-flight (because it's still subscribed), and
a `status` field living inside the streamed struct gets silently reset to whatever
the backend's snapshot says — usually back to idle, clobbering a purchase the user
is actively watching complete. `state` has exactly one writer (the stream); flow
state that must outlive an emission needs a different address.

For optimistic UI ahead of a durable write, use `patch`:

```swift
func select(plan: Plan) {
    patch { $0.copyWith(selectedPlan: plan) }      // instant, local, ephemeral
    UserDefaults.standard.lastPlanId = plan.id      // durable — the stream echoes it back
}
```

`patch` is deliberately ephemeral: the **next** stream emission replaces it. Pair
every `patch` with a durable write that will eventually round-trip through the same
stream — a patch with no durable echo behind it just silently reverts on the next
emission, which reads as a UI bug if you don't already know that's the contract.

## 7. Test the store

`StreamValue` subclasses are ordinary objects driven by `run()` — no view needed to
test them. `references/testing.md` has the reusable fixtures (a fake stream you can
drive by hand, and a polling `eventually()` helper for MainActor-cooperative
assertions) plus a worked example testing `refresh()` and error recovery.

## Self-check before calling it done

- Is the store constructed once, outside the view that renders it (never inline in
  `body`)?
- If the query has any mutable input, is it read via an overridden `makeStream()` —
  not captured into a factory closure?
- Is `refresh()` the only restart path (no second retry mechanism, no parked
  loop, no manual resubscribe)?
- Does anything call `.run()` directly, or wrap it in a bare `Task`? It should only
  ever run under `.task(id:)`, via `StreamBuilder` or `.observing(_:)`.
- Is flow state that must survive a stream emission (loading flags, transient
  banners tied to a write) stored *beside* `state`, not inside the streamed type?
- Does every `patch` have a durable write behind it?
- Is a one-shot write modeled with `FutureValue`, not shoehorned into a
  `StreamValue`?

## Reference files

- `references/api-reference.md` — exact member tables for `StreamValue`,
  `StreamState`, `StreamBuilder`, `View.observing(_:)`, `FutureValue`, `SideEffect`.
- `references/adapter-pattern.md` — wrapping a callback/delegate/Combine source as
  an `AsyncSequence`, and the class-backed-listener lifetime hazard.
- `references/testing.md` — the `Feed<T>` / `eventually()` test fixtures and a
  worked example.
