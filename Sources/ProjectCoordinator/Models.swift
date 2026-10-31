import Foundation

/// Project kinds for coding and non-coding desks.
public enum ProjectKind: String, Codable, Sendable, CaseIterable {
    case coding
    case writing
    case campaign
    case research
    case legal
    case accounting
    case business
    case personal
    case other
}

/// A tracked project. `path` is optional so non-coding work can live on the desk.
public struct Project: Codable, Sendable {
    public var name: String
    public var path: String?
    public var description: String?
    public var status: String?
    public var notes: String?
    public var techStack: [String]
    public var lastModified: Date
    public var currentTasks: [String]
    public var kind: ProjectKind
    public var repoURL: String?
    public var currentBranch: String?
    public var openPR: String?

    enum CodingKeys: String, CodingKey {
        case name, path, description, status, notes, techStack, lastModified, currentTasks
        case kind, repoURL, currentBranch, openPR
    }

    public init(
        name: String,
        path: String? = nil,
        description: String? = nil,
        status: String? = nil,
        notes: String? = nil,
        techStack: [String] = [],
        lastModified: Date = Date(),
        currentTasks: [String] = [],
        kind: ProjectKind = .coding,
        repoURL: String? = nil,
        currentBranch: String? = nil,
        openPR: String? = nil
    ) {
        self.name = name
        self.path = path
        self.description = description
        self.status = status
        self.notes = notes
        self.techStack = techStack
        self.lastModified = lastModified
        self.currentTasks = currentTasks
        self.kind = kind
        self.repoURL = repoURL
        self.currentBranch = currentBranch
        self.openPR = openPR
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        techStack = try container.decodeIfPresent([String].self, forKey: .techStack) ?? []
        lastModified = try container.decodeIfPresent(Date.self, forKey: .lastModified) ?? Date()
        currentTasks = try container.decodeIfPresent([String].self, forKey: .currentTasks) ?? []
        kind = try container.decodeIfPresent(ProjectKind.self, forKey: .kind)
            ?? (path == nil ? .other : .coding)
        repoURL = try container.decodeIfPresent(String.self, forKey: .repoURL)
        currentBranch = try container.decodeIfPresent(String.self, forKey: .currentBranch)
        openPR = try container.decodeIfPresent(String.self, forKey: .openPR)
    }
}

/// Default Kanban columns. Users may rename them on the board.
public enum DeskColumns {
    public static let defaults = ["backlog", "doing", "review", "done", "parked"]

    public static func fromStatus(_ status: String?) -> String {
        switch status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "active", "doing", "in progress", "in-progress", "wip":
            return "doing"
        case "completed", "complete", "archived", "done":
            return "done"
        case "review", "in review":
            return "review"
        case "parked", "blocked", "on hold", "hold":
            return "parked"
        default:
            return "backlog"
        }
    }
}

/// How long a card may sit in the done column before the desk treats it as archived.
/// The rule is a view over `column` and `updated`. Nothing is written back to cards.json.
public enum CardArchive {
    public static let defaultDays = 14
    public static let environmentKey = "DPC_ARCHIVE_DAYS"
    public static let doneColumn = "done"

    public static var defaultInterval: TimeInterval { interval(days: defaultDays) }

    public static func interval(days: Int) -> TimeInterval {
        TimeInterval(days) * 86_400
    }

    /// `DPC_ARCHIVE_DAYS` wins when it is a positive integer. Otherwise `configDays`, then 14.
    /// An empty or non-numeric env value is ignored and a warning is written to stderr.
    public static func days(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        configDays: Int? = nil
    ) -> Int {
        let configured = configDays.flatMap { $0 > 0 ? $0 : nil } ?? defaultDays
        guard let raw = environment[environmentKey] else { return configured }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parsed = Int(trimmed), parsed > 0 {
            return parsed
        }
        let shown = trimmed.isEmpty ? "(empty)" : trimmed
        CPCLog.warning("Ignoring invalid \(environmentKey)=\(shown); using \(configured)")
        return configured
    }
}

/// A Kanban card. `memoryRef` is an opaque id the user's memory product understands.
public struct Card: Codable, Sendable, Equatable {
    public var id: String
    public var project: String
    public var title: String
    public var column: String
    public var order: Int
    public var updated: Date
    public var due: Date?
    public var memoryRef: String?
    public var linkedPR: String?
    /// Short evidence line, such as a commit or URL. Absent from cards.json when nil.
    public var note: String?

    enum CodingKeys: String, CodingKey {
        case id, project, title, column, order, updated, due, memoryRef, linkedPR, note
    }

    public init(
        id: String,
        project: String,
        title: String,
        column: String,
        order: Int,
        updated: Date = Date(),
        due: Date? = nil,
        memoryRef: String? = nil,
        linkedPR: String? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.project = project
        self.title = title
        self.column = column
        self.order = order
        self.updated = updated
        self.due = due
        self.memoryRef = memoryRef
        self.linkedPR = linkedPR
        self.note = note
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        project = try container.decode(String.self, forKey: .project)
        title = try container.decode(String.self, forKey: .title)
        column = try container.decode(String.self, forKey: .column)
        order = try container.decode(Int.self, forKey: .order)
        updated = try container.decode(Date.self, forKey: .updated)
        due = try container.decodeIfPresent(Date.self, forKey: .due)
        memoryRef = try container.decodeIfPresent(String.self, forKey: .memoryRef)
        linkedPR = try container.decodeIfPresent(String.self, forKey: .linkedPR)
        let decodedNote = try container.decodeIfPresent(String.self, forKey: .note)
        note = decodedNote?.trimmingCharacters(in: .whitespacesAndNewlines)
        if note?.isEmpty == true { note = nil }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(project, forKey: .project)
        try container.encode(title, forKey: .title)
        try container.encode(column, forKey: .column)
        try container.encode(order, forKey: .order)
        try container.encode(updated, forKey: .updated)
        try container.encodeIfPresent(due, forKey: .due)
        try container.encodeIfPresent(memoryRef, forKey: .memoryRef)
        try container.encodeIfPresent(linkedPR, forKey: .linkedPR)
        try container.encodeIfPresent(note, forKey: .note)
    }

    public static func generateID() -> String {
        let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        return "c\(hex)"
    }

    public static func validateID(_ id: String) throws {
        _ = try normalizedID(id)
    }

    public static func normalizedID(_ id: String) throws -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"^c[a-f0-9]{8,32}$"#, options: .regularExpression) != nil else {
            throw CoordinatorError.invalidCardID
        }
        guard !trimmed.contains(".."), !trimmed.contains("/"), !trimmed.contains("\\") else {
            throw CoordinatorError.invalidCardID
        }
        return trimmed
    }

    /// Done cards older than the archive window. Other columns are never archived.
    /// Exactly `archiveAfter` seconds old is still active. Older than that is archived.
    public func isArchived(now: Date = Date(), archiveAfter: TimeInterval = CardArchive.defaultInterval) -> Bool {
        guard column.lowercased() == CardArchive.doneColumn else { return false }
        return now.timeIntervalSince(updated) > archiveAfter
    }
}

/// Whole-desk board persisted as `KnowledgeBase/desk/cards.json`.
public struct Board: Codable, Sendable {
    public var columns: [String]
    public var cards: [Card]

    public init(columns: [String] = DeskColumns.defaults, cards: [Card] = []) {
        self.columns = columns.isEmpty ? DeskColumns.defaults : columns
        self.cards = cards
    }
}
