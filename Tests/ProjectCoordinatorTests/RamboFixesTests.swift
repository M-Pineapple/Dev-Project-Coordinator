import Foundation
import Testing
@testable import ProjectCoordinator
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private struct FixDesk {
    let root: URL
    let kb: URL
    let work: URL

    static func make() throws -> FixDesk {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dpc-fix-\(UUID().uuidString)", isDirectory: true)
        let kb = root.appendingPathComponent("KnowledgeBase", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: kb.appendingPathComponent("projects"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return FixDesk(root: root, kb: kb, work: work)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func makeConfig(allowedPaths: [String], enableValidation: Bool = true) -> SecurityConfig {
    SecurityConfig(
        allowedPaths: allowedPaths,
        maxProjectNameLength: 100,
        maxDescriptionLength: 2000,
        maxNotesLength: 10_000,
        maxSearchPatternLength: 300,
        enableValidation: enableValidation
    )
}

@Suite("Rambo F1-F8 desk server", .serialized)
struct RamboDeskServerTests {
    @Test("empty, negative, and oversized Content-Length are invalid")
    func contentLengthParse() {
        #expect(DeskServer.parseContentLength(fromHeaderText: "GET / HTTP/1.1") == .none)
        #expect(DeskServer.parseContentLength(fromHeaderText: "Content-Length:") == .invalid)
        #expect(DeskServer.parseContentLength(fromHeaderText: "Content-Length: ") == .invalid)
        #expect(DeskServer.parseContentLength(fromHeaderText: "Content-Length: -1") == .invalid)
        #expect(DeskServer.parseContentLength(fromHeaderText: "Content-Length: 70000") == .invalid)
        #expect(DeskServer.parseContentLength(fromHeaderText: "Content-Length: abc") == .invalid)
        #expect(DeskServer.parseContentLength(fromHeaderText: "Content-Length: 12") == .value(12))
        #expect(DeskServer.parseContentLength(fromHeaderText: "Content-Length: 65536") == .value(65_536))
        #expect(DeskServer.parseContentLength(fromHeaderText: "Content-Length: 65537") == .invalid)
        #expect(DeskServer.parseContentLength(fromHeaderText: "CONTENT-LENGTH: 12") == .value(12))
        #expect(DeskServer.parseContentLength(fromHeaderText: "content-length: 12") == .value(12))
        #expect(
            DeskServer.parseContentLength(
                fromHeaderText: "GET / HTTP/1.1\r\nContent-Length-Extra: 99\r\nHost: 127.0.0.1:9"
            ) == .none
        )
        #expect(
            DeskServer.parseContentLength(
                fromHeaderText: "POST / HTTP/1.1\r\nContent-Length-Extra: 99\r\nContent-Length: 12"
            ) == .value(12)
        )
        #expect(
            DeskServer.parseContentLength(
                fromHeaderText: "POST / HTTP/1.1\r\nContent-Length: 12\r\nContent-Length: 12"
            ) == .invalid
        )
        #expect(
            DeskServer.parseContentLength(
                fromHeaderText: "POST / HTTP/1.1\r\nContent-Length: 12\r\nContent-Length: 13"
            ) == .invalid
        )
    }

    @Test("empty Content-Length over the wire is 400 and the process stays up")
    func emptyContentLengthLive() throws {
        let desk = try FixDesk.make()
        defer { desk.cleanup() }
        let server = try DeskServer(
            knowledgeBasePath: desk.kb.path,
            bindHost: "127.0.0.1",
            port: 0,
            htmlProvider: { "<html></html>" },
            onMove: { _, _ in },
            onAdd: { _, _ in }
        )
        try server.start()
        defer { server.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        let raw = "POST /api/cards/move HTTP/1.1\r\nHost: 127.0.0.1:\(server.port)\r\nContent-Length:\r\n\r\n"
        let first = try sendRaw(port: server.port, payload: raw)
        let firstText = String(data: first, encoding: .utf8) ?? ""
        #expect(firstText.contains("400"))
        #expect(firstText.lowercased().contains("invalid content-length") || firstText.contains("400"))

        let health = try sendRaw(
            port: server.port,
            payload: "GET /health HTTP/1.1\r\nHost: 127.0.0.1:\(server.port)\r\n\r\n"
        )
        let healthText = String(data: health, encoding: .utf8) ?? ""
        #expect(healthText.contains("200"))
        #expect(healthText.contains("ok"))
    }

    @Test("duplicate Content-Length over the wire is 400")
    func duplicateContentLengthLive() throws {
        let desk = try FixDesk.make()
        defer { desk.cleanup() }
        let server = try DeskServer(
            knowledgeBasePath: desk.kb.path,
            bindHost: "127.0.0.1",
            port: 0,
            htmlProvider: { "<html></html>" },
            onMove: { _, _ in },
            onAdd: { _, _ in }
        )
        try server.start()
        defer { server.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        let raw = "POST /api/cards/move HTTP/1.1\r\nHost: 127.0.0.1:\(server.port)\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\n{}"
        let first = try sendRaw(port: server.port, payload: raw)
        let firstText = String(data: first, encoding: .utf8) ?? ""
        #expect(firstText.contains("400"))

        let health = try sendRaw(
            port: server.port,
            payload: "GET /health HTTP/1.1\r\nHost: 127.0.0.1:\(server.port)\r\n\r\n"
        )
        let healthText = String(data: health, encoding: .utf8) ?? ""
        #expect(healthText.contains("200"))
        #expect(healthText.contains("ok"))
    }

    @Test("Host is required on GET and a header without a port is rejected")
    func hostOnEveryRequest() throws {
        #expect(DeskServer.hostAllowed("127.0.0.1", port: 9_001) == false)
        #expect(DeskServer.hostAllowed("localhost", port: 9_001) == false)
        #expect(DeskServer.hostAllowed("127.0.0.1:9001", port: 9_001) == true)
        #expect(DeskServer.hostAllowed("localhost:9001", port: 9_001) == true)
        #expect(DeskServer.hostAllowed("[::1]:9001", port: 9_001) == false)
        #expect(DeskServer.originAllowed("http://127.0.0.1:9001", port: 9_001) == true)
        #expect(DeskServer.originAllowed("http://localhost:9001", port: 9_001) == true)
        #expect(DeskServer.originAllowed("http://[::1]:9001", port: 9_001) == false)
        #expect(throws: DeskServerError.self) {
            try DeskServer.validateBindHost("::1")
        }

        let desk = try FixDesk.make()
        defer { desk.cleanup() }
        let server = try DeskServer(
            knowledgeBasePath: desk.kb.path,
            bindHost: "127.0.0.1",
            port: 0,
            htmlProvider: { "<html>desk</html>" },
            onMove: { _, _ in },
            onAdd: { _, _ in }
        )
        try server.start()
        defer { server.stop() }

        let missing = server.handleForTests(
            HTTPRequest(method: "GET", path: "/", headers: [:], body: Data())
        )
        #expect(missing.status == 403)
        #expect(missing.headers["Set-Cookie"] == nil)

        let rebound = server.handleForTests(
            HTTPRequest(method: "GET", path: "/", headers: ["host": "evil.example"], body: Data())
        )
        #expect(rebound.status == 403)
        #expect(rebound.headers["Set-Cookie"] == nil)

        let bare = server.handleForTests(
            HTTPRequest(method: "GET", path: "/", headers: ["host": "127.0.0.1"], body: Data())
        )
        #expect(bare.status == 403)
        #expect(bare.headers["Set-Cookie"] == nil)

        let ok = server.handleForTests(
            HTTPRequest(
                method: "GET",
                path: "/",
                headers: ["host": "127.0.0.1:\(server.port)"],
                body: Data()
            )
        )
        #expect(ok.status == 200)
        #expect(ok.headers["Set-Cookie"] == nil)
        #expect(ok.headers["Content-Security-Policy"]?.contains("default-src 'none'") == true)
        #expect(ok.headers["X-Content-Type-Options"] == "nosniff")
        #expect(ok.headers["Referrer-Policy"] == "no-referrer")

        let health = server.handleForTests(
            HTTPRequest(
                method: "GET",
                path: "/health",
                headers: ["host": "127.0.0.1:\(server.port)"],
                body: Data()
            )
        )
        #expect(health.status == 200)
        #expect(health.headers["X-Content-Type-Options"] == "nosniff")
        #expect(health.headers["Referrer-Policy"] == "no-referrer")
    }

    @Test("token compare is length-checked and jsonString emits valid JSON")
    func tokenAndJSON() throws {
        #expect(DeskServer.tokensEqual("abc", "abc"))
        #expect(DeskServer.tokensEqual("abc", "abd") == false)
        #expect(DeskServer.tokensEqual("abc", "ab") == false)

        let encoded = DeskServer.jsonString("line\n\t\"\\\u{0001}end")
        let object = try JSONSerialization.jsonObject(with: Data(encoded.utf8), options: [.fragmentsAllowed])
        #expect(object as? String == "line\n\t\"\\\u{0001}end")
    }

    @Test("token file is mode 0600")
    func tokenFileMode() throws {
        let desk = try FixDesk.make()
        defer { desk.cleanup() }
        let url = desk.kb.appendingPathComponent("desk/.write-token")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try DeskServer.writeTokenFile(token: "abc123", url: url)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let perms = attrs[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o600)
        #expect(try String(contentsOf: url, encoding: .utf8) == "abc123")
    }
}

@Suite("Rambo F9-F13 paths, files, cards")
struct RamboPathAndStoreTests {
    @Test("symlink that leaves an allowed root is rejected")
    func symlinkEscape() throws {
        let desk = try FixDesk.make()
        defer { desk.cleanup() }
        let secret = desk.root.appendingPathComponent("secret", isDirectory: true)
        try FileManager.default.createDirectory(at: secret, withIntermediateDirectories: true)
        try "hidden".write(to: secret.appendingPathComponent("note"), atomically: true, encoding: .utf8)
        let link = desk.work.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        #expect(throws: SecurityError.self) {
            try SecurityValidator.validateProjectPath(link.path, allowedBasePaths: [desk.work.path])
        }
    }

    @Test("a tilde later in the path is not expanded")
    func tildeOnlyAtStart() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dpc-tilde-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let weird = root.appendingPathComponent("foo~bar")
        let project = weird.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let result = try SecurityValidator.validateProjectPath(project.path, allowedBasePaths: [weird.path])
        #expect(result.contains("foo~bar"))
        #expect(SecurityValidator.expandPath("not~home") == URL(fileURLWithPath: "not~home").standardized.path)
    }

    @Test("forbidden roots from config are dropped")
    func forbiddenRoots() {
        #expect(SecurityValidator.isForbiddenRoot("/"))
        #expect(SecurityValidator.isForbiddenRoot("~"))
        #expect(SecurityValidator.isForbiddenRoot(NSHomeDirectory()))
        #expect(SecurityValidator.isForbiddenRoot(NSHomeDirectory() + "/.ssh"))
        #expect(SecurityValidator.isForbiddenRoot(NSHomeDirectory() + "/.gnupg"))
        #expect(SecurityValidator.isForbiddenRoot(NSHomeDirectory() + "/.aws"))
        #expect(SecurityValidator.isForbiddenRoot(NSHomeDirectory() + "/Library"))
        #expect(SecurityValidator.isForbiddenRoot(NSHomeDirectory() + "/Developer") == false)

        let config = makeConfig(allowedPaths: ["/", "~", "~/.ssh", "~/Library", NSHomeDirectory() + "/Developer"])
        let roots = SecurityValidator.effectiveAllowedBasePaths(config: config, extra: ["/"])
        #expect(!roots.contains("/"))
        #expect(!roots.contains(NSHomeDirectory()))
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
        #expect(!roots.contains(home + "/.ssh"))
        #expect(!roots.contains(home + "/Library"))
        #expect(roots.contains { $0 == home + "/Developer" || $0.hasPrefix(home + "/Developer") })
    }

    @Test("AtomicFile keeps destination and writes a bak")
    func atomicReplace() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dpc-atomic-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("cards.json")
        try Data("one".utf8).write(to: dest)
        try AtomicFile.replace(destination: dest, data: Data("two".utf8))
        #expect(try String(contentsOf: dest, encoding: .utf8) == "two")
        let bak = dir.appendingPathComponent("cards.json.bak")
        #expect(try String(contentsOf: bak, encoding: .utf8) == "one")
        try AtomicFile.replace(destination: dest, data: Data("three".utf8))
        #expect(try String(contentsOf: dest, encoding: .utf8) == "three")
        #expect(try String(contentsOf: bak, encoding: .utf8) == "two")
    }

    @Test("addCard limits title and project length and trims card ids")
    func cardLimits() async throws {
        let desk = try FixDesk.make()
        defer { desk.cleanup() }
        let analytics = ProjectAnalytics(knowledgeBasePath: desk.kb.path)
        let manager = ProjectManager(knowledgeBasePath: desk.kb.path, extraAllowedBases: [desk.work.path])
        await manager.initialize(analytics: analytics)
        _ = try await manager.fileUnderProject(name: "Board Demo", kind: .writing)

        await #expect(throws: SecurityError.self) {
            try await manager.addCard(
                project: "Board Demo",
                title: String(repeating: "a", count: SecurityValidator.maxDescriptionLength + 1),
                column: "backlog"
            )
        }
        let store = CardStore(knowledgeBasePath: desk.kb.path)
        await store.load()
        await #expect(throws: SecurityError.self) {
            try await store.addCard(
                project: String(repeating: "p", count: SecurityValidator.maxProjectNameLength + 1),
                title: "ok"
            )
        }

        let added = try await manager.addCard(project: "Board Demo", title: "Draft", column: "backlog")
        #expect(added.contains("Added card"))
        let created = await manager.boardSnapshot().cards.first { $0.title == "Draft" }
        let id = try #require(created?.id)
        let moved = try await manager.moveCard(id: "  \(id)  ", column: "doing")
        #expect(moved.contains("doing"))
    }
}

private func sendRaw(port: UInt16, payload: String) throws -> Data {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw CoordinatorError.fileSystemError("socket")
    }
    defer { close(fd) }
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(port).bigEndian
    addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let connected = withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else {
        throw CoordinatorError.fileSystemError("connect")
    }
    let bytes = Array(payload.utf8)
    let written = bytes.withUnsafeBytes { pointer in
        write(fd, pointer.baseAddress, bytes.count)
    }
    guard written == bytes.count else {
        throw CoordinatorError.fileSystemError("write")
    }
    var buffer = [UInt8](repeating: 0, count: 4096)
    var data = Data()
    while true {
        let n = buffer.withUnsafeMutableBytes { pointer in
            read(fd, pointer.baseAddress, pointer.count)
        }
        if n <= 0 { break }
        data.append(contentsOf: buffer.prefix(n))
        if data.range(of: Data("\r\n\r\n".utf8)) != nil { break }
    }
    return data
}

@Test func cardStoreReloadsFromDiskBeforeMutating() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cardstore-reload-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("desk"), withIntermediateDirectories: true)
    let longRunning = CardStore(knowledgeBasePath: root.path)
    try await longRunning.replaceBoard(Board(columns: DeskColumns.defaults, cards: []))
    let first = try await longRunning.addCard(project: "Demo", title: "First")

    // Another process changes the file behind the long-running store's back.
    let other = CardStore(knowledgeBasePath: root.path)
    await other.load()
    let second = try await other.addCard(project: "Demo", title: "Second")
    _ = try await other.moveCard(id: first.id, column: "done")

    // The long-running store must see both changes and keep them when it saves.
    _ = try await longRunning.moveCard(id: second.id, column: "doing")
    let check = CardStore(knowledgeBasePath: root.path)
    await check.load()
    let cards = await check.snapshot().cards
    #expect(cards.count == 2)
    #expect(cards.first { $0.id == first.id }?.column == "done")
    #expect(cards.first { $0.id == second.id }?.column == "doing")
}
