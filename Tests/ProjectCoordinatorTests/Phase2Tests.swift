import Foundation
import Testing
@testable import ProjectCoordinator

struct TempDesk {
    let root: URL
    let kb: URL
    let work: URL

    static func make() throws -> TempDesk {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dpc-\(UUID().uuidString)", isDirectory: true)
        let kb = root.appendingPathComponent("KnowledgeBase", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: kb.appendingPathComponent("projects"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return TempDesk(root: root, kb: kb, work: work)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite("WorkspaceProbe")
struct WorkspaceProbeTests {
    @Test("repo name from https and ssh remotes")
    func repoName() {
        #expect(WorkspaceProbe.repoName(fromRemote: "https://example.com/acme/widget-kit.git") == "widget-kit")
        #expect(WorkspaceProbe.repoName(fromRemote: "git@example.com:acme/widget-kit.git") == "widget-kit")
        #expect(WorkspaceProbe.projectName(path: "/tmp/work/widget-kit", remote: nil) == "widget-kit")
    }
}

@Suite("ProjectDetector")
struct ProjectDetectorTests {
    @Test("detects swift, python, node, and empty docs folders")
    func fixtures() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dpc-detect-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let swift = root.appendingPathComponent("swift-app")
        try FileManager.default.createDirectory(at: swift, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\n".write(to: swift.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        let python = root.appendingPathComponent("python-app")
        try FileManager.default.createDirectory(at: python, withIntermediateDirectories: true)
        try "[project]\nname='demo'\n".write(to: python.appendingPathComponent("pyproject.toml"), atomically: true, encoding: .utf8)

        let node = root.appendingPathComponent("node-app")
        try FileManager.default.createDirectory(at: node, withIntermediateDirectories: true)
        try "{\"name\":\"demo\"}\n".write(to: node.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)

        let docs = root.appendingPathComponent("empty-docs")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)

        #expect(ProjectDetector.detect(at: swift.path).tags.contains("swift"))
        #expect(ProjectDetector.detect(at: python.path).tags.contains("python"))
        #expect(ProjectDetector.detect(at: node.path).tags.contains("javascript"))
        #expect(ProjectDetector.detect(at: node.path).tags.contains("node"))
        #expect(ProjectDetector.detect(at: docs.path).tags == ["unknown"])
        #expect(ProjectDetector.detect(at: docs.path).kind == .other)
    }
}

@Suite("Phase 2 desk", .serialized)
struct Phase2DeskTests {
    @Test("old JSON still loads and analytics JSON is excluded")
    func oldJSONAndAnalyticsExclusion() async throws {
        let desk = try TempDesk.make()
        defer { desk.cleanup() }
        let projects = desk.kb.appendingPathComponent("projects")

        let old = """
        {
          "name": "LegacyApp",
          "path": "\(NSHomeDirectory())/Developer/LegacyApp",
          "description": "old",
          "status": "active",
          "techStack": ["Swift"],
          "lastModified": "2024-01-01T00:00:00Z",
          "currentTasks": []
        }
        """
        try Data(old.utf8).write(to: projects.appendingPathComponent("LegacyApp.json"))

        let injected = """
        {
          "name": "Injected",
          "path": "\(NSHomeDirectory())/Developer/Injected",
          "techStack": ["evil"],
          "lastModified": "2024-01-01T00:00:00Z",
          "currentTasks": []
        }
        """
        try Data(injected.utf8).write(to: projects.appendingPathComponent("Injected-analytics.json"))

        let analytics = ProjectAnalytics(knowledgeBasePath: desk.kb.path)
        let manager = ProjectManager(knowledgeBasePath: desk.kb.path, extraAllowedBases: [desk.work.path])
        await manager.initialize(analytics: analytics)
        let names = await manager.allProjects().map(\.name)
        #expect(names.contains("LegacyApp"))
        #expect(!names.contains("Injected"))
        let legacy = await manager.allProjects().first { $0.name == "LegacyApp" }
        #expect(legacy?.kind == .coding)
        #expect(legacy?.path != nil)
    }

    @Test("template markdown is not overwritten on start")
    func templateNotOverwritten() async throws {
        let desk = try TempDesk.make()
        defer { desk.cleanup() }
        let patterns = desk.kb.appendingPathComponent("patterns", isDirectory: true)
        try FileManager.default.createDirectory(at: patterns, withIntermediateDirectories: true)
        let file = patterns.appendingPathComponent("swift-patterns.md")
        try "USER EDIT".write(to: file, atomically: true, encoding: .utf8)

        let analytics = ProjectAnalytics(knowledgeBasePath: desk.kb.path)
        let manager = ProjectManager(knowledgeBasePath: desk.kb.path, extraAllowedBases: [desk.work.path])
        await manager.initialize(analytics: analytics)
        await manager.initialize(analytics: analytics)
        let body = try String(contentsOf: file, encoding: .utf8)
        #expect(body == "USER EDIT")
    }

    @Test("non-coding auto-create, dedupe, rename and merge")
    func nonCodingFlow() async throws {
        let desk = try TempDesk.make()
        defer { desk.cleanup() }
        let analytics = ProjectAnalytics(knowledgeBasePath: desk.kb.path)
        let manager = ProjectManager(knowledgeBasePath: desk.kb.path, extraAllowedBases: [desk.work.path])
        await manager.initialize(analytics: analytics)

        let created = try await manager.fileUnderProject(name: "Q4 Campaign", kind: .campaign)
        #expect(created.contains("Filed under new project: Q4 Campaign"))

        let again = try await manager.fileUnderProject(name: "q4-campaign", kind: .campaign)
        #expect(again.contains("Filed under existing project: Q4 Campaign"))

        let renamed = try await manager.renameProject(from: "Q4 Campaign", to: "Autumn Campaign")
        #expect(renamed.contains("Autumn Campaign"))

        _ = try await manager.fileUnderProject(name: "Legal Review", kind: .legal)
        let merged = try await manager.mergeProjects(source: "Legal Review", into: "Autumn Campaign")
        #expect(merged.contains("Merged"))
        let names = await manager.allProjects().map(\.name)
        #expect(names == ["Autumn Campaign"])
    }

    @Test("auto-detect from cwd and git remote")
    func autoDetectWorkspace() async throws {
        let desk = try TempDesk.make()
        defer { desk.cleanup() }
        let repo = desk.work.appendingPathComponent("widget-kit")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try "{\"name\":\"widget-kit\"}\n".write(to: repo.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try run(["git", "init"], cwd: repo)
        try run(["git", "remote", "add", "origin", "https://example.com/acme/widget-kit.git"], cwd: repo)

        let analytics = ProjectAnalytics(knowledgeBasePath: desk.kb.path)
        let manager = ProjectManager(knowledgeBasePath: desk.kb.path, extraAllowedBases: [desk.work.path])
        await manager.initialize(analytics: analytics)

        let result = try await manager.registerFromWorkspace(
            cwd: repo.path,
            gitRemote: "https://example.com/acme/widget-kit.git",
            branch: "main",
            openPR: "42"
        )
        #expect(result.contains("widget-kit"))
        let listed = await manager.allProjects()
        let names = listed.map(\.name)
        let project = listed.first { $0.name == "widget-kit" }
        #expect(names.contains("widget-kit"), "projects: \(names) result: \(result)")
        #expect(project?.techStack.contains("javascript") == true)
        #expect(project?.currentBranch == "main")
        let board = await manager.boardSnapshot()
        #expect(board.cards.contains { $0.linkedPR == "42" })
    }

    @Test("summary stays under 3200 characters at 30 projects")
    func summaryBudget() {
        var projects: [Project] = []
        var cards: [Card] = []
        for i in 1...30 {
            let name = "FixtureProject\(String(format: "%02d", i))"
            projects.append(
                Project(
                    name: name,
                    path: nil,
                    description: "desc",
                    status: i % 5 == 0 ? "done" : "Active",
                    notes: String(repeating: "n", count: 400),
                    techStack: ["python"],
                    kind: i % 2 == 0 ? .writing : .coding
                )
            )
            cards.append(
                Card(id: Card.generateID(), project: name, title: "next-\(i)", column: DeskColumns.fromStatus(projects.last?.status), order: i)
            )
        }
        let text = DeskSummary.render(projects: projects, board: Board(cards: cards))
        #expect(text.count <= DeskSummary.maxCharacters)
        #expect(DeskSummary.estimatedTokens(text) <= DeskSummary.tokenBudget)
        #expect(!text.contains(String(repeating: "n", count: 40)))
        #expect(!text.contains("/Users/"))
    }

    @Test("add a python repo with optional path skipped for writing")
    func addPythonAndWriting() async throws {
        let desk = try TempDesk.make()
        defer { desk.cleanup() }
        let py = desk.work.appendingPathComponent("py-app")
        try FileManager.default.createDirectory(at: py, withIntermediateDirectories: true)
        try "requests\n".write(to: py.appendingPathComponent("requirements.txt"), atomically: true, encoding: .utf8)

        let analytics = ProjectAnalytics(knowledgeBasePath: desk.kb.path)
        let manager = ProjectManager(knowledgeBasePath: desk.kb.path, extraAllowedBases: [desk.work.path])
        await manager.initialize(analytics: analytics)

        let added = try await manager.addProjectSecure(name: "PyApp", path: py.path, description: "demo")
        #expect(added.contains("python"))
        let writing = try await manager.addProjectSecure(
            name: "Essay",
            path: nil,
            description: "notes",
            kind: .writing
        )
        #expect(writing.contains("writing"))
        await #expect(throws: CoordinatorError.self) {
            try await manager.addProjectSecure(name: "NoPathCode", path: nil, description: nil, kind: .coding)
        }
    }

    @Test("card add and move round trip")
    func cardRoundTrip() async throws {
        let desk = try TempDesk.make()
        defer { desk.cleanup() }
        let analytics = ProjectAnalytics(knowledgeBasePath: desk.kb.path)
        let manager = ProjectManager(knowledgeBasePath: desk.kb.path, extraAllowedBases: [desk.work.path])
        await manager.initialize(analytics: analytics)
        _ = try await manager.fileUnderProject(name: "Board Demo", kind: .writing)
        let added = try await manager.addCard(project: "Board Demo", title: "Draft outline", column: "backlog")
        #expect(added.contains("Added card"))
        let created = await manager.boardSnapshot().cards.first { $0.title == "Draft outline" }
        let id = try #require(created?.id)
        #expect(id.hasPrefix("c"))
        let moved = try await manager.moveCard(id: id, column: "doing")
        #expect(moved.contains("doing"))
        let board = await manager.boardSnapshot()
        #expect(board.cards.contains { $0.id == id && $0.column == "doing" })
    }

    @Test("HTML escapes user strings")
    func htmlEscape() {
        let project = Project(name: "<script>p</script>", path: nil, kind: .writing)
        let card = Card(
            id: Card.generateID(),
            project: project.name,
            title: "<script>alert(1)</script>",
            column: "backlog",
            order: 0
        )
        let html = DeskPage.render(projects: [project], board: Board(cards: [card]))
        #expect(!html.contains("<script>alert(1)</script>"))
        #expect(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        #expect(html.contains("&lt;script&gt;p&lt;/script&gt;"))
    }

    @Test("server rejects missing token, bad token, wrong Origin, non-loopback bind")
    func deskServerGuards() throws {
        #expect(throws: DeskServerError.self) {
            try DeskServer.validateBindHost("0.0.0.0")
        }
        #expect(throws: DeskServerError.self) {
            try DeskServer.validateBindHost("1.2.3.4")
        }

        let desk = try TempDesk.make()
        defer { desk.cleanup() }
        final class MoveBox: @unchecked Sendable {
            var pair: (String, String)?
        }
        let moved = MoveBox()
        let server = try DeskServer(
            knowledgeBasePath: desk.kb.path,
            bindHost: "127.0.0.1",
            port: 0,
            htmlProvider: { "<html></html>" },
            onMove: { id, column in moved.pair = (id, column) },
            onAdd: { _, _ in }
        )
        try server.start()
        defer { server.stop() }

        let originOK = "http://127.0.0.1:\(server.port)"
        let hostOK = "127.0.0.1:\(server.port)"
        let body = Data(#"{"id":"cabcabcabcab","column":"done"}"#.utf8)

        let missing = server.handleForTests(
            HTTPRequest(
                method: "POST",
                path: "/api/cards/move",
                headers: ["origin": originOK, "host": hostOK],
                body: body
            )
        )
        #expect(missing.status == 401)
        #expect(String(data: missing.body, encoding: .utf8) == "missing token")

        let bad = server.handleForTests(
            HTTPRequest(
                method: "POST",
                path: "/api/cards/move",
                headers: ["origin": originOK, "host": hostOK, "x-dpc-token": "nope"],
                body: body
            )
        )
        #expect(bad.status == 401)
        #expect(String(data: bad.body, encoding: .utf8) == "bad token")

        let wrongOrigin = server.handleForTests(
            HTTPRequest(
                method: "POST",
                path: "/api/cards/move",
                headers: [
                    "origin": "http://evil.example",
                    "host": hostOK,
                    "x-dpc-token": server.token
                ],
                body: body
            )
        )
        #expect(wrongOrigin.status == 403)

        let ok = server.handleForTests(
            HTTPRequest(
                method: "POST",
                path: "/api/cards/move",
                headers: [
                    "origin": originOK,
                    "host": hostOK,
                    "x-dpc-token": server.token
                ],
                body: body
            )
        )
        #expect(ok.status == 200)
        #expect(moved.pair?.0 == "cabcabcabcab")
        #expect(moved.pair?.1 == "done")

        let attrs = try FileManager.default.attributesOfItem(atPath: server.tokenFileURL.path)
        let perms = attrs[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o600)

        #expect(server.token.count == 64)
    }
}

private func run(_ args: [String], cwd: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = args
    process.currentDirectoryURL = cwd
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
}
