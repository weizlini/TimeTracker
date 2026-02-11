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

        // Resume: if there is a running entry in JSON, reflect it.
        if let running = entries.first(where: { $0.endAt == nil }) {
            runningEntryId = running.id
            selectedProjectId = running.projectId
        }

        setupResumeNotifications()

        monitor.start(
            onStop: { [weak self] in
                Task { @MainActor in
                    self?.endRunningEntry(reason: .system)
                }
            },
            onUnlock: { [weak self] in
                Task { @MainActor in
                    self?.promptResumeIfNeeded()
                }
            }
        )
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
            let endedAt = Date()
            entries[idx].endAt = endedAt
            entries[idx].endedReason = reason
            persistEntries()

            if reason == .system {
                lastAutoStoppedProjectId = entries[idx].projectId
                lastAutoStopAt = endedAt
            }
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

    // MARK: - Resume Notification

    private func setupResumeNotifications() {
        let center = UNUserNotificationCenter.current()

        let resume = UNNotificationAction(
            identifier: resumeActionId,
            title: "Resume",
            options: [.foreground]
        )

        let category = UNNotificationCategory(
            identifier: resumeCategoryId,
            actions: [resume],
            intentIdentifiers: [],
            options: []
        )

        center.setNotificationCategories([category])
        center.delegate = NotificationDelegate.shared

        NotificationDelegate.shared.onResume = { [weak self] projectId in
            Task { @MainActor in
                self?.resumeFromReminder(projectId: projectId)
            }
        }

        center.requestAuthorization(options: [.alert, .sound]) { granted, err in
            if let err = err { print("Notif auth error:", err) }
            if !granted { print("Notif not granted") }
        }
    }

    private func promptResumeIfNeeded() {
        guard runningEntryId == nil else { return }

        guard let pid = lastAutoStoppedProjectId,
              let stoppedAt = lastAutoStopAt else { return }

        let secondsSince = Date().timeIntervalSince(stoppedAt)
        if secondsSince < 2 { return }
        if secondsSince > 2 * 3600 { return }

        let projectName = projects.first(where: { $0.id == pid })?.name ?? "your project"

        let content = UNMutableNotificationContent()
        content.title = "Resume tracking?"
        content.body = "You were tracking \(projectName). Do you want to resume?"
        content.sound = .default
        content.categoryIdentifier = resumeCategoryId
        content.userInfo = ["projectId": pid.uuidString]

        let req = UNNotificationRequest(
            identifier: "resume-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(req) { err in
            if let err = err { print("Notif add error:", err) }
        }
    }

    private func resumeFromReminder(projectId: UUID?) {
        guard runningEntryId == nil else { return }

        let pid = projectId ?? selectedProjectId ?? lastAutoStoppedProjectId
        guard let pid else { return }

        selectedProjectId = pid
        start()
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
                let sliceSecondsDouble = sliceEnd.timeIntervalSince(cursor)
                let sliceSeconds = Int(sliceSecondsDouble.rounded(.toNearestOrAwayFromZero))

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
