import Foundation

/// Probe a working directory and optional git remote. Never creates folders.
public struct WorkspaceInfo: Sendable, Equatable {
    public var name: String
    public var path: String
    public var repoURL: String?
    public var branch: String?
    public var tags: [String]
    public var kind: ProjectKind
}

public enum WorkspaceProbe {
    public static func probe(
        cwd: String,
        gitRemote: String? = nil,
        branch: String? = nil,
        fileManager: FileManager = .default
    ) -> WorkspaceInfo {
        let expanded = (cwd as NSString).expandingTildeInPath
        let path = URL(fileURLWithPath: expanded).standardized.path
        let detection = ProjectDetector.detect(at: path, fileManager: fileManager)

        let remote = gitRemote ?? git(["remote", "get-url", "origin"], cwd: path)
        let resolvedBranch = branch ?? git(["rev-parse", "--abbrev-ref", "HEAD"], cwd: path)

        let name = projectName(path: path, remote: remote)
        return WorkspaceInfo(
            name: name,
            path: path,
            repoURL: remote,
            branch: resolvedBranch,
            tags: detection.tags,
            kind: detection.kind == .other ? .coding : detection.kind
        )
    }

    public static func projectName(path: String, remote: String?) -> String {
        if let remote, let fromRemote = repoName(fromRemote: remote) {
            return fromRemote
        }
        let last = URL(fileURLWithPath: path).lastPathComponent
        return last.isEmpty ? "untitled" : last
    }

    public static func repoName(fromRemote remote: String) -> String? {
        var value = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix(".git") {
            value = String(value.dropLast(4))
        }
        if let slash = value.lastIndex(of: "/") {
            let name = String(value[value.index(after: slash)...])
            return name.isEmpty ? nil : name
        }
        if let colon = value.lastIndex(of: ":") {
            let name = String(value[value.index(after: colon)...])
            if !name.contains("/") && !name.isEmpty {
                return name
            }
        }
        return nil
    }

    private static func git(_ arguments: [String], cwd: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "--no-optional-locks",
            "-c", "core.fsmonitor=",
            "-c", "core.hooksPath=/dev/null"
        ] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }

        let timeout = GitTimeout(process: process)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
            timeout.fire()
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        timeout.cancel()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return nil }
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty == false) ? text : nil
    }
}

private final class GitTimeout: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var cancelled = false

    init(process: Process) {
        self.process = process
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func fire() {
        lock.lock()
        let skip = cancelled
        lock.unlock()
        if !skip, process.isRunning {
            process.terminate()
        }
    }
}
