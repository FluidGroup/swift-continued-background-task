import Foundation
import Observation

extension ContinuedTaskManager {

  /// A submitted operation and its observable execution state.
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
    public enum BackgroundState: Sendable {
      case notRequested
      case requesting
      case granted
      case unavailable(any Error)
      case expired
      case cancelled
    }

    public nonisolated let id = UUID()
    /// The title reported at submission and by later ``updateTitle(_:subtitle:)`` calls.
    public private(set) var title: String
    /// The subtitle reported at submission and by later ``updateTitle(_:subtitle:)`` calls.
    public private(set) var subtitle: String
    /// The operation's completed fraction in 100 units, updated on the main actor.
    ///
    /// Report work through ``Context/progress`` and request cancellation with ``cancel()``.
    /// The last reported value remains available after the job finishes.
    public nonisolated let progress: Progress
    public private(set) var state: State = .pending
    public internal(set) var backgroundState: BackgroundState = .notRequested

    @ObservationIgnored var cancelRequest: (() -> Void)?
    @ObservationIgnored private var onFinish: (@Sendable (UUID) -> Void)?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var execution: BackgroundExecution?
    @ObservationIgnored private var progressObservation: ProgressObservation?
    @ObservationIgnored private var result: Result<Output, any Error>?
    @ObservationIgnored private var waiters: [CheckedContinuation<Output, any Error>] = []
    @ObservationIgnored private var cancellationRequested = false

    init(
      title: String,
      subtitle: String,
      onFinish: @escaping @Sendable (UUID) -> Void
    ) {
      self.title = title
      self.subtitle = subtitle
      self.onFinish = onFinish
      self.progress = Progress(totalUnitCount: 100)
      self.progress.isCancellable = false
    }

    /// Renames the work shown in the system's continued-task UI.
    ///
    /// The update reaches the system task once it launches; before that it
    /// only changes this job's own values.
    public func updateTitle(_ title: String, subtitle: String) {
      self.title = title
      self.subtitle = subtitle
      execution?.updateTitle?(title, subtitle)
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
      guard result == nil, !cancellationRequested else {
        return
      }
      cancellationRequested = true

      if let worker {
        worker.cancel()
        return
      }

      cancelRequest?()
      if case .requesting = backgroundState {
        backgroundState = .cancelled
      }
      finish(.failure(CancellationError()))
    }

    func start(
      execution: BackgroundExecution? = nil,
      operation: @escaping @Sendable (Context) async throws -> Output
    ) {
      guard worker == nil, result == nil, !cancellationRequested else {
        execution?.complete(success: false)
        return
      }

      self.execution = execution
      cancelRequest = nil
      execution?.updateTitle?(title, subtitle)

      // An unstructured worker deliberately survives dismissal and the submitting task's cancellation.
      worker = Task.detached { [self] in
        let result: Result<Output, any Error>
        do {
          let context = try await makeContext()
          let output = try await operation(context)
          try Task.checkCancellation()
          result = .success(output)
        } catch {
          result = .failure(error)
        }
        await finish(result)
      }

      if let execution {
        execution.onExpiration = { [weak self] in
          guard let self, self.result == nil else {
            return
          }
          self.backgroundState = .expired
          self.cancel()
        }
        backgroundState = .granted
        execution.progress.totalUnitCount = 100
      }
      state = .running
    }

    private func makeContext() throws -> Context {
      // Start observers can cancel synchronously before the worker enters the main actor here.
      try Task.checkCancellation()

      let observation = ProgressObservation(presentation: progress, system: execution?.progress)
      progressObservation = observation
      return Context(
        progress: observation.source,
        titleUpdater: { [weak self] title, subtitle in
          await self?.updateTitle(title, subtitle: subtitle)
        }
      )
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

      progressObservation?.finish()
      progressObservation = nil
      execution?.complete(success: state == .succeeded)
      execution = nil
      worker = nil
      cancelRequest = nil
      let onFinish = onFinish
      self.onFinish = nil
      onFinish?(id)

      let waiters = waiters
      self.waiters.removeAll()
      for waiter in waiters {
        waiter.resume(with: result)
      }
    }

    /// Publishes the operation's fraction to the job and system until the job finishes.
    @MainActor
    private final class ProgressObservation {

      let source = Progress(totalUnitCount: 0)
      private let presentation: Progress
      private let system: Progress?
      private let observation: NSKeyValueObservation
      private var updates: Task<Void, Never>?

      init(presentation: Progress, system: Progress?) {
        self.presentation = presentation
        self.system = system

        // Only the latest fraction matters while the main actor is busy.
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.observation = source.observe(\.fractionCompleted, options: [.initial, .new]) { _, _ in
          continuation.yield(())
        }
        self.updates = Task { [weak self] in
          for await _ in stream {
            guard let self, !Task.isCancelled else {
              return
            }
            self.publish()
          }
        }
      }

      func finish() {
        observation.invalidate()
        updates?.cancel()
        publish()
      }

      private func publish() {
        let fraction = source.fractionCompleted
        guard fraction.isFinite else {
          return
        }

        // Reserve 100 units for a fully completed operation.
        let completed: Int64
        if fraction >= 1 {
          completed = 100
        } else {
          completed = min(99, Int64((max(0, fraction) * 100).rounded()))
        }
        if presentation.completedUnitCount != completed {
          presentation.completedUnitCount = completed
        }
        // A parent credits a child's units only when it finishes, so write system units directly.
        if let system, system.completedUnitCount != completed {
          system.completedUnitCount = completed
        }
      }

    }

  }

}
