import Testing
@testable import StreamUI

@Suite("SideEffect")
@MainActor
struct SideEffectTests {

    @Test("passes input through to the operation")
    func passesInput() async throws {
        var received: [String] = []
        let sideEffect = SideEffect<[String], Void> { received = $0 }
        try await sideEffect.run(["a", "b", "c"])
        #expect(received == ["a", "b", "c"])
    }

    @Test("returns the operation's output")
    func returnsOutput() async throws {
        let sideEffect = SideEffect<Int, Int> { $0 * 2 }
        let result = try await sideEffect.run(21)
        #expect(result == 42)
    }

    @Test("propagates errors from the operation")
    func propagatesErrors() async throws {
        struct Failure: Error {}
        let sideEffect = SideEffect<Void, Void> { throw Failure() }
        await #expect(throws: Failure.self) {
            try await sideEffect.run()
        }
    }

    @Test("Void-input side effect is runnable without arguments")
    func voidInputSugar() async throws {
        var called = false
        let sideEffect = SideEffect<Void, Void> { called = true }
        try await sideEffect.run()
        #expect(called)
    }
}
