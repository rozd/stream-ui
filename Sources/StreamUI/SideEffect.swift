@MainActor
public struct SideEffect<Input, Output> {
    let operation: @MainActor (Input) async throws -> Output

    public init(_ operation: @escaping @MainActor (Input) async throws -> Output) {
        self.operation = operation
    }

    public func run(_ input: Input) async throws -> Output {
        try await operation(input)
    }
}

extension SideEffect where Input == Void {

    public func run() async throws -> Output {
        try await run(())
    }
}
