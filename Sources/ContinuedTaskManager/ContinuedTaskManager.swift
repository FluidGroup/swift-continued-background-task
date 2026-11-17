import Foundation

/// Owns user-initiated work independently of the screen that submitted it.
/// Job ownership is actor-isolated; observable job state uses the main actor.
public actor ContinuedTaskManager {

  public enum BackgroundPolicy: Sendable {
    case whenAvailable
    case disabled
  }

  /// How the system handles a request it cannot launch immediately.
  public enum SubmissionStrategy: Sendable {
    /// Reject the request; the job then runs ordinarily.
    case fail
    /// Keep the request queued until the system launches it.
    case queue
  }

  /// Values supplied to an operation while its job is running.
  public struct Context: Sendable {

    /// The operation's progress in its own units, including any child progress.
    public let progress: Progress

    /// Renames the work in the system's continued-task UI and on the job.
    public let updateTitle: @Sendable (String, String) async -> Void

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
    strategy: SubmissionStrategy = .fail,
    requiredResources: BackgroundTaskRequiredResources = [],
    operation: @escaping @Sendable (Context) async throws -> Output
  ) async -> Job<Output> {
    
    let job = await MainActor.run {
      Job<Output>(
        title: title,
        subtitle: subtitle
      ) { [self] id in

        Task {
          await removeJob(id: id)
        }
      }
    }

    let identifier = "\(identifierPrefix).\(job.id.uuidString)"

    addJob(id: job.id, job: job)

    await MainActor.run { [executor] in
      // cancelAll() can run while this submission waits for the main actor.
      guard job.state == .pending else {
        return
      }

      switch (background, executor) {
      case (.disabled, _):
        job.start(operation: operation)
      case (.whenAvailable, .unsupported):
        job.backgroundState = .unavailable(BackgroundUnavailable.unsupported)
        job.start(operation: operation)
      #if os(iOS) && !targetEnvironment(macCatalyst)
      case (.whenAvailable, .system(let executor)):
        job.backgroundState = .requesting
        job.cancelRequest = {
          executor.cancel(identifier: identifier)
        }

        do {
          try executor.submit(
            identifier: identifier,
            title: title,
            subtitle: subtitle,
            requiredResources: requiredResources,
            strategy: strategy
          ) { [weak job] execution in
            
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
      #endif
      }
    }

    return job
  }

  /// Cancels the jobs owned when this call begins; later submissions are independent.
  public func cancelAll() async {
    for job in jobs.values {
      await job.cancel()
    }
  }

  private func removeJob(id: UUID) {
    jobs.removeValue(forKey: id)
  }
  
  private func addJob(id: UUID, job: any ManagedJob) {
    jobs[id] = job
  }

}

@MainActor
protocol ManagedJob: AnyObject, Sendable {

  func cancel()

}
