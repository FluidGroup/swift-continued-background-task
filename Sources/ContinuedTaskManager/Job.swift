import Foundation
import Observation

extension ContinuedTaskManager {

  @MainActor
  @Observable
  public final class Job<Output: Sendable>: Identifiable, ManagedJob {

    public enum State: Sendable {
      case pending
      case running
      case succeeded
      case failed
      case cancelled
    }

    /// Describes the continuation request, not whether the app is currently in the background.
    public enum BackgroundState {
      case notRequested
      case requesting
      case granted
      case unavailable(any Error)
      case expired
      case cancelled
    }

    public nonisolated let id = UUID()
    public let title: String
    public let subtitle: String
    public let progress = Progress(totalUnitCount: 0)
    public private(set) var state: State = .pending
    public internal(set) var backgroundState: BackgroundState = .notRequested

    @ObservationIgnored var cancelRequest: (() -> Void)?
    @ObservationIgnored var onFinish: (() -> Void)?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var execution: BackgroundExecution?
    @ObservationIgnored private var result: Result<Output, any Error>?
    @ObservationIgnored private var waiters: [CheckedContinuation<Output, any Error>] = []
    @ObservationIgnored private var cancellationRequested = false

    init(title: String, subtitle: String) {
      self.title = title
      self.subtitle = subtitle
    }

    /// Observing a result does not own the job. Cancel it explicitly with `cancel()`.
    public var value: Output {
      get async throws {
        if let result {
          return try result.get()
        }
        return try await withCheckedThrowingContinuation { continuation in
          waiters.append(continuation)
        }
      }
    }

    /// Requests cooperative cancellation. Running work finishes after its cleanup returns.
    public func cancel() {
      guard result == nil else {
        return
      }
      cancellationRequested = true

      if state == .pending {
        cancelRequest?()
        if case .requesting = backgroundState {
          backgroundState = .cancelled
        }
        finish(.failure(CancellationError()))
      } else {
        worker?.cancel()
      }
    }

    func start(
      execution: BackgroundExecution? = nil,
      operation: @escaping @Sendable (Context) async throws -> Output
    ) {
      guard state == .pending else {
        execution?.complete(success: false)
        return
      }

      self.execution = execution
      cancelRequest = nil
      if let execution {
        backgroundState = .granted
        execution.progress.totalUnitCount = 1
        execution.progress.addChild(progress, withPendingUnitCount: 1)
        execution.onExpiration = { [weak self] in
          guard let self, self.result == nil else {
            return
          }
          self.backgroundState = .expired
          self.cancel()
        }
      }

      state = .running
      let context = Context(progress: progress)
      // An unstructured worker deliberately survives dismissal and the submitting task's cancellation.
      worker = Task.detached { [self] in
        let result: Result<Output, any Error>
        do {
          try Task.checkCancellation()
          let output = try await operation(context)
          try Task.checkCancellation()
          result = .success(output)
        } catch {
          result = .failure(error)
        }
        await finish(result)
      }
    }

    private func finish(_ proposedResult: Result<Output, any Error>) {
      guard result == nil else {
        return
      }

      let result: Result<Output, any Error>
      if cancellationRequested {
        result = .failure(CancellationError())
      } else {
        result = proposedResult
      }
      self.result = result

      switch result {
      case .success:
        state = .succeeded
      case .failure(let error):
        if error is CancellationError {
          state = .cancelled
        } else {
          state = .failed
        }
      }

      execution?.complete(success: state == .succeeded)
      execution = nil
      worker = nil
      cancelRequest = nil
      let onFinish = onFinish
      self.onFinish = nil
      onFinish?()

      let waiters = waiters
      self.waiters.removeAll()
      for waiter in waiters {
        waiter.resume(with: result)
      }
    }

  }

}
