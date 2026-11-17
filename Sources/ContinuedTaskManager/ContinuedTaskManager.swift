import Foundation

/// Owns user-initiated work independently of the screen that submitted it.
/// Admission and observable state use the main actor; operations run on a separate task executor.
@MainActor
public final class ContinuedTaskManager {

  public enum BackgroundPolicy: Sendable {
    case whenAvailable
    case disabled
  }

  public struct Context: Sendable {

    public let progress: Progress

  }

  private let identifierPrefix: String
  private let executor: any BackgroundExecutor
  private var jobs: [UUID: any ManagedJob] = [:]

  public init(identifierPrefix: String) {
    self.identifierPrefix = identifierPrefix
    self.executor = makeBackgroundExecutor()
  }

  init(identifierPrefix: String, executor: any BackgroundExecutor) {
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
  ) -> Job<Output> {
    let job = Job<Output>(title: title, subtitle: subtitle)
    let identifier = "\(identifierPrefix).\(job.id.uuidString)"
    jobs[job.id] = job
    job.onFinish = { [self] in
      jobs.removeValue(forKey: job.id)
    }

    switch background {
    case .disabled:
      job.start(operation: operation)
    case .whenAvailable:
      job.backgroundState = .requesting
      job.cancelRequest = { [executor] in
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

    return job
  }

  public func cancelAll() {
    for job in Array(jobs.values) {
      job.cancel()
    }
  }

}

@MainActor
protocol ManagedJob: AnyObject {

  func cancel()

}
