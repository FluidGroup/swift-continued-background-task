# Continued Task Manager

Run user-initiated async work that can continue after your iOS app enters the background. `ContinuedTaskManager` wraps Apple's [`BGContinuedProcessingTask`](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask), with typed results, observable job state, progress, and cooperative cancellation.

On iOS 26 and later, it requests continued background execution. If the request is rejected or the platform does not support it, the same operation runs as an ordinary app task. Use it for work a person starts while your app is in the foreground, such as exporting media or processing files.

## Usage

Keep a manager at app lifetime. Given an app-provided `[URL]` named `fileURLs`, this example computes a checksum for each file:

```swift
import ContinuedTaskManager
import CryptoKit
import Foundation

let manager = ContinuedTaskManager(identifierPrefix: "com.example.app.checksums")

let job = await manager.submit(
  title: "Compute checksums",
  subtitle: "Processing \(fileURLs.count) files"
) { context in
  context.progress.totalUnitCount = Int64(fileURLs.count)
  var checksums: [String] = []

  for url in fileURLs {
    try Task.checkCancellation()
    let data = try Data(contentsOf: url)
    checksums.append(SHA256.hash(data: data).description)
    context.progress.completedUnitCount += 1
  }

  return checksums
}

let checksums = try await job.value
```

`submit` returns a `Job<Output>`; `job.value` waits for the result and throws the operation's error or `CancellationError`. Independent submissions can overlap. To skip the background request, pass `background: .disabled` to `submit`; progress, results, and cancellation work the same way.

Requests use Apple's `.fail` submission strategy by default, so rejection falls back immediately without leaving a queued system request that could duplicate the work. Pass `strategy: .queue` to keep a request queued until the system can launch it; the job then stays in `.requesting` until launch, and `job.cancel()` still withdraws it.

The manager is an actor. Its operation closure is `@Sendable`, runs outside the main actor, and must return a `Sendable` value. Read and update observable job state on `MainActor`; the job's `id` and progress reference are `nonisolated`.

## Add to your app

In Xcode, add this package URL and select the **ContinuedTaskManager** product:

```text
https://github.com/FluidGroup/swift-continued-background-task
```

For a Swift package, add the dependency and then the product to your target:

```swift
// Package.dependencies
.package(
  url: "https://github.com/FluidGroup/swift-continued-background-task",
  branch: "main"
)

// Target.dependencies
.product(name: "ContinuedTaskManager", package: "swift-continued-background-task")
```

The package uses Swift tools 6.0 and supports iOS 17+ and macOS 14+. Building for iOS requires the iOS 26 SDK or later (Xcode 26+). Continued background execution requires iOS 26+ on a supported device; earlier iOS versions and macOS use ordinary execution.

### Enable iOS background continuation

For an app with bundle identifier `com.example.app` and the example's `com.example.app.checksums` manager prefix, add these entries to the app target's `Info.plist`:

```xml
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
  <string>com.example.app.checksums.*</string>
</array>
<key>UIBackgroundModes</key>
<array>
  <string>processing</string>
</array>
```

Merge these values with any existing entries. In Xcode, `processing` corresponds to **Signing & Capabilities → Background Modes → Background processing**.

The manager's prefix must begin with your app's bundle identifier followed by a dot and contain no wildcard. The manager appends a UUID for each job, so the permitted identifier ends in `.*`. Registration and system task completion are handled by the library.

## Show progress and cancel

Report real work through `context.progress`, using units appropriate to the operation. The separate `job.progress` mirrors its completed fraction, including child progress, in 100 units on the main actor. When continuation is granted, the system's progress is updated too. The last reported fraction remains available after the job finishes.

Call `job.updateTitle(_:subtitle:)` as phases advance; the new values reach the system's continued-task UI once the task has launched and are readable on the job at any time.

Use `job.progress` for display and `job.cancel()` to request cancellation:

```swift
import ContinuedTaskManager
import SwiftUI

struct ChecksumJobView: View {

  let job: ContinuedTaskManager.Job<[String]>

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(job.title)
      ProgressView(job.progress)

      if job.state == .pending || job.state == .running {
        Button("Cancel", role: .destructive) {
          job.cancel()
        }
      }
    }
  }

}
```

Jobs survive the submitting task's cancellation and screen dismissal. Cancelling a task that is awaiting `job.value` does not cancel the job or stop that wait; cancel the job explicitly. Outside the main actor, call `await job.cancel()`. Use `await manager.cancelAll()` to cancel the jobs the manager owns when the call begins; later submissions are independent.

Cancellation is cooperative: check `Task.checkCancellation()` between work units or use cancellation-aware APIs. A running job finishes after its operation returns, including cleanup. System expiration or cancellation through the system UI also requests job cancellation.

### Understand fallback

`job.state` describes the work: `.pending`, `.running`, `.succeeded`, `.failed`, or `.cancelled`. `job.backgroundState` separately describes the continuation request:

| Background state | Meaning |
| --- | --- |
| `.notRequested` | Submitted with `background: .disabled`. |
| `.requesting` | Waiting for the system to launch the continued task. |
| `.granted` | Continued execution was granted; this does not mean the app is currently in the background. |
| `.unavailable(error)` | The platform is unsupported or the request failed; the operation runs ordinarily. Inspect the associated error for configuration or scheduling problems. |
| `.expired` | The system expired the continued task or the person stopped it through system UI. |
| `.cancelled` | The job was cancelled while its continuation request was pending. |

A successful job can have `.unavailable` background state.

### Request background GPU access

For GPU-backed operations, pass `requiredResources: [.gpu]` to `submit`. The default `[]` requests no additional resources and supports CPU/network work.

Background GPU use also requires a supported device and the app target's **Background GPU Access** capability (`com.apple.developer.background-tasks.continued-processing.gpu`). Check `BGTaskScheduler.supportedResources.contains(.gpu)` on iOS 26+ before offering background GPU work. The library forwards the resource requirement; it does not add the entitlement or check GPU availability for you. Rejected requests still fall back to ordinary execution.

See Apple's [continued-processing guide](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados) and [GPU entitlement documentation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.background-tasks.continued-processing.gpu) for device and capability requirements.

## Execution limits

Continuation never guarantees completion. Ordinary execution may be suspended or terminated when the app backgrounds, and even granted tasks can expire. Report accurate progress and make cancellation checks frequent enough for your workload.

This is in-process task management. Checkpointing, persistence, and restoration after process termination belong to your app. It does not schedule periodic work or relaunch your app to resume a job.

## Try the demo

Open [`Development/Demo.xcodeproj`](Development/Demo.xcodeproj) in **Xcode 27 or later**, select a signing team for a physical device, and run the **Demo** scheme. The project uses Apple's JSON `project.xcproj` format, modeled by [xcode-project-format](https://github.com/apple/xcode-project-format), and needs no generation step.

Start a checksum job with or without continuation, follow its progress, cancel an individual job or all jobs, and leave the app to try continued execution. Use a physical iOS 26+ device to validate actual background execution; the simulator is useful for ordinary execution and rejection fallback.

With [mise](https://mise.jdx.dev/) installed:

```sh
mise run demo:open
mise run demo:build
mise run test
```

With multiple Xcodes installed, set `DEVELOPER_DIR` to the selected Xcode 27+ `Contents/Developer` directory before running the demo tasks. `demo:build` builds for Simulator without signing. `test` runs the Swift Testing lifecycle suite (`swift test`), covering fallback, ownership, cancellation, progress, and completion handling.
