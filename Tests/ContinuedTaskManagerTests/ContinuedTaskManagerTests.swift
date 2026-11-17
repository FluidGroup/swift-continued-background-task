import Foundation
import Testing
@testable import ContinuedTaskManager

@Suite
@MainActor
struct ContinuedTaskManagerTests {

  @Test func disabledRunsWithoutRequestingBackgroundTime() async throws {
    let manager = ContinuedTaskManager(identifierPrefix: "com.example.test.work", executor: .unsupported)
    let job = await manager.submit(title: "Export", subtitle: "", background: .disabled) { context in
      context.progress.totalUnitCount = 2
      context.progress.completedUnitCount = 2
      return 42
    }

    #expect(try await job.value == 42)
    #expect(job.state == .succeeded)
    #expect(job.progress.fractionCompleted == 1)
    guard case .notRequested = job.backgroundState else {
      Issue.record("Background time should not have been requested")
      return
    }
  }

  @Test func unsupportedBackgroundExecutionFallsBack() async throws {
    let manager = ContinuedTaskManager(identifierPrefix: "com.example.test.work", executor: .unsupported)
    let job = await manager.submit(title: "Export", subtitle: "") { _ in 42 }

    #expect(try await job.value == 42)
    #expect(job.state == .succeeded)
    guard case .unavailable(BackgroundUnavailable.unsupported) = job.backgroundState else {
      Issue.record("Unsupported background execution should remain observable")
      return
    }
  }

  @Test func ordinaryExecutionRejectsLateBackgroundLaunch() async throws {
    let manager = ContinuedTaskManager(identifierPrefix: "com.example.test.work", executor: .unsupported)
    let counter = Counter()
    let job = await manager.submit(title: "Export", subtitle: "") { _ in
      await counter.increment()
    }

    #expect(try await job.value == 1)
    var completions: [Bool] = []
    let execution = BackgroundExecution(progress: Progress(totalUnitCount: 0)) {
      completions.append($0)
    }
    job.start(execution: execution) { _ in
      await counter.increment()
    }
    #expect(completions == [false])
    execution.complete(success: true)
    #expect(completions == [false])
    #expect(await counter.value == 1)
  }

  #if os(iOS) && !targetEnvironment(macCatalyst)
  @Test func rejectedBackgroundRequestFallsBack() async throws {
    let manager = ContinuedTaskManager(
      identifierPrefix: "invalid",
      executor: .system(SystemBackgroundExecutor())
    )
    let job = await manager.submit(title: "Export", subtitle: "") { _ in 42 }

    #expect(try await job.value == 42)
    #expect(job.state == .succeeded)
    guard case .unavailable = job.backgroundState else {
      Issue.record("The rejection should remain observable")
      return
    }
  }
  #endif

  @Test func backgroundExecutionStartsOnceAndReportsCompletionOnce() async throws {
    let job = ContinuedTaskManager.Job<Int>(title: "Export", subtitle: "") { _ in }
    let counter = Counter()
    let operation: @Sendable (ContinuedTaskManager.Context) async -> Int = { context in
      context.progress.totalUnitCount = 10
      context.progress.completedUnitCount = 10
      return await counter.increment()
    }

    #expect(job.state == .pending)
    #expect(await counter.value == 0)
    var completions: [Bool] = []
    let execution = BackgroundExecution(progress: Progress(totalUnitCount: 0)) {
      completions.append($0)
    }
    job.start(execution: execution, operation: operation)
    #expect(try await job.value == 1)
    #expect(execution.progress.fractionCompleted == 1)
    #expect(completions == [true])
    guard case .granted = job.backgroundState else {
      Issue.record("The request should be granted")
      return
    }

    let lateExecution = BackgroundExecution(progress: Progress(totalUnitCount: 0)) {
      completions.append($0)
    }
    job.start(execution: lateExecution, operation: operation)
    job.cancel()
    #expect(await counter.value == 1)
    #expect(completions == [true, false])
    #expect(job.state == .succeeded)
  }

  @Test func pendingCancellationResolvesValueAndRejectsLateLaunch() async {
    let job = ContinuedTaskManager.Job<Int>(title: "Export", subtitle: "") { _ in }
    job.backgroundState = .requesting
    var cancellationCount = 0
    job.cancelRequest = {
      cancellationCount += 1
    }
    let counter = Counter()

    job.cancel()
    job.cancel()
    await #expect(throws: CancellationError.self) {
      try await job.value
    }
    #expect(cancellationCount == 1)
    #expect(job.state == .cancelled)
    guard case .cancelled = job.backgroundState else {
      Issue.record("The pending background request should be cancelled")
      return
    }
    var completions: [Bool] = []
    let execution = BackgroundExecution(progress: Progress(totalUnitCount: 0)) {
      completions.append($0)
    }
    job.start(execution: execution) { _ in
      await counter.increment()
    }
    #expect(completions == [false])
    #expect(await counter.value == 0)
  }

  @Test func expirationCancelsRunningWorkAndCompletesUnsuccessfully() async {
    let job = ContinuedTaskManager.Job<Int>(title: "Export", subtitle: "") { _ in }
    let started = AsyncStream<Void>.makeStream()
    var completions: [Bool] = []
    let execution = BackgroundExecution(progress: Progress(totalUnitCount: 0)) {
      completions.append($0)
    }
    job.start(execution: execution) { _ in
      started.continuation.yield(())
      try await Task.sleep(for: .seconds(60))
      return 42
    }
    for await _ in started.stream {
      break
    }

    execution.onExpiration?()
    await #expect(throws: CancellationError.self) {
      try await job.value
    }
    #expect(job.state == .cancelled)
    #expect(completions == [false])
    #expect(execution.onExpiration == nil)
    guard case .expired = job.backgroundState else {
      Issue.record("Expiration should remain observable")
      return
    }
  }

  @Test func operationFailurePreservesErrorAndReportsFailure() async {
    let job = ContinuedTaskManager.Job<Int>(title: "Export", subtitle: "") { _ in }
    var completions: [Bool] = []
    let execution = BackgroundExecution(progress: Progress(totalUnitCount: 0)) {
      completions.append($0)
    }
    job.start(execution: execution) { _ in
      throw TestError.operation
    }

    await #expect(throws: TestError.operation) {
      try await job.value
    }
    #expect(job.state == .failed)
    #expect(completions == [false])
  }

  @Test func explicitCancellationWinsOverAnOperationReturningSuccess() async {
    let manager = ContinuedTaskManager(identifierPrefix: "com.example.test.work", executor: .unsupported)
    let started = AsyncStream<Void>.makeStream()
    let gate = Gate()
    let job = await manager.submit(title: "Export", subtitle: "", background: .disabled) { _ in
      await gate.wait(started: started.continuation)
      return 42
    }
    for await _ in started.stream {
      break
    }

    job.cancel()
    await gate.open()
    await #expect(throws: CancellationError.self) {
      try await job.value
    }
    #expect(job.state == .cancelled)
  }

  @Test func cancellingAWaiterDoesNotCancelTheJob() async throws {
    let job = ContinuedTaskManager.Job<Int>(title: "Export", subtitle: "") { _ in }
    let waiter = Task { try await job.value }
    waiter.cancel()
    job.start { _ in 42 }

    #expect(try await waiter.value == 42)
    #expect(try await job.value == 42)
    #expect(job.state == .succeeded)
  }

  @Test func cancelAllOwnsJobsWithDifferentOutputTypes() async {
    let manager = ContinuedTaskManager(identifierPrefix: "com.example.test.work", executor: .unsupported)
    let first = await manager.submit(title: "First", subtitle: "") { _ in
      try await Task.sleep(for: .seconds(60))
      return 42
    }
    let second = await manager.submit(title: "Second", subtitle: "") { _ in
      try await Task.sleep(for: .seconds(60))
      return "Done"
    }
    await manager.cancelAll()

    await #expect(throws: CancellationError.self) { try await first.value }
    await #expect(throws: CancellationError.self) { try await second.value }
    #expect(first.state == .cancelled)
    #expect(second.state == .cancelled)
  }

  @Test nonisolated func managerAndJobMetadataAreUsableOutsideMainActor() async throws {
    let manager = ContinuedTaskManager(identifierPrefix: "com.example.test.work")
    let job = await manager.submit(title: "Export", subtitle: "Preparing", background: .disabled) { context in
      context.progress.totalUnitCount = 1
      context.progress.completedUnitCount = 1
      return 42
    }

    #expect(job.title == "Export")
    #expect(job.subtitle == "Preparing")
    #expect(try await job.value == 42)
    #expect(job.progress.fractionCompleted == 1)
    #expect(await job.state == .succeeded)
    await manager.cancelAll()
  }

  @Test nonisolated func cancelAllOwnsConcurrentSubmissions() async {
    let manager = ContinuedTaskManager(identifierPrefix: "com.example.test.work")
    let jobs = await withTaskGroup(of: ContinuedTaskManager.Job<Int>.self) { group in
      for index in 0..<8 {
        group.addTask {
          await manager.submit(title: "Job \(index)", subtitle: "", background: .disabled) { _ in
            try await Task.sleep(for: .seconds(60))
            return index
          }
        }
      }

      var jobs: [ContinuedTaskManager.Job<Int>] = []
      for await job in group {
        jobs.append(job)
      }
      return jobs
    }

    await manager.cancelAll()
    for job in jobs {
      await #expect(throws: CancellationError.self) { try await job.value }
    }
  }

}

private enum TestError: Error, Equatable {
  case operation
}

private actor Counter {

  var value = 0

  func increment() -> Int {
    value += 1
    return value
  }

}

private actor Gate {

  private var continuation: CheckedContinuation<Void, Never>?

  func wait(started: AsyncStream<Void>.Continuation) async {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      started.yield(())
    }
  }

  func open() {
    continuation?.resume()
    continuation = nil
  }

}
