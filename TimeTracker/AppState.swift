import Foundation
import AppKit
import UserNotifications
internal import Combine

@MainActor
final class AppState: ObservableObject {
    @Published var projects: [Project] = []
    @Published var entries: [TimeEntry] = []
    @Published var selectedProjectId: UUID?
    @Published var runningEntryId: UUID?
    @Published var currentNote: String = ""

    let store = JsonStore()
    private let projectsFile = "projects.json"
    private let entriesFile = "time_entries.json"

    private let monitor = ActivityMonitor()

    private let resumeActionId = "RESUME_ACTION"
    private let resumeCategoryId = "RESUME_CATEGORY"

    private var lastAutoStoppedProjectId: UUID?
    private var lastAutoStopAt: Date?

    init() {
        do {
            projects = try store.loadOrDefault([Project].self, from: projectsFile, defaultValue: [])
            entries = try store.loadOrDefault([TimeEntry].self, from: entriesFile, defaultValue: [])
        } catch {
            print("LOAD failed:", error)
            projects = []
            entries = []
        }

        if let running = entries.first(where: { $0.endAt == nil }) {
            runningEntryId = running.id
            selectedProjectId = running.projectId
            currentNote = running.note ?? ""
        } else if let last = entries.max(by: { sortKey($0) < sortKey($1) }) {
            selectedProjectId = last.projectId
            currentNote = last.note ?? ""
        } else {
            selectedProjectId = projects.first?.id
        }

        monitor.start(
            onStop: { [weak self] in
                Task { @MainActor in
                    self?.endRunningEntry(reason: .system)
                }
            },
            onUnlock: { }
        )
    }

    private func sortKey(_ e: TimeEntry) -> Date {
        e.endAt ?? e.startAt
    }

    var runningEntry: TimeEntry? {
        guard let rid = runningEntryId else { return nil }
        return entries.first(where: { $0.id == rid && $0.endAt == nil })
    }

    var trimmedNote: String {
        currentNote.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canStart: Bool {
        selectedProjectId != nil && !trimmedNote.isEmpty
    }

    var canSwitchTask: Bool {
        guard let running = runningEntry else { return false }
        let runningNote = (running.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedNote.isEmpty && trimmedNote != runningNote
    }

    func primaryAction() {
        if runningEntry == nil {
            start()
        } else if canSwitchTask {
            switchTask()
        } else {
            endRunningEntry(reason: .user)
        }
    }

    func addProject(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let project = Project(name: trimmed)
        projects.append(project)
        selectedProjectId = project.id

        persistProjects()
    }

    private func persistProjects() {
        do { try store.save(projects, to: projectsFile) }
        catch { print("SAVE projects failed:", error) }
    }

    private func start() {
        guard canStart else { return }

        let e = TimeEntry(
            projectId: selectedProjectId!,
            startAt: Date(),
            endAt: nil,
            endedReason: nil,
            note: trimmedNote
        )
        entries.append(e)
        runningEntryId = e.id
        persistEntries()
    }

    private func switchTask() {
        guard canSwitchTask else { return }

        endRunningEntry(reason: .user)
        start()
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

    func stopAndQuit() {
        endRunningEntry(reason: .user)
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Used by menu bar title

    func runningSeconds(at now: Date = Date()) -> Int {
        guard let e = runningEntry else { return 0 }
        return max(0, Int(now.timeIntervalSince(e.startAt)))
    }

    /// Total seconds today for a project, including the currently-running entry (counted up to `now`).
    /// This is used by the menu bar title.
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

    private func persistEntries() {
        do { try store.save(entries, to: entriesFile) }
        catch { print("SAVE entries failed:", error) }
    }

    // MARK: - CSV Export

    private func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\n") || value.contains("\r") || value.contains("\"") {
            let doubled = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(doubled)\""
        }
        return value
    }

    /// Export columns (in this order): project,date,task,hours
    /// - Splits any entry that crosses midnight into separate day slices.
    /// - Groups by (project, date, task) and sums time.
    /// - Hours are rounded to 3 decimals.
    func exportAllEntriesCSV() -> URL? {
        let dir: URL
        do {
            dir = try store.appSupportDir()
        } catch {
            print("EXPORT failed: cannot resolve dir:", error)
            return nil
        }

        let now = Date()
        let cal = Calendar.current

        let timestamp: String = {
            let tf = DateFormatter()
            tf.locale = Locale(identifier: "en_US_POSIX")
            tf.timeZone = TimeZone.current
            tf.dateFormat = "yyyyMMdd-HHmmss"
            return tf.string(from: now)
        }()

        let outURL = dir.appendingPathComponent("time_entries-\(timestamp).csv")

        let projectNameById: [UUID: String] = Dictionary(
            uniqueKeysWithValues: projects.map { ($0.id, $0.name) }
        )

        let dayFormatter: DateFormatter = {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone.current
            df.dateFormat = "yyyy-MM-dd"
            return df
        }()

        struct Key: Hashable {
            let project: String
            let date: String
            let task: String
        }

        var secondsByKey: [Key: Int] = [:]

        for e in entries {
            let start = e.startAt
            let end = e.endAt ?? now
            guard end > start else { continue }

            let projectName = projectNameById[e.projectId] ?? "(Unknown Project)"
            let task = (e.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            var sliceStart = start
            while sliceStart < end {
                let dayStart = cal.startOfDay(for: sliceStart)
                guard let nextDayStart = cal.date(byAdding: .day, value: 1, to: dayStart) else { break }

                let sliceEnd = min(end, nextDayStart)
                guard sliceEnd > sliceStart else { break }

                let secs = Int(sliceEnd.timeIntervalSince(sliceStart).rounded(.toNearestOrAwayFromZero))
                let dateStr = dayFormatter.string(from: sliceStart)

                let key = Key(project: projectName, date: dateStr, task: task)
                secondsByKey[key, default: 0] += max(0, secs)

                sliceStart = sliceEnd
            }
        }

        let header = "project,date,task,hours"

        let rows: [String] = secondsByKey.keys
            .sorted { a, b in
                if a.project != b.project {
                    return a.project.localizedCaseInsensitiveCompare(b.project) == .orderedAscending
                }
                if a.date != b.date { return a.date < b.date }
                return a.task.localizedCaseInsensitiveCompare(b.task) == .orderedAscending
            }
            .map { key in
                let secs = secondsByKey[key] ?? 0
                let hours = Double(secs) / 3600.0
                let hoursStr = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), hours)
                return "\(csvEscape(key.project)),\(csvEscape(key.date)),\(csvEscape(key.task)),\(hoursStr)"
            }

        let csv = ([header] + rows).joined(separator: "\n") + "\n"

        do {
            try csv.write(to: outURL, atomically: true, encoding: .utf8)
            return outURL
        } catch {
            print("EXPORT failed:", error)
            return nil
        }
    }
}
