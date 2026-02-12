import Foundation

struct Project: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

enum EndedReason: String, Codable {
    case user
    case system
}

struct TimeEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let projectId: UUID
    let startAt: Date
    var endAt: Date?
    var endedReason: EndedReason?

    // Optional task/line-item description. Optional so older JSON still loads.
    var note: String?

    init(
        id: UUID = UUID(),
        projectId: UUID,
        startAt: Date,
        endAt: Date? = nil,
        endedReason: EndedReason? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.startAt = startAt
        self.endAt = endAt
        self.endedReason = endedReason
        self.note = note
    }
}
