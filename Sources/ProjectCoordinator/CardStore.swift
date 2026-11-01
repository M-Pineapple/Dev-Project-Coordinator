import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Advisory lock on `<knowledge base>/.dpc.lock`, the same file and `flock(LOCK_EX)` semantics
/// the `dpc` wrapper uses, so desk page, MCP and wrapper writes are serialised across processes.
///
/// The wrapper takes the lock before it starts this binary and passes its locked descriptor as
/// `DPC_LOCK_FD`. The inherited lock is trusted only when the descriptor is the same file as
/// `.dpc.lock` and a fresh handle on that file is refused the lock, which proves the lock is held
/// right now by the descriptor this process inherited. Anything else locks normally. The desk
/// server clears the variable at start-up, so a long-lived server always takes the lock itself.
struct BoardLock {
    static let fileName = ".dpc.lock"
    static let inheritedFDVariable = "DPC_LOCK_FD"
    let path: String
    let timeout: TimeInterval

    init(knowledgeBasePath: String, timeout: TimeInterval = 15) {
        self.path = URL(fileURLWithPath: knowledgeBasePath).appendingPathComponent(Self.fileName).path
        self.timeout = timeout
    }

    /// Called by the desk server so it never trusts a descriptor from whoever started it.
    static func ignoreInheritedLock() {
        unsetenv(inheritedFDVariable)
    }

    func openLockFile() throws -> Int32 {
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o644)
        guard fd >= 0 else {
            throw CoordinatorError.fileSystemError("cannot open board lock \(Self.fileName): errno \(errno)")
        }
        return fd
    }

    /// True only when `DPC_LOCK_FD` names an open descriptor on this lock file that holds the lock.
    func heldByInheritedDescriptor() -> Bool {
        guard let raw = getenv(Self.inheritedFDVariable),
              let inherited = Int32(String(cString: raw)), inherited > 2 else { return false }
        var a = stat(), b = stat()
        guard fstat(inherited, &a) == 0, lstat(path, &b) == 0,
              (b.st_mode & S_IFMT) == S_IFREG,
              a.st_dev == b.st_dev, a.st_ino == b.st_ino else { return false }
        guard let probe = try? openLockFile() else { return false }
        defer { close(probe) }
        if flock(probe, LOCK_EX | LOCK_NB) == 0 {
            // Nobody holds it, so the inherited descriptor proves nothing.
            flock(probe, LOCK_UN)
            return false
        }
        guard errno == EWOULDBLOCK else { return false }
        // Someone holds it. Taking it again on the inherited open file description succeeds
        // at once only if that description is the holder.
        return flock(inherited, LOCK_EX | LOCK_NB) == 0
    }

    /// One non-blocking attempt. Returns the locked descriptor, or nil if another writer holds it.
    func tryAcquire() throws -> Int32? {
        let fd = try openLockFile()
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let err = errno
            if err == EINTR { continue }
            close(fd)
            guard err == EWOULDBLOCK else {
                throw CoordinatorError.fileSystemError("cannot lock board: errno \(err)")
            }
            return nil
        }
        return fd
    }

    static func release(_ fd: Int32) {
        flock(fd, LOCK_UN)
        close(fd)
    }
}

/// Persists the desk board as JSON with copy-on-write backups.
public actor CardStore {
    private var board: Board
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock: BoardLock

    /// Waits for the board lock without blocking a thread: it polls with a non-blocking flock
    /// and suspends with Task.sleep between tries. The body runs synchronously, with no
    /// suspension point, so its load, change and save are not interleaved with other calls.
    private func withLock<T>(_ body: () throws -> T) async throws -> T {
        if lock.heldByInheritedDescriptor() { return try body() }
        let deadline = Date().addingTimeInterval(lock.timeout)
        while true {
            if let fd = try lock.tryAcquire() {
                defer { BoardLock.release(fd) }
                return try body()
            }
            if Date() >= deadline {
                throw CoordinatorError.fileSystemError("board is locked by another writer; try again")
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

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
    /// A missing file means an empty board, whether it was never created or was removed
    /// while this process ran, so a stale in-memory board is never kept or saved back. A file that exists but cannot
    /// be read or decoded throws, so callers never act on, or save over, a stale board.
    /// Loading does not write. Archive state is derived from the done column and `updated`,
    /// so opening the board does not dirty cards.json or the git mirror.
    public func load() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            board = Board(columns: DeskColumns.defaults, cards: [])
            return
        }
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

    public func migrateIfNeeded(from projects: [Project]) async throws {
        try await withLock { try migrateLocked(from: projects) }
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
    ) async throws -> Card {
        return try await withLock {
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

    public func moveCard(id: String, column: String, note: String? = nil) async throws -> Card {
        return try await withLock {
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
    ) async throws -> Card {
        return try await withLock {
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

    public func renameColumn(from old: String, to newName: String) async throws {
        try await withLock {
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

    public func reassignProject(from oldName: String, to newName: String) async throws {
        try await withLock {
            try load()
            for i in board.cards.indices where board.cards[i].project == oldName {
                board.cards[i].project = newName
                board.cards[i].updated = Date()
            }
            try save()
        }
    }

    public func replaceBoard(_ newBoard: Board) async throws {
        try await withLock {
            board = newBoard
            try save()
        }
    }
}
