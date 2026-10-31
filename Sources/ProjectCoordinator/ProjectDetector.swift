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

        let names = shallowNames(at: url, fileManager: fileManager)
        var tags: [String] = []

        if names.contains("Package.swift")
            || names.contains(where: { $0.hasSuffix(".xcodeproj") })
            || names.contains(where: { $0.hasSuffix(".xcworkspace") })
            || names.contains(where: { $0.hasSuffix(".swift") }) {
            tags.append("swift")
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
        if names.contains(where: { $0.hasSuffix(".csproj") || $0.hasSuffix(".sln") }) {
            tags.append("csharp")
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

    private static func shallowNames(at url: URL, fileManager: FileManager) -> Set<String> {
        var names: Set<String> = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .nameKey]
        guard let top = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return names
        }

        for item in top {
            let name = item.lastPathComponent
            names.insert(name)
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                if let nested = try? fileManager.contentsOfDirectory(
                    at: item,
                    includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles]
                ) {
                    for child in nested {
                        names.insert(child.lastPathComponent)
                    }
                }
            }
        }
        return names
    }
}
