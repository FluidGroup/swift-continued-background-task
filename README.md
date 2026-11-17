# Continued Task Manager

Run user-initiated async work with optional iOS 26 continued background execution. If the system rejects the request or the OS does not support it, the same operation runs as an ordinary app task.

```swift
import ContinuedTaskManager

// Keep the manager at app lifetime. Observable job state uses the main actor.
let manager = ContinuedTaskManager(identifierPrefix: "com.example.app.export")
let job = await manager.submit(title: "Export photos", subtitle: "Preparing") { context in
  context.progress.totalUnitCount = Int64(photos.count)
  for photo in photos {
    try Task.checkCancellation()
    try await export(photo)
    context.progress.completedUnitCount += 1
  }
  return destinationURL
}

let url = try await job.value
// await job.cancel() requests cancellation; await manager.cancelAll() cancels all owned jobs.
```

The manager is an actor. Operations are `@Sendable` and execute outside the main actor; observable job state uses `MainActor`. Job identifiers, titles, subtitles, and progress references are `nonisolated`. Jobs survive the submitting task or screen; cancelling a result waiter does not cancel the work. Independent submissions may overlap. Use `background: .disabled` for ordinary execution with the same progress and cancellation interface.

`job.state` describes the work; `job.backgroundState` separately exposes whether continuation was granted or why it was unavailable. Report progress through `context.progress`. The separate `job.progress` mirrors its completed fraction, including child progress, in 100 units on the main actor for use with SwiftUI's `ProgressView`. When background execution is granted, the system's progress is also updated in 100 units. Background requests use `.fail` internally, so rejected requests fall back without leaving an OS-queued duplicate.

For iOS 26 continuation, add `com.example.app.export.*` to `BGTaskSchedulerPermittedIdentifiers` and `processing` to `UIBackgroundModes`. The prefix must begin with your app's bundle ID. The package supports iOS 17+ and macOS 14+ with ordinary execution on systems without continued processing.

Continuation never guarantees completion. Report real progress and cooperate with cancellation; system expiration cancels the job, including when the user stops it through system UI. Ordinary execution may be suspended or terminated when the app backgrounds. Checkpointing, persistence, and restoration after process termination belong to the app. This initial implementation requests CPU/network execution, not background GPU access. See [Apple's continued-processing guide](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados).

Open `Development/Demo.xcodeproj` in **Xcode 27 or later**, select a signing team for a physical device, and run the `Demo` scheme. Its configuration is Apple's JSON `project.xcproj` format, modeled by [xcode-project-format](https://github.com/apple/xcode-project-format); there is no project-generation step. Start a checksum job, follow progress, cancel it, or leave the app to try system continuation. Use a physical device for actual background-runtime validation; the simulator is useful for ordinary execution and rejection fallback.

Run `mise run test` for the lifecycle tests or `mise run demo:build` to build the demo for Simulator. With multiple Xcodes installed, set `DEVELOPER_DIR` to the Xcode 27+ `Contents/Developer` directory first.
