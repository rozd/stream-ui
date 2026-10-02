import Observation

@MainActor
@Observable
public final class FutureValue<Params: Sendable, Result: Sendable>: Sendable {
    public typealias Operation = (_ params: Params) async throws -> Result

    public private(set) var state: State<Result> = .initial

    @ObservationIgnored
    private var task: Task<Void, Never>?

    @ObservationIgnored
    private let operation: Operation

    public init(operation: @escaping Operation) {
        self.operation = operation
    }

    public func execute(_ params: Params) {
        task?.cancel()
        state = .loading
        task = Task { [weak self] in
            do {
                let result = try await self?.operation(params)
                guard !Task.isCancelled else { return }
                guard let result else { return }
                self?.state = .success(result)
            } catch {
                guard !Task.isCancelled else { return }
                self?.state = .failure(error)
            }
        }
    }

    public func reset() {
        task?.cancel()
        task = nil
        state = .initial
    }
}

// MARK: - State

extension FutureValue {

    public enum State<Data: Sendable> {
        case initial
        case loading
        case success(Data)
        case failure(Error)
    }
}

// MARK: - Helpers

extension FutureValue {

    public var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    public var data: Result? {
        if case .success(let data) = state {
            return data
        }
        return nil
    }
}
