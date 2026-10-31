import Foundation
import MCP

/// Boots the MCP server with DPC tools using the official Swift SDK.
public enum MCPBootstrap {
    public static func makeServer(
        projectManager: ProjectManager,
        analytics: ProjectAnalytics
    ) async -> Server {
        let server = Server(
            name: CPCVersion.serverName,
            version: CPCVersion.string,
            capabilities: .init(
                tools: .init(listChanged: false)
            )
        )

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: Self.tools)
        }

        await server.withMethodHandler(CallTool.self) { params in
            do {
                let text = try await Self.executeTool(
                    name: params.name,
                    arguments: params.arguments ?? [:],
                    projectManager: projectManager,
                    analytics: analytics
                )
                return .init(
                    content: [.text(text: text, annotations: nil, _meta: nil)],
                    isError: false
                )
            } catch {
                return .init(
                    content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)],
                    isError: true
                )
            }
        }

        return server
    }

    public static func run() async throws {
        let knowledgeBasePath = KnowledgeBasePaths.resolve()
        let projectManager = ProjectManager(knowledgeBasePath: knowledgeBasePath)
        let analytics = ProjectAnalytics(knowledgeBasePath: knowledgeBasePath)
        await projectManager.initialize(analytics: analytics)
        let server = await makeServer(projectManager: projectManager, analytics: analytics)
        let transport = StdioTransport()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }

    private static func stringProp(_ description: String) -> Value {
        .object([
            "type": .string("string"),
            "description": .string(description)
        ])
    }

    private static func objectSchema(properties: [String: Value], required: [String]) -> Value {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map { .string($0) })
        ])
    }

    private static var tools: [Tool] {
        [
            Tool(
                name: "get_desk_summary",
                description: "Use this first. Compact desk under 800 tokens. Skip list_projects unless the user asks for a deep dive.",
                inputSchema: objectSchema(properties: [:], required: [])
            ),
            Tool(
                name: "list_projects",
                description: "Full project roster. Prefer get_desk_summary first. Use this for a deep dive only.",
                inputSchema: objectSchema(properties: [:], required: [])
            ),
            Tool(
                name: "get_project_status",
                description: "Full detail for one project, including notes. Prefer get_desk_summary first.",
                inputSchema: objectSchema(
                    properties: ["projectName": stringProp("Name of the project")],
                    required: ["projectName"]
                )
            ),
            Tool(
                name: "search_desk",
                description: "Search notes, card titles, kinds, and KnowledgeBase markdown. Prefer get_desk_summary first.",
                inputSchema: objectSchema(
                    properties: ["pattern": stringProp("Keyword to search for")],
                    required: ["pattern"]
                )
            ),
            Tool(
                name: "search_code_patterns",
                description: "Deprecated alias of search_desk. Prefer search_desk. Use get_desk_summary first.",
                inputSchema: objectSchema(
                    properties: ["pattern": stringProp("Keyword to search for")],
                    required: ["pattern"]
                )
            ),
            Tool(
                name: "add_project",
                description: "Manually register a project. Path is optional for non-coding work. Coding projects need a folder. Prefer register_from_workspace when an agent is already in a repo.",
                inputSchema: objectSchema(
                    properties: [
                        "name": stringProp("Project name"),
                        "path": stringProp("Optional folder path"),
                        "description": stringProp("Optional description"),
                        "kind": stringProp("coding, writing, campaign, research, legal, personal, or other")
                    ],
                    required: ["name"]
                )
            ),
            Tool(
                name: "update_project_status",
                description: "Update status or notes for a project. Prefer get_desk_summary first.",
                inputSchema: objectSchema(
                    properties: [
                        "projectName": stringProp("Name of the project"),
                        "status": stringProp("New status"),
                        "notes": stringProp("Notes (replace, do not append)")
                    ],
                    required: ["projectName"]
                )
            ),
            Tool(
                name: "get_project_timeline",
                description: "Status timeline for one project. Prefer get_desk_summary first.",
                inputSchema: objectSchema(
                    properties: ["projectName": stringProp("Name of the project")],
                    required: ["projectName"]
                )
            ),
            Tool(
                name: "get_activity_heatmap",
                description: "Activity counts for recent days. Prefer get_desk_summary first.",
                inputSchema: objectSchema(
                    properties: ["days": .object(["type": .string("integer"), "description": .string("Days to analyse (default 7)")])],
                    required: []
                )
            ),
            Tool(
                name: "get_technology_trends",
                description: "Language and tag counts. Opt-in deep dive. Prefer get_desk_summary first.",
                inputSchema: objectSchema(properties: [:], required: [])
            ),
            Tool(
                name: "get_project_health",
                description: "Legacy 0-100 scores. Prefer get_desk_summary and the Analytics tab.",
                inputSchema: objectSchema(properties: [:], required: [])
            ),
            Tool(
                name: "open_desk",
                description: "Write KnowledgeBase/desk/index.html and return its path. Open the file from disk.",
                inputSchema: objectSchema(properties: [:], required: [])
            ),
            Tool(
                name: "add_card",
                description: "Add a Kanban card. Optional memoryRef is an opaque id. DPC never copies memory prose.",
                inputSchema: objectSchema(
                    properties: [
                        "project": stringProp("Project name"),
                        "title": stringProp("Card title"),
                        "column": stringProp("Column (default backlog)"),
                        "memoryRef": stringProp("Optional opaque memory id or tag"),
                        "linkedPR": stringProp("Optional pull request URL or number")
                    ],
                    required: ["project", "title"]
                )
            ),
            Tool(
                name: "move_card",
                description: "Move a card to another column, then regenerate the desk page.",
                inputSchema: objectSchema(
                    properties: [
                        "id": stringProp("Card id"),
                        "column": stringProp("Target column")
                    ],
                    required: ["id", "column"]
                )
            ),
            Tool(
                name: "update_card",
                description: "Update card title, column, or memoryRef.",
                inputSchema: objectSchema(
                    properties: [
                        "id": stringProp("Card id"),
                        "title": stringProp("New title"),
                        "column": stringProp("New column"),
                        "memoryRef": stringProp("Opaque memory id or tag")
                    ],
                    required: ["id"]
                )
            ),
            Tool(
                name: "rename_column",
                description: "Rename a Kanban column. Cards in that column follow the new name.",
                inputSchema: objectSchema(
                    properties: [
                        "from": stringProp("Current column name"),
                        "to": stringProp("New column name")
                    ],
                    required: ["from", "to"]
                )
            ),
            Tool(
                name: "register_from_workspace",
                description: "Silently register or update a coding project from the agent's working directory and git remote. Never creates folders.",
                inputSchema: objectSchema(
                    properties: [
                        "cwd": stringProp("Working directory"),
                        "gitRemote": stringProp("Optional git remote URL"),
                        "branch": stringProp("Optional current branch"),
                        "openPR": stringProp("Optional open pull request to link as a card")
                    ],
                    required: ["cwd"]
                )
            ),
            Tool(
                name: "file_under_project",
                description: "Find the closest existing non-coding project or create one with no path. Reply includes Filed under new/existing project.",
                inputSchema: objectSchema(
                    properties: [
                        "name": stringProp("Project name inferred from context"),
                        "kind": stringProp("writing, campaign, research, legal, personal, or other"),
                        "description": stringProp("Optional description")
                    ],
                    required: ["name"]
                )
            ),
            Tool(
                name: "rename_project",
                description: "Rename a project after a wrong guess.",
                inputSchema: objectSchema(
                    properties: [
                        "from": stringProp("Current name"),
                        "to": stringProp("New name")
                    ],
                    required: ["from", "to"]
                )
            ),
            Tool(
                name: "merge_projects",
                description: "Merge a duplicate project into another. Cards move to the target.",
                inputSchema: objectSchema(
                    properties: [
                        "source": stringProp("Project to absorb"),
                        "target": stringProp("Project to keep")
                    ],
                    required: ["source", "target"]
                )
            ),
            Tool(
                name: "start_desk_server",
                description: "Opt-in localhost Kanban server bound to 127.0.0.1. Token file mode 0600. Static index.html still works without it.",
                inputSchema: objectSchema(properties: [:], required: [])
            ),
        ]
    }

    private static func executeTool(
        name: String,
        arguments: [String: Value],
        projectManager: ProjectManager,
        analytics: ProjectAnalytics
    ) async throws -> String {
        switch name {
        case "get_desk_summary":
            return await projectManager.deskSummary()

        case "list_projects":
            return try await projectManager.listProjects()

        case "get_project_status":
            guard let projectName = arguments["projectName"]?.stringValue else {
                throw CoordinatorError.invalidArguments
            }
            return try await projectManager.getProjectStatusSecure(projectName: projectName)

        case "search_desk", "search_code_patterns":
            guard let pattern = arguments["pattern"]?.stringValue else {
                throw CoordinatorError.invalidArguments
            }
            return try await projectManager.searchCodePatternsSecure(pattern: pattern)

        case "add_project":
            guard let projectName = arguments["name"]?.stringValue else {
                throw CoordinatorError.invalidArguments
            }
            let path = arguments["path"]?.stringValue
            let description = arguments["description"]?.stringValue
            let kind = arguments["kind"]?.stringValue.flatMap(ProjectKind.init(rawValue:))
            let result = try await projectManager.addProjectSecure(
                name: projectName,
                path: path,
                description: description,
                kind: kind
            )
            await analytics.recordActivity(for: projectName, type: .accessed)
            return result

        case "update_project_status":
            guard let projectName = arguments["projectName"]?.stringValue else {
                throw CoordinatorError.invalidArguments
            }
            let status = arguments["status"]?.stringValue
            let notes = arguments["notes"]?.stringValue
            if let newStatus = status {
                await analytics.updateStatus(for: projectName, newStatus: newStatus)
            }
            if notes != nil {
                await analytics.recordActivity(for: projectName, type: .noteAdded)
            }
            return try await projectManager.updateProjectStatusSecure(
                projectName: projectName,
                status: status,
                notes: notes
            )

        case "get_project_timeline":
            guard let projectName = arguments["projectName"]?.stringValue else {
                throw CoordinatorError.invalidArguments
            }
            return await analytics.getStatusDuration(for: projectName)
                ?? "No timeline data available for \(projectName)"

        case "get_activity_heatmap":
            let days = arguments["days"]?.intValue ?? 7
            return await analytics.getActivityHeatMap(days: days)

        case "get_technology_trends":
            return await analytics.getTechnologyTrends()

        case "get_project_health":
            return await analytics.getProjectHealthReport()

        case "open_desk":
            return try await projectManager.openDesk()

        case "add_card":
            guard let project = arguments["project"]?.stringValue,
                  let title = arguments["title"]?.stringValue else {
                throw CoordinatorError.invalidArguments
            }
            return try await projectManager.addCard(
                project: project,
                title: title,
                column: arguments["column"]?.stringValue,
                memoryRef: arguments["memoryRef"]?.stringValue,
                linkedPR: arguments["linkedPR"]?.stringValue
            )

        case "move_card":
            guard let id = arguments["id"]?.stringValue,
                  let column = arguments["column"]?.stringValue else {
                throw CoordinatorError.invalidArguments
            }
            return try await projectManager.moveCard(id: id, column: column)

        case "update_card":
            guard let id = arguments["id"]?.stringValue else {
                throw CoordinatorError.invalidArguments
            }
            return try await projectManager.updateCard(
                id: id,
                title: arguments["title"]?.stringValue,
                column: arguments["column"]?.stringValue,
                memoryRef: arguments["memoryRef"]?.stringValue
            )

        case "rename_column":
            guard let from = arguments["from"]?.stringValue,
                  let to = arguments["to"]?.stringValue else {
                throw CoordinatorError.invalidArguments
            }
            return try await projectManager.renameColumn(from: from, to: to)

        case "register_from_workspace":
            guard let cwd = arguments["cwd"]?.stringValue else {
                throw CoordinatorError.invalidArguments
            }
            return try await projectManager.registerFromWorkspace(
                cwd: cwd,
                gitRemote: arguments["gitRemote"]?.stringValue,
                branch: arguments["branch"]?.stringValue,
                openPR: arguments["openPR"]?.stringValue
            )

        case "file_under_project":
            guard let name = arguments["name"]?.stringValue else {
                throw CoordinatorError.invalidArguments
            }
            let kind = arguments["kind"]?.stringValue.flatMap(ProjectKind.init(rawValue:))
            return try await projectManager.fileUnderProject(
                name: name,
                kind: kind,
                description: arguments["description"]?.stringValue
            )

        case "rename_project":
            guard let from = arguments["from"]?.stringValue,
                  let to = arguments["to"]?.stringValue else {
                throw CoordinatorError.invalidArguments
            }
            return try await projectManager.renameProject(from: from, to: to)

        case "merge_projects":
            guard let source = arguments["source"]?.stringValue,
                  let target = arguments["target"]?.stringValue else {
                throw CoordinatorError.invalidArguments
            }
            return try await projectManager.mergeProjects(source: source, into: target)

        case "start_desk_server":
            return try await projectManager.startDeskServer()

        default:
            throw CoordinatorError.unknownTool
        }
    }
}
