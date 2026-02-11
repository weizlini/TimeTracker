import SwiftUI
import AppKit
internal import Combine

struct ContentView: View {
    @ObservedObject var state: AppState

    @State private var isAddingProject = false
    @State private var newProjectName = ""
    @FocusState private var addProjectFieldFocused: Bool

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
                    beginAddProject()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add project")
            }

            if isAddingProject {
                VStack(alignment: .leading, spacing: 10) {
                    Text("New Project")
                        .font(.headline)

                    TextField("Name", text: $newProjectName)
                        .textFieldStyle(.roundedBorder)
                        .focused($addProjectFieldFocused)
                        .onSubmit { commitAddProject() }

                    HStack {
                        Button("Cancel") { cancelAddProject() }
                            .keyboardShortcut(.escape, modifiers: [])

                        Spacer()

                        Button("Add") { commitAddProject() }
                            .disabled(newProjectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .keyboardShortcut(.return, modifiers: [])
                    }
                }
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
                    state.stopAndQuit()
                }
                .keyboardShortcut("q")
            }
        }
        .padding(16)
        .frame(width: 420, height: isAddingProject ? 250 : 190)
        .onReceive(ticker) { d in now = d }
    }

    private func beginAddProject() {
        newProjectName = ""
        isAddingProject = true
        DispatchQueue.main.async {
            addProjectFieldFocused = true
        }
    }

    private func cancelAddProject() {
        isAddingProject = false
        newProjectName = ""
        addProjectFieldFocused = false
    }

    private func commitAddProject() {
        let trimmed = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        state.addProject(name: trimmed)
        cancelAddProject()
    }

    private func formatHMS(_ totalSeconds: Int) -> String {
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}
