import SwiftUI
import AppKit
internal import Combine

struct ContentView: View {
    @ObservedObject var state: AppState

    @State private var isAddingProject = false
    @State private var newProjectName = ""
    @FocusState private var addProjectFieldFocused: Bool
    @FocusState private var noteFieldFocused: Bool

    @State private var now = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        let hasProjects = !state.projects.isEmpty
        let hasSelectedProject = state.selectedProjectId != nil && hasProjects
        let canUsePrimaryButton = state.runningEntry != nil || state.canStart

        let runningNote = (state.runningEntry?.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let typedNote = state.trimmedNote
        let canContinuePrevious =
            state.runningEntry != nil &&
            typedNote != runningNote &&
            !runningNote.isEmpty

        VStack(alignment: .leading, spacing: 12) {

            // Project row + add button
            HStack(spacing: 8) {
                if hasProjects {
                    Picker("Project", selection: Binding(
                        get: { state.selectedProjectId },
                        set: { state.selectedProjectId = $0 }
                    )) {
                        ForEach(state.projects) { p in
                            Text(p.name).tag(Optional(p.id))
                        }
                    }
                    .frame(minWidth: 220)
                } else {
                    Text("No projects — click + to add")
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 220, alignment: .leading)
                }

                Button {
                    beginAddProject()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add project")
            }

            // Inline add-project editor
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

            // Task field
            TextField(
                hasSelectedProject ? "What are you working on?" : "Select/add project first",
                text: Binding(
                    get: { state.currentNote },
                    set: { state.currentNote = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)
            .disabled(!hasSelectedProject)
            .focused($noteFieldFocused)
            .onSubmit {
                // If we're in "switch" mode, Enter triggers switch
                if state.canSwitchTask {
                    state.primaryAction()
                }
            }

            // Continue previous task button (only when running and field differs)
            if canContinuePrevious {
                Button("Continue previous task: \"\(runningNote)\"") {
                    state.currentNote = runningNote
                    DispatchQueue.main.async {
                        noteFieldFocused = true
                    }
                }
                .font(.caption)
            }

            HStack(spacing: 10) {
                Button {
                    state.primaryAction()
                } label: {
                    Text(primaryButtonTitle)
                        .frame(width: 90)
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!canUsePrimaryButton)

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
        .frame(width: 420, height: isAddingProject ? 320 : 260)
        .onReceive(ticker) { d in now = d }
        .onAppear {
            DispatchQueue.main.async {
                if hasSelectedProject {
                    noteFieldFocused = true
                }
            }
        }
        .onChange(of: state.selectedProjectId) { _, newValue in
            DispatchQueue.main.async {
                if newValue != nil && !state.projects.isEmpty {
                    noteFieldFocused = true
                } else {
                    noteFieldFocused = false
                }
            }
        }
    }

    private var primaryButtonTitle: String {
        if state.runningEntry == nil { return "Start" }
        if state.canSwitchTask { return "Switch" }
        return "Stop"
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
