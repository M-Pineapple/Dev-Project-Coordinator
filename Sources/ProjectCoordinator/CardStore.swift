import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Advisory lock on `<knowledge base>/.dpc.lock`, the same file and `flock(LOCK_EX)` semantics
/// the `dpc` wrapper uses, so desk page, MCP and wrapper writes are serialised across processes.
/// Set `DPC_LOCK_HELD=1` in the environment when the parent process already holds the lock
/// (the wrapper takes it before it starts this binary); taking it again here would deadlock.
struct BoardLock {
    static let fileName = ".dpc.lock"
    let path: String
    let timeout: TimeInterval

    init(knowledgeBasePath: String, timeout: TimeInterval = 15) {
        self.path = URL(fileURLWithPath: knowledgeBasePath).appendingPathComponent(Self.fileName).path
        self.timeout = timeout
    }

    static var heldByParent: Bool {
        ProcessInfo.processInfo.environment["DPC_LOCK_HELD"] == "1"
    }

    func withLock<T>(_ body: () throws -> T) throws -> T {
        if Self.heldByParent { return try body() }
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw CoordinatorError.fileSystemError("cannot open board lock \(Self.fileName): errno \(errno)")
        }
        defer { close(fd) }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let err = errno
            guard err == EWOULDBLOCK || err == EINTR else {
                throw CoordinatorError.fileSystemError("cannot lock board: errno \(err)")
            }
            if Date() >= deadline {
                throw CoordinatorError.fileSystemError("board is locked by another writer; try again")
            }
            usleep(20_000)
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}

/// Persists the desk board as JSON with copy-on-write backups.
public actor CardStore {
    private var board: Board
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock: BoardLock

    public init(knowledgeBasePath: String, lockTimeout: TimeInterval = 15) {
        self.lock = BoardLock(knowledgeBasePath: knowledgeBasePath, timeout: lockTimeout)
        let desk = URL(fileURLWithPath: knowledgeBasePath).appendingPathComponent("desk", isDirectory: true)
        self.fileURL = desk.appendingPathComponent("cards.json")
        self.board = Board()
        self.encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    /// Re-read from disk. Called before every mutation and snapshot so a long-running
    /// process (desk server, MCP host) never saves over changes another process made.
    /// A missing file (fresh board) keeps the in-memory board. A file that exists but cannot
    /// be read or decoded throws, so callers never act on, or save over, a stale board.
    /// Loading does not write. Archive state is derived from the done column and `updated`,
    /// so opening the board does not dirty cards.json or the git mirror.
    public func load() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let loaded: Board
        do {
            let data = try Data(contentsOf: fileURL)
            loaded = try decoder.decode(Board.self, from: data)
        } catch {
            throw CoordinatorError.fileSystemError("cannot read desk/cards.json: \(error.localizedDescription)")
        }
        board = loaded
        if board.columns.isEmpty {
            board.columns = DeskColumns.defaults
        }
    }

    /// Reads stay unlocked: saves replace cards.json by atomic rename, so a reader sees
    /// either the old or the new file, never a partial one.
    public func snapshot() throws -> Board {
        try load()
        return board
    }

    public func save() throws {
        let data = try encoder.encode(board)
        try AtomicFile.replace(destination: fileURL, data: data)
    }

    public func migrateIfNeeded(from projects: [Project]) throws {
        try lock.withLock { try migrateLocked(from: projects) }
    }

    private func migrateLocked(from projects: [Project]) throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try load()
            return
        }
        var order = 0
        var cards: [Card] = []
        for project in projects.sorted(by: { $0.name < $1.name }) {
            let column = DeskColumns.fromStatus(project.status)
            if project.currentTasks.isEmpty {
                cards.append(
                    Card(
                        id: Card.generateID(),
                        project: project.name,
                        title: project.name,
                        column: column,
                        order: order
                    )
                )
                order += 1
            } else {
                for task in project.currentTasks {
                    cards.append(
                        Card(
                            id: Card.generateID(),
                            project: project.name,
                            title: task,
                            column: "doing",
                            order: order
                        )
                    )
                    order += 1
                }
            }
        }
        board = Board(columns: DeskColumns.defaults, cards: cards)
        try save()
    }

    public func addCard(
        project: String,
        title: String,
        column: String? = nil,
        memoryRef: String? = nil,
        linkedPR: String? = nil,
        due: Date? = nil,
        note: String? = nil
    ) throws -> Card {
        return try lock.withLock {
            try load()
            let col = column ?? "backlog"
            guard board.columns.contains(col) else {
                throw CoordinatorError.invalidColumn
            }
            let projectName = try SecurityValidator.validateText(
                project,
                maxLength: SecurityValidator.maxProjectNameLength,
                fieldName: "Card project"
            )
            let cardTitle = try SecurityValidator.validateText(
                title,
                maxLength: SecurityValidator.maxDescriptionLength,
                fieldName: "Card title"
            )
            let card = Card(
                id: Card.generateID(),
                project: projectName,
                title: cardTitle,
                column: col,
                order: (board.cards.map(\.order).max() ?? -1) + 1,
                due: due,
                memoryRef: memoryRef,
                linkedPR: linkedPR,
                note: try cleanedNote(note)
            )
            board.cards.append(card)
            try save()
            return card
        }
    }

    public func moveCard(id: String, column: String, note: String? = nil) throws -> Card {
        return try lock.withLock {
            try load()
            let trimmedID = try Card.normalizedID(id)
            guard board.columns.contains(column) else {
                throw CoordinatorError.invalidColumn
            }
            guard let index = board.cards.firstIndex(where: { $0.id == trimmedID }) else {
                throw CoordinatorError.cardNotFound
            }
            board.cards[index].column = column
            if let note {
                board.cards[index].note = try cleanedNote(note)
            }
            // `updated` is the archive clock. Refreshing it, and leaving done, brings the card back.
            // The card is never removed from cards.json. A missing note leaves any existing note in place.
            board.cards[index].updated = Date()
            try save()
            return board.cards[index]
        }
    }

    public func updateCard(
        id: String,
        title: String? = nil,
        column: String? = nil,
        memoryRef: String? = nil,
        due: Date? = nil,
        linkedPR: String? = nil,
        note: String? = nil
    ) throws -> Card {
        return try lock.withLock {
            try load()
            let trimmedID = try Card.normalizedID(id)
            guard let index = board.cards.firstIndex(where: { $0.id == trimmedID }) else {
                throw CoordinatorError.cardNotFound
            }
            if let column {
                guard board.columns.contains(column) else {
                    throw CoordinatorError.invalidColumn
                }
                board.cards[index].column = column
            }
            if let title {
                board.cards[index].title = try SecurityValidator.validateText(
                    title,
                    maxLength: SecurityValidator.maxDescriptionLength,
                    fieldName: "Card title"
                )
            }
            if let memoryRef { board.cards[index].memoryRef = memoryRef }
            if let due { board.cards[index].due = due }
            if let linkedPR { board.cards[index].linkedPR = linkedPR }
            if let note { board.cards[index].note = try cleanedNote(note) }
            // Any edit refreshes `updated`, so a done card older than the archive window
            // returns to the board. Leaving done does the same. Nothing is deleted.
            board.cards[index].updated = Date()
            try save()
            return board.cards[index]
        }
    }

    /// Blank text clears the note. Nil means the caller did not send one.
    private func cleanedNote(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let cleaned = try SecurityValidator.validateText(
            raw,
            maxLength: SecurityValidator.maxNotesLength,
            fieldName: "Card note"
        )
        return cleaned.isEmpty ? nil : cleaned
    }

    public func renameColumn(from old: String, to newName: String) throws {
        try lock.withLock {
            try load()
            let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw CoordinatorError.invalidColumn }
            guard let index = board.columns.firstIndex(of: old) else {
                throw CoordinatorError.invalidColumn
            }
            board.columns[index] = trimmed
            for i in board.cards.indices where board.cards[i].column == old {
                board.cards[i].column = trimmed
            }
            try save()
        }
    }

    public func reassignProject(from oldName: String, to newName: String) throws {
        try lock.withLock {
            try load()
            for i in board.cards.indices where board.cards[i].project == oldName {
                board.cards[i].project = newName
                board.cards[i].updated = Date()
            }
            try save()
        }
    }

    public func replaceBoard(_ newBoard: Board) throws {
        try lock.withLock {
            board = newBoard
            try save()
        }
    }
}
