import Foundation

/// Compact desk text. Hard cap 800 tokens (~3,200 characters).
public enum DeskSummary {
    public static let maxCharacters = 3_200
    public static let tokenBudget = 800

    public static func render(projects: [Project], board: Board, now: Date = Date()) -> String {
        let staleIDs = staleProjects(projects: projects, board: board, now: now)
        let blocked = board.cards.filter { $0.column.lowercased() == "parked" }.count
        let done = board.cards.filter { $0.column.lowercased() == "done" }.count

        var columnCounts: [String: Int] = [:]
        for column in board.columns { columnCounts[column] = 0 }
        for card in board.cards {
            columnCounts[card.column, default: 0] += 1
        }
        let colLine = board.columns.map { "\($0)=\(columnCounts[$0] ?? 0)" }.joined(separator: " ")

        var lines: [String] = []
        lines.append(
            "DPC desk  projects=\(projects.count)  stale=\(staleIDs.count)  blocked=\(blocked)  done=\(done)"
        )
        lines.append("cols: \(colLine)")
        lines.append("id   col     kind     tags     age  next")

        let sorted = projects.sorted { $0.name < $1.name }
        var body: [String] = []
        for (index, project) in sorted.enumerated() {
            let shortID = String(format: "p%02d", index + 1)
            let cards = board.cards.filter { $0.project == project.name }
            let col = cards.first.map(\.column) ?? DeskColumns.fromStatus(project.status)
            let tags = project.techStack.prefix(2).joined(separator: ",")
            let age = ageLabel(since: project.lastModified, now: now)
            let next = cards.first(where: { $0.column != "done" && $0.column != "parked" })?.title
                ?? cards.first?.title
                ?? "-"
            let nextShort = String(next.prefix(24))
            body.append(
                "\(shortID)  \(pad(col, 7))  \(pad(project.kind.rawValue, 8))  \(pad(tags, 8))  \(pad(age, 4))  \(nextShort)"
            )
        }

        let staleLine = staleIDs.isEmpty ? "stale: none" : "stale: \(staleIDs.joined(separator: " "))"
        let footer = staleLine

        var used = lines.joined(separator: "\n").count + 1 + footer.count + 1
        var included: [String] = []
        var truncated = 0
        for row in body {
            if used + row.count + 1 > maxCharacters {
                truncated = body.count - included.count
                break
            }
            included.append(row)
            used += row.count + 1
        }

        var output = (lines + included).joined(separator: "\n")
        if truncated > 0 {
            output += "\ntruncated \(truncated)"
        }
        output += "\n\(footer)"

        if output.count > maxCharacters {
            output = String(output.prefix(maxCharacters - 12)) + "\ntruncated"
        }
        return output
    }

    public static func estimatedTokens(_ text: String) -> Int {
        text.count / 4
    }

    private static func staleProjects(projects: [Project], board: Board, now: Date) -> [String] {
        let limit: TimeInterval = 14 * 86_400
        var ids: [String] = []
        let sorted = projects.sorted { $0.name < $1.name }
        for (index, project) in sorted.enumerated() {
            let cards = board.cards.filter { $0.project == project.name }
            let last = ([project.lastModified] + cards.map(\.updated)).max() ?? project.lastModified
            if now.timeIntervalSince(last) > limit {
                ids.append(String(format: "p%02d", index + 1))
            }
        }
        return ids
    }

    private static func ageLabel(since: Date, now: Date) -> String {
        let days = Int(now.timeIntervalSince(since) / 86_400)
        if days <= 0 { return "0d" }
        if days < 99 { return "\(days)d" }
        return "99d"
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        if text.count >= width { return String(text.prefix(width)) }
        return text + String(repeating: " ", count: width - text.count)
    }
}
