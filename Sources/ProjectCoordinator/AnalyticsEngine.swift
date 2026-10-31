import Foundation

/// Structured analytics shared by MCP tool markdown and the desk HTML.
public enum AnalyticsEngine {
    public static let heatMapDefaultDays = 7
    public static let heatMapPageDays = 14

    // MARK: - Health

    public enum HealthBand: String, Sendable {
        case critical
        case attention
        case healthy

        public var heading: String {
            switch self {
            case .critical: return "Critical (Needs Immediate Attention)"
            case .attention: return "Needs Attention"
            case .healthy: return "Healthy Projects"
            }
        }

        public static func band(for score: Int) -> HealthBand {
            if score < 40 { return .critical }
            if score < 70 { return .attention }
            return .healthy
        }
    }

    public struct HealthFactor: Sendable {
        public let label: String
        public let score: Int
        public let detail: String
    }

    public struct HealthRow: Sendable {
        public let name: String
        public let kind: ProjectKind
        public let score: Int
        public let band: HealthBand
        public let factors: [HealthFactor]
        public let recommendations: [String]
    }

    public struct HealthReport: Sendable {
        public let rows: [HealthRow]

        public var critical: [HealthRow] { rows.filter { $0.band == .critical } }
        public var attention: [HealthRow] { rows.filter { $0.band == .attention } }
        public var healthy: [HealthRow] { rows.filter { $0.band == .healthy } }
        public var meanScore: Int {
            guard !rows.isEmpty else { return 0 }
            return rows.reduce(0) { $0 + $1.score } / rows.count
        }
    }

    public static func health(
        projects: [Project],
        records: [ProjectWithAnalytics],
        now: Date = Date()
    ) -> HealthReport {
        let byName = dictionary(records)
        let rows = projects.sorted { $0.name < $1.name }.map { project in
            score(project: project, record: record(for: project, in: byName), now: now)
        }
        return HealthReport(rows: rows.sorted { $0.score > $1.score })
    }

    // MARK: - Heat map

    public struct HeatCell: Sendable {
        public let day: Date
        public let count: Int
        public let level: Int
    }

    public struct HeatRow: Sendable {
        public let name: String
        public let score: Int
        public let eventCount: Int
        public let levelLabel: String
        public let cells: [HeatCell]
    }

    public struct HeatMapReport: Sendable {
        public let days: Int
        public let rows: [HeatRow]
        public let dailyTotals: [HeatCell]
        public let totalEvents: Int
    }

    public static func heatMap(
        projects: [Project],
        records: [ProjectWithAnalytics],
        days: Int = heatMapPageDays,
        now: Date = Date()
    ) -> HeatMapReport {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -(days - 1), to: now) ?? now)
        let dayList: [Date] = (0..<days).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: start)
        }
        let byName = dictionary(records)

        var rows: [HeatRow] = projects.sorted { $0.name < $1.name }.map { project in
            let record = record(for: project, in: byName)
            let recent = record.activityLog.filter { $0.timestamp >= start }
            var counts: [Date: Int] = [:]
            for event in recent {
                let day = calendar.startOfDay(for: event.timestamp)
                counts[day, default: 0] += 1
            }
            let cells = dayList.map { day in
                let count = counts[day] ?? 0
                return HeatCell(day: day, count: count, level: cellLevel(count))
            }
            let score = activityScore(events: recent)
            return HeatRow(
                name: project.name,
                score: score,
                eventCount: recent.count,
                levelLabel: heatLabel(score: score),
                cells: cells
            )
        }
        rows.sort { $0.score > $1.score }

        let dailyTotals = dayList.map { day in
            let count = rows.reduce(0) { $0 + ($1.cells.first { $0.day == day }?.count ?? 0) }
            return HeatCell(day: day, count: count, level: cellLevel(count))
        }
        let total = dailyTotals.reduce(0) { $0 + $1.count }
        return HeatMapReport(days: days, rows: rows, dailyTotals: dailyTotals, totalEvents: total)
    }

    public static func heatLabel(score: Int) -> String {
        switch score {
        case 0: return "quiet"
        case 1...5: return "warm"
        case 6...15: return "active"
        default: return "hot"
        }
    }

    // MARK: - Technology trends

    public struct TechFramework: Sendable {
        public let name: String
        public let count: Int
        public let sharePercent: Int
        public let projects: [String]
        public let lastUsed: Date?
    }

    public struct TechTrendsReport: Sendable {
        public let codingProjectCount: Int
        public let frameworks: [TechFramework]
        public let emerging: [TechFramework]
        public let adoption: [TechFramework]
    }

    public static func techTrends(
        projects: [Project],
        records: [ProjectWithAnalytics],
        now: Date = Date()
    ) -> TechTrendsReport {
        let coding = projects.filter { $0.kind == .coding }.sorted { $0.name < $1.name }
        let byName = dictionary(records)
        var using: [String: [String]] = [:]
        var lastUsed: [String: Date] = [:]

        for project in coding {
            let record = record(for: project, in: byName)
            let tags = record.techStack.isEmpty ? project.techStack : record.techStack
            for tech in tags {
                using[tech, default: []].append(project.name)
                let stamp = record.lastModified
                if lastUsed[tech] == nil || stamp > lastUsed[tech]! {
                    lastUsed[tech] = stamp
                }
            }
            _ = now
        }

        let total = coding.count
        let frameworks: [TechFramework] = using.keys.sorted().map { tech in
            let names = (using[tech] ?? []).sorted()
            let count = names.count
            let share = total > 0 ? (count * 100) / total : 0
            return TechFramework(
                name: tech,
                count: count,
                sharePercent: share,
                projects: names,
                lastUsed: lastUsed[tech]
            )
        }
        .sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.name < rhs.name
        }

        let emerging = frameworks.filter { $0.count >= 1 && $0.count <= 2 }
        let adoption = frameworks.sorted { lhs, rhs in
            (lhs.lastUsed ?? .distantPast) > (rhs.lastUsed ?? .distantPast)
        }.prefix(5).map { $0 }

        return TechTrendsReport(
            codingProjectCount: total,
            frameworks: frameworks,
            emerging: emerging,
            adoption: Array(adoption)
        )
    }

    // MARK: - Timeline

    public struct TimelineSpan: Sendable {
        public let status: String
        public let start: Date
        public let end: Date?
        public let durationText: String
        public let seconds: TimeInterval
    }

    public struct TimelineRow: Sendable {
        public let name: String
        public let created: Date
        public let currentStatus: String
        public let ageText: String
        public let spans: [TimelineSpan]
    }

    public struct TimelineReport: Sendable {
        public let rows: [TimelineRow]
    }

    public static func timeline(
        projects: [Project],
        records: [ProjectWithAnalytics],
        now: Date = Date()
    ) -> TimelineReport {
        let byName = dictionary(records)
        let rows = projects.sorted { $0.name < $1.name }.map { project in
            row(from: record(for: project, in: byName), fallbackStatus: project.status, now: now)
        }
        return TimelineReport(rows: rows)
    }

    public static func timelineRow(record: ProjectWithAnalytics, now: Date = Date()) -> TimelineRow {
        row(from: record, fallbackStatus: record.status, now: now)
    }

    // MARK: - Markdown (tool output)

    public static func markdownHealth(_ report: HealthReport) -> String {
        var result = "## Project Health Report\n\n"
        if report.rows.isEmpty {
            result += "No projects currently tracked.\n"
            return result
        }

        if !report.critical.isEmpty {
            result += "### \(HealthBand.critical.heading):\n"
            for row in report.critical {
                result += formatHealthBlock(row)
            }
        }
        if !report.attention.isEmpty {
            result += "\n### \(HealthBand.attention.heading):\n"
            for row in report.attention {
                result += formatHealthBlock(row)
            }
        }
        if !report.healthy.isEmpty {
            result += "\n### \(HealthBand.healthy.heading):\n"
            for row in report.healthy {
                result += "- **\(row.name)** (Health: \(row.score)/100)\n"
            }
        }
        return result
    }

    public static func markdownHeatMap(_ report: HeatMapReport) -> String {
        var result = "## Project Activity Heat Map (Past \(report.days) Days)\n\n"
        if report.rows.isEmpty {
            result += "No projects currently tracked.\n"
            return result
        }
        for row in report.rows {
            result += "\(row.levelLabel) **\(row.name)** (\(row.score) activity points"
            if row.eventCount > 0 {
                result += " - \(eventPhrase(row.eventCount))"
            }
            result += ")\n"
        }
        result += "\n### Daily Activity Breakdown:\n"
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        for cell in report.dailyTotals where cell.count > 0 {
            result += "- \(formatter.string(from: cell.day)): \(eventPhrase(cell.count))\n"
        }
        if report.totalEvents == 0 {
            result += "- No events in this window\n"
        }
        result += "\nTotal events: \(report.totalEvents)\n"
        return result
    }

    public static func markdownTechTrends(_ report: TechTrendsReport) -> String {
        var result = "## Technology Analysis\n\n"
        if report.codingProjectCount == 0 {
            result += "No coding projects on the desk. Technology trends cover coding projects only.\n"
            return result
        }
        if report.frameworks.isEmpty {
            result += "No language or framework tags on coding projects yet.\n"
            return result
        }

        result += "### Framework Usage:\n"
        for item in report.frameworks {
            result += "- **\(item.name)**: \(item.sharePercent)% of coding projects (\(item.count)/\(report.codingProjectCount))\n"
            if item.projects.count <= 3 {
                result += "  - Used in: \(item.projects.joined(separator: ", "))\n"
            }
        }

        if !report.emerging.isEmpty {
            result += "\n### Emerging Technologies:\n"
            for item in report.emerging {
                result += "- **\(item.name)** (exploring in: \(item.projects.joined(separator: ", ")))\n"
            }
        }

        result += "\n### Recent Technology Adoptions:\n"
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        for item in report.adoption {
            if let date = item.lastUsed {
                result += "- \(item.name): Last used \(formatter.string(from: date))\n"
            } else {
                result += "- \(item.name)\n"
            }
        }
        return result
    }

    public static func markdownTimeline(row: TimelineRow) -> String {
        var result = "## Status Timeline for \(row.name)\n\n"
        if let current = row.spans.last {
            result += "**Current Status**: \(current.status) (for \(current.durationText))\n\n"
        } else {
            result += "**Current Status**: \(row.currentStatus)\n\n"
        }
        if row.spans.count > 1 {
            result += "### Previous Statuses:\n"
            for span in row.spans.dropLast().reversed() {
                result += "- **\(span.status)**: \(span.durationText)\n"
            }
        }
        result += "\n**Total Project Age**: \(row.ageText)"
        return result
    }

    // MARK: - Internals

    private static func dictionary(_ records: [ProjectWithAnalytics]) -> [String: ProjectWithAnalytics] {
        Dictionary(records.map { ($0.name, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    public static func record(for project: Project, in records: [String: ProjectWithAnalytics]) -> ProjectWithAnalytics {
        records[project.name] ?? ProjectWithAnalytics(from: project)
    }

    private static func score(project: Project, record: ProjectWithAnalytics, now: Date) -> HealthRow {
        let kind = project.kind
        var factors: [HealthFactor] = []

        let recent = record.activityLog.filter {
            $0.timestamp > Calendar.current.date(byAdding: .day, value: -30, to: now)!
        }
        let activity = min(100, activityScore(events: recent) * 5)
        factors.append(HealthFactor(
            label: "Activity Level",
            score: activity,
            detail: "\(eventPhrase(recent.count)) in last 30 days"
        ))

        let statusChanges = record.statusHistory.filter {
            $0.startDate > Calendar.current.date(byAdding: .day, value: -30, to: now)!
        }.count
        let momentum = min(100, statusChanges * 25)
        factors.append(HealthFactor(
            label: "Progress Momentum",
            score: momentum,
            detail: "\(statusChanges) status move\(statusChanges == 1 ? "" : "s") in last 30 days"
        ))

        let daysSinceUpdate = now.timeIntervalSince(record.lastModified) / 86_400
        let freshness = max(0, 100 - Int(daysSinceUpdate * 10))
        factors.append(HealthFactor(
            label: "Freshness",
            score: freshness,
            detail: "Last updated \(daysAgoPhrase(Int(daysSinceUpdate)))"
        ))

        if kind == .coding {
            let hasDescription = (record.description ?? project.description) != nil
            let notes = record.notes ?? project.notes
            let hasNotes = notes != nil && !(notes ?? "").isEmpty
            let docs = (hasDescription ? 50 : 0) + (hasNotes ? 50 : 0)
            factors.append(HealthFactor(
                label: "Documentation Quality",
                score: docs,
                detail: hasDescription && hasNotes ? "Well documented" : "Needs more documentation"
            ))

            let totalTasks = record.currentTasks.count + record.completedTasks.count
            let completion = totalTasks > 0 ? (record.completedTasks.count * 100) / totalTasks : 50
            factors.append(HealthFactor(
                label: "Task Completion",
                score: completion,
                detail: "\(record.completedTasks.count)/\(totalTasks) tasks completed"
            ))
        } else {
            let totalTasks = record.currentTasks.count + record.completedTasks.count
            if totalTasks > 0 {
                let completion = (record.completedTasks.count * 100) / totalTasks
                factors.append(HealthFactor(
                    label: "Task Completion",
                    score: completion,
                    detail: "\(record.completedTasks.count)/\(totalTasks) tasks completed"
                ))
            }
        }

        let overall = factors.reduce(0) { $0 + $1.score } / max(factors.count, 1)

        var recommendations: [String] = []
        if activity < 30 { recommendations.append("Increase project activity") }
        if freshness < 50 { recommendations.append("Update project status") }
        if kind == .coding {
            if let docs = factors.first(where: { $0.label == "Documentation Quality" }), docs.score < 50 {
                recommendations.append("Add project documentation")
            }
            if let tasks = factors.first(where: { $0.label == "Task Completion" }),
               tasks.score < 30,
               record.currentTasks.count + record.completedTasks.count > 0 {
                recommendations.append("Focus on completing tasks")
            }
        }
        if momentum == 0 { recommendations.append("Move the status or a card this week") }

        return HealthRow(
            name: project.name,
            kind: kind,
            score: overall,
            band: HealthBand.band(for: overall),
            factors: factors,
            recommendations: recommendations
        )
    }

    private static func row(
        from record: ProjectWithAnalytics,
        fallbackStatus: String?,
        now: Date
    ) -> TimelineRow {
        let history: [StatusHistory]
        if record.statusHistory.isEmpty, let status = record.status ?? fallbackStatus {
            history = [StatusHistory(status: status, startDate: record.createdDate)]
        } else {
            history = record.statusHistory
        }
        let spans = history.map { item -> TimelineSpan in
            let end = item.endDate
            let seconds = (end ?? now).timeIntervalSince(item.startDate)
            let duration = StatusHistory(status: item.status, startDate: item.startDate, endDate: end ?? now)
            return TimelineSpan(
                status: item.status,
                start: item.startDate,
                end: end,
                durationText: duration.formattedDuration,
                seconds: max(seconds, 1)
            )
        }
        let age = StatusHistory(status: "Total", startDate: record.createdDate, endDate: now)
        return TimelineRow(
            name: record.name,
            created: record.createdDate,
            currentStatus: record.status ?? fallbackStatus ?? "unknown",
            ageText: age.formattedDuration,
            spans: spans
        )
    }

    public static func eventPhrase(_ count: Int) -> String {
        count == 1 ? "1 event" : "\(count) events"
    }

    public static func daysAgoPhrase(_ days: Int) -> String {
        switch days {
        case ...0: return "today"
        case 1: return "1 day ago"
        default: return "\(days) days ago"
        }
    }

    public static func activityScore(events: [ActivityEvent]) -> Int {
        var score = 0
        for event in events {
            switch event.type {
            case .statusChange: score += 5
            case .noteAdded: score += 3
            case .taskAdded: score += 2
            case .taskCompleted: score += 4
            case .accessed: score += 1
            case .searched: score += 1
            }
        }
        return score
    }

    public static func cellLevel(_ count: Int) -> Int {
        switch count {
        case 0: return 0
        case 1: return 1
        case 2...3: return 2
        case 4...6: return 3
        default: return 4
        }
    }

    private static func formatHealthBlock(_ row: HealthRow) -> String {
        var result = "#### \(row.name) (Health: \(row.score)/100)\n"
        for factor in row.factors {
            let mark = factor.score >= 70 ? "ok" : factor.score >= 40 ? "watch" : "low"
            result += "  - \(mark) \(factor.label): \(factor.score)/100 - \(factor.detail)\n"
        }
        if !row.recommendations.isEmpty {
            result += "  - **Recommendations**: \(row.recommendations.joined(separator: ", "))\n"
        }
        result += "\n"
        return result
    }
}
