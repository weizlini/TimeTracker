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

    private func persistEntries() {
        do { try store.save(entries, to: entriesFile) }
        catch { print("SAVE entries failed:", error) }
    }

    // MARK: - CSV Export (daily totals)

    /// Exports a daily summary CSV (one row per day) to Desktop/TimeTracker.
    /// Columns: date,hours
    func exportAllEntriesCSV() -> URL? {
        let dir: URL
        do {
            dir = try store.appSupportDir()
        } catch {
            print("EXPORT failed: cannot resolve dir:", error)
            return nil
        }

        let cal = Calendar.current
        let now = Date()

        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = TimeZone.current
        dayFormatter.dateFormat = "yyyy-MM-dd"

        let timestamp = {
            let tf = DateFormatter()
            tf.locale = Locale(identifier: "en_US_POSIX")
            tf.dateFormat = "yyyyMMdd-HHmmss"
            return tf.string(from: Date())
        }()

        let outURL = dir.appendingPathComponent("time_entries-by-day-\(timestamp).csv")

        var secondsByDayStart: [Date: Int] = [:]

        for e in entries {
            let start = e.startAt
            let end = e.endAt ?? now
            guard end > start else { continue }

            var cursor = start
            while cursor < end {
                let dayStart = cal.startOfDay(for: cursor)
                guard let nextDayStart = cal.date(byAdding: .day, value: 1, to: dayStart) else { break }

                let sliceEnd = min(end, nextDayStart)
                let sliceSeconds = Int(sliceEnd.timeIntervalSince(cursor).rounded(.toNearestOrAwayFromZero))
                secondsByDayStart[dayStart, default: 0] += max(0, sliceSeconds)
                cursor = sliceEnd
            }
        }

        let header = "date,hours"

        let rows: [String] = secondsByDayStart
            .keys
            .sorted()
            .map { dayStart in
                let secs = secondsByDayStart[dayStart] ?? 0
                let hours = Double(secs) / 3600.0
                let hoursStr = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), hours)
                return "\(dayFormatter.string(from: dayStart)),\(hoursStr)"
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
