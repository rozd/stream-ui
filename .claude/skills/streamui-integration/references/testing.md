# Testing a `StreamValue` store

A store is just an object driven by `run()` — you don't need a view or SwiftUI's
runtime to exercise it, only a task calling `run()` and a fake sequence you can push
values into by hand. `Tests/StreamUITests/StreamValueTests.swift` in the StreamUI
package itself is the reference suite; the two fixtures below are the reusable
parts.

## Fixture 1: a driveable fake stream

```swift
@MainActor
final class Feed<T: Sendable> {
    private(set) var continuations: [AsyncThrowingStream<T, any Error>.Continuation] = []

    var latest: AsyncThrowingStream<T, any Error>.Continuation {
        continuations.last!
    }

    /// Called by the store's factory / makeStream() — once per run, exactly
    /// like a real adapter would build a fresh sequence each time.
    func make() -> any AsyncSequence<T, any Error> & Sendable {
        let (stream, continuation) = AsyncThrowingStream<T, any Error>.makeStream()
        continuations.append(continuation)
        return stream
    }
}
```

Passing `feed.make` as the store's factory means every `run()` (first run, and any
run after `refresh()`) gets a fresh continuation you can yield into and inspect —
`feed.continuations.count` tells you how many times the sequence has actually been
rebuilt, which is the thing worth asserting on when testing `refresh()` /
parameterized `makeStream()` overrides.

## Fixture 2: polling for `@MainActor` state changes

`run()` and `state` are `@MainActor`-isolated, and test bodies interleave with the
running task cooperatively rather than deterministically — so assertions need to
poll rather than assume a fixed number of suspension points:

```swift
func eventually(
    timeout: Duration = .seconds(2),
    _ condition: @MainActor () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(condition())   // fails with a clear message if it never became true
}
```

## Worked example

```swift
@MainActor
@Suite("RecentOrders")
struct RecentOrdersTests {

    @Test("refresh() clears state and restarts the subscription")
    func refreshRestarts() async throws {
        let feed = Feed<[Order]>()
        let store = StreamValue<[Order]> { feed.make() }

        let run = Task { await store.run() }
        try await eventually { feed.continuations.count == 1 }

        feed.latest.yield([Order.fixture])
        try await eventually { store.state.data?.isEmpty == false }

        let before = store.runID
        store.refresh()

        #expect(store.runID != before)   // .task(id:) would restart here
        #expect(store.state.data == nil) // cleared, not left stale

        run.cancel()
        await run.value
    }

    @Test("a stream failure becomes .error")
    func failureBecomesError() async throws {
        struct Boom: Error {}
        let feed = Feed<[Order]>()
        let store = StreamValue<[Order]> { feed.make() }

        let run = Task { await store.run() }
        try await eventually { feed.continuations.count == 1 }
        feed.latest.finish(throwing: Boom())

        await run.value
        if case .error = store.state {} else { Issue.record("expected .error") }
    }
}
```

Notes that generalize beyond this example:

- Drive the fake stream, then `run.cancel(); await run.value` at the end of every
  test — `run()` only returns on cancellation, a normal stream end, or an error, so
  a test that doesn't finish or cancel the run leaks a suspended task past the test.
- For a subclass with an overridden `makeStream()` (the parameterized-store
  pattern), assert on a recorded list of what each call actually built, not just the
  final state — that's what catches a parameter silently frozen at its `init`-time
  value instead of being read fresh on each run (see `SKILL.md` step 4).
- If your app target enables MainActor-by-default isolation (a per-module compiler
  setting, common in apps that lean on `@Observable` domain types everywhere), any
  test suite that touches those types needs `@MainActor` on the suite itself —
  otherwise Swift Testing runs it on a background worker and the runtime isolation
  assertion traps, taking the whole parallel test process down with it. If a test
  run reports a wall of unrelated failures at `0.000s`, that's usually the symptom;
  check the crash report's faulting frame rather than trusting the failure list.
