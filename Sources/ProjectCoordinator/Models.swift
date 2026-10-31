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

    public init(
        id: String,
        project: String,
        title: String,
        column: String,
        order: Int,
        updated: Date = Date(),
        due: Date? = nil,
        memoryRef: String? = nil,
        linkedPR: String? = nil
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
