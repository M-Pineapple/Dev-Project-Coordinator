import Foundation
import Testing
@testable import ProjectCoordinator

@Suite("Polish desk page")
struct PolishDeskPageTests {
    private var now: Date {
        Date(timeIntervalSince1970: 1_730_376_000)
    }

    @Test("header copy, inline logo, and favicon data URI")
    func headerAssets() {
        let html = DeskPage.render(projects: [], board: Board(), now: now, mode: .file)
        #expect(html.contains("Analytics and Kanban from local JSON. Nothing leaves this machine."))
        #expect(!html.contains("the box"))
        #expect(html.contains("class=\"logo logo-light\""))
        #expect(html.contains("class=\"logo logo-dark\""))
        #expect(html.contains("data:image/svg+xml;base64,"))
        #expect(html.contains("rel=\"icon\""))
        #expect(!html.contains("rel=\"manifest\""))
        #expect(!html.contains("apple-touch-icon"))
        #expect(html.contains("apple-mobile-web-app-capable"))
        #expect(html.contains("theme-color"))
    }

    @Test("live mode includes manifest and apple-touch-icon")
    func liveHead() {
        let html = DeskPage.render(projects: [], board: Board(), now: now, mode: .live)
        #expect(html.contains("rel=\"manifest\""))
        #expect(html.contains("/manifest.webmanifest"))
        #expect(html.contains("rel=\"apple-touch-icon\""))
        #expect(html.contains("/icon-180.png"))
        #expect(html.contains("apple-mobile-web-app-title"))
        #expect(html.contains("ArrowLeft"))
        #expect(html.contains("Enter"))
        #expect(html.contains("prefers-reduced-motion"))
        #expect(html.contains("lifting"))
        #expect(html.contains("kcard-ph"))
        #expect(html.contains("toast"))
        #expect(html.contains("aria-busy"))
        #expect(html.contains("removeAttribute('aria-busy')"))
    }

    @Test("kanban cards show chips and hide raw ids")
    func kanbanChips() {
        let project = Project(name: "WidgetKit", path: "/tmp/w", kind: .coding)
        let legal = Project(name: "Autumn review", path: nil, kind: .legal)
        let cards = [
            Card(
                id: "c111111111111",
                project: "WidgetKit",
                title: "Ship charts",
                column: "doing",
                order: 0,
                updated: now.addingTimeInterval(-86_400),
                linkedPR: "42"
            ),
            Card(
                id: "c444444444444",
                project: "Autumn review",
                title: "Counsel memo",
                column: "doing",
                order: 1,
                updated: now.addingTimeInterval(-3 * 86_400),
                memoryRef: "mem-legal-1"
            )
        ]
        let html = DeskPage.render(
            projects: [project, legal],
            board: Board(cards: cards),
            now: now,
            mode: .file
        )
        #expect(html.contains("data-id=\"c111111111111\""))
        #expect(html.contains("title=\"c111111111111\""))
        #expect(!html.contains("WidgetKit · c111111111111"))
        #expect(!html.contains("Autumn review · c444444444444"))
        #expect(html.contains("kind-coding"))
        #expect(html.contains("kind-legal"))
        #expect(html.contains("kchip kpr"))
        #expect(html.contains("PR 42"))
        #expect(html.contains("kchip kref"))
        #expect(html.contains("mem-legal-1"))
        #expect(html.contains("1 day ago"))
        #expect(html.contains("count-pill"))
        #expect(html.contains("No cards in this column."))
        #expect(!html.contains(">Empty<"))
    }

    @Test("HTTPS PR chips become links and javascript URLs do not")
    func prChipSafety() {
        let project = Project(name: "App", path: "/tmp/a", kind: .coding)
        let safe = Card(
            id: "cbbbbbbbbbbbb",
            project: "App",
            title: "PR",
            column: "review",
            order: 0,
            linkedPR: "https://example.com/acme/app/pull/9"
        )
        let html = DeskPage.render(projects: [project], board: Board(cards: [safe]), now: now)
        #expect(html.contains("href=\"https://example.com/acme/app/pull/9\""))
        #expect(html.contains("rel=\"noopener noreferrer\""))
        #expect(html.contains("target=\"_blank\""))
        #expect(html.contains("PR 9"))

        let evil = Card(
            id: "cccccccccccc",
            project: "App",
            title: "Bad",
            column: "review",
            order: 1,
            linkedPR: "javascript:alert(1)"
        )
        let blocked = DeskPage.render(projects: [project], board: Board(cards: [evil]), now: now)
        #expect(!blocked.contains("href=\"javascript:"))
        #expect(blocked.contains("kchip kpr"))

        let http = Card(
            id: "cdddddddddddd",
            project: "App",
            title: "HTTP",
            column: "review",
            order: 2,
            linkedPR: "http://example.com/acme/app/pull/9"
        )
        let httpHTML = DeskPage.render(projects: [project], board: Board(cards: [http]), now: now)
        #expect(!httpHTML.contains("href=\"http://"))
        #expect(httpHTML.contains("kchip kpr"))
    }
}

@Suite("Polish desk server", .serialized)
struct PolishDeskServerTests {
    @Test("port resolution: env, config, default")
    func portResolution() {
        #expect(DeskServer.defaultPort == 47_821)
        #expect(DeskServer.resolvePort(environment: [:]) == 47_821)
        #expect(DeskServer.resolvePort(configPort: 49_000, environment: [:]) == 49_000)
        #expect(DeskServer.resolvePort(configPort: 49_000, environment: ["DPC_DESK_PORT": "48001"]) == 48_001)
        #expect(DeskServer.resolvePort(environment: ["DPC_DESK_PORT": "0"]) == 47_821)
        #expect(DeskServer.resolvePort(configPort: 0, environment: [:]) == 47_821)
        #expect(DeskServer.resolvePort(configPort: 49_000, environment: ["DPC_DESK_PORT": "nope"]) == 49_000)
        #expect(DeskServer.resolvePort(environment: ["DPC_DESK_PORT": "abc"]) == 47_821)
        #expect(DeskServer.resolvePort(environment: ["DPC_DESK_PORT": ""]) == 47_821)
    }

    @Test("old security-config JSON without deskPort still loads")
    func configDecodeDefaultPort() throws {
        let json = """
        {"allowedPaths":["/tmp"],"maxProjectNameLength":100,"maxDescriptionLength":2000,"maxNotesLength":10000,"maxSearchPatternLength":300,"enableValidation":true}
        """
        let config = try JSONDecoder().decode(SecurityConfig.self, from: Data(json.utf8))
        #expect(config.deskPort == 47_821)
        #expect(config.allowedPaths == ["/tmp"])
    }

    @Test("cookie set on sign-in, redirect strips token, writes need cookie or header")
    func tokenCookieAndRedirect() throws {
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
            htmlProvider: { "<html>desk</html>" },
            onMove: { id, column in moved.pair = (id, column) },
            onAdd: { _, _ in }
        )
        try server.start()
        defer { server.stop() }

        let hostOK = "127.0.0.1:\(server.port)"
        let originOK = "http://127.0.0.1:\(server.port)"
        let body = Data(#"{"id":"cabcabcabcab","column":"done"}"#.utf8)

        #expect(!server.plainURL.contains("token"))
        #expect(!server.plainURL.contains("signin"))
        #expect(server.plainURL.hasSuffix("/"))
        #expect(server.signInURL.contains("?signin="))
        #expect(!server.signInURL.contains("?token="))
        #expect(server.signInURL.hasPrefix(server.plainURL))
        let code = try #require(server.currentSignInCode())
        #expect(code.count == 64)
        #expect(!server.signInURL.contains(server.token))

        let page = server.handleForTests(
            HTTPRequest(method: "GET", path: "/", headers: ["host": hostOK], body: Data())
        )
        #expect(page.status == 200)
        #expect(page.headers["Set-Cookie"] == nil)
        #expect(page.headers["Referrer-Policy"] == "no-referrer")

        let tokenRoute = server.handleForTests(
            HTTPRequest(
                method: "GET",
                path: "/?token=\(server.token)",
                headers: ["host": hostOK],
                body: Data()
            )
        )
        #expect(tokenRoute.status == 401)
        #expect(tokenRoute.headers["Set-Cookie"] == nil)

        let badSignIn = server.handleForTests(
            HTTPRequest(
                method: "GET",
                path: "/?signin=nope",
                headers: ["host": hostOK],
                body: Data()
            )
        )
        #expect(badSignIn.status == 401)
        #expect(badSignIn.headers["Set-Cookie"] == nil)

        let signIn = server.handleForTests(
            HTTPRequest(
                method: "GET",
                path: "/?signin=\(code)",
                headers: ["host": hostOK],
                body: Data()
            )
        )
        #expect(signIn.status == 303)
        #expect(signIn.headers["Location"] == "/")
        #expect(signIn.headers["Set-Cookie"] == DeskServer.tokenCookie(server.token))
        #expect(signIn.headers["Set-Cookie"]?.contains("HttpOnly") == true)
        #expect(signIn.headers["Set-Cookie"]?.contains("SameSite=Strict") == true)
        #expect(signIn.headers["Set-Cookie"]?.contains("Path=/") == true)

        let missing = server.handleForTests(
            HTTPRequest(
                method: "POST",
                path: "/api/cards/move",
                headers: ["origin": originOK, "host": hostOK],
                body: body
            )
        )
        #expect(missing.status == 401)

        let withCookie = server.handleForTests(
            HTTPRequest(
                method: "POST",
                path: "/api/cards/move",
                headers: [
                    "origin": originOK,
                    "host": hostOK,
                    "cookie": "dpc_token=\(server.token)"
                ],
                body: body
            )
        )
        #expect(withCookie.status == 200)
        #expect(moved.pair?.1 == "done")

        let withHeader = server.handleForTests(
            HTTPRequest(
                method: "POST",
                path: "/api/cards/move",
                headers: [
                    "origin": originOK,
                    "host": hostOK,
                    "x-dpc-token": server.token
                ],
                body: Data(#"{"id":"cabcabcabcab","column":"review"}"#.utf8)
            )
        )
        #expect(withHeader.status == 200)
        #expect(moved.pair?.1 == "review")
    }

    @Test("manifest and icons are served")
    func manifestAndIcons() throws {
        let desk = try TempDesk.make()
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
        let host = "127.0.0.1:\(server.port)"

        let manifest = server.handleForTests(
            HTTPRequest(method: "GET", path: "/manifest.webmanifest", headers: ["host": host], body: Data())
        )
        #expect(manifest.status == 200)
        let text = String(data: manifest.body, encoding: .utf8) ?? ""
        #expect(text.contains("Dev Project Coordinator"))
        #expect(text.contains("\"short_name\": \"DPC\""))
        #expect(text.contains("standalone"))
        #expect(text.contains("#2f5d50"))
        #expect(text.contains("#f6f4ef"))
        #expect(manifest.headers["Content-Type"]?.contains("manifest") == true)

        let icon = server.handleForTests(
            HTTPRequest(method: "GET", path: "/icon-180.png", headers: ["host": host], body: Data())
        )
        #expect(icon.status == 200)
        #expect(icon.headers["Content-Type"]?.contains("image") == true)
        #expect(icon.body.count > 32)

        let favicon = server.handleForTests(
            HTTPRequest(method: "GET", path: "/favicon.svg", headers: ["host": host], body: Data())
        )
        #expect(favicon.status == 200)
        #expect(String(data: favicon.body, encoding: .utf8)?.contains("viewBox=\"0 0 16 16\"") == true)
    }

    @Test("busy fixed port fails clearly")
    func busyPort() throws {
        let desk = try TempDesk.make()
        defer { desk.cleanup() }
        let first = try DeskServer(
            knowledgeBasePath: desk.kb.path,
            bindHost: "127.0.0.1",
            port: 0,
            htmlProvider: { "<html></html>" },
            onMove: { _, _ in },
            onAdd: { _, _ in }
        )
        try first.start()
        defer { first.stop() }
        let used = first.port
        let secondDesk = try TempDesk.make()
        defer { secondDesk.cleanup() }
        #expect(throws: DeskServerError.portInUse(used)) {
            let second = try DeskServer(
                knowledgeBasePath: secondDesk.kb.path,
                bindHost: "127.0.0.1",
                port: used,
                htmlProvider: { "<html></html>" },
                onMove: { _, _ in },
                onAdd: { _, _ in }
            )
            try second.start()
            second.stop()
        }
    }

    @Test("rotate writes a new 0600 token")
    func rotateToken() throws {
        let desk = try TempDesk.make()
        defer { desk.cleanup() }
        let server = try DeskServer(
            knowledgeBasePath: desk.kb.path,
            bindHost: "127.0.0.1",
            port: 0,
            htmlProvider: { "<html></html>" },
            onMove: { _, _ in },
            onAdd: { _, _ in }
        )
        let original = server.token
        let originalCode = try #require(server.currentSignInCode())
        try server.start()
        defer { server.stop() }
        try server.rotateToken()
        #expect(server.token != original)
        #expect(server.token.count == 64)
        let attrs = try FileManager.default.attributesOfItem(atPath: server.tokenFileURL.path)
        let perms = attrs[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o600)
        #expect(try String(contentsOf: server.tokenFileURL, encoding: .utf8) == server.token)
        let newCode = try #require(server.currentSignInCode())
        #expect(newCode != originalCode)

        let host = "127.0.0.1:\(server.port)"
        let oldSignIn = server.handleForTests(
            HTTPRequest(
                method: "GET",
                path: "/?signin=\(originalCode)",
                headers: ["host": host],
                body: Data()
            )
        )
        #expect(oldSignIn.status == 401)
        let tokenRoute = server.handleForTests(
            HTTPRequest(
                method: "GET",
                path: "/?token=\(server.token)",
                headers: ["host": host],
                body: Data()
            )
        )
        #expect(tokenRoute.status == 401)
        let newSignIn = server.handleForTests(
            HTTPRequest(
                method: "GET",
                path: "/?signin=\(newCode)",
                headers: ["host": host],
                body: Data()
            )
        )
        #expect(newSignIn.status == 303)
    }

    @Test("start_desk_server message has a tokenless Dock URL")
    func startDeskServerMessage() async throws {
        var lastError: Error?
        for _ in 0..<8 {
            let desk = try TempDesk.make()
            defer { desk.cleanup() }
            let port = UInt16.random(in: 49_100...49_700)
            let config = SecurityConfig(
                allowedPaths: [desk.work.path],
                maxProjectNameLength: 100,
                maxDescriptionLength: 2000,
                maxNotesLength: 10_000,
                maxSearchPatternLength: 300,
                enableValidation: true,
                deskPort: port
            )
            try config.save(to: desk.kb.appendingPathComponent("security-config.json").path)
            let analytics = ProjectAnalytics(knowledgeBasePath: desk.kb.path)
            let manager = ProjectManager(knowledgeBasePath: desk.kb.path, extraAllowedBases: [desk.work.path])
            await manager.initialize(analytics: analytics)
            do {
                let message = try await manager.startDeskServer()
                let firstLine = message.split(separator: "\n").first.map(String.init) ?? ""
                #expect(firstLine == "http://127.0.0.1:\(port)/")
                #expect(!firstLine.contains("token"))
                #expect(!firstLine.contains("signin"))
                #expect(message.contains("?signin="))
                #expect(!message.contains("?token="))
                #expect(message.contains("valid once, for 10 minutes"))
                #expect(message.contains("Write token file:"))
                let firstCode = signInCode(from: message)
                let minted = try await manager.startDeskServer()
                #expect(!minted.contains("Write token rotated."))
                let secondCode = signInCode(from: minted)
                #expect(secondCode != firstCode)
                #expect(minted.contains("valid once, for 10 minutes"))
                let rotated = try await manager.startDeskServer(rotate: true)
                #expect(rotated.contains("Write token rotated."))
                #expect(rotated.contains("http://127.0.0.1:\(port)/"))
                #expect(signInCode(from: rotated) != secondCode)
                return
            } catch let error as DeskServerError {
                if case .portInUse = error {
                    lastError = error
                    continue
                }
                throw error
            }
        }
        throw lastError ?? DeskServerError.portInUse(0)
    }
}

private func signInCode(from message: String) -> String? {
    guard let range = message.range(of: "?signin=") else { return nil }
    let rest = message[range.upperBound...]
    let end = rest.firstIndex(where: { $0.isWhitespace || $0 == "\n" }) ?? rest.endIndex
    return String(rest[..<end])
}
