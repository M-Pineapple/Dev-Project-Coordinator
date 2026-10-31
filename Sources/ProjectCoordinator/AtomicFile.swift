import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Copy-on-write backup then atomic replace.
/// `FileManager.replaceItemAt` reports "file doesn't exist" on Linux (swift-corelibs)
/// even when the destination is present, so the swap is `rename(2)` on every platform.
public enum AtomicFile {
    public static func replace(destination: URL, data: Data) throws {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let tmp = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).tmp-\(UUID().uuidString)"
        )
        try data.write(to: tmp, options: .atomic)

        if FileManager.default.fileExists(atPath: destination.path) {
            let backup = directory.appendingPathComponent(destination.lastPathComponent + ".bak")
            if FileManager.default.fileExists(atPath: backup.path) {
                try FileManager.default.removeItem(at: backup)
            }
            try FileManager.default.copyItem(at: destination, to: backup)
        }

        do {
            try renameReplacing(from: tmp, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    /// Same-directory `rename(2)` replaces an existing destination. That is atomic.
    private static func renameReplacing(from source: URL, to destination: URL) throws {
        let rc = source.path.withCString { src in
            destination.path.withCString { dst in
                rename(src, dst)
            }
        }
        guard rc == 0 else {
            let code = errno
            let detail = String(cString: strerror(code))
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: "Could not replace \(destination.lastPathComponent): \(detail)"]
            )
        }
    }
}
