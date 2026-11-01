import Foundation
import Testing
@testable import ProjectCoordinator

@Suite("Done card archive")
struct ArchiveTests {
    private let day: TimeInterval = 86_400

    private func card(
        _ id: String,
        _ title: String,
        _ column: String,
        ageDays: Double,
        order: Int,
        project: String = "Ledger",
        now: Date
    ) -> Card {
        Card(
            id: id,
            project: project,
            title: title,
            column: column,
            order: order,
            updated: now.addingTimeInterval(-ageDays * day)
        )
    }

    @Test("threshold is older than the window, and other columns stay active")
    func threshold() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let window = CardArchive.interval(days: 14)
        let onTheLine = card("c111111111111", "On the line", "done", ageDays: 14, order: 0, now: now)
        let justOver = card("c222222222222", "Just over", "done", ageDays: 14 + (1 / day), order: 1, now: now)
        let parked = card("c333333333333", "Held", "parked", ageDays: 40, order: 2, now: now)
        let doing = card("c444444444444", "Open", "doing", ageDays: 40, order: 3, now: now)
        let titledDone = card("c555555555555", "Capital", "Done", ageDays: 20, order: 4, now: now)

        #expect(!onTheLine.isArchived(now: now, archiveAfter: window))
        #expect(justOver.isArchived(now: now, archiveAfter: window))
        #expect(!parked.isArchived(now: now, archiveAfter: window))
        #expect(!doing.isArchived(now: now, archiveAfter: window))
        #expect(titledDone.isArchived(now: now, archiveAfter: window))
        #expect(!justOver.isArchived(now: now, archiveAfter: CardArchive.interval(days: 30)))
        #expect(CardArchive.days(environment: [:], configDays: nil) == 14)
        #expect(CardArchive.days(environment: ["DPC_ARCHIVE_DAYS": "7"], configDays: 21) == 7)
        #expect(CardArchive.days(environment: ["DPC_ARCHIVE_DAYS": "nope"], configDays: 21) == 21)
        #expect(CardArchive.days(environment: ["DPC_ARCHIVE_DAYS": ""], configDays: nil) == 14)
        #expect(CardArchive.days(environment: [:], configDays: 0) == 14)
    }

    @Test("old cards.json without archive fields decodes, and a stored flag is ignored")
    func decodesOldFile() throws {
        let raw = """
        {"cards":[{"column":"done","id":"cabcabcabcab","order":1,"project":"Ledger","title":"File return","updated":"2020-01-15T00:00:00Z"}],"columns":["backlog","doing","review","done","parked"]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let board = try decoder.decode(Board.self, from: Data(raw.utf8))
        let card = try #require(board.cards.first)
        #expect(card.title == "File return")
        #expect(card.due == nil)
        #expect(card.memoryRef == nil)
        #expect(card.linkedPR == nil)
        #expect(card.isArchived(now: Date(timeIntervalSince1970: 1_800_000_000)))

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fresh = self.card("c111111111111", "Fresh", "backlog", ageDays: 1, order: 0, now: now)
        var payload = try JSONSerialization.jsonObject(with: try encoded(fresh)) as! [String: Any]
        var cards = payload["cards"] as! [[String: Any]]
        cards[0].removeValue(forKey: "due")
        cards[0].removeValue(forKey: "memoryRef")
        cards[0].removeValue(forKey: "linkedPR")
        cards[0]["archived"] = true
        payload["cards"] = cards
        let legacy = try JSONSerialization.data(withJSONObject: payload)
        let decoded = try decoder.decode(Board.self, from: legacy)
        let decodedCard = try #require(decoded.cards.first)
        #expect(!decodedCard.isArchived(now: now))
        let text = String(decoding: legacy, as: UTF8.self)
        #expect(text.contains("\"archived\""))
    }

    @Test("loading an aged board does not rewrite cards.json")
    func loadDoesNotWrite() async throws {
        let desk = try TempDesk.make()
        defer { desk.cleanup() }
        let now = Date()
        let aged = card("c111111111111", "Old filing", "done", ageDays: 20, order: 0, now: now)
        let store = CardStore(knowledgeBasePath: desk.kb.path)
        try await store.replaceBoard(Board(cards: [aged]))
        let url = desk.kb.appendingPathComponent("desk/cards.json")
        let before = try Data(contentsOf: url)
        let text = String(decoding: before, as: UTF8.self)
        #expect(!text.contains("\"archived\""))
        #expect(!text.contains("archivedAt"))
        let snap = try await store.snapshot()
        #expect(snap.cards.count == 1)
        #expect(try #require(snap.cards.first).isArchived(now: Date()))
        let after = try Data(contentsOf: url)
        #expect(before == after)
    }

    @Test("move and update bring a done card back and keep it on disk")
    func unarchiveOnMoveAndUpdate() async throws {
        let desk = try TempDesk.make()
        defer { desk.cleanup() }
        let now = Date()
        let store = CardStore(knowledgeBasePath: desk.kb.path)
        try await store.replaceBoard(
            Board(cards: [
                card("c111111111111", "Old filing", "done", ageDays: 20, order: 0, now: now),
                card("c222222222222", "Also old", "done", ageDays: 30, order: 1, now: now),
                card("c333333333333", "Touched", "done", ageDays: 40, order: 2, now: now)
            ])
        )

        let moved = try await store.moveCard(id: "c111111111111", column: "doing")
        #expect(moved.column == "doing")
        #expect(!moved.isArchived())

        let updated = try await store.updateCard(id: "c222222222222", column: "review")
        #expect(updated.column == "review")
        #expect(!updated.isArchived())

        let retitled = try await store.updateCard(id: "c333333333333", title: "Touched again")
        #expect(retitled.column == "done")
        #expect(retitled.title == "Touched again")
        #expect(!retitled.isArchived())

        let snap = try await store.snapshot()
        #expect(snap.cards.count == 3)
        let saved = try String(contentsOf: desk.kb.appendingPathComponent("desk/cards.json"), encoding: .utf8)
        #expect(saved.contains("c111111111111"))
        #expect(saved.contains("c222222222222"))
        #expect(saved.contains("c333333333333"))
        #expect(!saved.contains("\"archived\""))
        #expect(!saved.contains("archivedAt"))
    }

    @Test("summary and project status omit archived cards, search still marks them")
    func toolLists() async throws {
        let desk = try TempDesk.make()
        defer { desk.cleanup() }
        let analytics = ProjectAnalytics(knowledgeBasePath: desk.kb.path)
        let manager = ProjectManager(knowledgeBasePath: desk.kb.path, extraAllowedBases: [desk.work.path])
        await manager.initialize(analytics: analytics)
        _ = try await manager.fileUnderProject(name: "Ledger", kind: .accounting)

        let now = Date()
        let store = CardStore(knowledgeBasePath: desk.kb.path)
        try await store.replaceBoard(
            Board(cards: [
                card("c111111111111", "Old return", "done", ageDays: 20, order: 0, now: now),
                card("c222222222222", "Fresh return", "done", ageDays: 2, order: 1, now: now),
                card("c333333333333", "Draft note", "doing", ageDays: 1, order: 2, now: now)
            ])
        )

        let summary = try await manager.deskSummary()
        #expect(summary.contains("archived=1"))
        #expect(summary.contains("done=1"))
        #expect(summary.contains("Draft note"))
        #expect(!summary.contains("Old return"))

        let withArchived = try await manager.deskSummary(includeArchived: true)
        #expect(withArchived.contains("arch  c111111111111  Old return"))

        let status = try await manager.getProjectStatus(projectName: "Ledger")
        #expect(status.contains("[done] Fresh return (c222222222222)"))
        #expect(status.contains("[doing] Draft note (c333333333333)"))
        #expect(!status.contains("Old return"))
        #expect(status.contains("Archived: 1"))

        let full = try await manager.getProjectStatus(projectName: "Ledger", includeArchived: true)
        #expect(full.contains("[done] Old return (c111111111111) archived"))

        let found = try await manager.searchCodePatterns(pattern: "return")
        let lines = found.split(separator: "\n").map(String.init)
        #expect(lines.contains { $0.contains("c111111111111") && $0.contains("[archived]") })
        #expect(lines.contains { $0.contains("c222222222222") && !$0.contains("[archived]") })

        _ = try await store.moveCard(id: "c111111111111", column: "doing")
        let after = try await manager.getProjectStatus(projectName: "Ledger")
        #expect(after.contains("Old return"))
        #expect(after.contains("Archived: 0"))
        #expect(!after.contains("[archived]"))
        #expect(!after.contains(") archived"))
    }

    @Test("kanban hides aged done cards and leaves the 7 day stat and board flow alone")
    func toggleDataLeavesAnalyticsAlone() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let project = Project(name: "Ledger", path: nil, status: "Active", lastModified: now, kind: .accounting)
        let cards = [
            card("c111111111111", "Fresh", "done", ageDays: 2, order: 0, now: now),
            card("c222222222222", "Week plus", "done", ageDays: 10, order: 1, now: now),
            card("c333333333333", "Old filing", "done", ageDays: 20, order: 2, now: now),
            card("c444444444444", "Still open", "doing", ageDays: 30, order: 3, now: now)
        ]
        let board = Board(cards: cards)
        let html = DeskPage.render(projects: [project], board: board, now: now, archiveAfter: CardArchive.defaultInterval)

        #expect(html.contains("<h3>done <span class=\"count-pill\">2</span></h3>"))
        #expect(html.contains("Show archived (1)"))
        #expect(html.contains("class=\"archive-toggle\""))
        #expect(html.contains("data-archive-count=\"1\""))
        #expect(html.contains("aria-expanded=\"false\""))
        #expect(html.contains("<article class=\"kcard archived\" title=\"c333333333333\" hidden"))
        #expect(html.contains("<article class=\"kcard\" title=\"c111111111111\""))
        #expect(html.contains("<article class=\"kcard\" title=\"c222222222222\""))
        #expect(html.contains(".kcard.archived { opacity:.55; }"))
        #expect(html.contains("Hide archived ("))
        #expect(html.contains("<b>1</b><span>Done in 7 days</span>"))
        #expect(html.contains("<tr><td>done</td><td>3</td></tr>"))
        #expect(html.contains("Throughput into done (7 days): 1."))
        #expect(!html.contains("<article class=\"kcard archived\" title=\"c444444444444\""))

        let shorter = DeskPage.render(
            projects: [project],
            board: board,
            now: now,
            archiveAfter: CardArchive.interval(days: 7)
        )
        #expect(shorter.contains("Show archived (2)"))
        #expect(shorter.contains("<h3>done <span class=\"count-pill\">1</span></h3>"))
        #expect(shorter.contains("<article class=\"kcard archived\" title=\"c222222222222\" hidden"))
        #expect(shorter.contains("<b>1</b><span>Done in 7 days</span>"))
        #expect(shorter.contains("<tr><td>done</td><td>3</td></tr>"))

        let freshOnly = DeskPage.render(
            projects: [project],
            board: Board(cards: [cards[0]]),
            now: now,
            archiveAfter: CardArchive.defaultInterval
        )
        #expect(!freshOnly.contains("class=\"archive-toggle\""))
    }

    @Test("security-config archiveDays is optional and the desk page uses it")
    func configDays() throws {
        let missing = """
        {"allowedPaths":["/tmp/custom-root"],"maxProjectNameLength":100,"maxDescriptionLength":2000,"maxNotesLength":10000,"maxSearchPatternLength":300,"enableValidation":true}
        """
        let decoder = JSONDecoder()
        let old = try decoder.decode(SecurityConfig.self, from: Data(missing.utf8))
        #expect(old.archiveDays == 14)
        #expect(old.allowedPaths == ["/tmp/custom-root"])

        let invalid = """
        {"allowedPaths":["/tmp/kept"],"maxProjectNameLength":100,"maxDescriptionLength":2000,"maxNotesLength":10000,"maxSearchPatternLength":300,"enableValidation":true,"archiveDays":"nope"}
        """
        let broken = try decoder.decode(SecurityConfig.self, from: Data(invalid.utf8))
        #expect(broken.archiveDays == 14)
        #expect(broken.allowedPaths == ["/tmp/kept"])

        let desk = try TempDesk.make()
        defer { desk.cleanup() }
        let file = """
        {"allowedPaths":["/tmp/kept"],"maxProjectNameLength":100,"maxDescriptionLength":2000,"maxNotesLength":10000,"maxSearchPatternLength":300,"enableValidation":true,"archiveDays":5}
        """
        try file.write(to: desk.kb.appendingPathComponent("security-config.json"), atomically: true, encoding: .utf8)
        let fromFile = DeskPage.archiveInterval(knowledgeBasePath: desk.kb.path, environment: [:])
        #expect(fromFile == CardArchive.interval(days: 5))
        let overridden = DeskPage.archiveInterval(
            knowledgeBasePath: desk.kb.path,
            environment: ["DPC_ARCHIVE_DAYS": "30"]
        )
        #expect(overridden == CardArchive.interval(days: 30))

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let board = Board(cards: [
            card("c111111111111", "Three days", "done", ageDays: 3, order: 0, now: now),
            card("c222222222222", "Six days", "done", ageDays: 6, order: 1, now: now)
        ])
        let html = DeskPage.render(projects: [], board: board, now: now, archiveAfter: fromFile)
        #expect(html.contains("Show archived (1)"))
        #expect(html.contains("<article class=\"kcard\" title=\"c111111111111\""))
        #expect(html.contains("<article class=\"kcard archived\" title=\"c222222222222\" hidden"))
    }

    @Test("a drag move through the desk server un-archives and keeps the card")
    func deskServerMoveUnarchives() async throws {
        let desk = try TempDesk.make()
        defer { desk.cleanup() }
        let store = CardStore(knowledgeBasePath: desk.kb.path)
        let now = Date()
        try await store.replaceBoard(
            Board(cards: [
                card("cabcabcabcab", "Old filing", "done", ageDays: 21, order: 0, now: now)
            ])
        )
        let errors = ErrorBox()
        let server = try DeskServer(
            knowledgeBasePath: desk.kb.path,
            bindHost: "127.0.0.1",
            port: 0,
            htmlProvider: { "<html></html>" },
            onMove: { id, column in
                let semaphore = DispatchSemaphore(value: 0)
                Task.detached {
                    do {
                        _ = try await store.moveCard(id: id, column: column)
                    } catch {
                        errors.error = error
                    }
                    semaphore.signal()
                }
                semaphore.wait()
                if let error = errors.error { throw error }
            },
            onAdd: { _, _ in }
        )
        try server.start()
        defer { server.stop() }

        let origin = "http://127.0.0.1:\(server.port)"
        let host = "127.0.0.1:\(server.port)"
        let body = Data(#"{"id":"cabcabcabcab","column":"doing"}"#.utf8)
        let response: HTTPResponse = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let result = server.handleForTests(
                    HTTPRequest(
                        method: "POST",
                        path: "/api/cards/move",
                        headers: [
                            "origin": origin,
                            "host": host,
                            "x-dpc-token": server.token
                        ],
                        body: body
                    )
                )
                continuation.resume(returning: result)
            }
        }
        #expect(response.status == 200)
        let snap = try await store.snapshot()
        let moved = try #require(snap.cards.first)
        #expect(moved.column == "doing")
        #expect(!moved.isArchived())
        #expect(snap.cards.count == 1)
    }

    @Test("stale count still sees a recent archived card when the window is short")
    func staleIgnoresArchiveFilter() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let project = Project(
            name: "RecentCard",
            path: nil,
            status: "Active",
            lastModified: now.addingTimeInterval(-20 * day),
            kind: .accounting
        )
        let board = Board(cards: [
            card("c111111111111", "Five days", "done", ageDays: 5, order: 0, project: "RecentCard", now: now)
        ])
        let text = DeskSummary.render(
            projects: [project],
            board: board,
            now: now,
            archiveAfter: CardArchive.interval(days: 3)
        )
        #expect(text.contains("archived=1"))
        #expect(text.contains("stale=0"))
        #expect(text.contains("stale: none"))
        #expect(!text.contains("Five days"))
    }

    @Test("optional note is omitted when nil, shown escaped, and searchable")
    func cardNote() async throws {
        let bare = Card(
            id: "cabcabcabcab",
            project: "Ledger",
            title: "File return",
            column: "done",
            order: 0,
            updated: Date(timeIntervalSince1970: 1_577_836_800)
        )
        let bareJSON = String(decoding: try encoded(bare), as: UTF8.self)
        #expect(!bareJSON.contains("\"note\""))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let roundTrip = try decoder.decode(Board.self, from: Data(bareJSON.utf8))
        #expect(roundTrip.cards.first?.note == nil)

        let withNote = """
        {"cards":[{"column":"doing","id":"cabcabcabcab","note":"Tech: commit 299b827","order":0,"project":"Ledger","title":"File return","updated":"2020-01-15T00:00:00Z"}],"columns":["backlog","doing","review","done","parked"]}
        """
        let decoded = try decoder.decode(Board.self, from: Data(withNote.utf8))
        #expect(decoded.cards.first?.note == "Tech: commit 299b827")

        let desk = try TempDesk.make()
        defer { desk.cleanup() }
        let analytics = ProjectAnalytics(knowledgeBasePath: desk.kb.path)
        let manager = ProjectManager(knowledgeBasePath: desk.kb.path, extraAllowedBases: [desk.work.path])
        await manager.initialize(analytics: analytics)
        _ = try await manager.fileUnderProject(name: "Ledger", kind: .accounting)
        let added = try await manager.addCard(
            project: "Ledger",
            title: "Close the books",
            column: "doing",
            note: "Tech: commit 299b827"
        )
        #expect(added.contains("Added card"))
        let created = try await manager.boardSnapshot().cards.first { $0.title == "Close the books" }
        let id = try #require(created?.id)
        #expect(created?.note == "Tech: commit 299b827")

        let saved = try String(contentsOf: desk.kb.appendingPathComponent("desk/cards.json"), encoding: .utf8)
        #expect(saved.contains("\"note\""))
        #expect(saved.contains("Tech: commit 299b827"))

        let moved = try await manager.moveCard(id: id, column: "review")
        #expect(moved.contains("review"))
        let kept = try await manager.boardSnapshot().cards.first { $0.id == id }
        #expect(kept?.note == "Tech: commit 299b827")
        #expect(kept?.column == "review")

        _ = try await manager.moveCard(id: id, column: "done", note: "https://example.com/evidence")
        let replaced = try await manager.boardSnapshot().cards.first { $0.id == id }
        #expect(replaced?.note == "https://example.com/evidence")

        _ = try await manager.updateCard(id: id, note: "   ")
        let cleared = try await manager.boardSnapshot().cards.first { $0.id == id }
        #expect(cleared?.note == nil)
        let clearedJSON = try String(contentsOf: desk.kb.appendingPathComponent("desk/cards.json"), encoding: .utf8)
        #expect(!clearedJSON.contains("\"note\""))

        _ = try await manager.updateCard(id: id, note: "Tech: <b>299b827</b> & friends")
        let noted = try await manager.boardSnapshot().cards.first { $0.id == id }
        let html = DeskPage.render(
            projects: [Project(name: "Ledger", path: nil, kind: .accounting)],
            board: Board(cards: [try #require(noted)])
        )
        #expect(html.contains("<p class=\"knote\">Tech: &lt;b&gt;299b827&lt;/b&gt; &amp; friends</p>"))
        #expect(!html.contains("<b>299b827</b>"))
        #expect(html.contains(".knote {"))

        let found = try await manager.searchCodePatterns(pattern: "299b827")
        #expect(found.contains(id))
        #expect(found.contains("299b827"))
        let miss = try await manager.searchCodePatterns(pattern: "not-in-the-title-or-note")
        #expect(!miss.contains(id))

        let status = try await manager.getProjectStatus(projectName: "Ledger")
        #expect(status.contains("299b827"))
    }

    private func encoded(_ card: Card) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Board(cards: [card]))
    }
}

private final class ErrorBox: @unchecked Sendable {
    var error: (any Error)?
}
