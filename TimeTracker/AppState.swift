import Foundation
import AppKit
internal import Combine

@MainActor
final class AppState: ObservableObject {
    @Published var projects: [Project] = []
    @Published var entries: [TimeEntry] = []
    @Published var selectedProjectId: UUID?
    @Published var runningEntryId: UUID?

    let store = JsonStore()
    private let projectsFile = "projects.json"
    private let entriesFile = "time_entries.json"

    private let monitor = ActivityMonitor()

    init() {
        do {
            projects = try store.loadOrDefault([Project].self, from: projectsFile, defaultValue: [])
            entries = try store.loadOrDefault([TimeEntry].self, from: entriesFile, defaultValue: [])
        } catch {
            // If the Desktop path fails (sandbox ON), you'll see it quickly.
            print("LOAD failed:", error)
            projects = []
            entries = []
        }

        // Resume: if there is a running entry in JSON, reflect it.
        // (We only store running via endAt==nil, so find it.)
        if let running = entries.first(where: { $0.endAt == nil }) {
            runningEntryId = running.id
            selectedProjectId = running.projectId
        }

        monitor.start { [weak self] in
            Task { @MainActor in
                self?.endRunningEntry(reason: .system)
            }
        }
    }

    var runningEntry: TimeEntry? {
        guard let rid = runningEntryId else { return nil }
        return entries.first(where: { $0.id == rid && $0.endAt == nil })
    }

    func addProject(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let p = Project(name: trimmed)
        projects.append(p)
        selectedProjectId = p.id
        persistProjects()
    }

    func toggleStartStop() {
        if runningEntryId != nil {
            endRunningEntry(reason: .user)
        } else {
            start()
        }
    }

    private func start() {
        guard let pid = selectedProjectId else { return }
        // End any stray running entry (shouldn't happen, but keep it safe).
        endRunningEntry(reason: .system)

        let e = TimeEntry(projectId: pid, startAt: Date(), endAt: nil, endedReason: nil)
        entries.append(e)
        runningEntryId = e.id
        persistEntries()
    }

    func endRunningEntry(reason: EndedReason) {
        guard let rid = runningEntryId else { return }

        guard let idx = entries.firstIndex(where: { $0.id == rid }) else {
            runningEntryId = nil
            return
        }

        if entries[idx].endAt == nil {
            entries[idx].endAt = Date()
            entries[idx].endedReason = reason
            persistEntries()
        }

        runningEntryId = nil
    }

    func runningSeconds(at now: Date = Date()) -> Int {
        guard let e = runningEntry else { return 0 }
        return max(0, Int(now.timeIntervalSince(e.startAt)))
    }

    func totalSecondsTodayLive(for projectId: UUID, at now: Date = Date()) -> Int {
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: now)

        return entries
            .filter { $0.projectId == projectId }
            .compactMap { entry -> Int? in
                let end = entry.endAt ?? now
                if end < startOfDay { return nil }
                let clampedStart = max(entry.startAt, startOfDay)
                let seconds = Int(end.timeIntervalSince(clampedStart))
                return max(0, seconds)
            }
            .reduce(0, +)
    }

    // MARK: - Persistence

    private func persistProjects() {
        do { try store.save(projects, to: projectsFile) }
        catch { print("SAVE projects failed:", error) }
    }

    private func persistEntries() {
        do { try store.save(entries, to: entriesFile) }
        catch { print("SAVE entries failed:", error) }
    }

    // MARK: - CSV Export (simplified)

    /// Exports all completed entries (endAt != nil) as CSV to Desktop/TimeTracker.
    /// Columns: project,start,end,hours
    func exportAllEntriesCSV() -> URL? {
        let dir: URL
        do {
            dir = try store.appSupportDir()
        } catch {
            print("EXPORT failed: cannot resolve dir:", error)
            return nil
        }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"

        let timestamp = {
            let tf = DateFormatter()
            tf.dateFormat = "yyyyMMdd-HHmmss"
            return tf.string(from: Date())
        }()

        let outURL = dir.appendingPathComponent("time_entries-\(timestamp).csv")

        func projectName(for id: UUID) -> String {
            projects.first(where: { $0.id == id })?.name ?? "Unknown Project"
        }

        func csvEscape(_ s: String) -> String {
            if s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") {
                return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
            }
            return s
        }

        let header = "project,start,end,hours"

        let rows: [String] = entries
            .sorted { $0.startAt < $1.startAt }
            .compactMap { e in
                guard let endAt = e.endAt else { return nil }
                let start = df.string(from: e.startAt)
                let end = df.string(from: endAt)
                let seconds = max(0, Int(endAt.timeIntervalSince(e.startAt)))
                let hours = Double(seconds) / 3600.0
                return "\(csvEscape(projectName(for: e.projectId))),\(start),\(end),\(String(format: "%.2f", hours))"
            }

        let csv = ([header] + rows).joined(separator: "\n")

        do {
            try csv.write(to: outURL, atomically: true, encoding: .utf8)
            return outURL
        } catch {
            print("EXPORT failed:", error)
            return nil
        }
    }
}
