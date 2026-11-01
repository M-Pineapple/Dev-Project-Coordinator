import Foundation
import Testing
@testable import ProjectCoordinator
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private func makeBoardRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("dpc-lock-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("desk"), withIntermediateDirectories: true)
    return root
}

@Suite("CardStore board lock and load errors", .serialized)
struct BoardLockTests {
    @Test("two writers on the same board lose no update")
    func concurrentWritersKeepEveryCard() async throws {
        let root = try makeBoardRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = CardStore(knowledgeBasePath: root.path)
        try await seed.replaceBoard(Board(columns: DeskColumns.defaults, cards: []))

        // Two stores stand in for two processes (desk server and an MCP host).
        // Each opens the lock file itself, so flock serialises them as it would across processes.
        let a = CardStore(knowledgeBasePath: root.path)
        let b = CardStore(knowledgeBasePath: root.path)
        let perWriter = 40
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { for i in 0..<perWriter { _ = try await a.addCard(project: "Demo", title: "A\(i)") } }
            group.addTask { for i in 0..<perWriter { _ = try await b.addCard(project: "Demo", title: "B\(i)") } }
            try await group.waitForAll()
        }

        let cards = try await CardStore(knowledgeBasePath: root.path).snapshot().cards
        #expect(cards.count == perWriter * 2)
        #expect(Set(cards.map(\.title)).count == perWriter * 2)
    }

    @Test("a write waits for the lock the dpc wrapper holds")
    func writeRespectsExternalLock() async throws {
        let root = try makeBoardRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let lockPath = root.appendingPathComponent(".dpc.lock").path
        let fd = open(lockPath, O_RDWR | O_CREAT, 0o644)
        #expect(fd >= 0)
        defer { close(fd) }
        #expect(flock(fd, LOCK_EX) == 0)

        let store = CardStore(knowledgeBasePath: root.path, lockTimeout: 0.2)
        await #expect(throws: CoordinatorError.self) {
            _ = try await store.addCard(project: "Demo", title: "Blocked")
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("desk/cards.json").path))

        #expect(flock(fd, LOCK_UN) == 0)
        _ = try await store.addCard(project: "Demo", title: "After")
        #expect(try await store.snapshot().cards.map(\.title) == ["After"])
    }

    @Test("corrupt cards.json surfaces an error and is not overwritten")
    func corruptBoardThrows() async throws {
        let root = try makeBoardRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CardStore(knowledgeBasePath: root.path)
        _ = try await store.addCard(project: "Demo", title: "Kept in memory")

        let file = root.appendingPathComponent("desk/cards.json")
        let garbage = Data("{ not json".utf8)
        try garbage.write(to: file)

        await #expect(throws: CoordinatorError.self) { try await store.load() }
        await #expect(throws: CoordinatorError.self) { _ = try await store.snapshot() }
        await #expect(throws: CoordinatorError.self) {
            _ = try await store.addCard(project: "Demo", title: "Must not land")
        }
        #expect(try Data(contentsOf: file) == garbage)
    }

    @Test("missing cards.json is still an empty board")
    func missingBoardIsEmpty() async throws {
        let root = try makeBoardRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CardStore(knowledgeBasePath: root.path)
        try await store.load()
        #expect(try await store.snapshot().cards.isEmpty)
    }

    @Test("cards.json removed while the store is live reads as an empty board")
    func removedBoardIsEmpty() async throws {
        let root = try makeBoardRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CardStore(knowledgeBasePath: root.path)
        _ = try await store.addCard(project: "Demo", title: "Old")
        try FileManager.default.removeItem(at: root.appendingPathComponent("desk/cards.json"))
        #expect(try await store.snapshot().cards.isEmpty)
        _ = try await store.addCard(project: "Demo", title: "New")
        #expect(try await CardStore(knowledgeBasePath: root.path).snapshot().cards.map(\.title) == ["New"])
    }

    @Test("DPC_LOCK_FD is trusted only for a descriptor that holds this board's lock")
    func inheritedDescriptorIsVerified() async throws {
        let root = try makeBoardRoot()
        let other = try makeBoardRoot()
        defer {
            unsetenv("DPC_LOCK_FD")
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: other)
        }
        let lockPath = root.appendingPathComponent(".dpc.lock").path
        let fd = open(lockPath, O_RDWR | O_CREAT, 0o644)
        #expect(fd >= 0)
        defer { close(fd) }
        let store = CardStore(knowledgeBasePath: root.path, lockTimeout: 0.2)

        // Right file, but not locked: no proof, so the store locks for itself and succeeds.
        setenv("DPC_LOCK_FD", String(fd), 1)
        _ = try await store.addCard(project: "Demo", title: "Unlocked")

        // A descriptor on another board's lock file, held, does not open this board.
        let otherFD = open(other.appendingPathComponent(".dpc.lock").path, O_RDWR | O_CREAT, 0o644)
        defer { close(otherFD) }
        #expect(flock(otherFD, LOCK_EX) == 0)
        #expect(flock(fd, LOCK_EX) == 0)
        setenv("DPC_LOCK_FD", String(otherFD), 1)
        await #expect(throws: CoordinatorError.self) {
            _ = try await store.addCard(project: "Demo", title: "Wrong file")
        }
        // A bare old-style flag is ignored.
        setenv("DPC_LOCK_HELD", "1", 1)
        unsetenv("DPC_LOCK_FD")
        await #expect(throws: CoordinatorError.self) {
            _ = try await store.addCard(project: "Demo", title: "Old flag")
        }
        unsetenv("DPC_LOCK_HELD")

        // The holder's own descriptor: trusted, the write goes through at once.
        setenv("DPC_LOCK_FD", String(fd), 1)
        _ = try await store.addCard(project: "Demo", title: "Held")

        // The desk server clears the variable and waits like any other writer.
        BoardLock.ignoreInheritedLock()
        await #expect(throws: CoordinatorError.self) {
            _ = try await store.addCard(project: "Demo", title: "Desk")
        }
        #expect(flock(fd, LOCK_UN) == 0)
        #expect(try await store.snapshot().cards.map(\.title) == ["Unlocked", "Held"])
    }
}
