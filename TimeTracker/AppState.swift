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
                    self?.autoStopRunningEntry()
                }
            },
            onUnlock: { [weak self] in
                Task { @MainActor in
                    self?.maybePromptResumeAfterUnlock()
                }
            }
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

    private func autoStopRunningEntry() {
        guard let running = runningEntry else { return }
        endRunningEntry(reason: .system)
        scheduleResumeNotification(projectId: running.projectId)
    }

    private func maybePromptResumeAfterUnlock() {
        resumeLastAutoStoppedIfRecent()
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

    /// Total seconds for a project across *all time*, including the currently-running entry (counted up to `now`).
    func totalSecondsAllTimeLive(for projectId: UUID, at now: Date = Date()) -> Int {
        return entries
            .filter { $0.projectId == projectId }
            .compactMap { entry -> Int? in
                let end = entry.endAt ?? now
                let seconds = Int(end.timeIntervalSince(entry.startAt))
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

    private func timestampString(for date: Date) -> String {
        let tf = DateFormatter()
        tf.locale = Locale(identifier: "en_US_POSIX")
        tf.timeZone = TimeZone.current
        tf.dateFormat = "yyyyMMdd-HHmmss"
        return tf.string(from: date)
    }

    private func dayFormatter() -> DateFormatter {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current
        df.dateFormat = "yyyy-MM-dd"
        return df
    }

    private func filenameSafe(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Project" }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = trimmed.unicodeScalars.map { scalar -> Character in
            if allowed.contains(scalar) { return Character(scalar) }
            return "_"
        }
        let s = String(mapped)
        // collapse multiple underscores a bit (simple pass)
        while s.contains("__") {
            return s.replacingOccurrences(of: "__", with: "_")
        }
        return s
    }

    func exportProjectEntriesCSV(projectId: UUID) -> URL? {
        let dir: URL
        do {
            dir = try store.appSupportDir()
        } catch {
            print("EXPORT failed: cannot resolve dir:", error)
            return nil
        }

        let now = Date()
        let cal = Calendar.current

        let timestamp = timestampString(for: now)
        let projectName = projects.first(where: { $0.id == projectId })?.name ?? "Unknown"
        let safeProjectName = filenameSafe(projectName)
        let outURL = dir.appendingPathComponent("\(safeProjectName)-\(timestamp).csv")

        let df = dayFormatter()

        struct Key: Hashable {
            let date: String
            let task: String
        }

        var secondsByKey: [Key: Int] = [:]

        for e in entries where e.projectId == projectId {
            let start = e.startAt
            let end = e.endAt ?? now
            guard end > start else { continue }

            let task = (e.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let safeTask = task.isEmpty ? "(no task)" : task

            // Walk day by day if it crosses midnight.
            var cursor = start
            while cursor < end {
                let dayStart = cal.startOfDay(for: cursor)
                guard let nextDayStart = cal.date(byAdding: .day, value: 1, to: dayStart) else { break }

                let sliceStart = max(cursor, dayStart)
                let sliceEnd = min(end, nextDayStart)

                if sliceEnd > sliceStart {
                    let dateStr = df.string(from: dayStart)
                    let key = Key(date: dateStr, task: safeTask)
                    let seconds = Int(sliceEnd.timeIntervalSince(sliceStart))
                    secondsByKey[key, default: 0] += max(0, seconds)
                }

                cursor = nextDayStart
            }
        }

        // Stable ordering for readability
        let sortedKeys = secondsByKey.keys.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.task < $1.task
        }

        var lines: [String] = []
        lines.append("date,task,hours")

        for key in sortedKeys {
            let seconds = secondsByKey[key] ?? 0
            let hours = Double(seconds) / 3600.0
            let hoursStr = String(format: "%.3f", hours)

            let row = [
                csvEscape(key.date),
                csvEscape(key.task),
                csvEscape(hoursStr)
            ].joined(separator: ",")

            lines.append(row)
        }

        let csv = lines.joined(separator: "\n") + "\n"

        do {
            try csv.write(to: outURL, atomically: true, encoding: .utf8)
            return outURL
        } catch {
            print("EXPORT failed: write:", error)
            return nil
        }
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

        let timestamp = timestampString(for: now)
        let outURL = dir.appendingPathComponent("time_entries-\(timestamp).csv")

        let projectNameById: [UUID: String] = Dictionary(
            uniqueKeysWithValues: projects.map { ($0.id, $0.name) }
        )

        let df = dayFormatter()

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

            let projectName = projectNameById[e.projectId] ?? "Unknown"
            let task = (e.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let safeTask = task.isEmpty ? "(no task)" : task

            // Walk day by day if it crosses midnight.
            var cursor = start
            while cursor < end {
                let dayStart = cal.startOfDay(for: cursor)
                guard let nextDayStart = cal.date(byAdding: .day, value: 1, to: dayStart) else { break }

                let sliceStart = max(cursor, dayStart)
                let sliceEnd = min(end, nextDayStart)

                if sliceEnd > sliceStart {
                    let dateStr = df.string(from: dayStart)
                    let key = Key(project: projectName, date: dateStr, task: safeTask)
                    let seconds = Int(sliceEnd.timeIntervalSince(sliceStart))
                    secondsByKey[key, default: 0] += max(0, seconds)
                }

                cursor = nextDayStart
            }
        }

        // Stable ordering for readability
        let sortedKeys = secondsByKey.keys.sorted {
            if $0.project != $1.project { return $0.project < $1.project }
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.task < $1.task
        }

        var lines: [String] = []
        lines.append("project,date,task,hours")

        for key in sortedKeys {
            let seconds = secondsByKey[key] ?? 0
            let hours = Double(seconds) / 3600.0
            let hoursStr = String(format: "%.3f", hours)

            let row = [
                csvEscape(key.project),
                csvEscape(key.date),
                csvEscape(key.task),
                csvEscape(hoursStr)
            ].joined(separator: ",")

            lines.append(row)
        }

        let csv = lines.joined(separator: "\n") + "\n"

        do {
            try csv.write(to: outURL, atomically: true, encoding: .utf8)
            return outURL
        } catch {
            print("EXPORT failed: write:", error)
            return nil
        }
    }

    // MARK: - Notifications (resume after auto-stop)

    func configureResumeNotificationsIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                print("NOTIF auth error:", error)
                return
            }
            if !granted {
                print("NOTIF not granted")
                return
            }
            self.registerResumeCategory()
        }
    }

    private func registerResumeCategory() {
        let resume = UNNotificationAction(
            identifier: resumeActionId,
            title: "Resume",
            options: [.foreground]
        )

        let cat = UNNotificationCategory(
            identifier: resumeCategoryId,
            actions: [resume],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([cat])
    }

    private func scheduleResumeNotification(projectId: UUID) {
        // Remember for "resume on click"
        lastAutoStoppedProjectId = projectId
        lastAutoStopAt = Date()

        let content = UNMutableNotificationContent()
        content.title = "Timer stopped"
        content.body = "Resume the last project?"
        content.sound = .default
        content.categoryIdentifier = resumeCategoryId

        // Fire shortly after unlock; for simplicity, schedule ~1s later.
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(req) { err in
            if let err = err { print("NOTIF schedule error:", err) }
        }
    }

    func resumeLastAutoStoppedIfRecent(maxAgeSeconds: TimeInterval = 30) {
        guard let pid = lastAutoStoppedProjectId, let at = lastAutoStopAt else { return }
        guard Date().timeIntervalSince(at) <= maxAgeSeconds else { return }

        // Resume means: select project, keep the current note, and start if note is non-empty.
        selectedProjectId = pid
        if canStart {
            primaryAction()
        }
    }
}
