# StreamUI — Design Rationale & Hazards

This file records *why* StreamUI v2 is shaped the way it is, the concurrency facts it
depends on (each verified experimentally), and the v1 bugs that motivated the redesign.
Read this before "simplifying" anything — several lines of code are load-bearing in
non-obvious ways.

## Goals

- Use `AsyncSequence` as the single reactive primitive for SwiftUI (no Combine, no
  view-model layer — stores are named queries, not per-screen VMs).
- Keep view code concise: exhaustive `switch` over `empty/value/error` via a builder.
- Be "truly SwiftUI": lifecycle derived from **view identity** through structured
  concurrency, not imperative start/stop calls.
- No magic: explicit closures, visible lifecycle, enforced single-writer contract.

## Core decisions

### 1. Views drive the run; the store owns no tasks

v1 stored a `Task` on the object (`observe()`/`finish()`/`deinit`-cancel + a retry
`AsyncStream`). All of v1's bugs lived in that machinery. v2 inverts control:

```swift
.task(id: stream.runID) { await stream.run() }
```

SwiftUI starts the run on appearance, cancels on disappearance, and restarts when the
id changes. `run()` consumes exactly **one** stream — there is no internal
resubscribe loop, so no loop can ever spin.

Consequences:
- `StreamValue` needs no `deinit`, no stored `Task`, no cancellation bookkeeping.
- Calling `run()` from a free-running `Task` is a contract violation (nothing would
  ever cancel it). The builder and `.observing(_:)` are the only intended callers.

### 2. `runID = ObjectIdentifier + generation`

- **Generation** is bumped by `refresh()`. It is a *tracked* (`@Observable`) stored
  property **on purpose** — `.task(id:)` only restarts if the body that read the id is
  invalidated. Marking it `@ObservationIgnored` silently breaks every restart. This is
  the kit's most fragile invariant; there is no compiler help if it regresses.
- **ObjectIdentifier** handles the store instance itself changing (a parent
  deliberately passes a new store). Without it, `.task(id: generation)` would compare
  `0 == 0` across different instances and never restart.
- `run()` snapshots `generation` on entry and guards every state write with
  `generation == expected`: a stale run (its stream has an in-flight value while
  `refresh()` already moved on) can *never* write. MainActor serializes everything
  else, so this is the only guard needed.

### 3. One restart verb: `refresh()`

v1 had `refresh()` (cancel + resubscribe) *and* `retry()` (signal a parked loop via a
shared `AsyncStream`). Two names, two mechanisms, one of which was fatally broken (see
§AsyncStream semantics). v2 keeps exactly one: `refresh()` = clear state + bump
generation. Error-view retry buttons call it; parameter `didSet`s call it. Resetting
to `.empty` on refresh is deliberate — after retry or a parameter change, showing
stale data is a lie; show loading.

### 4. Keep-last-value on re-appearance

`run()` does **not** reset state on entry (except clearing a stale `.error`). Rationale:
`NavigationStack` fires the covered view's disappear on push, so v1's
reset-to-`.empty`-on-observe caused a loading flash plus Firestore listener churn on
*every* push/pop and tab switch. v2: re-appearing keeps the last value while the new
subscription warms up; Firestore's local cache typically re-emits within milliseconds.
The stale-`.error` exception exists so a fresh appearance visibly retries a previously
failed stream instead of showing a dead error screen forever.

### 5. `private(set) state` + `patch` — the single-writer contract

v1's `state` was publicly settable and eight stores wrote to it
(`state = state.whenValue { … }`), which made "who writes state?" unanswerable and
produced a real bug class: a stream emission clobbering imperative writes (the
purchase-flow "stuck sheet"). v2:

- The stream (via `run()`) is the only writer of streamed data.
- `patch { }` is the one named escape hatch: an **ephemeral** local override for
  optimistic UI, documented to vanish on the next emission. It reproduces
  `whenValue`-assignment semantics exactly (no-op unless `.value`; a thrown transform
  becomes `.error`), so the migration was mechanical.
- Flow state that must *survive* emissions (purchase `status`/`feedback`) moves to
  separate observed properties beside `state`. Access control alone can't enforce
  this split — it's a documented contract, enforced by the regression test
  `streamEmissionDoesNotClobberStatus`.

### 6. Explicit factory closure; `makeStream()` for parameters

v1 took the stream as `@escaping @autoclosure`, which *looks* like passing a value and
hides capture semantics. It caused a real, user-visible bug (`Scheduler`): inside an
init, the parameter name shadows the property, and an escaping closure passed to
`super.init` cannot capture `self` — so the autoclosure froze the **init-time**
`date` forever. `didSet { refresh() }` dutifully re-ran the same stale query; the date
picker never worked. (Verified with a minimal compile test: mutate the property, the
factory still returns the init-time value.)

v2 rules:
- The factory is an explicit `{ … }` closure — capture is at least visible.
- Any store whose query depends on **mutable** properties must not use a factory at
  all: override `makeStream()` (a template method reads current property values on
  every invocation, making the freeze impossible to write), and `refresh()` in the
  property's `didSet`.
- One designated init with an optional factory (`init(_ factory: … = nil)`), because a
  separate `init()` is inherited by empty subclasses and collides with their
  `convenience init()` extensions ("invalid redeclaration of synthesized initializer").
  `makeStream()` traps with a clear message if neither factory nor override exists.

### 7. Multi-observer semantics: duplicate runs, last-writer-wins

Two views observing one store each run their own `.task`, hence two identical
subscriptions. Options considered: reference-counted single-flight with handoff
between structured tasks (genuinely awkward — you cannot migrate a loop between
tasks), or tolerate duplicates. Chosen: tolerate. Firestore shares the underlying
watch channel across identical listeners, values are idempotent, and MainActor
serializes writes. Documented, not hidden. Revisit only if a non-idempotent source
shows up.

## Verified concurrency facts

These were established with small runnable experiments during the redesign — they are
facts about the runtime, not opinions.

### AsyncStream consumption semantics (why v1's retry was fatally broken)

Experiment: create `AsyncStream<Void>`, iterate with `break`, iterate again; separately
cancel a consuming task, then iterate again.

- Breaking out of `for await` does **not** terminate the stream — a later iteration
  still receives new yields.
- **Cancelling a task that is parked on `for await` terminates the stream
  permanently.** All future iterations return immediately with zero elements.

v1 parked its resubscribe loop on a retry `AsyncStream` while in the error state. The
moment a view disappeared during an error (`finish()` → task cancel), the retry stream
was dead forever; the *next* error made `for await` return instantly and the
`while !Task.isCancelled` loop degenerated into a tight, UI-invisible
subscribe-fail-resubscribe spin against Firestore. v2 has no parked loops at all.

### Sequence lifetime (the `withExtendedLifetime` pin in `run()`)

The Firestore adapter returns a **class-backed** sequence: `ListenerStream` finishes
its continuation in `deinit` (that is its whole purpose — it guarantees listener
removal when a downstream `map` throws and the terminal `onTermination` would never
fire). The mapped chain (`ListenerStream().map{}.map{}`) is structs-around-a-class,
and **iterators do not retain the sequences they came from**. Therefore:

```swift
for try await value in makeStream() { … }   // BROKEN — do not "simplify" to this
```

deallocates `ListenerStream` right after `makeAsyncIterator()`, its `deinit` finishes
the continuation, and the listener dies before the first snapshot. Symptom: app-wide
infinite loading, zero errors, no Firestore watch channel ever opened. This was found
via a baseline-vs-change control run on the Lab build (unit tests with plain
`AsyncThrowingStream`s cannot catch it — the stream storage outlives the wrapper).

The fix in `run()`:

```swift
let stream = makeStream()
defer { withExtendedLifetime(stream) {} }   // pin for the whole loop, all build configs
for try await value in stream { … }
```

A plain `let` binding is what accidentally saved v1 (its `observe()` had one), but a
local's guaranteed lifetime only extends to its last use — the `defer` pin makes it
airtight under optimization. Regression test: `retainsClassBackedSequence` iterates a
`DeinitFinishingSequence` that mirrors `ListenerStream` exactly.

### MainActor-by-default isolation (app target setting)

The app builds with MainActor-as-default isolation. Facts that bit during this work:

- **Extensions re-default to `@MainActor` even when the extended type is declared
  `nonisolated`.** A `nonisolated struct State` with helpers in a separate `extension`
  gets MainActor-isolated helpers. Members declared *inside* the nonisolated type body
  stay nonisolated.
- Making value-type helpers `nonisolated` pulls a thread: they call domain entity
  members (`Membership.isActive` etc.) which are themselves MainActor under the
  default. Going nonisolated bottom-up across the domain layer was out of scope; the
  pragmatic rule is: **domain logic is MainActor; test suites that touch it must be
  `@MainActor`.** A non-annotated Swift Testing suite runs on a background worker, the
  runtime isolation assertion traps (`dispatch_assert_queue_fail`), and the crash
  kills the whole parallel test process — every other test "fails" in 0.000s, and the
  blamed test in the report is whichever was running, not necessarily the culprit.
  Read the `.ips` crash report's faulting frame, not the failure list.

## v1 → v2 API mapping

| v1 | v2 |
|---|---|
| `super.init(<stream expr>)` (autoclosure) | `super.init { <stream expr> }` (explicit closure) |
| params captured by the stream expr | override `makeStream()` + `refresh()` in `didSet` |
| `stream.observe()` / `stream.finish()` | delete — `StreamBuilder` drives; or `.observing(stream)` |
| `stream.retry()` (signal parked loop) | `stream.refresh()` |
| `stream.refresh()` (cancel+restart) | `stream.refresh()` (same name, structured mechanics) |
| `state = state.whenValue { … }` | `patch { … }` |
| status/feedback fields inside streamed `State` | observed properties beside `state` |
| `@State private var stream` inside `StreamBuilder` | `let stream` + `ObjectIdentifier` in `runID` |
| `onAppear { observe() } / onDisappear { finish() }` | `.task(id: runID) { await run() }` |

Bugs fixed by the redesign (all reproduced/verified before fixing):

1. **Scheduler date freeze** — autoclosure captured the init parameter; the date
   picker re-ran the original day forever.
2. **Retry hot-loop** — dead retry `AsyncStream` after cancel-while-errored turned
   persistent errors into a tight resubscribe spin.
3. **Purchase status clobber** — memberships emission (backend writes the document
   mid-purchase) reset a streamed `status` to idle mid-flight.
4. **Loading flash + listener churn** on every navigation push/pop and tab switch
   (reset-to-empty on every `onAppear`).
5. **Sequence lifetime** (introduced and fixed within v2) — see above; now pinned and
   regression-tested.

## Known limitations / deliberate non-features

- **No silent refresh** (keep showing the old value while resubscribing). All current
  call sites want either keep-last (re-appearance — automatic) or honest loading
  (retry / parameter change — `refresh()`). Add a `refresh(keepingValue:)` only when a
  pull-to-refresh screen actually needs it.
- **No automatic retry/backoff.** Errors wait for an explicit `refresh()` or a fresh
  appearance. An auto-retry policy would need backoff, and hides genuine failures.
- **Duplicate subscriptions on shared stores** (see §7). Acceptable for idempotent
  sources; revisit for non-idempotent ones.
- **`FutureValue` keeps an unstructured `Task`** on purpose: button-triggered one-shot
  writes should not necessarily die with the view that started them (an Apple Pay
  charge must not be cancelled by a sheet dismissal). `execute` cancels the previous
  run; `[weak self]` prevents retain cycles. It is the write-path primitive — keep it
  separate from the read-path `StreamValue`.
- **`StreamBuilder(id:stream:...)` overlaps with `StreamValue`** by design: it is the
  zero-ceremony end of the spectrum (no store, no refresh, id-keyed restart). Both
  share the same three-case rendering idiom — it was originally a sibling type
  (`SequenceBuilder`) and was folded into `StreamBuilder` as a second initializer.
- `when` / `maybeWhen` / `whenValue` on `StreamState` are Dart/freezed-style folds kept
  for ergonomics; `StreamBuilder` itself switches directly and does not need them.
