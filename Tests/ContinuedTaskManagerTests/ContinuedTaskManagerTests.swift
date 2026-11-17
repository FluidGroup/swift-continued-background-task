import Foundation
import Testing
@testable import ContinuedTaskManager

@Suite
@MainActor
struct ContinuedTaskManagerTests {

  @Test func disabledRunsWithoutRequestingBackgroundTime() async throws {
    let executor = TestExecutor()
    let manager = makeManager(executor)
    let job = await manager.submit(title: "Export", subtitle: "", background: .disabled) { context in
      context.progress.totalUnitCount = 2
      context.progress.completedUnitCount = 2
      return 42
    }

    #expect(try await job.value == 42)
    #expect(job.state == .succeeded)
    #expect(job.progress.fractionCompleted == 1)
    #expect(executor.submissionCount == 0)
    guard case .notRequested = job.backgroundState else {
      Issue.record("Background time should not have been requested")
      return
    }
  }

  @Test func rejectionFallsBackAndLateLaunchDoesNotRepeatWork() async throws {
    let executor = TestExecutor()
    executor.rejection = TestError.rejected
    let manager = makeManager(executor)
    let counter = Counter()
    let job = await manager.submit(title: "Export", subtitle: "") { _ in
      await counter.increment()
    }

    #expect(try await job.value == 1)
    guard case .unavailable(let error) = job.backgroundState else {
      Issue.record("The rejection should remain observable")
      return
    }
    #expect(error is TestError)

    let execution = executor.launch()
    #expect(executor.completions == [false])
    execution.complete(success: true)
    #expect(executor.completions == [false])
    #expect(await counter.value == 1)
  }

  @Test func acceptedRequestStartsOnceAndReportsCompletionOnce() async throws {
    let executor = TestExecutor()
    let manager = makeManager(executor)
    let counter = Counter()
    let job = await manager.submit(title: "Export", subtitle: "") { context in
      context.progress.totalUnitCount = 10
      context.progress.completedUnitCount = 10
      return await counter.increment()
    }

    #expect(job.state == .pending)
    #expect(await counter.value == 0)
    let execution = executor.launch()
    #expect(try await job.value == 1)
    #expect(execution.progress.fractionCompleted == 1)
    #expect(executor.completions == [true])
    guard case .granted = job.backgroundState else {
      Issue.record("The request should be granted")
      return
    }

    _ = executor.launch()
    job.cancel()
    #expect(await counter.value == 1)
    #expect(executor.completions == [true, false])
    #expect(job.state == .succeeded)
  }

  @Test func pendingCancellationResolvesValueAndRejectsLateLaunch() async {
    let executor = TestExecutor()
    let manager = makeManager(executor)
    let counter = Counter()
    let job = await manager.submit(title: "Export", subtitle: "") { _ in
      await counter.increment()
    }

    job.cancel()
    job.cancel()
    await #expect(throws: CancellationError.self) {
      try await job.value
    }
    #expect(executor.cancellationCount == 1)
    #expect(job.state == .cancelled)
    _ = executor.launch()
    #expect(executor.completions == [false])
    #expect(await counter.value == 0)
  }

  @Test func expirationCancelsRunningWorkAndCompletesUnsuccessfully() async {
    let executor = TestExecutor()
    let manager = makeManager(executor)
    let started = AsyncStream<Void>.makeStream()
    let job = await manager.submit(title: "Export", subtitle: "") { _ in
      started.continuation.yield(())
      try await Task.sleep(for: .seconds(60))
      return 42
    }
    let execution = executor.launch()
    for await _ in started.stream {
      break
    }

    execution.onExpiration?()
    await #expect(throws: CancellationError.self) {
      try await job.value
    }
    #expect(job.state == .cancelled)
    #expect(executor.completions == [false])
    #expect(execution.onExpiration == nil)
    guard case .expired = job.backgroundState else {
      Issue.record("Expiration should remain observable")
      return
    }
  }

  @Test func operationFailurePreservesErrorAndReportsFailure() async {
    let executor = TestExecutor()
    let manager = makeManager(executor)
    let job = await manager.submit(title: "Export", subtitle: "") { _ -> Int in
      throw TestError.operation
    }
    _ = executor.launch()

    await #expect(throws: TestError.operation) {
      try await job.value
    }
    #expect(job.state == .failed)
    #expect(executor.completions == [false])
  }

  @Test func explicitCancellationWinsOverAnOperationReturningSuccess() async {
    let executor = TestExecutor()
    let manager = makeManager(executor)
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
    let executor = TestExecutor()
    let manager = makeManager(executor)
    let job = await manager.submit(title: "Export", subtitle: "") { _ in 42 }
    let waiter = Task { try await job.value }
    waiter.cancel()
    _ = executor.launch()

    #expect(try await waiter.value == 42)
    #expect(try await job.value == 42)
    #expect(job.state == .succeeded)
  }

  @Test func cancelAllOwnsJobsWithDifferentOutputTypes() async {
    let executor = TestExecutor()
    let manager = makeManager(executor)
    let first = await manager.submit(title: "First", subtitle: "") { _ in 42 }
    let second = await manager.submit(title: "Second", subtitle: "") { _ in "Done" }
    await manager.cancelAll()

    await #expect(throws: CancellationError.self) { try await first.value }
    await #expect(throws: CancellationError.self) { try await second.value }
    #expect(executor.cancellationCount == 2)
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

  private func makeManager(_ executor: TestExecutor) -> ContinuedTaskManager {
    ContinuedTaskManager(identifierPrefix: "com.example.test.work", executor: executor)
  }

}

private enum TestError: Error, Equatable {
  case rejected
  case operation
}

@MainActor
private final class TestExecutor: BackgroundExecutor {

  var rejection: (any Error)?
  var submissionCount = 0
  var cancellationCount = 0
  var completions: [Bool] = []
  private var launchHandler: (@MainActor (BackgroundExecution) -> Void)?

  func submit(
    identifier: String,
    title: String,
    subtitle: String,
    launch: @escaping @MainActor (BackgroundExecution) -> Void
  ) throws {
    submissionCount += 1
    launchHandler = launch
    if let rejection {
      throw rejection
    }
  }

  func cancel(identifier: String) {
    cancellationCount += 1
  }

  func launch() -> BackgroundExecution {
    let execution = BackgroundExecution(progress: Progress(totalUnitCount: 0)) { [self] success in
      completions.append(success)
    }
    launchHandler?(execution)
    return execution
  }

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
