import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum DeskServerError: LocalizedError, Sendable, Equatable {
    case nonLoopbackBind(String)
    case listenFailed(String)
    case alreadyRunning
    case tokenFileFailed
    case portInUse(UInt16)

    public var errorDescription: String? {
        switch self {
        case .nonLoopbackBind(let host):
            return "Desk server must bind to 127.0.0.1, not \(host)"
        case .listenFailed(let message):
            return "Desk server listen failed: \(message)"
        case .alreadyRunning:
            return "Desk server is already running"
        case .tokenFileFailed:
            return "Desk server could not write the write-token file"
        case .portInUse(let port):
            return "Desk port \(port) is already in use. Stop the other process or set DPC_DESK_PORT / security-config deskPort."
        }
    }
}

public enum ContentLengthParse: Equatable, Sendable {
    case none
    case value(Int)
    case invalid
}

public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var reason: String
    public var headers: [String: String]
    public var body: Data

    public static let securityHeaders: [String: String] = [
        "Content-Security-Policy": "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'unsafe-inline'; img-src 'self' data:; manifest-src 'self'; connect-src 'self'; frame-ancestors 'none'",
        "X-Content-Type-Options": "nosniff"
    ]

    public init(status: Int, reason: String, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.reason = reason
        self.headers = Self.mergeSecurityHeaders(headers)
        self.body = body
    }

    public static func mergeSecurityHeaders(_ extra: [String: String]) -> [String: String] {
        var headers = securityHeaders
        extra.forEach { headers[$0.key] = $0.value }
        return headers
    }

    public static func text(_ status: Int, _ reason: String, _ body: String, extra: [String: String] = [:]) -> HTTPResponse {
        let data = Data(body.utf8)
        var headers = [
            "Content-Type": "text/plain; charset=utf-8",
            "Content-Length": String(data.count),
            "Cache-Control": "no-store"
        ]
        extra.forEach { headers[$0.key] = $0.value }
        return HTTPResponse(status: status, reason: reason, headers: headers, body: data)
    }

    public static func html(_ html: String, setCookie: String? = nil) -> HTTPResponse {
        let data = Data(html.utf8)
        var headers = [
            "Content-Type": "text/html; charset=utf-8",
            "Content-Length": String(data.count),
            "Cache-Control": "no-store"
        ]
        if let setCookie { headers["Set-Cookie"] = setCookie }
        return HTTPResponse(status: 200, reason: "OK", headers: headers, body: data)
    }

    public static func redirect(location: String, setCookie: String? = nil) -> HTTPResponse {
        var headers = [
            "Location": location,
            "Content-Length": "0",
            "Cache-Control": "no-store"
        ]
        if let setCookie { headers["Set-Cookie"] = setCookie }
        return HTTPResponse(status: 303, reason: "See Other", headers: headers, body: Data())
    }

    public static func bytes(_ body: Data, contentType: String) -> HTTPResponse {
        HTTPResponse(
            status: 200,
            reason: "OK",
            headers: [
                "Content-Type": contentType,
                "Content-Length": String(body.count),
                "Cache-Control": "no-store"
            ],
            body: body
        )
    }

    public static func json(_ status: Int, _ reason: String, _ body: String) -> HTTPResponse {
        let data = Data(body.utf8)
        return HTTPResponse(
            status: status,
            reason: reason,
            headers: [
                "Content-Type": "application/json; charset=utf-8",
                "Content-Length": String(data.count),
                "Cache-Control": "no-store"
            ],
            body: data
        )
    }
}

/// Loopback HTTP server for optional drag-and-drop. Bind is 127.0.0.1 only.
public final class DeskServer: @unchecked Sendable {
    public static let maxBodyBytes = 65_536
    public static let socketTimeoutSeconds: Int = 5
    public static let defaultPort: UInt16 = 47_821

    public let bindHost: String
    public private(set) var port: UInt16
    public private(set) var token: String
    public let tokenFileURL: URL
    private let htmlProvider: @Sendable () -> String
    private let onMove: @Sendable (String, String) throws -> Void
    private let onAdd: @Sendable (String, String) throws -> Void
    private var listenFD: Int32 = -1
    private var running = false
    private let lock = NSLock()

    public init(
        knowledgeBasePath: String,
        bindHost: String = "127.0.0.1",
        port: UInt16 = 0,
        htmlProvider: @escaping @Sendable () -> String,
        onMove: @escaping @Sendable (String, String) throws -> Void,
        onAdd: @escaping @Sendable (String, String) throws -> Void
    ) throws {
        try Self.validateBindHost(bindHost)
        self.bindHost = bindHost
        self.port = port
        self.token = Self.randomToken()
        self.htmlProvider = htmlProvider
        self.onMove = onMove
        self.onAdd = onAdd
        let desk = URL(fileURLWithPath: knowledgeBasePath).appendingPathComponent("desk", isDirectory: true)
        try FileManager.default.createDirectory(at: desk, withIntermediateDirectories: true)
        self.tokenFileURL = desk.appendingPathComponent(".write-token")
        try Self.writeTokenFile(token: token, url: tokenFileURL)
    }

    public static func validateBindHost(_ host: String) throws {
        guard host == "127.0.0.1" else {
            throw DeskServerError.nonLoopbackBind(host)
        }
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    public func start() throws {
        lock.lock()
        if running {
            lock.unlock()
            throw DeskServerError.alreadyRunning
        }
        lock.unlock()

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DeskServerError.listenFailed("socket") }
        if port == 0 {
            var reuse: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
        }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr = in_addr(s_addr: bindHost.withCString { inet_addr($0) })

        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let code = errno
            close(fd)
            if port != 0 && code == EADDRINUSE {
                throw DeskServerError.portInUse(port)
            }
            throw DeskServerError.listenFailed("bind")
        }
        guard listen(fd, 16) == 0 else {
            close(fd)
            throw DeskServerError.listenFailed("listen")
        }

        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(fd, sockaddrPointer, &len)
            }
        }
        guard nameResult == 0 else {
            close(fd)
            throw DeskServerError.listenFailed("getsockname")
        }
        port = UInt16(bigEndian: actual.sin_port)
        listenFD = fd
        lock.lock(); running = true; lock.unlock()

        let server = self
        Thread.detachNewThread {
            server.acceptLoop()
        }
    }

    public func stop() {
        lock.lock()
        running = false
        let fd = listenFD
        listenFD = -1
        lock.unlock()
        if fd >= 0 { close(fd) }
    }

    public func handleForTests(_ request: HTTPRequest) -> HTTPResponse {
        handle(request)
    }

    public func rotateToken() throws {
        let newToken = Self.randomToken()
        try Self.writeTokenFile(token: newToken, url: tokenFileURL)
        lock.lock()
        token = newToken
        lock.unlock()
    }

    public var plainURL: String {
        "http://127.0.0.1:\(port)/"
    }

    public var signInURL: String {
        "http://127.0.0.1:\(port)/?token=\(currentToken())"
    }

    private func currentToken() -> String {
        lock.lock()
        defer { lock.unlock() }
        return token
    }

    public static func resolvePort(
        configPort: UInt16? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> UInt16 {
        if let raw = environment["DPC_DESK_PORT"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let parsed = UInt16(raw), parsed > 0 {
            return parsed
        }
        if let configPort, configPort > 0 {
            return configPort
        }
        return defaultPort
    }

    public static func tokenCookie(_ token: String) -> String {
        "dpc_token=\(token); Path=/; HttpOnly; SameSite=Strict"
    }

    public static func splitPathAndQuery(_ raw: String) -> (path: String, query: [String: String]) {
        let parts = raw.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(parts[0])
        var query: [String: String] = [:]
        if parts.count == 2 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let value = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
                query[key] = value
            }
        }
        return (path, query)
    }

    private func acceptLoop() {
        while isRunning {
            var addr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    accept(self.listenFD, sockaddrPointer, &len)
                }
            }
            if client < 0 {
                if !isRunning { break }
                continue
            }
            Self.applySocketTimeouts(fd: client)
            let response: HTTPResponse
            switch readRequest(fd: client) {
            case .invalidContentLength:
                response = HTTPResponse.text(400, "Bad Request", "invalid content-length")
            case .bytes(let data):
                if let request = Self.parseRequest(data) {
                    response = handle(request)
                } else {
                    response = HTTPResponse.text(400, "Bad Request", "bad request")
                }
            }
            writeResponse(fd: client, response: response)
            close(client)
        }
    }

    private func handle(_ request: HTTPRequest) -> HTTPResponse {
        if !Self.hostAllowed(request.headers["host"], port: port) {
            return HTTPResponse.text(403, "Forbidden", "host rejected")
        }

        let method = request.method.uppercased()
        let parsed = Self.splitPathAndQuery(request.path)
        let path = parsed.path
        let query = parsed.query

        if method == "GET" {
            if path == "/" || path == "/index" || path == "/index.html" {
                if let presented = query["token"] {
                    let current = currentToken()
                    guard Self.tokensEqual(presented, current) else {
                        return HTTPResponse.text(401, "Unauthorized", "bad token")
                    }
                    return HTTPResponse.redirect(location: "/", setCookie: Self.tokenCookie(current))
                }
                return HTTPResponse.html(htmlProvider())
            }
            if path == "/health" {
                return HTTPResponse.text(200, "OK", "ok")
            }
            if path == "/manifest.webmanifest" {
                let body = Data(DeskAssets.manifestJSON().utf8)
                return HTTPResponse.bytes(body, contentType: "application/manifest+json; charset=utf-8")
            }
            if path == "/icon-180.png", let png = DeskAssets.pngIcon(size: 180) {
                return HTTPResponse.bytes(png, contentType: "image/png")
            }
            if path == "/icon-192.png", let png = DeskAssets.pngIcon(size: 192) {
                return HTTPResponse.bytes(png, contentType: "image/png")
            }
            if path == "/icon-512.png", let png = DeskAssets.pngIcon(size: 512) {
                return HTTPResponse.bytes(png, contentType: "image/png")
            }
            if path == "/icon.svg" {
                return HTTPResponse.bytes(Data(DeskAssets.logoLightSVG.utf8), contentType: "image/svg+xml; charset=utf-8")
            }
            if path == "/favicon.svg" {
                return HTTPResponse.bytes(Data(DeskAssets.faviconSVG.utf8), contentType: "image/svg+xml; charset=utf-8")
            }
        }
        if method == "OPTIONS" {
            return HTTPResponse(
                status: 204,
                reason: "No Content",
                headers: ["Content-Length": "0", "Cache-Control": "no-store"],
                body: Data()
            )
        }

        if method == "POST" {
            if let failure = authorizeWrite(request) {
                return failure
            }
            if request.path == "/api/cards/move" {
                guard let json = Self.jsonObject(request.body),
                      let id = json["id"],
                      let column = json["column"] else {
                    return HTTPResponse.json(400, "Bad Request", #"{"error":"invalid body"}"#)
                }
                do {
                    try onMove(id, column)
                    return HTTPResponse.json(200, "OK", #"{"ok":true}"#)
                } catch {
                    return HTTPResponse.json(400, "Bad Request", "{\"error\":\(Self.jsonString(error.localizedDescription))}")
                }
            }
            if request.path == "/api/cards/add" {
                guard let json = Self.jsonObject(request.body),
                      let project = json["project"],
                      let title = json["title"] else {
                    return HTTPResponse.json(400, "Bad Request", #"{"error":"invalid body"}"#)
                }
                do {
                    try onAdd(project, title)
                    return HTTPResponse.json(200, "OK", #"{"ok":true}"#)
                } catch {
                    return HTTPResponse.json(400, "Bad Request", "{\"error\":\(Self.jsonString(error.localizedDescription))}")
                }
            }
        }
        return HTTPResponse.text(404, "Not Found", "not found")
    }

    func authorizeWrite(_ request: HTTPRequest) -> HTTPResponse? {
        let origin = request.headers["origin"]
        if !Self.originAllowed(origin, port: port) {
            return HTTPResponse.text(403, "Forbidden", "origin rejected")
        }
        if !Self.hostAllowed(request.headers["host"], port: port) {
            return HTTPResponse.text(403, "Forbidden", "host rejected")
        }
        let presented = presentedToken(request)
        guard let presented, Self.tokensEqual(presented, currentToken()) else {
            if presented == nil {
                return HTTPResponse.text(401, "Unauthorized", "missing token")
            }
            return HTTPResponse.text(401, "Unauthorized", "bad token")
        }
        return nil
    }

    private func presentedToken(_ request: HTTPRequest) -> String? {
        if let header = request.headers["x-dpc-token"], !header.isEmpty {
            return header
        }
        if let cookie = request.headers["cookie"] {
            for part in cookie.split(separator: ";") {
                let item = part.trimmingCharacters(in: .whitespaces)
                if item.hasPrefix("dpc_token=") {
                    return String(item.dropFirst("dpc_token=".count))
                }
            }
        }
        if let json = Self.jsonObject(request.body), let token = json["token"], !token.isEmpty {
            return token
        }
        return nil
    }

    public static func originAllowed(_ origin: String?, port: UInt16) -> Bool {
        guard let origin, !origin.isEmpty else { return false }
        let allowed = [
            "http://127.0.0.1:\(port)",
            "http://localhost:\(port)"
        ]
        return allowed.contains(origin)
    }

    public static func hostAllowed(_ host: String?, port: UInt16) -> Bool {
        guard let host else { return false }
        let value = host.lowercased()
        return [
            "127.0.0.1:\(port)",
            "localhost:\(port)"
        ].contains(value)
    }

    public static func tokensEqual(_ left: String, _ right: String) -> Bool {
        let leftBytes = Array(left.utf8)
        let rightBytes = Array(right.utf8)
        guard leftBytes.count == rightBytes.count else { return false }
        var diff: UInt8 = 0
        for index in leftBytes.indices {
            diff |= leftBytes[index] ^ rightBytes[index]
        }
        return diff == 0
    }

    static func randomToken() -> String {
        var rng = SystemRandomNumberGenerator()
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        for _ in 0..<32 {
            bytes.append(UInt8.random(in: 0...255, using: &rng))
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func writeTokenFile(token: String, url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tmp = directory.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        let tmpPath = tmp.path
        let fd = tmpPath.withCString { pointer in
            open(pointer, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        }
        guard fd >= 0 else {
            throw DeskServerError.tokenFileFailed
        }
        let bytes = Array(token.utf8)
        let written = bytes.withUnsafeBytes { pointer in
            write(fd, pointer.baseAddress, bytes.count)
        }
        close(fd)
        guard written == bytes.count else {
            try? FileManager.default.removeItem(at: tmp)
            throw DeskServerError.tokenFileFailed
        }
        let renamed = tmpPath.withCString { from in
            url.path.withCString { to in
                rename(from, to)
            }
        }
        if renamed != 0 {
            try? FileManager.default.removeItem(at: tmp)
            throw DeskServerError.tokenFileFailed
        }
    }

    enum ReadOutcome {
        case bytes(Data)
        case invalidContentLength
    }

    public static func parseContentLength(fromHeaderText headerText: String) -> ContentLengthParse {
        let lines = headerText.split(separator: "\r\n")
        var found: Int?
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard name == "content-length" else { continue }
            if found != nil {
                return .invalid
            }
            let raw = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty, let value = Int(raw), value >= 0, value <= maxBodyBytes else {
                return .invalid
            }
            found = value
        }
        guard let value = found else { return .none }
        return .value(value)
    }

    static func applySocketTimeouts(fd: Int32) {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    private func readRequest(fd: Int32) -> ReadOutcome {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let maxTotal = Self.maxBodyBytes + 8192
        while data.count < maxTotal {
            let n = buffer.withUnsafeMutableBytes { pointer in
                read(fd, pointer.baseAddress, pointer.count)
            }
            if n <= 0 { break }
            data.append(contentsOf: buffer.prefix(n))
            if let range = data.range(of: Data("\r\n\r\n".utf8)) {
                guard let headerText = String(data: data.prefix(range.lowerBound), encoding: .utf8) else {
                    return .invalidContentLength
                }
                switch Self.parseContentLength(fromHeaderText: headerText) {
                case .invalid:
                    return .invalidContentLength
                case .none:
                    break
                case .value(let length):
                    let headerEnd = range.upperBound
                    if data.count - headerEnd >= length { break }
                    continue
                }
                break
            }
        }
        return .bytes(data)
    }

    private func writeResponse(fd: Int32, response: HTTPResponse) {
        var header = "HTTP/1.1 \(response.status) \(response.reason)\r\n"
        for (key, value) in response.headers {
            header += "\(key): \(value)\r\n"
        }
        header += "\r\n"
        var payload = Data(header.utf8)
        payload.append(response.body)
        payload.withUnsafeBytes { pointer in
            _ = write(fd, pointer.baseAddress, payload.count)
        }
    }

    static func parseRequest(_ data: Data) -> HTTPRequest? {
        guard let range = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let headerText = String(data: data.prefix(range.lowerBound), encoding: .utf8) else { return nil }
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let start = lines.first else { return nil }
        let parts = start.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        let body = data.suffix(from: range.upperBound)
        return HTTPRequest(
            method: String(parts[0]),
            path: String(parts[1]),
            headers: headers,
            body: Data(body)
        )
    }

    static func jsonObject(_ data: Data) -> [String: String]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var out: [String: String] = [:]
        for (key, value) in object {
            if let string = value as? String {
                out[key] = string
            } else if let number = value as? NSNumber {
                out[key] = number.stringValue
            }
        }
        return out
    }

    static func jsonString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return text
    }
}
