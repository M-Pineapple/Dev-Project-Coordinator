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
        now: Date = Date(),
        mode: DeskPageMode = .file
    ) -> String {
        let analytics = analyticsTables(projects: projects, board: board, now: now)
        let kanban = kanbanBoard(projects: projects, board: board, mode: mode)
        let script = mode == .live ? liveScript() : tabScript()
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Dev Project Coordinator desk</title>
        <style>
        :root { color-scheme: light dark; --bg:#f6f4ef; --ink:#1b1b1b; --muted:#5c5c5c; --line:#d9d4c8; --card:#fff; --accent:#2f5d50; }
        @media (prefers-color-scheme: dark) {
          :root { --bg:#161513; --ink:#f3efe6; --muted:#b4aea2; --line:#3a372f; --card:#221f1b; --accent:#8fbfb0; }
        }
        body { margin:0; font:15px/1.45 ui-sans-serif, system-ui, sans-serif; background:var(--bg); color:var(--ink); }
        header { padding:1.25rem 1.5rem 0.5rem; }
        h1 { font-size:1.35rem; font-weight:650; margin:0 0 0.35rem; }
        .sub { color:var(--muted); margin:0 0 1rem; }
        nav { display:flex; gap:0.5rem; padding:0 1.5rem; border-bottom:1px solid var(--line); }
        nav button { background:none; border:0; border-bottom:2px solid transparent; padding:0.6rem 0.4rem; color:var(--muted); cursor:pointer; }
        nav button[aria-selected="true"] { color:var(--ink); border-bottom-color:var(--accent); }
        main { padding:1rem 1.5rem 2rem; }
        .panel { display:none; }
        .panel.active { display:block; }
        table { border-collapse:collapse; width:100%; margin:0.75rem 0 1.25rem; background:var(--card); }
        th, td { text-align:left; padding:0.45rem 0.6rem; border-bottom:1px solid var(--line); vertical-align:top; }
        th { font-size:0.8rem; letter-spacing:0.02em; color:var(--muted); font-weight:600; }
        .board { display:flex; gap:0.75rem; overflow-x:auto; align-items:flex-start; }
        .col { min-width:16rem; background:var(--card); border:1px solid var(--line); border-radius:8px; padding:0.6rem; }
        .col h3 { margin:0 0 0.5rem; font-size:0.95rem; }
        .card { border:1px solid var(--line); border-radius:6px; padding:0.5rem; margin:0 0 0.5rem; background:var(--bg); }
        .card small { color:var(--muted); display:block; }
        .bar { display:flex; height:0.7rem; border-radius:99px; overflow:hidden; background:var(--line); margin:0.5rem 0 1rem; }
        .bar span { display:block; height:100%; background:var(--accent); }
        .note { color:var(--muted); font-size:0.9rem; }
        </style>
        </head>
        <body>
        <header>
        <h1>Dev Project Coordinator</h1>
        <p class="sub">Local desk. Data stays on this machine.</p>
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
        now: Date = Date()
    ) throws -> URL {
        let desk = URL(fileURLWithPath: knowledgeBasePath).appendingPathComponent("desk", isDirectory: true)
        try FileManager.default.createDirectory(at: desk, withIntermediateDirectories: true)
        let html = render(projects: projects, board: board, now: now, mode: .file)
        let url = desk.appendingPathComponent("index.html")
        guard let data = html.data(using: .utf8) else {
            throw CoordinatorError.fileSystemError("Could not encode desk HTML")
        }
        try AtomicFile.replace(destination: url, data: data)
        return url
    }

    private static func analyticsTables(projects: [Project], board: Board, now: Date) -> String {
        var columnCounts: [(String, Int)] = board.columns.map { col in
            (col, board.cards.filter { $0.column == col }.count)
        }
        if columnCounts.isEmpty {
            columnCounts = DeskColumns.defaults.map { ($0, 0) }
        }
        let totalCards = max(board.cards.count, 1)
        let bar = columnCounts.map { _, count in
            let pct = Int((Double(count) / Double(totalCards)) * 100)
            return "<span style=\"width:\(pct)%\"></span>"
        }.joined()

        let staleLimit: TimeInterval = 14 * 86_400
        let staleCards = board.cards.filter { now.timeIntervalSince($0.updated) > staleLimit }
        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        let throughput = board.cards.filter { $0.column.lowercased() == "done" && $0.updated >= weekAgo }.count
        let parked = board.cards.filter { $0.column.lowercased() == "parked" }.count

        var kindCounts: [String: Int] = [:]
        for project in projects {
            kindCounts[project.kind.rawValue, default: 0] += 1
        }

        let attention = attentionItems(projects: projects, board: board, now: now)

        func rows(_ items: [(String, String)]) -> String {
            items.map { "<tr><td>\(HTMLEscape.escape($0.0))</td><td>\(HTMLEscape.escape($0.1))</td></tr>" }
                .joined()
        }

        let colRows = rows(columnCounts.map { ($0.0, String($0.1)) })
        let kindRows = rows(kindCounts.keys.sorted().map { ($0, String(kindCounts[$0] ?? 0)) })
        let staleRows = staleCards.prefix(12).map {
            "<tr><td>\(HTMLEscape.escape($0.id))</td><td>\(HTMLEscape.escape($0.title))</td><td>\(HTMLEscape.escape($0.project))</td></tr>"
        }.joined()
        let attentionRows = attention.map {
            "<tr><td>\(HTMLEscape.escape($0))</td></tr>"
        }.joined()

        let freshness = projects.map { now.timeIntervalSince($0.lastModified) / 86_400 }
        let oldest = freshness.max().map { "\(Int($0))d" } ?? "n/a"

        return """
        <h2>Attention</h2>
        <table><thead><tr><th>Look at today</th></tr></thead><tbody>\(attentionRows)</tbody></table>
        <h2>Board flow</h2>
        <div class="bar">\(bar)</div>
        <table><thead><tr><th>Column</th><th>Cards</th></tr></thead><tbody>\(colRows)</tbody></table>
        <p>Stale cards (no move in 14 days): \(staleCards.count). Throughput into done (7 days): \(throughput). Parked: \(parked).</p>
        <table><thead><tr><th>Stale id</th><th>Title</th><th>Project</th></tr></thead><tbody>\(staleRows)</tbody></table>
        <h2>Kind mix</h2>
        <table><thead><tr><th>Kind</th><th>Projects</th></tr></thead><tbody>\(kindRows)</tbody></table>
        <p>Oldest project write: \(HTMLEscape.escape(oldest)). Events stay on disk in analytics JSON.</p>
        """
    }

    private static func kanbanBoard(projects: [Project], board: Board, mode: DeskPageMode) -> String {
        let hint: String
        switch mode {
        case .file:
            hint = "<p class=\"note\">Read-only file. Ask the agent to move a card, or start the optional localhost desk server for drag-and-drop.</p>"
        case .live:
            hint = "<p class=\"note\">Drag a card onto another column. Writes stay on this machine.</p>"
        }
        var columnsHTML = ""
        for column in board.columns {
            let cards = board.cards.filter { $0.column == column }.sorted { $0.order < $1.order }
            let cardsHTML = cards.map { card in
                let title = HTMLEscape.escape(card.title)
                let project = HTMLEscape.escape(card.project)
                let id = HTMLEscape.escape(card.id)
                let ref = card.memoryRef.map { "<small>memoryRef \(HTMLEscape.escape($0))</small>" } ?? ""
                let draggable = mode == .live ? " draggable=\"true\" data-id=\"\(id)\"" : ""
                return "<article class=\"card\"\(draggable)><strong>\(title)</strong><small>\(project) · \(id)</small>\(ref)</article>"
            }.joined()
            let drop = mode == .live ? " data-column=\"\(HTMLEscape.escape(column))\"" : ""
            columnsHTML += "<section class=\"col\"\(drop)><h3>\(HTMLEscape.escape(column))</h3>\(cardsHTML)</section>"
        }
        let names = projects.map { HTMLEscape.escape($0.name) }.joined(separator: ", ")
        return "\(hint)<div class=\"board\">\(columnsHTML)</div><p class=\"note\">Projects: \(names)</p>"
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
        document.querySelectorAll('.card[draggable]').forEach(card=>{
          card.addEventListener('dragstart',e=>{ e.dataTransfer.setData('text/plain', card.dataset.id); });
        });
        document.querySelectorAll('.col[data-column]').forEach(col=>{
          col.addEventListener('dragover',e=>e.preventDefault());
          col.addEventListener('drop',async e=>{
            e.preventDefault();
            const id=e.dataTransfer.getData('text/plain');
            const body=JSON.stringify({id, column: col.dataset.column});
            const res=await fetch('/api/cards/move',{method:'POST', credentials:'same-origin', headers:{'Content-Type':'application/json'}, body});
            if(res.ok) location.reload();
          });
        });
        """
    }
}
