import Foundation

/// Owns user-initiated work independently of the screen that submitted it.
/// Job ownership is actor-isolated; observable job state uses the main actor.
public actor ContinuedTaskManager {

  public enum BackgroundPolicy: Sendable {
    case whenAvailable
    case disabled
  }

  public struct Context: Sendable {

    public let progress: Progress

  }

  private let identifierPrefix: String
  private let executor: BackgroundExecutor
  private var jobs: [UUID: any ManagedJob] = [:]

  public init(identifierPrefix: String) {
    self.identifierPrefix = identifierPrefix
    self.executor = makeBackgroundExecutor()
  }

  init(identifierPrefix: String, executor: BackgroundExecutor) {
    self.identifierPrefix = identifierPrefix
    self.executor = executor
  }

  /// Each submission is independent. Background rejection falls back to ordinary execution.
  /// The operation must cooperate with cancellation and report real progress.
  public func submit<Output: Sendable>(
    title: String,
    subtitle: String,
    background: BackgroundPolicy = .whenAvailable,
    operation: @escaping @Sendable (Context) async throws -> Output
  ) async -> Job<Output> {
    let job = Job<Output>(title: title, subtitle: subtitle) { [self] id in
      Task {
        await removeJob(id: id)
      }
    }
    let identifier = "\(identifierPrefix).\(job.id.uuidString)"
    jobs[job.id] = job

    await MainActor.run { [executor] in
      // cancelAll() can run while this submission waits for the main actor.
      guard job.state == .pending else {
        return
      }

      switch background {
      case .disabled:
        job.start(operation: operation)
      case .whenAvailable:
        job.backgroundState = .requesting
        job.cancelRequest = {
          executor.cancel(identifier: identifier)
        }

        do {
          try executor.submit(identifier: identifier, title: title, subtitle: subtitle) { [weak job] execution in
            guard let job else {
              execution.complete(success: false)
              return
            }
            job.start(execution: execution, operation: operation)
          }
        } catch {
          job.backgroundState = .unavailable(error)
          job.cancelRequest = nil
          job.start(operation: operation)
        }
      }
    }

    return job
  }

  /// Cancels the jobs owned when this call begins; later submissions are independent.
  public func cancelAll() async {
    for job in Array(jobs.values) {
      await job.cancel()
    }
  }

  private func removeJob(id: UUID) {
    jobs.removeValue(forKey: id)
  }

}

@MainActor
protocol ManagedJob: AnyObject, Sendable {

  func cancel()

}
