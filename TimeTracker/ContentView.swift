import SwiftUI
import AppKit
internal import Combine

struct ContentView: View {
    @ObservedObject var state: AppState

    @State private var showingAdd = false
    @State private var newProjectName = ""

    @State private var now = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Picker("Project", selection: Binding(
                    get: { state.selectedProjectId },
                    set: { state.selectedProjectId = $0 }
                )) {
                    ForEach(state.projects) { p in
                        Text(p.name).tag(Optional(p.id))
                    }
                }
                .frame(minWidth: 220)

                Button {
                    newProjectName = ""
                    showingAdd = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add project")
            }

            HStack(spacing: 10) {
                Button {
                    state.toggleStartStop()
                } label: {
                    Text(state.runningEntry != nil ? "Stop" : "Start")
                        .frame(width: 90)
                }
                .keyboardShortcut(.space, modifiers: [])

                if let pid = state.selectedProjectId {
                    let todaySecs = state.totalSecondsTodayLive(for: pid, at: now)
                    Text("Today: \(formatHMS(todaySecs))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)

                    if state.runningEntry != nil {
                        let runSecs = state.runningSeconds(at: now)
                        Text("Session: \(formatHMS(runSecs))")
                            .monospacedDigit()
                    }
                } else {
                    Text("Pick a project")
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            if let running = state.runningEntry,
               let p = state.projects.first(where: { $0.id == running.projectId }) {
                Text("Running: \(p.name)")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Divider()

            HStack {
                Button("Export CSV") {
                    if let url = state.exportAllEntriesCSV() {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
        .padding(16)
        .frame(width: 420, height: 190)
        .onReceive(ticker) { d in now = d }
        .sheet(isPresented: $showingAdd) {
            VStack(alignment: .leading, spacing: 12) {
                Text("New Project").font(.headline)

                TextField("Name", text: $newProjectName)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Spacer()
                    Button("Cancel") { showingAdd = false }
                    Button("Add") {
                        state.addProject(name: newProjectName)
                        showingAdd = false
                    }
                    .disabled(newProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(16)
            .frame(width: 360)
        }
    }

    private func formatHMS(_ totalSeconds: Int) -> String {
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}
