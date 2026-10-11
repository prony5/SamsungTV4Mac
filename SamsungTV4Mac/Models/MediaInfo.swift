import Foundation

/// Result of `ffprobe -show_format -show_streams`.
struct MediaInfo: Decodable {
    struct Stream: Decodable {
        struct Disposition: Decodable {
            let attachedPic: Int?
        }

        let index: Int
        let codecType: String?
        let codecName: String?
        let codecTagString: String?
        let profile: String?
        let pixFmt: String?
        let width: Int?
        let height: Int?
        let channels: Int?
        let avgFrameRate: String?
        let disposition: Disposition?
        let tags: [String: String]?

        var codec: String { codecName ?? "unknown" }

        var fps: Double? {
            guard let parts = avgFrameRate?.split(separator: "/"), parts.count == 2,
                  let n = Double(parts[0]), let d = Double(parts[1]), d > 0, n > 0 else { return nil }
            return n / d
        }

        /// Human readable codec name, e.g. "MPEG4 (XVID)".
        var displayCodec: String {
            var s = codec.uppercased()
            if let tag = codecTagString?.trimmingCharacters(in: .whitespaces),
               tag.count == 4, tag.allSatisfy({ $0.isLetter || $0.isNumber }),
               tag.uppercased() != s {
                s += " (\(tag.uppercased()))"
            }
            return s
        }
    }

    struct Format: Decodable {
        let formatName: String?
        let duration: String?
        let size: String?
    }

    let streams: [Stream]
    let format: Format

    var duration: Double { Double(format.duration ?? "") ?? 0 }
    var size: Int64 { Int64(format.size ?? "") ?? 0 }

    var video: Stream? {
        streams.first { $0.codecType == "video" && $0.disposition?.attachedPic != 1 }
    }
    var audio: [Stream] { streams.filter { $0.codecType == "audio" } }
    /// Text subtitles that can be carried over into Matroska.
    var textSubtitles: [Stream] {
        streams.filter { $0.codecType == "subtitle" && ["subrip", "ass", "ssa", "mov_text"].contains($0.codec) }
    }
}

/// What has to happen to a file before a Samsung (Tizen) TV can play it.
struct PlaybackPlan {
    var remux = false
    var transcodeVideo = false
    /// Audio stream indexes that must be re-encoded.
    var transcodeAudio: Set<Int> = []
    var notes: [String] = []

    var direct: Bool { !remux && !transcodeVideo && transcodeAudio.isEmpty }

    // Conservative set of formats supported by Samsung Tizen TVs (2016+).
    // Xvid/DivX (mpeg4) and DTS are notably missing on 2018+ models.
    static let videoCodecs: Set<String> = ["h264", "hevc", "vp9", "mpeg2video"]
    static let audioCodecs: Set<String> = ["aac", "ac3", "eac3", "mp3"]

    init(media: MediaInfo, fileExtension: String) {
        let format = media.format.formatName ?? ""
        let containerOK = ["mp4", "matroska", "webm", "mpegts"].contains { format.contains($0) }

        if let v = media.video {
            let tenBitH264 = v.codec == "h264" && (v.pixFmt ?? "").contains("10")
            if !Self.videoCodecs.contains(v.codec) || tenBitH264 {
                transcodeVideo = true
                notes.append(String(format: NSLocalizedString("Video %@ → H.264", comment: ""), v.displayCodec))
            }
        }
        for a in media.audio where !Self.audioCodecs.contains(a.codec) {
            transcodeAudio.insert(a.index)
            notes.append(String(format: NSLocalizedString("Audio %@ → AC3", comment: ""), a.displayCodec))
        }
        if !containerOK {
            remux = true
            notes.append(String(format: NSLocalizedString("Container %@ → MKV", comment: ""), fileExtension.uppercased()))
        }
    }
}
