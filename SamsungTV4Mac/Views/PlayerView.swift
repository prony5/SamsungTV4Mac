import SwiftUI

struct PlayerView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 18) {
            if !model.ffmpegInstalled {
                FFmpegBanner()
            }

            if let url = model.mediaURL {
                FileCard(url: url)
            } else {
                DropZone(isTargeted: isDropTargeted)
            }

            ActionArea()

            Spacer(minLength: 0)

            if model.cacheSize > 0 {
                HStack {
                    Spacer()
                    Text("Converted files cache: \(ByteCountFormatter.string(fromByteCount: model.cacheSize, countStyle: .file))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Clear") { model.clearCache() }
                        .controlSize(.small)
                        .disabled(model.isBusy || model.phase == .playing)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: \.isFileURL) else { return false }
            model.openFile(url)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .navigationTitle(model.selectedDevice?.displayName ?? "SamsungTV4Mac")
    }
}

private struct DropZone: View {
    @EnvironmentObject private var model: AppModel
    let isTargeted: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "film.stack")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
            Text("Drop a video file here")
                .font(.title3)
            Button("Choose File…") { model.chooseFile() }
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
        }
        .background(isTargeted ? Color.accentColor.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct FileCard: View {
    @EnvironmentObject private var model: AppModel
    let url: URL

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 6) {
                Text(url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(2)
                    .textSelection(.enabled)

                if let media = model.media {
                    Text(summary(media))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if let plan = model.plan {
                        CompatibilityBadge(plan: plan)
                    }
                } else if model.phase == .probing {
                    ProgressView("Analyzing file…")
                        .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
            Button("Choose Another…") { model.chooseFile() }
                .disabled(model.isBusy)
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }

    private func summary(_ media: MediaInfo) -> String {
        var parts: [String] = []
        if media.duration > 0 { parts.append(formatTime(media.duration)) }
        if media.size > 0 { parts.append(ByteCountFormatter.string(fromByteCount: media.size, countStyle: .file)) }
        if let v = media.video {
            var s = v.displayCodec
            if let w = v.width, let h = v.height { s += " \(w)×\(h)" }
            parts.append(s)
        }
        for a in media.audio.prefix(3) {
            var s = a.displayCodec
            if let ch = a.channels { s += ch == 6 ? " 5.1" : ch == 8 ? " 7.1" : " \(ch)ch" }
            if let lang = a.tags?["language"], lang != "und" { s += " \(lang)" }
            parts.append(s)
        }
        return parts.joined(separator: " · ")
    }
}

private struct CompatibilityBadge: View {
    let plan: PlaybackPlan

    var body: some View {
        if plan.direct {
            Label("Plays on the TV as is", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Label("Will be converted for the TV", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
                    .font(.callout)
                Text(plan.notes.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ActionArea: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            switch model.phase {
            case .converting(let progress):
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: progress) {
                        Text("Converting for the TV… \(Int(progress * 100))%")
                    }
                    HStack {
                        Text("Uses the hardware encoder; usually 50–100× faster than real time.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { model.cancel() }
                    }
                }
            case .starting:
                ProgressView("Starting playback on the TV…")
            case .playing:
                PlaybackControls()
            case .failed(let message):
                VStack(spacing: 12) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    PlayButton()
                }
            case .idle, .probing:
                PlayButton()
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct PlayButton: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button { model.play() } label: {
            Label(title, systemImage: "play.tv.fill")
                .frame(minWidth: 220)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(model.mediaURL == nil || model.selectedDevice == nil || model.phase == .probing)
    }

    private var title: String {
        guard let device = model.selectedDevice else { return NSLocalizedString("Select a TV", comment: "") }
        return String(format: NSLocalizedString("Play on %@", comment: ""), device.displayName)
    }
}

private struct PlaybackControls: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(Color.accentColor)
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Text(formatTime(model.position))
                    .monospacedDigit()
                    .frame(width: 64, alignment: .trailing)
                Slider(value: $model.position, in: 0...max(model.duration, 1)) { editing in
                    model.isSeeking = editing
                    if !editing { model.seek(to: model.position) }
                }
                Text(formatTime(model.duration))
                    .monospacedDigit()
                    .frame(width: 64, alignment: .leading)
            }

            HStack(spacing: 22) {
                Button { model.seek(by: -30) } label: { Image(systemName: "gobackward.30") }
                    .help("Back 30 seconds")
                Button { model.togglePause() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 28)
                }
                .keyboardShortcut(.space, modifiers: [])
                .help(model.isPlaying ? Text("Pause") : Text("Play"))
                Button { model.seek(by: 30) } label: { Image(systemName: "goforward.30") }
                    .help("Forward 30 seconds")
                Button { model.stop() } label: { Image(systemName: "stop.fill") }
                    .help("Stop")
            }
            .font(.title2)
            .buttonStyle(.borderless)

            if model.volumeAvailable {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: $model.volume, in: 0...100) { editing in
                        if !editing { model.commitVolume() }
                    }
                    .frame(width: 180)
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }

    private var status: String {
        let name = model.playingDevice?.displayName ?? ""
        switch model.transportState {
        case "PLAYING": return String(format: NSLocalizedString("Playing on %@", comment: ""), name)
        case "PAUSED_PLAYBACK": return String(format: NSLocalizedString("Paused on %@", comment: ""), name)
        default: return String(format: NSLocalizedString("Loading on %@…", comment: ""), name)
        }
    }
}

private struct FFmpegBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 4) {
                Text("ffmpeg is not installed")
                    .font(.headline)
                Text("Without it, files are sent to the TV as is and unsupported formats can't be converted. Install it with Homebrew:")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: "brew install ffmpeg")
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

func formatTime(_ seconds: Double) -> String {
    let t = max(0, Int(seconds.isFinite ? seconds : 0))
    return t >= 3600
        ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
        : String(format: "%d:%02d", t / 60, t % 60)
}
