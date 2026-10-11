import Foundation
import Network

/// Tiny HTTP/1.1 file server with Range support — just enough for DLNA renderers.
final class MediaServer: @unchecked Sendable {
    static let dlnaFeatures = "DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000"

    private let queue = DispatchQueue(label: "SamsungTV4Mac.MediaServer")
    private let lock = NSLock()
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var files: [String: URL] = [:]

    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "mkv": return "video/x-matroska"
        case "mov": return "video/quicktime"
        case "ts", "m2ts", "mts": return "video/mp2t"
        case "webm": return "video/webm"
        case "avi": return "video/x-msvideo"
        default: return "application/octet-stream"
        }
    }

    /// Starts the listener (once) and returns its port.
    func start() async throws -> UInt16 {
        if let current = lock.withLock({ listener != nil && port != 0 ? port : nil }) { return current }

        let newListener = try NWListener(using: .tcp, on: .any)
        newListener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let resumed = Box(false)
        return try await withCheckedThrowingContinuation { cont in
            newListener.stateUpdateHandler = { [weak self] state in
                guard !resumed.value else { return }
                switch state {
                case .ready:
                    resumed.value = true
                    let p = newListener.port?.rawValue ?? 0
                    self?.lock.withLock { self?.listener = newListener; self?.port = p }
                    cont.resume(returning: p)
                case .failed(let error):
                    resumed.value = true
                    cont.resume(throwing: error)
                default:
                    break
                }
            }
            newListener.start(queue: queue)
        }
    }

    /// Makes a file available and returns its URL path (stable per file).
    func publish(_ file: URL) -> String {
        lock.withLock {
            if let existing = files.first(where: { $0.value == file }) { return existing.key }
            let ext = file.pathExtension.isEmpty ? "" : ".\(file.pathExtension.lowercased())"
            let path = "/media/\(UUID().uuidString.prefix(8).lowercased())\(ext)"
            files[path] = file
            return path
        }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "SamsungTV4Mac.MediaServer.connection"))
        receiveHead(connection, buffer: Data())
    }

    private func receiveHead(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(connection, head: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            } else if error != nil || isComplete || buffer.count > 65_536 {
                connection.cancel()
            } else {
                self.receiveHead(connection, buffer: buffer)
            }
        }
    }

    private func respond(_ connection: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { return finish(connection, status: "400 Bad Request") }
        let method = String(requestLine[0])
        let path = String(requestLine[1].split(separator: "?").first ?? "")

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        guard method == "GET" || method == "HEAD" else { return finish(connection, status: "405 Method Not Allowed") }
        guard let file = lock.withLock({ files[path] }),
              let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.uint64Value,
              let handle = try? FileHandle(forReadingFrom: file)
        else { return finish(connection, status: "404 Not Found") }

        var start: UInt64 = 0
        var end: UInt64 = size > 0 ? size - 1 : 0
        var partial = false
        if let range = headers["range"], let r = Self.parseRange(range, size: size) {
            (start, end, partial) = (r.lowerBound, r.upperBound, true)
        } else if headers["range"] != nil {
            try? handle.close()
            return finish(connection, status: "416 Range Not Satisfiable", extra: "Content-Range: bytes */\(size)\r\n")
        }

        let length = size == 0 ? 0 : end - start + 1
        var response = "HTTP/1.1 \(partial ? "206 Partial Content" : "200 OK")\r\n"
        response += "Content-Type: \(Self.mimeType(for: file))\r\n"
        response += "Content-Length: \(length)\r\n"
        response += "Accept-Ranges: bytes\r\n"
        if partial { response += "Content-Range: bytes \(start)-\(end)/\(size)\r\n" }
        response += "transferMode.dlna.org: Streaming\r\n"
        response += "contentFeatures.dlna.org: \(Self.dlnaFeatures)\r\n"
        response += "Connection: close\r\n\r\n"

        connection.send(content: Data(response.utf8), completion: .contentProcessed { error in
            guard error == nil, method == "GET", length > 0 else {
                try? handle.close()
                connection.cancel()
                return
            }
            do { try handle.seek(toOffset: start) } catch { try? handle.close(); connection.cancel(); return }
            Self.streamBody(connection, handle: handle, remaining: length)
        })
    }

    private static func streamBody(_ connection: NWConnection, handle: FileHandle, remaining: UInt64) {
        let chunk = (try? handle.read(upToCount: Int(min(remaining, 512 * 1024)))) ?? Data()
        guard !chunk.isEmpty else {
            try? handle.close()
            connection.cancel()
            return
        }
        let left = remaining - UInt64(chunk.count)
        connection.send(content: chunk, completion: .contentProcessed { error in
            if error != nil || left == 0 {
                try? handle.close()
                // Let the last bytes drain before closing.
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            streamBody(connection, handle: handle, remaining: left)
        })
    }

    private func finish(_ connection: NWConnection, status: String, extra: String = "") {
        let response = "HTTP/1.1 \(status)\r\n\(extra)Content-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8), contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Parses `bytes=start-end`, `bytes=start-` and `bytes=-suffix`.
    static func parseRange(_ header: String, size: UInt64) -> ClosedRange<UInt64>? {
        guard size > 0, header.hasPrefix("bytes=") else { return nil }
        let spec = header.dropFirst(6).split(separator: ",").first ?? ""
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let a = parts[0].trimmingCharacters(in: .whitespaces)
        let b = parts[1].trimmingCharacters(in: .whitespaces)
        if a.isEmpty {
            guard let suffix = UInt64(b), suffix > 0 else { return nil }
            return (size - min(suffix, size))...(size - 1)
        }
        guard let start = UInt64(a), start < size else { return nil }
        let end = UInt64(b).map { min($0, size - 1) } ?? size - 1
        guard end >= start else { return nil }
        return start...end
    }
}

/// Mutable state shared with callbacks that run on a single serial queue.
final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
