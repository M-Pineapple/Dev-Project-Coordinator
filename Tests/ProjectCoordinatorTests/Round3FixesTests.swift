import Foundation
import Testing
@testable import ProjectCoordinator

@Suite("Rambo round 3 P3 desk fixes", .serialized)
struct Round3FixesTests {
    @Test("R3-2 single-use sign-in code; used, expired, and ?token= are 401")
    func singleUseSignIn() throws {
        let desk = try TempDesk.make()
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
        let host = "127.0.0.1:\(server.port)"
        let code = try #require(server.currentSignInCode())
        #expect(server.signInURL.contains("?signin=\(code)"))
        #expect(!server.signInURL.contains(server.token))
        #expect(!server.signInURL.contains("?token="))

        let first = server.handleForTests(
            HTTPRequest(method: "GET", path: "/?signin=\(code)", headers: ["host": host], body: Data())
        )
        #expect(first.status == 303)
        #expect(first.headers["Location"] == "/")
        #expect(first.headers["Set-Cookie"] == DeskServer.tokenCookie(server.token))
        #expect(first.headers["Referrer-Policy"] == "no-referrer")

        let reuse = server.handleForTests(
            HTTPRequest(method: "GET", path: "/?signin=\(code)", headers: ["host": host], body: Data())
        )
        #expect(reuse.status == 401)
        #expect(reuse.headers["Set-Cookie"] == nil)

        let fresh = server.mintSignInCode()
        server.now = { Date().addingTimeInterval(DeskServer.signInCodeTTL + 1) }
        let expired = server.handleForTests(
            HTTPRequest(method: "GET", path: "/?signin=\(fresh)", headers: ["host": host], body: Data())
        )
        #expect(expired.status == 401)
        #expect(expired.headers["Set-Cookie"] == nil)
        server.now = { Date() }

        let writeToken = server.handleForTests(
            HTTPRequest(
                method: "GET",
                path: "/?token=\(server.token)",
                headers: ["host": host],
                body: Data()
            )
        )
        #expect(writeToken.status == 401)
        #expect(writeToken.headers["Set-Cookie"] == nil)

        let minted = server.mintSignInCode()
        #expect(minted != code)
        let second = server.handleForTests(
            HTTPRequest(method: "GET", path: "/?signin=\(minted)", headers: ["host": host], body: Data())
        )
        #expect(second.status == 303)
        #expect(second.headers["Set-Cookie"] == DeskServer.tokenCookie(server.token))
    }

    @Test("R3-3 Referrer-Policy on every response")
    func referrerPolicyOnEveryResponse() throws {
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
        let paths = ["/", "/health", "/manifest.webmanifest", "/favicon.svg", "/nope"]
        for path in paths {
            let response = server.handleForTests(
                HTTPRequest(method: "GET", path: path, headers: ["host": host], body: Data())
            )
            #expect(response.headers["Referrer-Policy"] == "no-referrer")
        }
        let options = server.handleForTests(
            HTTPRequest(method: "OPTIONS", path: "/", headers: ["host": host], body: Data())
        )
        #expect(options.status == 204)
        #expect(options.headers["Referrer-Policy"] == "no-referrer")
        let forbidden = server.handleForTests(
            HTTPRequest(method: "GET", path: "/", headers: ["host": "evil.example"], body: Data())
        )
        #expect(forbidden.status == 403)
        #expect(forbidden.headers["Referrer-Policy"] == "no-referrer")
    }

    @Test("R3-3 PR chips are https only with noopener noreferrer")
    func httpsOnlyPRChips() {
        let project = Project(name: "App", path: "/tmp/a", kind: .coding)
        let now = Date(timeIntervalSince1970: 1_730_376_000)
        let https = Card(
            id: "c111111111111",
            project: "App",
            title: "Safe",
            column: "review",
            order: 0,
            linkedPR: "https://github.com/acme/app/pull/7"
        )
        let html = DeskPage.render(projects: [project], board: Board(cards: [https]), now: now)
        #expect(html.contains("href=\"https://github.com/acme/app/pull/7\""))
        #expect(html.contains("rel=\"noopener noreferrer\""))
        #expect(html.contains("target=\"_blank\""))

        for linked in ["http://github.com/acme/app/pull/7", "javascript:alert(1)", "ftp://example.com/7"] {
            let card = Card(
                id: "c222222222222",
                project: "App",
                title: "Blocked",
                column: "review",
                order: 1,
                linkedPR: linked
            )
            let blocked = DeskPage.render(projects: [project], board: Board(cards: [card]), now: now)
            #expect(!blocked.contains("class=\"kchip kpr\" href"))
            #expect(blocked.contains("<span class=\"kchip kpr\">"))
        }
    }

    @Test("R3-4 README documents cookie port scope and fail-closed port")
    func readmeCookiePortScope() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("README.md")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("Browsers do not scope cookies by port"))
        #expect(text.contains("fails closed"))
        #expect(text.contains("single-use sign-in code limits what a squatter can get"))
        #expect(text.contains("valid once, for 10 minutes"))
        #expect(text.contains("`GET /?token=` is rejected"))
    }

    @Test("R3-5 live script locks a card with aria-busy during move")
    func moveCardLocksInFlight() {
        let html = DeskPage.render(projects: [], board: Board(), now: Date(), mode: .live)
        #expect(html.contains("if(card.getAttribute('aria-busy')==='true') return;"))
        #expect(html.contains("card.setAttribute('aria-busy','true')"))
        #expect(html.contains("card.removeAttribute('aria-busy')"))
        #expect(html.contains("if(card.getAttribute('aria-busy')==='true'){ e.preventDefault(); return; }"))
        #expect(html.contains(".kcard[aria-busy=\"true\"]"))
        #expect(html.contains("finally{"))
    }

    @Test("R3-6 any matching dpc_token cookie is accepted")
    func anyMatchingCookie() throws {
        let desk = try TempDesk.make()
        defer { desk.cleanup() }
        final class MoveBox: @unchecked Sendable {
            var column: String?
        }
        let moved = MoveBox()
        let server = try DeskServer(
            knowledgeBasePath: desk.kb.path,
            bindHost: "127.0.0.1",
            port: 0,
            htmlProvider: { "<html></html>" },
            onMove: { _, column in moved.column = column },
            onAdd: { _, _ in }
        )
        try server.start()
        defer { server.stop() }
        let host = "127.0.0.1:\(server.port)"
        let origin = "http://127.0.0.1:\(server.port)"
        let body = Data(#"{"id":"cabcabcabcab","column":"done"}"#.utf8)

        let firstWrong = server.handleForTests(
            HTTPRequest(
                method: "POST",
                path: "/api/cards/move",
                headers: [
                    "origin": origin,
                    "host": host,
                    "cookie": "dpc_token=wrong; dpc_token=\(server.token); extra=1"
                ],
                body: body
            )
        )
        #expect(firstWrong.status == 200)
        #expect(moved.column == "done")

        let onlyWrong = server.handleForTests(
            HTTPRequest(
                method: "POST",
                path: "/api/cards/move",
                headers: [
                    "origin": origin,
                    "host": host,
                    "cookie": "dpc_token=wrong; dpc_token=also-wrong"
                ],
                body: body
            )
        )
        #expect(onlyWrong.status == 401)
        #expect(String(data: onlyWrong.body, encoding: .utf8) == "bad token")
    }

    @Test("R3-7 invalid deskPort keeps allowedPaths and does not rewrite the file")
    func invalidDeskPortDoesNotRewrite() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dpc-r3-port-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("security-config.json")
        let json = """
        {"allowedPaths":["/tmp/custom-root"],"maxProjectNameLength":100,"maxDescriptionLength":2000,"maxNotesLength":10000,"maxSearchPatternLength":300,"enableValidation":true,"deskPort":"nope"}
        """
        try Data(json.utf8).write(to: url)
        let before = try String(contentsOf: url, encoding: .utf8)
        let config = SecurityConfig.load(from: url.path)
        #expect(config.allowedPaths == ["/tmp/custom-root"])
        #expect(config.deskPort == DeskServer.defaultPort)
        let after = try String(contentsOf: url, encoding: .utf8)
        #expect(after == before)

        let zeroURL = dir.appendingPathComponent("zero.json")
        let zeroJSON = """
        {"allowedPaths":["/tmp/zero-root"],"maxProjectNameLength":100,"maxDescriptionLength":2000,"maxNotesLength":10000,"maxSearchPatternLength":300,"enableValidation":true,"deskPort":0}
        """
        try Data(zeroJSON.utf8).write(to: zeroURL)
        let zeroBefore = try String(contentsOf: zeroURL, encoding: .utf8)
        let zeroConfig = SecurityConfig.load(from: zeroURL.path)
        #expect(zeroConfig.allowedPaths == ["/tmp/zero-root"])
        #expect(zeroConfig.deskPort == DeskServer.defaultPort)
        #expect(try String(contentsOf: zeroURL, encoding: .utf8) == zeroBefore)
    }

    @Test("R3-7 bad DPC_DESK_PORT falls back to config then default")
    func badEnvPortFallsBack() {
        #expect(DeskServer.resolvePort(configPort: 49_000, environment: ["DPC_DESK_PORT": "nope"]) == 49_000)
        #expect(DeskServer.resolvePort(configPort: 49_000, environment: ["DPC_DESK_PORT": "0"]) == 49_000)
        #expect(DeskServer.resolvePort(environment: ["DPC_DESK_PORT": "not-a-port"]) == DeskServer.defaultPort)
        #expect(DeskServer.resolvePort(configPort: 49_000, environment: [:]) == 49_000)
    }
}
