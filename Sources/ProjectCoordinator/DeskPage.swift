import Foundation

public enum DeskPageMode: Sendable {
    case file
    case live
}

/// Local Analytics + Kanban HTML. No remote fonts, no beacons.
public enum DeskPage {
    public static func render(
        projects: [Project],
        board: Board,
        records: [ProjectWithAnalytics] = [],
        now: Date = Date(),
        mode: DeskPageMode = .file
    ) -> String {
        let health = AnalyticsEngine.health(projects: projects, records: records, now: now)
        let heat = AnalyticsEngine.heatMap(
            projects: projects,
            records: records,
            days: AnalyticsEngine.heatMapPageDays,
            now: now
        )
        let trends = AnalyticsEngine.techTrends(projects: projects, records: records, now: now)
        let timeline = AnalyticsEngine.timeline(projects: projects, records: records, now: now)
        let analytics = analyticsPanel(
            projects: projects,
            board: board,
            health: health,
            heat: heat,
            trends: trends,
            timeline: timeline,
            now: now
        )
        let kanban = kanbanBoard(projects: projects, board: board, mode: mode, now: now)
        let script = mode == .live ? liveScript() : tabScript()
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Dev Project Coordinator desk</title>
        \(DeskAssets.headMarkup(mode: mode))
        <style>\(styles)</style>
        </head>
        <body>
        <div class="grain" aria-hidden="true"></div>
        <header>
        <div class="brand">
        \(DeskAssets.logoLightSVG)
        \(DeskAssets.logoDarkSVG)
        <div>
        <p class="eyebrow">Local desk</p>
        <h1>Dev Project Coordinator</h1>
        </div>
        </div>
        <p class="sub">Analytics and Kanban from local JSON. Nothing leaves this machine.</p>
        </header>
        <nav role="tablist">
        <button role="tab" id="tab-analytics" aria-selected="true" aria-controls="panel-analytics">Analytics</button>
        <button role="tab" id="tab-kanban" aria-selected="false" aria-controls="panel-kanban">Kanban</button>
        </nav>
        <main>
        <section class="panel active" id="panel-analytics" role="tabpanel">\(analytics)</section>
        <section class="panel" id="panel-kanban" role="tabpanel">\(kanban)</section>
        </main>
        <script>\(script)</script>
        </body>
        </html>
        """
    }

    public static func write(
        knowledgeBasePath: String,
        projects: [Project],
        board: Board,
        records: [ProjectWithAnalytics] = [],
        now: Date = Date()
    ) throws -> URL {
        let desk = URL(fileURLWithPath: knowledgeBasePath).appendingPathComponent("desk", isDirectory: true)
        try FileManager.default.createDirectory(at: desk, withIntermediateDirectories: true)
        let html = render(projects: projects, board: board, records: records, now: now, mode: .file)
        let url = desk.appendingPathComponent("index.html")
        guard let data = html.data(using: .utf8) else {
            throw CoordinatorError.fileSystemError("Could not encode desk HTML")
        }
        try AtomicFile.replace(destination: url, data: data)
        return url
    }

    public static func renderFromKnowledgeBase(
        knowledgeBasePath: String,
        mode: DeskPageMode,
        now: Date = Date()
    ) -> String {
        let loaded = loadFromDisk(knowledgeBasePath: knowledgeBasePath)
        return render(
            projects: loaded.projects,
            board: loaded.board,
            records: loaded.records,
            now: now,
            mode: mode
        )
    }

    public static func loadFromDisk(
        knowledgeBasePath: String
    ) -> (projects: [Project], board: Board, records: [ProjectWithAnalytics]) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let projectsDir = URL(fileURLWithPath: knowledgeBasePath).appendingPathComponent("projects")
        var projects: [Project] = []
        var records: [ProjectWithAnalytics] = []
        if let files = try? FileManager.default.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" {
                let name = file.lastPathComponent
                guard !name.contains("EXAMPLE") else { continue }
                guard let data = try? Data(contentsOf: file) else { continue }
                if name.hasSuffix("-analytics.json") {
                    if let record = try? decoder.decode(ProjectWithAnalytics.self, from: data) {
                        records.append(record)
                    }
                } else if let project = try? decoder.decode(Project.self, from: data) {
                    projects.append(project)
                }
            }
        }
        let cardsURL = URL(fileURLWithPath: knowledgeBasePath).appendingPathComponent("desk/cards.json")
        let board: Board
        if let data = try? Data(contentsOf: cardsURL),
           let decoded = try? decoder.decode(Board.self, from: data) {
            board = decoded
        } else {
            board = Board()
        }
        return (projects.sorted { $0.name < $1.name }, board, records)
    }

    // MARK: - Styles

    private static let styles = """
    :root {
      color-scheme: light dark;
      --bg:#f3efe6; --ink:#1c1914; --muted:#6a6458; --line:#d8d0c2; --card:#fffaf2;
      --accent:#2f5d50; --accent-2:#c46b3a; --warn:#b5812a; --bad:#9a3b2f; --review:#3d5a80; --done:#6b8f71;
      --shadow:0 18px 40px -28px rgba(28,25,20,.45);
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg:#16140f; --ink:#f4efe4; --muted:#b3aa9a; --line:#3a362c; --card:#221e18;
        --accent:#8fbfb0; --accent-2:#e09a6a; --warn:#e0b15a; --bad:#e07a6e; --review:#8aa4c8; --done:#9cbc9a;
        --shadow:0 18px 40px -24px rgba(0,0,0,.7);
      }
    }
    * { box-sizing:border-box; }
    body { margin:0; font:15px/1.45 ui-sans-serif, system-ui, sans-serif; background:var(--bg); color:var(--ink); }
    .grain { pointer-events:none; position:fixed; inset:0; opacity:.035; background-image:repeating-linear-gradient(0deg, transparent, transparent 3px, currentColor 4px); }
    .dash-split { display:grid; grid-template-columns:1.25fr .75fr; gap:1rem; margin:0 0 1rem; align-items:stretch; }
    .dash-split .card { margin:0; display:flex; flex-direction:column; }
    @media (max-width:900px) { .dash-split { grid-template-columns:1fr; } }
    header { padding:1.6rem 1.6rem .4rem; position:relative; }
    .brand { display:flex; align-items:center; gap:.85rem; margin:0 0 .35rem; }
    .logo { width:2.7rem; height:2.7rem; flex:none; border-radius:.72rem; display:block; }
    .logo-dark { display:none; }
    .eyebrow { letter-spacing:.16em; text-transform:uppercase; font-size:.68rem; color:var(--accent); margin:0 0 .35rem; }
    h1 { font-size:1.85rem; font-weight:650; margin:0; letter-spacing:-.03em; }
    h2 { font-size:1.05rem; margin:0 0 .7rem; letter-spacing:-.01em; }
    .sub { color:var(--muted); margin:0 0 1rem; max-width:40rem; }
    nav { display:flex; gap:.5rem; padding:0 1.6rem; border-bottom:1px solid var(--line); position:relative; }
    nav button { background:none; border:0; border-bottom:2px solid transparent; padding:.7rem .45rem; color:var(--muted); cursor:pointer; font:inherit; }
    nav button:hover { color:var(--ink); }
    nav button[aria-selected="true"] { color:var(--ink); border-bottom-color:var(--accent); }
    main { padding:1.1rem 1.6rem 2.4rem; position:relative; }
    .panel { display:none; }
    .panel.active { display:block; }
    .stats { display:grid; grid-template-columns:repeat(4,minmax(0,1fr)); gap:.75rem; margin:0 0 1.2rem; }
    .stat { background:var(--card); border:1px solid var(--line); border-radius:14px; padding:.85rem 1rem; box-shadow:var(--shadow), inset 3px 0 0 var(--accent); animation:rise .55s cubic-bezier(.22,1,.36,1) both; }
    .stat:nth-child(2) { animation-delay:.06s; box-shadow:var(--shadow), inset 3px 0 0 var(--accent-2); }
    .stat:nth-child(3) { animation-delay:.12s; box-shadow:var(--shadow), inset 3px 0 0 var(--warn); }
    .stat:nth-child(4) { animation-delay:.18s; box-shadow:var(--shadow), inset 3px 0 0 var(--done); }
    .stat b { display:block; font-variant-numeric:tabular-nums; font-size:1.7rem; letter-spacing:-.04em; line-height:1.1; }
    .stat span { color:var(--muted); font-size:.78rem; }
    .grid { display:grid; gap:1rem; }
    .card { background:var(--card); border:1px solid var(--line); border-radius:16px; padding:1rem 1.05rem 1.1rem; box-shadow:var(--shadow); animation:rise .6s cubic-bezier(.22,1,.36,1) both; margin:0 0 1rem; }
    .card h3 { font-size:.9rem; margin:.9rem 0 .45rem; color:var(--muted); font-weight:650; }
    table { border-collapse:collapse; width:100%; margin:.4rem 0 0; }
    th, td { text-align:left; padding:.42rem .5rem; border-bottom:1px solid var(--line); vertical-align:top; }
    th { font-size:.75rem; letter-spacing:.04em; text-transform:uppercase; color:var(--muted); font-weight:600; }
    .board { display:flex; gap:.75rem; overflow-x:auto; align-items:stretch; padding-bottom:.35rem; }
    .col { flex:1 1 0; min-width:11.5rem; min-height:12rem; background:var(--card); border:1px solid var(--line); border-radius:12px; padding:.65rem; border-top:3px solid var(--col-accent, var(--muted)); }
    .col h3 { margin:0 0 .5rem; font-size:.95rem; display:flex; justify-content:space-between; align-items:center; gap:.5rem; }
    .col[data-accent="0"] { --col-accent: var(--muted); }
    .col[data-accent="1"] { --col-accent: var(--accent); }
    .col[data-accent="2"] { --col-accent: var(--review); }
    .col[data-accent="3"] { --col-accent: var(--done); }
    .col[data-accent="4"] { --col-accent: var(--accent-2); }
    .col.drop-target { box-shadow: inset 0 0 0 2px var(--accent); }
    .count-pill { font-size:.72rem; font-variant-numeric:tabular-nums; min-width:1.4rem; text-align:center; border-radius:999px; padding:.12rem .45rem; background:var(--bg); border:1px solid var(--line); color:var(--ink); }
    .kcard { border:1px solid var(--line); border-radius:8px; padding:.55rem .6rem .5rem; margin:0 0 .5rem; background:var(--bg); transition: transform .22s cubic-bezier(.22,1,.36,1), box-shadow .22s cubic-bezier(.22,1,.36,1); }
    .kcard[draggable="true"] { cursor:grab; }
    .kcard[aria-busy="true"] { pointer-events:none; opacity:.72; cursor:progress; }
    .kcard:focus-visible { outline:2px solid var(--accent); outline-offset:2px; }
    .kcard.lifting { transform: rotate(-9deg) scale(1.04); box-shadow: 0 22px 36px -16px rgba(28,25,20,.5); z-index:2; }
    .kcard-ph { border:1.5px dashed var(--accent); border-radius:8px; min-height:3.1rem; margin:0 0 .5rem; background:color-mix(in oklab, var(--accent) 10%, transparent); }
    .kcard strong { display:block; }
    .kmeta { display:flex; flex-wrap:wrap; gap:.3rem; margin:.4rem 0 0; align-items:center; }
    .kchip { border:1px solid var(--line); border-radius:999px; padding:.1rem .45rem; font-size:.72rem; background:var(--card); color:var(--ink); text-decoration:none; }
    .kchip.kind-coding { background:color-mix(in oklab, var(--accent) 18%, var(--card)); }
    .kchip.kind-writing { background:color-mix(in oklab, var(--review) 18%, var(--card)); }
    .kchip.kind-campaign { background:color-mix(in oklab, var(--accent-2) 18%, var(--card)); }
    .kchip.kind-research { background:color-mix(in oklab, var(--done) 18%, var(--card)); }
    .kchip.kind-legal { background:color-mix(in oklab, var(--review) 22%, var(--card)); }
    .kchip.kind-accounting { background:color-mix(in oklab, var(--warn) 18%, var(--card)); }
    .kchip.kind-business { background:color-mix(in oklab, var(--accent) 12%, var(--card)); }
    .kchip.kind-personal { background:color-mix(in oklab, var(--done) 14%, var(--card)); }
    .kchip.kind-other { background:var(--card); }
    .kchip.kpr { border-color:color-mix(in oklab, var(--review) 45%, var(--line)); }
    .kchip.kref { border-color:color-mix(in oklab, var(--accent) 45%, var(--line)); }
    .ktime { color:var(--muted); font-size:.72rem; margin-left:.1rem; }
    .toast { position:fixed; bottom:1.2rem; left:50%; transform:translateX(-50%) translateY(8px); background:var(--ink); color:var(--bg); padding:.45rem .85rem; border-radius:8px; font-size:.85rem; opacity:0; pointer-events:none; transition:opacity .25s cubic-bezier(.22,1,.36,1), transform .25s cubic-bezier(.22,1,.36,1); z-index:20; }
    .toast.show { opacity:1; transform:translateX(-50%) translateY(0); }
    .flow { display:flex; height:.85rem; border-radius:99px; overflow:hidden; background:var(--line); margin:.35rem 0 .8rem; }
    .flow i { display:block; height:100%; transform-origin:left; animation:grow .8s cubic-bezier(.22,1,.36,1) both; }
    .flow i.c0, .swatch.c0 { background:#6a6458; background:var(--muted); }
    .flow i.c1, .swatch.c1 { background:#2f5d50; background:var(--accent); }
    .flow i.c2, .swatch.c2 { background:#3d5a80; background:var(--review); }
    .flow i.c3, .swatch.c3 { background:#6b8f71; background:var(--done); }
    .flow i.c4, .swatch.c4 { background:#c46b3a; background:var(--accent-2); }
    .chips { display:flex; flex-wrap:wrap; gap:.4rem; }
    .chip { border:1px solid var(--line); border-radius:999px; padding:.2rem .6rem; font-size:.8rem; background:var(--bg); display:inline-flex; flex-direction:row; align-items:center; gap:.35rem; white-space:nowrap; }
    .swatch { width:.55rem; height:.55rem; min-width:.55rem; min-height:.55rem; border-radius:99px; display:inline-block; flex:none; }
    .attn { display:grid; gap:.45rem; margin:0; padding:0; }
    .attn li { list-style:none; display:flex; gap:.7rem; align-items:center; background:var(--bg); border:1px solid var(--line); border-radius:10px; padding:.55rem .7rem; }
    .pulse { width:.55rem; height:.55rem; border-radius:50%; background:var(--accent-2); box-shadow:0 0 0 0 var(--accent-2); animation:pulse 1.8s cubic-bezier(.16,1,.3,1) infinite; flex:none; }
    .rank { font-variant-numeric:tabular-nums; color:var(--muted); width:1.2rem; flex:none; }
    .health-groups { display:grid; gap:1rem; }
    .health-row { display:grid; grid-template-columns:repeat(2,minmax(0,1fr)); gap:.75rem; }
    .hcard { display:flex; gap:.8rem; align-items:flex-start; border:1px solid var(--line); border-radius:12px; padding:.7rem; background:var(--bg); }
    .hcard.critical { border-color:color-mix(in oklab, var(--bad) 45%, var(--line)); }
    .hcard.attention { border-color:color-mix(in oklab, var(--warn) 45%, var(--line)); }
    .hmeta { min-width:0; }
    .hmeta strong { display:block; }
    .hmeta small { color:var(--muted); }
    .fpills { display:flex; flex-wrap:wrap; gap:.3rem; margin:.4rem 0 0; }
    .fpill { font-size:.72rem; border:1px solid var(--line); border-radius:999px; padding:.12rem .45rem; color:var(--muted); }
    .gauge { width:4.4rem; height:4.4rem; flex:none; }
    .gauge circle { fill:none; stroke-width:2.6; stroke-linecap:round; }
    .g-bg { stroke:#d8d0c2; stroke:var(--line); }
    .g-fg { stroke:#2f5d50; stroke:var(--accent); animation:gauge .9s cubic-bezier(.22,1,.36,1) both; }
    .gauge.critical .g-fg { stroke:#9a3b2f; stroke:var(--bad); }
    .gauge.attention .g-fg { stroke:#b5812a; stroke:var(--warn); }
    .gauge text { font:700 9px/1 ui-sans-serif, system-ui, sans-serif; fill:#1c1914; fill:var(--ink); }
    .heat-wrap { overflow-x:auto; }
    .heat { display:grid; gap:.35rem; min-width:36rem; }
    .heat-row, .heat-head { display:grid; grid-template-columns:9rem 1fr 3.2rem; gap:.5rem; align-items:center; }
    .heat-name { font-size:.85rem; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
    .heat-cells { display:grid; grid-template-columns:repeat(14,1fr); gap:3px; }
    .heat-labels span { aspect-ratio:auto; height:auto; background:none; font-size:.65rem; text-align:center; color:var(--muted); animation:none; border-radius:0; font-variant-numeric:tabular-nums; }
    .heat-cell { display:block; width:100%; height:1.05rem; min-height:1.05rem; border-radius:3px; background:#e7dfd0; animation:cell .45s cubic-bezier(.22,1,.36,1) both; animation-delay:calc(var(--i, 0) * 28ms); }
    .heat-cell:hover { outline:1px solid var(--ink); transform:scale(1.18); z-index:1; }
    .heat-cell.lv-1 { background:#b7cfc6; }
    .heat-cell.lv-2 { background:#8fb3a6; }
    .heat-cell.lv-3 { background:#5d8f7e; }
    .heat-cell.lv-4 { background:#2f5d50; }
    .heat-total { text-align:right; font-variant-numeric:tabular-nums; color:var(--muted); font-size:.8rem; }
    .legend { display:flex; gap:.35rem; align-items:center; color:var(--muted); font-size:.78rem; margin:.6rem 0 0; }
    .legend i { width:.7rem; height:.7rem; border-radius:2px; display:inline-block; background:#e7dfd0; }
    .legend i.lv-1 { background:#b7cfc6; }
    .legend i.lv-2 { background:#8fb3a6; }
    .legend i.lv-3 { background:#5d8f7e; }
    .legend i.lv-4 { background:#2f5d50; }
    .spark { width:100%; height:3.2rem; display:block; margin:.2rem 0 .8rem; }
    .spark polyline { fill:none; stroke:#2f5d50; stroke:var(--accent); stroke-width:1.8; stroke-linejoin:round; stroke-linecap:round; }
    .spark polygon { fill:#d5e4de; stroke:none; }
    .share { display:grid; gap:.45rem; }
    .share-row { display:grid; grid-template-columns:7.5rem 1fr 5.8rem; gap:.5rem; align-items:center; }
    .share-bar { height:.55rem; background:var(--line); border-radius:99px; overflow:hidden; }
    .share-bar span { display:block; height:100%; background:var(--accent); transform-origin:left; animation:grow .85s cubic-bezier(.22,1,.36,1) both; }
    .empty { color:var(--muted); margin:0; font-size:.85rem; }
    details.timeline { border:1px solid var(--line); border-radius:10px; padding:.45rem .7rem; background:var(--bg); margin:0 0 .45rem; }
    details.timeline summary { cursor:pointer; display:flex; justify-content:space-between; align-items:center; gap:1rem; list-style:none; }
    details.timeline summary::-webkit-details-marker { display:none; }
    details.timeline summary::before { content:""; width:.38rem; height:.38rem; border-right:2px solid var(--muted); border-bottom:2px solid var(--muted); transform:rotate(-45deg); margin-right:.15rem; flex:none; }
    details.timeline[open] summary::before { transform:rotate(45deg); }
    .span-bar { display:flex; height:.7rem; border-radius:99px; overflow:hidden; margin:.55rem 0; background:var(--line); }
    .span-bar i { display:block; height:100%; }
    .span-bar i:nth-child(odd) { background:var(--accent); }
    .span-bar i:nth-child(even) { background:var(--accent-2); }
    .note { color:var(--muted); font-size:.9rem; }
    @keyframes rise { from { opacity:0; transform:translateY(8px); } to { opacity:1; transform:none; } }
    @keyframes grow { from { transform:scaleX(0); } to { transform:scaleX(1); } }
    @keyframes gauge { from { stroke-dashoffset:100; } }
    @keyframes cell { from { opacity:0; transform:scale(.6); } to { opacity:1; transform:none; } }
    @keyframes pulse { 0% { box-shadow:0 0 0 0 color-mix(in oklab, var(--accent-2) 55%, transparent); } 100% { box-shadow:0 0 0 10px transparent; } }
    @media (max-width:900px) {
      .stats { grid-template-columns:repeat(2,minmax(0,1fr)); }
      .health-row { grid-template-columns:1fr; }
    }
    @media (max-width:640px) {
      .stats { grid-template-columns:1fr 1fr; }
      header, main, nav { padding-left:1rem; padding-right:1rem; }
      .heat { min-width:22rem; }
      .heat-row, .heat-head { grid-template-columns:4.8rem 1fr 1.8rem; }
    }
    @media (prefers-color-scheme: dark) {
      .logo-light { display:none; }
      .logo-dark { display:block; }
      .kcard.lifting { box-shadow: 0 22px 36px -14px rgba(0,0,0,.7); }
      .g-bg { stroke:#3a362c; }
      .g-fg { stroke:#8fbfb0; }
      .gauge.critical .g-fg { stroke:#e07a6e; }
      .gauge.attention .g-fg { stroke:#e0b15a; }
      .gauge text { fill:#f4efe4; }
      .heat-cell, .legend i { background:#2c281f; }
      .heat-cell.lv-1, .legend i.lv-1 { background:#35574d; }
      .heat-cell.lv-2, .legend i.lv-2 { background:#4d7a6c; }
      .heat-cell.lv-3, .legend i.lv-3 { background:#6fa090; }
      .heat-cell.lv-4, .legend i.lv-4 { background:#8fbfb0; }
      .spark polygon { fill:#2a3f38; }
      .spark polyline { stroke:#8fbfb0; }
      .flow i.c0, .swatch.c0 { background:#b3aa9a; }
      .flow i.c1, .swatch.c1 { background:#8fbfb0; }
      .flow i.c2, .swatch.c2 { background:#8aa4c8; }
      .flow i.c3, .swatch.c3 { background:#9cbc9a; }
      .flow i.c4, .swatch.c4 { background:#e09a6a; }
    }
    @media (prefers-reduced-motion: reduce) {
      * { animation:none !important; transition:none !important; }
    }
    """

    // MARK: - Analytics panel

    private static func analyticsPanel(
        projects: [Project],
        board: Board,
        health: AnalyticsEngine.HealthReport,
        heat: AnalyticsEngine.HeatMapReport,
        trends: AnalyticsEngine.TechTrendsReport,
        timeline: AnalyticsEngine.TimelineReport,
        now: Date
    ) -> String {
        statsStrip(projects: projects, board: board, health: health, heat: heat, now: now)
            + "<div class=\"dash-split\">"
            + attentionSection(projects: projects, board: board, now: now)
            + kindMix(projects: projects, now: now)
            + "</div>"
            + boardFlow(board: board, now: now)
            + healthSection(health)
            + heatSection(heat)
            + techSection(trends)
            + timelineSection(timeline)
    }

    private static func statsStrip(
        projects: [Project],
        board: Board,
        health: AnalyticsEngine.HealthReport,
        heat: AnalyticsEngine.HeatMapReport,
        now: Date
    ) -> String {
        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        let throughput = board.cards.filter { $0.column.lowercased() == "done" && $0.updated >= weekAgo }.count
        return """
        <div class="stats">
        <div class="stat"><b>\(projects.count)</b><span>Projects on the desk</span></div>
        <div class="stat"><b>\(heat.totalEvents)</b><span>Events in 14 days</span></div>
        <div class="stat"><b>\(health.rows.isEmpty ? "—" : "\(health.meanScore)")</b><span>Mean health</span></div>
        <div class="stat"><b>\(throughput)</b><span>Done in 7 days</span></div>
        </div>
        """
    }

    private static func attentionSection(projects: [Project], board: Board, now: Date) -> String {
        let items = attentionItems(projects: projects, board: board, now: now)
        let rows = items.enumerated().map { index, item in
            let pulse = index == 0 ? "<i class=\"pulse\" aria-hidden=\"true\"></i>" : ""
            return "<li>\(pulse)<span class=\"rank\">\(index + 1)</span><span>\(HTMLEscape.escape(item))</span></li>"
        }.joined()
        let body = rows.isEmpty ? "<p class=\"empty\">Nothing on the desk yet.</p>" : "<ol class=\"attn\">\(rows)</ol>"
        return "<section class=\"card\"><h2>Attention</h2>\(body)</section>"
    }

    private static func boardFlow(board: Board, now: Date) -> String {
        var columnCounts: [(String, Int)] = board.columns.map { col in
            (col, board.cards.filter { $0.column == col }.count)
        }
        if columnCounts.isEmpty {
            columnCounts = DeskColumns.defaults.map { ($0, 0) }
        }
        let totalCards = max(board.cards.count, 1)
        let bar = columnCounts.enumerated().compactMap { index, item -> String? in
            guard item.1 > 0 else { return nil }
            let pct = Int((Double(item.1) / Double(totalCards)) * 100)
            return "<i class=\"c\(index % 5)\" style=\"width:\(pct)%\" title=\"\(HTMLEscape.escape(item.0)): \(item.1)\"></i>"
        }.joined()
        let flowLegend = columnCounts.enumerated().map { index, item in
            "<span class=\"chip\"><i class=\"swatch c\(index % 5)\"></i>\(HTMLEscape.escape(item.0)) · \(item.1)</span>"
        }.joined()
        let staleLimit: TimeInterval = 14 * 86_400
        let staleCards = board.cards.filter { now.timeIntervalSince($0.updated) > staleLimit }
        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        let throughput = board.cards.filter { $0.column.lowercased() == "done" && $0.updated >= weekAgo }.count
        let parked = board.cards.filter { $0.column.lowercased() == "parked" }.count
        let colRows = columnCounts.map {
            "<tr><td>\(HTMLEscape.escape($0.0))</td><td>\($0.1)</td></tr>"
        }.joined()
        let staleTable: String
        if staleCards.isEmpty {
            staleTable = ""
        } else {
            let staleRows = staleCards.prefix(12).map {
                "<tr><td>\(HTMLEscape.escape($0.id))</td><td>\(HTMLEscape.escape($0.title))</td><td>\(HTMLEscape.escape($0.project))</td></tr>"
            }.joined()
            staleTable = "<table><thead><tr><th>Stale id</th><th>Title</th><th>Project</th></tr></thead><tbody>\(staleRows)</tbody></table>"
        }
        return """
        <section class="card">
        <h2>Board flow</h2>
        <div class="flow">\(bar)</div>
        <div class="chips">\(flowLegend)</div>
        <table><thead><tr><th>Column</th><th>Cards</th></tr></thead><tbody>\(colRows)</tbody></table>
        <p>Stale cards (no move in 14 days): \(staleCards.count). Throughput into done (7 days): \(throughput). Parked: \(parked).</p>
        \(staleTable)
        </section>
        """
    }

    private static func kindMix(projects: [Project], now: Date) -> String {
        var kindCounts: [String: Int] = [:]
        for project in projects {
            kindCounts[project.kind.rawValue, default: 0] += 1
        }
        let orderedKinds = kindCounts.keys.sorted()
        let total = max(projects.count, 1)
        let bar = orderedKinds.enumerated().map { index, kind in
            let n = kindCounts[kind] ?? 0
            let pct = Int((Double(n) / Double(total)) * 100)
            return "<i class=\"c\(index % 5)\" style=\"width:\(pct)%\" title=\"\(HTMLEscape.escape(kind)): \(n)\"></i>"
        }.joined()
        let chips = orderedKinds.enumerated().map { index, kind in
            let n = kindCounts[kind] ?? 0
            return "<span class=\"chip\"><i class=\"swatch c\(index % 5)\"></i>\(HTMLEscape.escape(kind)) · \(n)</span>"
        }.joined()
        let freshness = projects.map { Int(now.timeIntervalSince($0.lastModified) / 86_400) }
        let oldest = freshness.max().map { "\($0)d" } ?? "n/a"
        return """
        <section class="card">
        <h2>Kind mix</h2>
        <div class="flow">\(bar)</div>
        <div class="chips">\(chips)</div>
        <p>Oldest project write: \(HTMLEscape.escape(oldest)). Events stay on disk in analytics JSON.</p>
        </section>
        """
    }

    private static func healthSection(_ report: AnalyticsEngine.HealthReport) -> String {
        if report.rows.isEmpty {
            return "<section class=\"card\"><h2>Project health</h2><p class=\"empty\">No projects to score.</p></section>"
        }
        func group(_ title: String, _ rows: [AnalyticsEngine.HealthRow], _ band: String) -> String {
            guard !rows.isEmpty else { return "" }
            let cards = rows.map { row in gaugeCard(row, band: band) }.joined()
            return "<h3>\(HTMLEscape.escape(title))</h3><div class=\"health-row\">\(cards)</div>"
        }
        return """
        <section class="card">
        <h2>Project health</h2>
        <div class="health-groups">
        \(group(AnalyticsEngine.HealthBand.critical.heading, report.critical, "critical"))
        \(group(AnalyticsEngine.HealthBand.attention.heading, report.attention, "attention"))
        \(group(AnalyticsEngine.HealthBand.healthy.heading, report.healthy, "healthy"))
        </div>
        </section>
        """
    }

    private static func gaugeCard(_ row: AnalyticsEngine.HealthRow, band: String) -> String {
        let recs = row.recommendations.isEmpty
            ? ""
            : "<small>\(HTMLEscape.escape(row.recommendations.joined(separator: " · ")))</small>"
        let factors = row.factors.map {
            let title = HTMLEscape.escape("\($0.label) \($0.score)/100 — \($0.detail)")
            return "<span class=\"fpill\" title=\"\(title)\">\(HTMLEscape.escape(factorShort($0.label))) \($0.score)</span>"
        }.joined()
        return """
        <article class="hcard \(band)">
        \(gauge(score: row.score, band: band))
        <div class="hmeta">
        <strong>\(HTMLEscape.escape(row.name))</strong>
        <small>\(HTMLEscape.escape(row.kind.rawValue))</small>
        <div class="fpills">\(factors)</div>
        \(recs)
        </div>
        </article>
        """
    }

    private static func gauge(score: Int, band: String) -> String {
        let clamped = min(100, max(0, score))
        let offset = 100 - clamped
        return """
        <svg class="gauge \(band)" viewBox="0 0 36 36" role="img" aria-label="Health \(clamped)">
          <circle class="g-bg" cx="18" cy="18" r="15.9155" fill="none" stroke="#d8d0c2" stroke-width="2.8"></circle>
          <circle class="g-fg" cx="18" cy="18" r="15.9155" fill="none" stroke="\(gaugeStroke(band))" stroke-width="2.8" stroke-linecap="round" stroke-dasharray="100" stroke-dashoffset="\(offset)" transform="rotate(-90 18 18)"></circle>
          <text x="18" y="21.5" text-anchor="middle" font-size="9" font-weight="700" fill="#1c1914">\(clamped)</text>
        </svg>
        """
    }

    private static func heatSection(_ report: AnalyticsEngine.HeatMapReport) -> String {
        let spark = sparkline(report.dailyTotals)
        let labels = report.dailyTotals.map { cell in
            return "<span title=\"\(HTMLEscape.escape(shortDay(cell.day)))\">\(dayNumber(cell.day))</span>"
        }.joined()
        let head = report.dailyTotals.enumerated().map { index, cell in
            "<span class=\"heat-cell lv-\(cell.level)\" style=\"--i:\(index)\" title=\"\(HTMLEscape.escape(shortDay(cell.day))): \(eventLabel(cell.count))\"></span>"
        }.joined()
        let rows = report.rows.map { row in
            let cells = row.cells.enumerated().map { index, cell in
                "<span class=\"heat-cell lv-\(cell.level)\" style=\"--i:\(index)\" title=\"\(HTMLEscape.escape(row.name)) · \(HTMLEscape.escape(shortDay(cell.day))): \(eventLabel(cell.count))\"></span>"
            }.joined()
            return """
            <div class="heat-row">
            <span class="heat-name">\(HTMLEscape.escape(row.name))</span>
            <span class="heat-cells">\(cells)</span>
            <span class="heat-total">\(row.eventCount)</span>
            </div>
            """
        }.joined()
        let empty = report.rows.isEmpty ? "<p class=\"empty\">No activity window to plot.</p>" : ""
        return """
        <section class="card">
        <h2>Activity heat map</h2>
        <p class="note">Last \(report.days) days. \(report.totalEvents) events across the desk.</p>
        \(spark)
        <div class="heat-wrap"><div class="heat">
        <div class="heat-head"><span class="heat-name"></span><span class="heat-cells heat-labels">\(labels)</span><span class="heat-total"></span></div>
        <div class="heat-head"><span class="heat-name">Desk</span><span class="heat-cells">\(head)</span><span class="heat-total">\(report.totalEvents)</span></div>
        \(rows)
        </div></div>
        \(empty)
        <p class="legend">Less <i class="lv-0"></i><i class="lv-1"></i><i class="lv-2"></i><i class="lv-3"></i><i class="lv-4"></i> more</p>
        </section>
        """
    }

    private static func sparkline(_ cells: [AnalyticsEngine.HeatCell]) -> String {
        guard !cells.isEmpty else { return "" }
        let maxCount = max(cells.map(\.count).max() ?? 1, 1)
        let width = 280.0
        let height = 48.0
        let step = cells.count > 1 ? width / Double(cells.count - 1) : width
        var points: [String] = []
        for (index, cell) in cells.enumerated() {
            let x = Double(index) * step
            let y = height - (Double(cell.count) / Double(maxCount) * (height - 4) + 2)
            points.append("\(round(x * 10) / 10),\(round(y * 10) / 10)")
        }
        let line = points.joined(separator: " ")
        let area = "0,\(height) \(line) \(width),\(height)"
        return """
        <svg class="spark" viewBox="0 0 \(Int(width)) \(Int(height))" preserveAspectRatio="none" role="img" aria-label="Fourteen day activity sparkline">
          <polygon points="\(area)"></polygon>
          <polyline points="\(line)" vector-effect="non-scaling-stroke"></polyline>
        </svg>
        """
    }

    private static func techSection(_ report: AnalyticsEngine.TechTrendsReport) -> String {
        if report.codingProjectCount == 0 {
            return """
            <section class="card">
            <h2>Technology trends</h2>
            <p class="empty">No coding projects on the desk. Technology trends cover coding projects only.</p>
            </section>
            """
        }
        if report.frameworks.isEmpty {
            return """
            <section class="card">
            <h2>Technology trends</h2>
            <p class="empty">No language or framework tags on coding projects yet.</p>
            </section>
            """
        }
        let bars = report.frameworks.map { item in
            """
            <div class="share-row">
            <span>\(HTMLEscape.escape(item.name))</span>
            <div class="share-bar"><span style="width:\(item.sharePercent)%"></span></div>
            <span>\(item.count)/\(report.codingProjectCount) · \(item.sharePercent)%</span>
            </div>
            """
        }.joined()
        let emerging: String
        if report.emerging.isEmpty {
            emerging = "<p class=\"note\">No emerging tags (used in 1–2 coding projects).</p>"
        } else {
            let chips = report.emerging.map {
                "<span class=\"chip\">\(HTMLEscape.escape($0.name)) · \(HTMLEscape.escape($0.projects.joined(separator: ", ")))</span>"
            }.joined()
            emerging = "<h3>Emerging</h3><div class=\"chips\">\(chips)</div>"
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        let adoption = report.adoption.map { item in
            let when = item.lastUsed.map { formatter.string(from: $0) } ?? "unknown"
            return "<tr><td>\(HTMLEscape.escape(item.name))</td><td>\(HTMLEscape.escape(when))</td></tr>"
        }.joined()
        return """
        <section class="card">
        <h2>Technology trends</h2>
        <p class="note">Coding projects only (\(report.codingProjectCount)).</p>
        <div class="share">\(bars)</div>
        \(emerging)
        <h3>Adoption timeline</h3>
        <table><thead><tr><th>Tag</th><th>Last used</th></tr></thead><tbody>\(adoption)</tbody></table>
        </section>
        """
    }

    private static func timelineSection(_ report: AnalyticsEngine.TimelineReport) -> String {
        if report.rows.isEmpty {
            return "<section class=\"card\"><h2>Project timeline</h2><p class=\"empty\">No projects to plot.</p></section>"
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        let blocks = report.rows.map { row -> String in
            let total = max(row.spans.reduce(0) { $0 + $1.seconds }, 1)
            let bar = row.spans.map { span in
                let pct = max(Int((span.seconds / total) * 100), 2)
                return "<i style=\"width:\(pct)%\" title=\"\(HTMLEscape.escape(span.status)): \(HTMLEscape.escape(span.durationText))\"></i>"
            }.joined()
            let history = row.spans.map {
                "<tr><td>\(HTMLEscape.escape($0.status))</td><td>\(HTMLEscape.escape($0.durationText))</td></tr>"
            }.joined()
            return """
            <details class="timeline">
            <summary><strong>\(HTMLEscape.escape(row.name))</strong><span>\(HTMLEscape.escape(row.currentStatus)) · \(HTMLEscape.escape(row.ageText))</span></summary>
            <p class="note">Created \(HTMLEscape.escape(formatter.string(from: row.created)))</p>
            <div class="span-bar">\(bar)</div>
            <table><thead><tr><th>Status</th><th>Time in status</th></tr></thead><tbody>\(history)</tbody></table>
            </details>
            """
        }.joined()
        return """
        <section class="card">
        <h2>Project timeline</h2>
        <p class="note">Created date, current status, and time in each status. Open a row for the filmstrip.</p>
        \(blocks)
        </section>
        """
    }

    private static func kanbanBoard(projects: [Project], board: Board, mode: DeskPageMode, now: Date) -> String {
        let hint: String
        switch mode {
        case .file:
            hint = "<p class=\"note\">Read-only file. Ask the agent to move a card, or start the optional localhost desk server for drag-and-drop.</p>"
        case .live:
            hint = "<p class=\"note\">Drag a card, or focus it and use arrow keys then Enter. Writes stay on this machine.</p>"
        }
        let kindByProject = Dictionary(uniqueKeysWithValues: projects.map { ($0.name, $0.kind) })
        var columnsHTML = ""
        for (index, column) in board.columns.enumerated() {
            let cards = board.cards.filter { $0.column == column }.sorted { $0.order < $1.order }
            let cardsHTML: String
            if cards.isEmpty {
                cardsHTML = "<p class=\"empty\">No cards in this column.</p>"
            } else {
                cardsHTML = cards.map { card in
                    kanbanCard(card, kind: kindByProject[card.project] ?? .other, mode: mode, now: now)
                }.joined()
            }
            let drop = mode == .live ? " data-column=\"\(HTMLEscape.escape(column))\"" : ""
            columnsHTML += """
            <section class="col" data-accent="\(index % 5)"\(drop)>
            <h3>\(HTMLEscape.escape(column)) <span class="count-pill">\(cards.count)</span></h3>
            \(cardsHTML)
            </section>
            """
        }
        let names = projects.map { HTMLEscape.escape($0.name) }.joined(separator: ", ")
        return "\(hint)<div class=\"board\">\(columnsHTML)</div><p class=\"note\">Projects: \(names)</p>"
    }

    private static func kanbanCard(_ card: Card, kind: ProjectKind, mode: DeskPageMode, now: Date) -> String {
        let title = HTMLEscape.escape(card.title)
        let id = HTMLEscape.escape(card.id)
        let project = HTMLEscape.escape(card.project)
        let liveAttrs = mode == .live
            ? " draggable=\"true\" tabindex=\"0\" data-id=\"\(id)\""
            : " data-id=\"\(id)\""
        var chips = "<span class=\"kchip kind-\(kind.rawValue)\">\(project)</span>"
        if let linked = card.linkedPR, !linked.isEmpty {
            chips += prChip(linked)
        }
        if let ref = card.memoryRef, !ref.isEmpty {
            chips += "<span class=\"kchip kref\">\(HTMLEscape.escape(ref))</span>"
        }
        chips += "<span class=\"ktime\">\(HTMLEscape.escape(relativeUpdated(card.updated, now: now)))</span>"
        return "<article class=\"kcard\" title=\"\(id)\"\(liveAttrs)><strong>\(title)</strong><div class=\"kmeta\">\(chips)</div></article>"
    }

    private static func prChip(_ linkedPR: String) -> String {
        let trimmed = linkedPR.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        let label = last.allSatisfy(\.isNumber) ? "PR \(last)" : (trimmed.lowercased().hasPrefix("pr") ? trimmed : "PR \(trimmed)")
        let escapedLabel = HTMLEscape.escape(label)
        if let url = URL(string: trimmed), url.scheme?.lowercased() == "https" {
            return "<a class=\"kchip kpr\" href=\"\(HTMLEscape.escape(trimmed))\" rel=\"noopener noreferrer\" target=\"_blank\">\(escapedLabel)</a>"
        }
        return "<span class=\"kchip kpr\">\(escapedLabel)</span>"
    }

    private static func relativeUpdated(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 45 { return "just now" }
        if seconds < 90 { return "1 min ago" }
        if seconds < 3600 {
            return "\(Int(seconds / 60)) min ago"
        }
        if seconds < 5400 { return "1 hour ago" }
        if seconds < 86_400 {
            return "\(Int(seconds / 3600)) hours ago"
        }
        return AnalyticsEngine.daysAgoPhrase(Int(seconds / 86_400))
    }

    private static func attentionItems(projects: [Project], board: Board, now: Date) -> [String] {
        var scored: [(Int, String)] = []
        for project in projects {
            let cards = board.cards.filter { $0.project == project.name }
            let parked = cards.contains { $0.column.lowercased() == "parked" }
            let days = Int(now.timeIntervalSince(project.lastModified) / 86_400)
            var score = days
            if parked { score += 50 }
            if cards.contains(where: { now.timeIntervalSince($0.updated) > 14 * 86_400 }) { score += 20 }
            scored.append((score, "\(project.name) (\(project.kind.rawValue), \(days)d)"))
        }
        return scored.sorted { $0.0 > $1.0 }.prefix(5).map(\.1)
    }

    private static func eventLabel(_ count: Int) -> String {
        count == 1 ? "1 event" : "\(count) events"
    }

    private static func dayNumber(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter.string(from: date)
    }

    private static func gaugeStroke(_ band: String) -> String {
        switch band {
        case "critical": return "#9a3b2f"
        case "attention": return "#b5812a"
        default: return "#2f5d50"
        }
    }

    private static func factorShort(_ label: String) -> String {
        switch label {
        case "Activity Level": return "Activity"
        case "Progress Momentum": return "Momentum"
        case "Documentation Quality": return "Docs"
        case "Task Completion": return "Tasks"
        default: return label
        }
    }

    private static func shortDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM"
        return formatter.string(from: date)
    }

    private static func tabScript() -> String {
        """
        const tabs=[...document.querySelectorAll('nav button')];
        const panels=[...document.querySelectorAll('.panel')];
        tabs.forEach(tab=>tab.addEventListener('click',()=>{
          tabs.forEach(t=>t.setAttribute('aria-selected', String(t===tab)));
          panels.forEach(p=>p.classList.toggle('active', p.id==='panel-'+tab.id.replace('tab-','')));
        }));
        """
    }

    private static func liveScript() -> String {
        tabScript() + """
        const reduce=window.matchMedia('(prefers-reduced-motion: reduce)').matches;
        const toastEl=document.createElement('div');
        toastEl.className='toast';
        toastEl.setAttribute('role','status');
        document.body.appendChild(toastEl);
        function toast(msg){
          toastEl.textContent=msg;
          toastEl.classList.add('show');
          clearTimeout(toastEl._t);
          toastEl._t=setTimeout(()=>toastEl.classList.remove('show'), 2200);
        }
        function columnOf(card){ return card.closest('.col'); }
        function updateCounts(){
          document.querySelectorAll('.col[data-column]').forEach(col=>{
            const n=col.querySelectorAll('.kcard').length;
            const pill=col.querySelector('.count-pill');
            if(pill) pill.textContent=String(n);
            let empty=col.querySelector('.empty');
            if(n===0 && !empty){
              empty=document.createElement('p');
              empty.className='empty';
              empty.textContent='No cards in this column.';
              col.appendChild(empty);
            }
            if(n>0 && empty) empty.remove();
          });
        }
        async function moveCard(card, column){
          if(card.getAttribute('aria-busy')==='true') return;
          const id=card.dataset.id;
          const from=columnOf(card);
          const next=card.nextElementSibling;
          const dest=document.querySelector('.col[data-column="'+CSS.escape(column)+'"]');
          if(!dest || !from) return;
          card.setAttribute('aria-busy','true');
          dest.querySelectorAll('.kcard-ph').forEach(p=>p.remove());
          dest.appendChild(card);
          updateCounts();
          try{
            const res=await fetch('/api/cards/move',{method:'POST', credentials:'same-origin', headers:{'Content-Type':'application/json'}, body:JSON.stringify({id, column})});
            if(!res.ok) throw new Error(await res.text());
          }catch(err){
            if(next && next.parentNode===from) from.insertBefore(card, next);
            else from.appendChild(card);
            updateCounts();
            toast('Move failed. Card returned.');
          }finally{
            card.removeAttribute('aria-busy');
          }
        }
        let dragCard=null;
        document.querySelectorAll('.kcard[draggable]').forEach(card=>{
          card.addEventListener('dragstart',e=>{
            if(card.getAttribute('aria-busy')==='true'){ e.preventDefault(); return; }
            dragCard=card;
            e.dataTransfer.setData('text/plain', card.dataset.id);
            e.dataTransfer.effectAllowed='move';
            if(!reduce) card.classList.add('lifting');
          });
          card.addEventListener('dragend',()=>{
            card.classList.remove('lifting');
            document.querySelectorAll('.kcard-ph').forEach(p=>p.remove());
            dragCard=null;
          });
          card.addEventListener('keydown',e=>{
            if(card.getAttribute('aria-busy')==='true'){ e.preventDefault(); return; }
            const cols=[...document.querySelectorAll('.col[data-column]')];
            const col=columnOf(card);
            const ci=cols.indexOf(col);
            const list=[...col.querySelectorAll('.kcard')];
            const ri=list.indexOf(card);
            if(e.key==='ArrowDown'){ e.preventDefault(); (list[ri+1]||list[0]).focus(); }
            if(e.key==='ArrowUp'){ e.preventDefault(); (list[ri-1]||list[list.length-1]).focus(); }
            if(e.key==='ArrowLeft' || e.key==='ArrowRight'){
              e.preventDefault();
              const dest=cols[ci+(e.key==='ArrowRight'?1:-1)];
              if(!dest) return;
              card.dataset.pending=dest.dataset.column;
              cols.forEach(c=>c.classList.toggle('drop-target', c===dest));
              toast('Enter to move to '+dest.dataset.column);
            }
            if(e.key==='Enter' && card.dataset.pending){
              e.preventDefault();
              const destCol=card.dataset.pending;
              delete card.dataset.pending;
              cols.forEach(c=>c.classList.remove('drop-target'));
              moveCard(card, destCol);
            }
            if(e.key==='Escape'){
              delete card.dataset.pending;
              cols.forEach(c=>c.classList.remove('drop-target'));
            }
          });
        });
        document.querySelectorAll('.col[data-column]').forEach(col=>{
          col.addEventListener('dragover',e=>{
            e.preventDefault();
            if(!dragCard) return;
            let ph=col.querySelector('.kcard-ph');
            if(!ph){ ph=document.createElement('div'); ph.className='kcard-ph'; ph.setAttribute('aria-hidden','true'); }
            col.appendChild(ph);
          });
          col.addEventListener('dragleave',e=>{
            if(!col.contains(e.relatedTarget)){
              const ph=col.querySelector('.kcard-ph');
              if(ph) ph.remove();
            }
          });
          col.addEventListener('drop',e=>{
            e.preventDefault();
            const id=e.dataTransfer.getData('text/plain');
            const card=document.querySelector('.kcard[data-id="'+CSS.escape(id)+'"]');
            if(card) moveCard(card, col.dataset.column);
          });
        });
        """
    }
}
