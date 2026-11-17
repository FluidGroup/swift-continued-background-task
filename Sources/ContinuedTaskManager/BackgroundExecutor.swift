import Foundation

@MainActor
protocol BackgroundExecutor: AnyObject {

  func submit(
    identifier: String,
    title: String,
    subtitle: String,
    launch: @escaping @MainActor (BackgroundExecution) -> Void
  ) throws

  func cancel(identifier: String)

}

/// Keeps OS completion idempotent, including callbacks arriving after cancellation.
@MainActor
final class BackgroundExecution {

  let progress: Progress
  var onExpiration: (() -> Void)?
  private var completion: ((Bool) -> Void)?

  init(progress: Progress, completion: @escaping (Bool) -> Void) {
    self.progress = progress
    self.completion = completion
  }

  func complete(success: Bool) {
    let completion = completion
    self.completion = nil
    onExpiration = nil
    completion?(success)
  }

}

enum BackgroundUnavailable: LocalizedError {
  case unsupported
  case invalidIdentifier
  case missingPermittedIdentifier
  case registrationFailed

  var errorDescription: String? {
    switch self {
    case .unsupported:
      "Continued background execution requires iOS 26 or later on a supported device."
    case .invalidIdentifier:
      "The identifier prefix must start with the app's bundle identifier and contain no wildcard."
    case .missingPermittedIdentifier:
      "Add the identifier prefix followed by .* to BGTaskSchedulerPermittedIdentifiers."
    case .registrationFailed:
      "The system could not register the continued background task."
    }
  }
}

@MainActor
func makeBackgroundExecutor() -> any BackgroundExecutor {
  #if os(iOS) && !targetEnvironment(macCatalyst)
  if #available(iOS 26, *) {
    return SystemBackgroundExecutor()
  }
  #endif
  return UnsupportedBackgroundExecutor()
}

@MainActor
private final class UnsupportedBackgroundExecutor: BackgroundExecutor {

  func submit(
    identifier: String,
    title: String,
    subtitle: String,
    launch: @escaping @MainActor (BackgroundExecution) -> Void
  ) throws {
    throw BackgroundUnavailable.unsupported
  }

  func cancel(identifier: String) {}

}

#if os(iOS) && !targetEnvironment(macCatalyst)
import BackgroundTasks

@available(iOS 26, *)
@MainActor
private final class SystemBackgroundExecutor: BackgroundExecutor {

  private var launches: [String: @MainActor (BackgroundExecution) -> Void] = [:]

  func submit(
    identifier: String,
    title: String,
    subtitle: String,
    launch: @escaping @MainActor (BackgroundExecution) -> Void
  ) throws {
    guard let bundleID = Bundle.main.bundleIdentifier,
      identifier.hasPrefix(bundleID + "."), !identifier.contains("*")
    else {
      throw BackgroundUnavailable.invalidIdentifier
    }
    let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
    guard permitted.contains(where: { pattern in
      pattern == identifier || (pattern.hasSuffix(".*") && identifier.hasPrefix(String(pattern.dropLast())))
    }) else {
      throw BackgroundUnavailable.missingPermittedIdentifier
    }

    launches[identifier] = launch
    // Registrations outlive individual jobs. The scheduler closure must not retain their operations.
    let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
      MainActor.assumeIsolated {
        guard let task = task as? BGContinuedProcessingTask else {
          task.setTaskCompleted(success: false)
          return
        }
        guard let launch = self?.launches.removeValue(forKey: identifier) else {
          task.setTaskCompleted(success: false)
          return
        }
        let execution = BackgroundExecution(progress: task.progress) { success in
          task.expirationHandler = nil
          task.setTaskCompleted(success: success)
        }
        task.expirationHandler = { [weak execution] in
          Task { @MainActor in
            execution?.onExpiration?()
          }
        }
        launch(execution)
      }
    }

    guard registered else {
      launches.removeValue(forKey: identifier)
      throw BackgroundUnavailable.registrationFailed
    }

    let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
    request.strategy = .fail
    do {
      try BGTaskScheduler.shared.submit(request)
    } catch {
      launches.removeValue(forKey: identifier)
      throw error
    }
  }

  func cancel(identifier: String) {
    launches.removeValue(forKey: identifier)
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
  }

}
#endif
