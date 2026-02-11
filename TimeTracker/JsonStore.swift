import Foundation

final class JsonStore {
    private let fm = FileManager.default
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// For this project: store everything in an easy-to-find folder on the Desktop.
    /// NOTE: This requires sandbox OFF (or a proper security-scoped bookmark approach).
    func appSupportDir() throws -> URL {
        let home = fm.homeDirectoryForCurrentUser
        let dir = home
            .appendingPathComponent("Desktop", isDirectory: true)
            .appendingPathComponent("TimeTracker", isDirectory: true)

        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        return dir
    }

    private func fileURL(_ filename: String) throws -> URL {
        try appSupportDir().appendingPathComponent(filename, isDirectory: false)
    }

    func save<T: Encodable>(_ value: T, to filename: String) throws {
        let url = try fileURL(filename)
        let data = try encoder.encode(value)
        try data.write(to: url, options: [.atomic])
    }

    func load<T: Decodable>(_ type: T.Type, from filename: String) throws -> T {
        let url = try fileURL(filename)
        let data = try Data(contentsOf: url)
        return try decoder.decode(type, from: data)
    }

    func loadOrDefault<T: Codable>(
        _ type: T.Type,
        from filename: String,
        defaultValue: @autoclosure () -> T
    ) throws -> T {
        do {
            return try load(type, from: filename)
        } catch {
            let fallback = defaultValue()
            try save(fallback, to: filename)
            return fallback
        }
    }
}
