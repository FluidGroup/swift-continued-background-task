import ContinuedTaskManager
import CryptoKit
import Observation
import SwiftUI

@main
struct DemoApp: App {

  @State private var model = DemoModel()

  var body: some Scene {
    WindowGroup {
      DemoView(model: model)
    }
  }

}

@MainActor
@Observable
private final class DemoModel {

  let manager = ContinuedTaskManager(identifierPrefix: "app.fluidgroup.ContinuedTaskDemo.work")
  private(set) var jobs: [ContinuedTaskManager.Job<String>] = []

  func start(background: ContinuedTaskManager.BackgroundPolicy) async {
    let job = await manager.submit(
      title: "Compute checksums",
      subtitle: "Hashing 32 GiB of sample data",
      background: background
    ) { context in
      let block = Data(repeating: 0x5A, count: 1_048_576)
      context.progress.totalUnitCount = 512
      var digest = ""

      for batch in 0..<512 {
        for _ in 0..<64 {
          try Task.checkCancellation()
          digest = SHA256.hash(data: block).description
        }
        context.progress.completedUnitCount = Int64(batch + 1)
      }

      return digest
    }
    jobs.insert(job, at: 0)
  }

}

private struct DemoView: View {

  private let model: DemoModel

  init(model: DemoModel) {
    self.model = model
  }

  var body: some View {
    NavigationStack {
      List {
        Section {
          Button("Start with background continuation", systemImage: "play.fill") {
            Task {
              await model.start(background: .whenAvailable)
            }
          }
          Button("Start without background continuation", systemImage: "iphone") {
            Task {
              await model.start(background: .disabled)
            }
          }
        } footer: {
          Text("The job hashes sample data on the CPU. On a supported device, start a job and leave the app to see system progress. A rejected continuation request still runs the job while the app is active.")
        }

        Section("Jobs") {
          if model.jobs.isEmpty {
            Text("Start a job to follow its progress.")
              .foregroundStyle(.secondary)
          }
          ForEach(model.jobs) { job in
            JobRow(job: job)
          }
        }
      }
      .navigationTitle("Continued Tasks")
      .toolbar {
        Button("Cancel all", role: .destructive) {
          Task {
            await model.manager.cancelAll()
          }
        }
      }
    }
  }

}

private struct JobRow: View {

  private let job: ContinuedTaskManager.Job<String>
  @State private var outcome: String?

  init(job: ContinuedTaskManager.Job<String>) {
    self.job = job
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(job.title)
          .font(.headline)
        Spacer()
        Text(stateText)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      ProgressView(job.progress)
      Label(backgroundText, systemImage: "app.badge")
        .font(.caption)
        .foregroundStyle(.secondary)

      if let outcome {
        Text(outcome)
          .font(.caption.monospaced())
          .textSelection(.enabled)
      }

      if job.state == .pending || job.state == .running {
        Button("Cancel job", role: .destructive) {
          job.cancel()
        }
      }
    }
    .padding(.vertical, 6)
    .task {
      do {
        outcome = try await job.value
      } catch is CancellationError {
        outcome = "Cancelled"
      } catch {
        outcome = error.localizedDescription
      }
    }
  }

  private var stateText: String {
    switch job.state {
    case .pending: "Waiting to start"
    case .running: "Running"
    case .succeeded: "Completed"
    case .failed: "Failed"
    case .cancelled: "Cancelled"
    }
  }

  private var backgroundText: String {
    switch job.backgroundState {
    case .notRequested: "Background continuation not requested"
    case .requesting: "Requesting background continuation"
    case .granted: "Background continuation granted"
    case .unavailable(let error): "Foreground execution: \(error.localizedDescription)"
    case .expired: "Background continuation ended by the system or user"
    case .cancelled: "Background request cancelled"
    }
  }

}

#Preview {
  DemoView(model: DemoModel())
}
