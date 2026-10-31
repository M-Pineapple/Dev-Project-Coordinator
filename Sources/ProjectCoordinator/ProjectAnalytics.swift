import Foundation

// MARK: - Analytics Models

/// Tracks status changes over time
public struct StatusHistory: Codable, Sendable {
    public let status: String
    public let startDate: Date
    public var endDate: Date?

    public init(status: String, startDate: Date, endDate: Date? = nil) {
        self.status = status
        self.startDate = startDate
        self.endDate = endDate
    }
    
    /// Duration in this status (seconds)
    var duration: TimeInterval {
        let end = endDate ?? Date()
        return end.timeIntervalSince(startDate)
    }
    
    /// Human-readable duration
    var formattedDuration: String {
        let days = Int(duration / 86400)
        let hours = Int((duration.truncatingRemainder(dividingBy: 86400)) / 3600)
        let minutes = Int((duration.truncatingRemainder(dividingBy: 3600)) / 60)
        
        var parts: [String] = []
        if days > 0 { parts.append("\(days) day\(days == 1 ? "" : "s")") }
        if hours > 0 { parts.append("\(hours) hour\(hours == 1 ? "" : "s")") }
        if minutes > 0 && days == 0 { parts.append("\(minutes) minute\(minutes == 1 ? "" : "s")") }
        
        return parts.isEmpty ? "Just started" : parts.joined(separator: ", ")
    }
}

/// Tracks project activity events
public struct ActivityEvent: Codable, Sendable {
    public enum EventType: String, Codable, Sendable {
        case statusChange = "status_change"
        case noteAdded = "note_added"
        case taskAdded = "task_added"
        case taskCompleted = "task_completed"
        case accessed = "accessed"
        case searched = "searched"
    }
    
    public let timestamp: Date
    public let type: EventType
    public let description: String?

    public init(timestamp: Date, type: EventType, description: String? = nil) {
        self.timestamp = timestamp
        self.type = type
        self.description = description
    }
}

/// Technology usage analytics
struct TechnologyStats: Codable {
    var frameworkCounts: [String: Int] = [:]
    var lastUsed: [String: Date] = [:]
    var projectsUsing: [String: [String]] = [:] // tech -> [projectNames]
    
    mutating func recordTechnology(_ tech: String, for project: String) {
        frameworkCounts[tech] = (frameworkCounts[tech] ?? 0) + 1
        lastUsed[tech] = Date()
        
        if var projects = projectsUsing[tech] {
            if !projects.contains(project) {
                projects.append(project)
                projectsUsing[tech] = projects
            }
        } else {
            projectsUsing[tech] = [project]
        }
    }
}

/// Enhanced project model with analytics
public struct ProjectWithAnalytics: Codable, Sendable {
    // Original project fields
    public var name: String
    public let path: String?
    public var description: String?
    public var status: String?
    public var notes: String?
    public var techStack: [String]
    public var lastModified: Date
    public var currentTasks: [String]
    public var kind: ProjectKind?

    // New analytics fields
    public var statusHistory: [StatusHistory] = []
    public var activityLog: [ActivityEvent] = []
    public var createdDate: Date = Date()
    public var completedTasks: [String] = []

    enum CodingKeys: String, CodingKey {
        case name, path, description, status, notes, techStack, lastModified, currentTasks
        case kind, statusHistory, activityLog, createdDate, completedTasks
    }

    // Convert from old Project model
    public init(from project: Project) {
        self.name = project.name
        self.path = project.path
        self.description = project.description
        self.status = project.status
        self.notes = project.notes
        self.techStack = project.techStack
        self.lastModified = project.lastModified
        self.currentTasks = project.currentTasks
        self.kind = project.kind

        // FIX: Use project's lastModified as createdDate for migration
        // This preserves the original project date instead of using current time
        self.createdDate = project.lastModified

        // Initialize status history with current status
        if let currentStatus = project.status {
            self.statusHistory = [StatusHistory(status: currentStatus, startDate: project.lastModified)]
        }
    }

    // Direct initializer for new projects
    public init(
        name: String,
        path: String?,
        description: String?,
        status: String?,
        notes: String?,
        techStack: [String],
        lastModified: Date,
        currentTasks: [String],
        kind: ProjectKind? = nil,
        statusHistory: [StatusHistory] = [],
        activityLog: [ActivityEvent] = [],
        createdDate: Date = Date(),
        completedTasks: [String] = []
    ) {
        self.name = name
        self.path = path
        self.description = description
        self.status = status
        self.notes = notes
        self.techStack = techStack
        self.lastModified = lastModified
        self.currentTasks = currentTasks
        self.kind = kind
        self.createdDate = createdDate
        self.completedTasks = completedTasks
        self.activityLog = activityLog
        if statusHistory.isEmpty, let currentStatus = status {
            self.statusHistory = [StatusHistory(status: currentStatus, startDate: createdDate)]
        } else {
            self.statusHistory = statusHistory
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        techStack = try container.decodeIfPresent([String].self, forKey: .techStack) ?? []
        lastModified = try container.decodeIfPresent(Date.self, forKey: .lastModified) ?? Date()
        currentTasks = try container.decodeIfPresent([String].self, forKey: .currentTasks) ?? []
        kind = try container.decodeIfPresent(ProjectKind.self, forKey: .kind)
        statusHistory = try container.decodeIfPresent([StatusHistory].self, forKey: .statusHistory) ?? []
        activityLog = try container.decodeIfPresent([ActivityEvent].self, forKey: .activityLog) ?? []
        createdDate = try container.decodeIfPresent(Date.self, forKey: .createdDate) ?? lastModified
        completedTasks = try container.decodeIfPresent([String].self, forKey: .completedTasks) ?? []
    }
}

// MARK: - Analytics Engine

public actor ProjectAnalytics {
    private var projects: [String: ProjectWithAnalytics] = [:]
    private var globalTechStats = TechnologyStats()
    private let knowledgeBasePath: String
    
    public init(knowledgeBasePath: String) {
        self.knowledgeBasePath = knowledgeBasePath
    }
    
    public init() {
        self.knowledgeBasePath = KnowledgeBasePaths.resolve()
    }
    
    public func allRecords() -> [ProjectWithAnalytics] {
        Array(projects.values)
    }

    public func reports(
        projects deskProjects: [Project],
        now: Date = Date(),
        heatDays: Int = AnalyticsEngine.heatMapPageDays
    ) -> (
        health: AnalyticsEngine.HealthReport,
        heat: AnalyticsEngine.HeatMapReport,
        trends: AnalyticsEngine.TechTrendsReport,
        timeline: AnalyticsEngine.TimelineReport
    ) {
        let records = allRecords()
        return (
            AnalyticsEngine.health(projects: deskProjects, records: records, now: now),
            AnalyticsEngine.heatMap(projects: deskProjects, records: records, days: heatDays, now: now),
            AnalyticsEngine.techTrends(projects: deskProjects, records: records, now: now),
            AnalyticsEngine.timeline(projects: deskProjects, records: records, now: now)
        )
    }

    // MARK: - Time Tracking

    public func getStatusDuration(for projectName: String) async -> String? {
        guard let project = projects[projectName] else { return nil }
        return AnalyticsEngine.markdownTimeline(row: AnalyticsEngine.timelineRow(record: project))
    }
    
    // MARK: - Activity Heat Map
    
    public func getActivityHeatMap(days: Int = 7) async -> String {
        let report = AnalyticsEngine.heatMap(
            projects: deskProjectsFromRecords(),
            records: allRecords(),
            days: max(days, 1),
            now: Date()
        )
        return AnalyticsEngine.markdownHeatMap(report)
    }
    
    // MARK: - Technology Trends
    
    public func getTechnologyTrends() async -> String {
        AnalyticsEngine.markdownTechTrends(
            AnalyticsEngine.techTrends(projects: deskProjectsFromRecords(), records: allRecords())
        )
    }
    
    // MARK: - Project Health Scoring
    
    public func getProjectHealthReport() async -> String {
        AnalyticsEngine.markdownHealth(
            AnalyticsEngine.health(projects: deskProjectsFromRecords(), records: allRecords())
        )
    }

    public func getProjectHealthReport(projects deskProjects: [Project], now: Date = Date()) -> String {
        AnalyticsEngine.markdownHealth(
            AnalyticsEngine.health(projects: deskProjects, records: allRecords(), now: now)
        )
    }

    private func deskProjectsFromRecords() -> [Project] {
        projects.values.map { record in
            Project(
                name: record.name,
                path: record.path,
                description: record.description,
                status: record.status,
                notes: record.notes,
                techStack: record.techStack,
                lastModified: record.lastModified,
                currentTasks: record.currentTasks,
                kind: record.kind ?? .coding
            )
        }
    }
    
    // MARK: - Helper Methods
    
    func updateProject(_ project: ProjectWithAnalytics) async {
        projects[project.name] = project
        
        // Update global tech stats
        for tech in project.techStack {
            globalTechStats.recordTechnology(tech, for: project.name)
        }
    }
    
    public func migrateProject(_ oldProject: Project) async -> ProjectWithAnalytics {
        let newProject = ProjectWithAnalytics(from: oldProject)
        await updateProject(newProject)
        return newProject
    }
    
    public func recordActivity(
        for projectName: String,
        type: ActivityEvent.EventType,
        description: String? = nil,
        at timestamp: Date = Date()
    ) async {
        guard var project = projects[projectName] else { return }
        let event = ActivityEvent(timestamp: timestamp, type: type, description: description)
        project.activityLog.append(event)
        project.lastModified = timestamp
        await updateProject(project)
        try? await saveAnalytics()
    }

    public func updateStatus(for projectName: String, newStatus: String, at timestamp: Date = Date()) async {
        guard var project = projects[projectName] else { return }
        if !project.statusHistory.isEmpty {
            project.statusHistory[project.statusHistory.count - 1].endDate = timestamp
        }
        project.statusHistory.append(StatusHistory(status: newStatus, startDate: timestamp))
        project.status = newStatus
        let event = ActivityEvent(timestamp: timestamp, type: .statusChange, description: "Status changed to: \(newStatus)")
        project.activityLog.append(event)
        project.lastModified = timestamp
        await updateProject(project)
        try? await saveAnalytics()
    }

    public func renameProject(from oldName: String, to newName: String) async {
        guard var record = projects.removeValue(forKey: oldName) else { return }
        record.name = newName
        projects[newName] = record
        let oldPath = "\(knowledgeBasePath)/projects/\(oldName)-analytics.json"
        try? FileManager.default.removeItem(atPath: oldPath)
        try? await saveAnalytics()
    }

    public func mergeProject(source: String, into target: String) async {
        guard let src = projects.removeValue(forKey: source) else { return }
        if var dst = projects[target] {
            dst.activityLog.append(contentsOf: src.activityLog)
            dst.activityLog.sort { $0.timestamp < $1.timestamp }
            dst.statusHistory.append(contentsOf: src.statusHistory)
            dst.completedTasks.append(contentsOf: src.completedTasks)
            if dst.createdDate > src.createdDate {
                dst.createdDate = src.createdDate
            }
            if dst.techStack.isEmpty {
                dst.techStack = src.techStack
            }
            projects[target] = dst
        } else {
            var moved = src
            moved.name = target
            projects[target] = moved
        }
        try? FileManager.default.removeItem(atPath: "\(knowledgeBasePath)/projects/\(source)-analytics.json")
        try? await saveAnalytics()
    }
    
    // MARK: - Persistence
    
    public func saveAnalytics() async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601
        
        // Save individual project analytics
        for (name, project) in projects {
            let data = try encoder.encode(project)
            let filePath = "\(knowledgeBasePath)/projects/\(name)-analytics.json"
            try data.write(to: URL(fileURLWithPath: filePath))
        }
        
        rebuildGlobalTechStats()
        let analyticsDir = "\(knowledgeBasePath)/analytics"
        try FileManager.default.createDirectory(
            atPath: analyticsDir,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let techData = try encoder.encode(globalTechStats)
        let techPath = "\(analyticsDir)/global-tech-stats.json"
        try techData.write(to: URL(fileURLWithPath: techPath))
    }

    private func rebuildGlobalTechStats() {
        var stats = TechnologyStats()
        for record in projects.values where (record.kind ?? .coding) == .coding {
            for tech in record.techStack {
                stats.recordTechnology(tech, for: record.name)
            }
        }
        globalTechStats = stats
    }
    
    func hasAnalytics(for projectName: String) async -> Bool {
        return projects[projectName] != nil
    }
    
    public func loadAnalytics() async {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        // Create analytics directory if needed
        let analyticsPath = "\(knowledgeBasePath)/analytics"
        try? FileManager.default.createDirectory(
            atPath: analyticsPath,
            withIntermediateDirectories: true,
            attributes: nil
        )
        
        // Load project analytics
        let projectsPath = "\(knowledgeBasePath)/projects"
        if let files = try? FileManager.default.contentsOfDirectory(atPath: projectsPath) {
            for file in files where file.hasSuffix("-analytics.json") {
                let filePath = "\(projectsPath)/\(file)"
                if let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
                   let project = try? decoder.decode(ProjectWithAnalytics.self, from: data) {
                    projects[project.name] = project
                }
            }
        }
        
        // Load global tech stats
        let techPath = "\(knowledgeBasePath)/analytics/global-tech-stats.json"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: techPath)),
           let stats = try? decoder.decode(TechnologyStats.self, from: data) {
            globalTechStats = stats
        }
    }
}
