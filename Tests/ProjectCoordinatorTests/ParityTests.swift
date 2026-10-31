import Foundation
import Testing
@testable import ProjectCoordinator

@Suite("Parity analytics and detector")
struct ParityAnalyticsTests {
    private var now: Date {
        Date(timeIntervalSince1970: 1_730_376_000) // 2024-10-31
    }

    @Test("desk page includes full analytics sections and escapes names")
    func pageSectionsAndEscaping() {
        let evil = Project(name: "<script>p</script>", path: nil, lastModified: now, kind: .legal)
        let record = ProjectWithAnalytics(
            name: evil.name,
            path: nil,
            description: nil,
            status: "review",
            notes: nil,
            techStack: [],
            lastModified: now,
            currentTasks: [],
            kind: .legal,
            activityLog: [
                ActivityEvent(timestamp: now.addingTimeInterval(-86_400), type: .statusChange, description: "<b>")
            ],
            createdDate: now.addingTimeInterval(-10 * 86_400)
        )
        let html = DeskPage.render(
            projects: [evil],
            board: Board(),
            records: [record],
            now: now
        )
        #expect(html.contains("<h2>Project health</h2>"))
        #expect(html.contains("<h2>Activity heat map</h2>"))
        #expect(html.contains("<h2>Technology trends</h2>"))
        #expect(html.contains("<h2>Project timeline</h2>"))
        #expect(html.contains("heat-cell"))
        #expect(html.contains("class=\"gauge"))
        #expect(html.contains("spark"))
        #expect(!html.contains("<script>p</script>"))
        #expect(html.contains("&lt;script&gt;p&lt;/script&gt;"))
        #expect(html.contains("No coding projects on the desk"))
    }

    @Test("non-coding health skips documentation penalty")
    func nonCodingHealth() {
        let coding = Project(name: "App", path: "/tmp/app", lastModified: now, kind: .coding)
        let legal = Project(name: "Matter", path: nil, lastModified: now, kind: .legal)
        let records = [coding, legal].map { ProjectWithAnalytics(from: $0) }
        let report = AnalyticsEngine.health(projects: [coding, legal], records: records, now: now)
        let app = report.rows.first { $0.name == "App" }
        let matter = report.rows.first { $0.name == "Matter" }
        #expect(app?.factors.contains { $0.label == "Documentation Quality" } == true)
        #expect(matter?.factors.contains { $0.label == "Documentation Quality" } == false)
        #expect(app?.recommendations.contains("Add project documentation") == true)
        #expect(matter?.recommendations.contains("Add project documentation") == false)
        #expect((matter?.score ?? 0) > (app?.score ?? 100))
        let markdown = AnalyticsEngine.markdownHealth(report)
        #expect(!markdown.contains("🚨"))
        #expect(markdown.contains("### Critical") || markdown.contains("### Needs Attention") || markdown.contains("### Healthy"))
    }

    @Test("empty heat map and coding-only trends")
    func emptyStates() {
        let campaign = Project(name: "Launch", path: nil, lastModified: now, kind: .campaign)
        let heat = AnalyticsEngine.heatMap(projects: [campaign], records: [], days: 14, now: now)
        #expect(heat.totalEvents == 0)
        #expect(heat.rows.count == 1)
        #expect(heat.rows[0].cells.count == 14)
        let md = AnalyticsEngine.markdownHeatMap(heat)
        #expect(md.contains("quiet"))
        #expect(!md.contains("🔥"))
        #expect(!md.contains("💤"))
        let trends = AnalyticsEngine.techTrends(projects: [campaign], records: [])
        #expect(trends.codingProjectCount == 0)
        #expect(AnalyticsEngine.markdownTechTrends(trends).contains("coding projects only"))
    }

    @Test("detector tags docker, spm, swiftui, xcode, and dotnet")
    func detectorTags() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dpc-parity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let swift = root.appendingPathComponent("swift-app")
        try FileManager.default.createDirectory(at: swift, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\n".write(to: swift.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "import SwiftUI\nstruct A {}\n".write(to: swift.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: swift.appendingPathComponent("Demo.xcodeproj"), withIntermediateDirectories: true)

        let docker = root.appendingPathComponent("compose")
        try FileManager.default.createDirectory(at: docker, withIntermediateDirectories: true)
        try "FROM swift:6.0\n".write(to: docker.appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)

        let dotnet = root.appendingPathComponent("ledger")
        try FileManager.default.createDirectory(at: dotnet, withIntermediateDirectories: true)
        try "<Project></Project>\n".write(to: dotnet.appendingPathComponent("Ledger.csproj"), atomically: true, encoding: .utf8)

        let swiftTags = ProjectDetector.detect(at: swift.path).tags
        #expect(swiftTags.contains("swift"))
        #expect(swiftTags.contains("spm"))
        #expect(swiftTags.contains("swiftui"))
        #expect(swiftTags.contains("xcode-project"))

        #expect(ProjectDetector.detect(at: docker.path).tags.contains("docker"))
        let net = ProjectDetector.detect(at: dotnet.path).tags
        #expect(net.contains("csharp"))
        #expect(net.contains("dotnet"))
    }

    @Test("accounting and business kinds file without a path")
    func extraKinds() async throws {
        let desk = try TempDesk.make()
        defer { desk.cleanup() }
        let analytics = ProjectAnalytics(knowledgeBasePath: desk.kb.path)
        let manager = ProjectManager(knowledgeBasePath: desk.kb.path, extraAllowedBases: [desk.work.path])
        await manager.initialize(analytics: analytics)
        let vat = try await manager.fileUnderProject(name: "Q3 VAT", kind: .accounting)
        #expect(vat.contains("Filed under new project: Q3 VAT"))
        let firm = try await manager.fileUnderProject(name: "Holdings", kind: .business)
        #expect(firm.contains("Filed under new project: Holdings"))
        let projects = await manager.allProjects()
        #expect(projects.contains { $0.name == "Q3 VAT" && $0.kind == .accounting })
        #expect(projects.contains { $0.name == "Holdings" && $0.kind == .business })
    }

    @Test("rename keeps analytics history")
    func renameKeepsAnalytics() async throws {
        let desk = try TempDesk.make()
        defer { desk.cleanup() }
        let analytics = ProjectAnalytics(knowledgeBasePath: desk.kb.path)
        let manager = ProjectManager(knowledgeBasePath: desk.kb.path, extraAllowedBases: [desk.work.path])
        await manager.initialize(analytics: analytics)
        _ = try await manager.fileUnderProject(name: "Draft", kind: .legal)
        await analytics.recordActivity(for: "Draft", type: .noteAdded, description: "filed", at: now)
        _ = try await manager.renameProject(from: "Draft", to: "Autumn review")
        let records = await analytics.allRecords()
        #expect(records.contains { $0.name == "Autumn review" && $0.activityLog.count >= 1 })
        #expect(!FileManager.default.fileExists(atPath: desk.kb.appendingPathComponent("projects/Draft-analytics.json").path))
        #expect(FileManager.default.fileExists(atPath: desk.kb.appendingPathComponent("projects/Autumn review-analytics.json").path))
    }

    @Test("writes sample desk html for visual review")
    func writeSampleDesk() async throws {
        let html = SampleDesk.makeHTML(now: now)
        #expect(html.contains("<h2>Project health</h2>"))
        #expect(html.contains("<h2>Activity heat map</h2>"))
        #expect(html.contains("WidgetKit"))
        #expect(html.contains("Q3 VAT"))
        #expect(html.contains("fpill"))
        #expect(html.contains("1 event"))
        #expect(!html.contains("1 events"))
        #expect(html.contains("1 status move"))
        #expect(!html.contains("1 status moves"))
        #expect(html.contains("1 day ago"))
        #expect(!html.contains("1 days ago"))
        let out = SampleDesk.outputURL()
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try html.write(to: out, atomically: true, encoding: .utf8)
        #expect(FileManager.default.fileExists(atPath: out.path))
    }
}

enum SampleDesk {
    static func outputURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".scratch/out/sample-desk.html")
    }

    static func makeHTML(now: Date) -> String {
        let calendar = Calendar.current
        func days(_ n: Int) -> Date { calendar.date(byAdding: .day, value: n, to: now) ?? now }

        let widget = Project(
            name: "WidgetKit",
            path: "/tmp/widget-kit",
            description: "Node dashboard widgets",
            status: "doing",
            notes: "PR 42 in review",
            techStack: ["javascript", "node", "typescript"],
            lastModified: days(-1),
            currentTasks: ["polish charts"],
            kind: .coding
        )
        let ledger = Project(
            name: "Ledger",
            path: "/tmp/ledger",
            description: "Python books",
            status: "review",
            notes: "VAT extract",
            techStack: ["python", "docker"],
            lastModified: days(-2),
            currentTasks: [],
            kind: .coding
        )
        let harbor = Project(
            name: "Harbor",
            path: "/tmp/harbor",
            description: "Go ingest",
            status: "backlog",
            techStack: ["go", "docker"],
            lastModified: days(-8),
            currentTasks: ["metrics"],
            kind: .coding
        )
        let legal = Project(
            name: "Autumn review",
            path: nil,
            status: "doing",
            lastModified: days(-3),
            kind: .legal
        )
        let vat = Project(
            name: "Q3 VAT",
            path: nil,
            status: "review",
            lastModified: days(-4),
            kind: .accounting
        )
        let campaign = Project(
            name: "Launch wave",
            path: nil,
            status: "parked",
            lastModified: days(-12),
            kind: .campaign
        )
        let projects = [widget, ledger, harbor, legal, vat, campaign]

        func record(
            _ project: Project,
            created: Int,
            history: [(String, Int, Int?)],
            events: [(Int, ActivityEvent.EventType)]
        ) -> ProjectWithAnalytics {
            var spans: [StatusHistory] = []
            for item in history {
                let start = days(item.1)
                let end = item.2.map { days($0) }
                spans.append(StatusHistory(status: item.0, startDate: start, endDate: end))
            }
            let log = events.map { ActivityEvent(timestamp: days($0.0), type: $0.1, description: project.name) }
            return ProjectWithAnalytics(
                name: project.name,
                path: project.path,
                description: project.description,
                status: project.status,
                notes: project.notes,
                techStack: project.techStack,
                lastModified: project.lastModified,
                currentTasks: project.currentTasks,
                kind: project.kind,
                statusHistory: spans,
                activityLog: log,
                createdDate: days(created),
                completedTasks: project.kind == .coding ? ["scaffold"] : []
            )
        }

        let records = [
            record(widget, created: -40, history: [("backlog", -40, -20), ("doing", -20, nil)], events: [
                (-13, .accessed), (-10, .taskAdded), (-6, .statusChange), (-3, .noteAdded), (-1, .taskCompleted)
            ]),
            record(ledger, created: -30, history: [("doing", -30, -8), ("review", -8, nil)], events: [
                (-12, .noteAdded), (-9, .taskAdded), (-5, .accessed), (-2, .statusChange)
            ]),
            record(harbor, created: -18, history: [("backlog", -18, nil)], events: [
                (-14, .accessed), (-7, .searched)
            ]),
            record(legal, created: -21, history: [("backlog", -21, -10), ("doing", -10, nil)], events: [
                (-11, .statusChange), (-4, .noteAdded), (-1, .accessed)
            ]),
            record(vat, created: -25, history: [("doing", -25, -6), ("review", -6, nil)], events: [
                (-8, .noteAdded), (-6, .statusChange), (-2, .accessed)
            ]),
            record(campaign, created: -50, history: [("doing", -50, -14), ("parked", -14, nil)], events: [
                (-14, .statusChange)
            ])
        ]

        let cards = [
            Card(id: "c111111111111", project: "WidgetKit", title: "PR 42", column: "doing", order: 0, updated: days(-1), linkedPR: "42"),
            Card(id: "c222222222222", project: "Ledger", title: "VAT extract", column: "review", order: 0, updated: days(-2)),
            Card(id: "c333333333333", project: "Harbor", title: "Metrics", column: "backlog", order: 0, updated: days(-8)),
            Card(id: "c444444444444", project: "Autumn review", title: "Counsel memo", column: "doing", order: 0, updated: days(-3), memoryRef: "mem-legal-1"),
            Card(id: "c555555555555", project: "Q3 VAT", title: "File return", column: "review", order: 0, updated: days(-4)),
            Card(id: "c666666666666", project: "Launch wave", title: "Hold copy", column: "parked", order: 0, updated: days(-12))
        ]
        return DeskPage.render(
            projects: projects,
            board: Board(cards: cards),
            records: records,
            now: now
        )
    }
}
