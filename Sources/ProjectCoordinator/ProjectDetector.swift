import Foundation

/// Shallow language detection from top-level files plus one directory level.
public struct DetectionResult: Sendable, Equatable {
    public var tags: [String]
    public var kind: ProjectKind

    public init(tags: [String], kind: ProjectKind) {
        self.tags = tags
        self.kind = kind
    }
}

public enum ProjectDetector {
    public static func detect(at path: String, fileManager: FileManager = .default) -> DetectionResult {
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return DetectionResult(tags: ["unknown"], kind: .other)
        }

        let scan = shallowScan(at: url, fileManager: fileManager)
        let names = scan.names
        var tags: [String] = []

        let hasPackageSwift = names.contains("Package.swift")
        let hasXcodeProject = names.contains(where: { $0.hasSuffix(".xcodeproj") })
        let hasXcodeWorkspace = names.contains(where: { $0.hasSuffix(".xcworkspace") })
        let hasSwiftSource = names.contains(where: { $0.hasSuffix(".swift") })
        if hasPackageSwift || hasXcodeProject || hasXcodeWorkspace || hasSwiftSource {
            tags.append("swift")
        }
        if hasPackageSwift { tags.append("spm") }
        if hasXcodeProject { tags.append("xcode-project") }
        if hasXcodeWorkspace { tags.append("xcode-workspace") }
        if scan.swiftFiles.contains(where: containsSwiftUI) {
            tags.append("swiftui")
        }
        if names.contains("pyproject.toml")
            || names.contains("requirements.txt")
            || names.contains("setup.py")
            || names.contains("Pipfile")
            || names.contains(where: { $0.hasSuffix(".py") }) {
            tags.append("python")
        }
        let hasTSConfig = names.contains("tsconfig.json")
        let hasPackageJSON = names.contains("package.json")
        if hasPackageJSON { tags.append("node") }
        if hasTSConfig || names.contains(where: { $0.hasSuffix(".ts") || $0.hasSuffix(".tsx") }) {
            tags.append("typescript")
        } else if hasPackageJSON {
            tags.append("javascript")
        }
        if names.contains("go.mod") { tags.append("go") }
        if names.contains("Cargo.toml") { tags.append("rust") }
        if names.contains("Gemfile") { tags.append("ruby") }
        if names.contains("composer.json") { tags.append("php") }
        if names.contains("pom.xml") || names.contains("build.gradle") { tags.append("java") }
        if names.contains("build.gradle.kts") || names.contains(where: { $0.hasSuffix(".kt") }) {
            tags.append("kotlin")
        }
        if names.contains(where: { $0.hasSuffix(".csproj") || $0.hasSuffix(".sln") })
            || names.contains("global.json") {
            tags.append("csharp")
            tags.append("dotnet")
        }
        if names.contains("Dockerfile")
            || names.contains("Containerfile")
            || names.contains("docker-compose.yml")
            || names.contains("docker-compose.yaml")
            || names.contains("compose.yml")
            || names.contains("compose.yaml") {
            tags.append("docker")
        }
        let hasMakefile = names.contains("Makefile") || names.contains("makefile")
        let hasCpp = names.contains("CMakeLists.txt")
            || (hasMakefile && names.contains(where: { $0.hasSuffix(".cpp") || $0.hasSuffix(".cc") }))
        if hasCpp { tags.append("cpp") }

        let languageManifest = tags.contains { $0 != "web" }
        if names.contains("index.html"), !languageManifest {
            tags.append("web")
        }

        if tags.isEmpty {
            return DetectionResult(tags: ["unknown"], kind: .other)
        }
        return DetectionResult(tags: tags, kind: .coding)
    }

    private struct ShallowScan {
        var names: Set<String>
        var swiftFiles: [URL]
    }

    private static func shallowScan(at url: URL, fileManager: FileManager) -> ShallowScan {
        var names: Set<String> = []
        var swiftFiles: [URL] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .nameKey]
        guard let top = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return ShallowScan(names: names, swiftFiles: swiftFiles)
        }

        func consider(_ item: URL) {
            let name = item.lastPathComponent
            names.insert(name)
            if name.hasSuffix(".swift") {
                swiftFiles.append(item)
            }
        }

        for item in top {
            consider(item)
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                if let nested = try? fileManager.contentsOfDirectory(
                    at: item,
                    includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles]
                ) {
                    for child in nested {
                        consider(child)
                    }
                }
            }
        }
        return ShallowScan(names: names, swiftFiles: Array(swiftFiles.prefix(24)))
    }

    private static func containsSwiftUI(_ file: URL) -> Bool {
        guard let data = try? Data(contentsOf: file, options: [.mappedIfSafe]) else { return false }
        let prefix = data.prefix(65_536)
        guard let text = String(data: prefix, encoding: .utf8) else { return false }
        return text.contains("import SwiftUI")
    }
}
