import CryptoKit
import Foundation

enum MediaToolError: LocalizedError {
    case notFound(String)
    case probeFailed(String)
    case convertFailed(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let tool):
            return String(format: NSLocalizedString("%@ not found. Install it with: brew install ffmpeg", comment: ""), tool)
        case .probeFailed(let msg):
            return String(format: NSLocalizedString("Could not read the file: %@", comment: ""), msg)
        case .convertFailed(let msg):
            return String(format: NSLocalizedString("Conversion failed: %@", comment: ""), msg)
        }
    }
}

/// Wrappers around the ffprobe / ffmpeg command line tools.
enum MediaTools {
    /// GUI apps don't inherit the shell PATH, so look in the usual places.
    static func find(_ name: String) -> URL? {
        var dirs: [String] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin").path { dirs.append(bundled) }
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
        dirs += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return dirs.lazy
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var isFFmpegInstalled: Bool { find("ffmpeg") != nil && find("ffprobe") != nil }

    static func probe(_ file: URL) async throws -> MediaInfo {
        guard let ffprobe = find("ffprobe") else { throw MediaToolError.notFound("ffprobe") }
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = ffprobe
            process.arguments = ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", file.path]
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw MediaToolError.probeFailed(String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(MediaInfo.self, from: data)
        }.value
    }

    // MARK: - Conversion

    static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SamsungTV4Mac", isDirectory: true)
    }

    /// Converted file location, keyed by source path + size + modification date.
    static func cachedURL(for source: URL) -> URL {
        let attrs = try? FileManager.default.attributesOfItem(atPath: source.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let digest = SHA256.hash(data: Data("\(source.path)|\(size)|\(mtime)".utf8))
        let key = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent("\(key).mkv")
    }

    static func cacheSize() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    static func clearCache() {
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    static func ffmpegArguments(input: URL, output: URL, media: MediaInfo, plan: PlaybackPlan) -> [String] {
        var args = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-nostats", "-progress", "pipe:1",
                    "-fflags", "+genpts", "-i", input.path]

        if let v = media.video {
            args += ["-map", "0:\(v.index)"]
            if plan.transcodeVideo {
                // ~0.2 bits per pixel is plenty for hardware H.264; clamp to sane limits.
                let pixels = Double((v.width ?? 1280) * (v.height ?? 720))
                let bitrate = Int(min(25_000_000, max(2_500_000, pixels * (v.fps ?? 25) * 0.2)))
                args += ["-c:v", "h264_videotoolbox", "-b:v", "\(bitrate)", "-profile:v", "high", "-pix_fmt", "yuv420p"]
            } else {
                args += ["-c:v", "copy"]
            }
        }

        for (i, a) in media.audio.enumerated() {
            args += ["-map", "0:\(a.index)"]
            if plan.transcodeAudio.contains(a.index) {
                let channels = a.channels ?? 2
                args += ["-c:a:\(i)", "ac3", "-b:a:\(i)", channels > 2 ? "448k" : "192k"]
                if channels > 6 { args += ["-ac:a:\(i)", "6"] }
            } else {
                args += ["-c:a:\(i)", "copy"]
            }
        }

        for (i, s) in media.textSubtitles.enumerated() {
            args += ["-map", "0:\(s.index)", "-c:s:\(i)", s.codec == "mov_text" ? "srt" : "copy"]
        }

        args += ["-max_muxing_queue_size", "4096", "-f", "matroska", output.path]
        return args
    }

    /// Converts `source` into a TV-friendly MKV in the cache and returns its URL.
    /// Cancelling the calling task terminates ffmpeg.
    static func convert(_ source: URL, media: MediaInfo, plan: PlaybackPlan,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let output = cachedURL(for: source)
        if FileManager.default.fileExists(atPath: output.path) { return output }
        guard let ffmpeg = find("ffmpeg") else { throw MediaToolError.notFound("ffmpeg") }

        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let partial = output.appendingPathExtension("part")
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ffmpegArguments(input: source, output: partial, media: media, plan: plan)
        process.standardInput = FileHandle.nullDevice

        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let duration = media.duration
        let lineBuffer = Box("")
        stdout.fileHandleForReading.readabilityHandler = { handle in
            lineBuffer.value += String(decoding: handle.availableData, as: UTF8.self)
            while let newline = lineBuffer.value.firstIndex(of: "\n") {
                let line = lineBuffer.value[..<newline]
                lineBuffer.value.removeSubrange(...newline)
                if line.hasPrefix("out_time_us="), let us = Double(line.dropFirst(12)), duration > 0 {
                    progress(min(1, max(0, us / 1_000_000 / duration)))
                }
            }
        }
        let errLock = NSLock()
        let errData = Box(Data())
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            errLock.withLock {
                errData.value.append(chunk)
                if errData.value.count > 16_384 { errData.value = errData.value.suffix(8_192) }
            }
        }

        do {
            try Task.checkCancellation()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    process.terminationHandler = { p in
                        stdout.fileHandleForReading.readabilityHandler = nil
                        stderr.fileHandleForReading.readabilityHandler = nil
                        if p.terminationReason == .uncaughtSignal {
                            cont.resume(throwing: CancellationError())
                        } else if p.terminationStatus != 0 {
                            let msg = errLock.withLock { String(decoding: errData.value, as: UTF8.self) }
                            let lastLine = msg.split(separator: "\n").last.map(String.init) ?? "exit code \(p.terminationStatus)"
                            cont.resume(throwing: MediaToolError.convertFailed(lastLine))
                        } else {
                            cont.resume()
                        }
                    }
                    do { try process.run() } catch { cont.resume(throwing: error) }
                }
            } onCancel: {
                // terminate() raises if the process was never launched.
                if process.isRunning { process.terminate() }
            }
            try FileManager.default.moveItem(at: partial, to: output)
            progress(1)
            return output
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }
}
