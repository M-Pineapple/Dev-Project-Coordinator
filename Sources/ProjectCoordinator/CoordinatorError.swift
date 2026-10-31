import Foundation

public enum CoordinatorError: LocalizedError, Sendable {
    case invalidArguments
    case unknownTool
    case projectNotFound
    case fileSystemError(String)
    case codingRequiresPath
    case duplicateProject(String)
    case nearDuplicate(String)
    case cardNotFound
    case invalidColumn
    case invalidCardID

    public var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "Invalid arguments provided"
        case .unknownTool:
            return "Unknown tool requested"
        case .projectNotFound:
            return "Project not found"
        case .fileSystemError(let message):
            return "File system error: \(message)"
        case .codingRequiresPath:
            return "Coding projects need a folder path. Pass path or use register_from_workspace."
        case .duplicateProject(let name):
            return "A project named \(name) already exists. Use rename_project or merge_projects."
        case .nearDuplicate(let name):
            return "That looks like existing project \(name). Use that name, or rename_project / merge_projects."
        case .cardNotFound:
            return "Card not found"
        case .invalidColumn:
            return "Unknown column. Default columns are backlog, doing, review, done, parked."
        case .invalidCardID:
            return "Card id is invalid"
        }
    }
}
