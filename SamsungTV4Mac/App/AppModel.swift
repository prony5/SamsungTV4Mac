import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum Phase: Equatable {
        case idle
        case probing
        case converting(Double)
        case starting
        case playing
        case failed(String)
    }

    // Devices
    @Published private(set) var devices: [TVDevice] = []
    @Published var selectedDeviceID: TVDevice.ID? {
        didSet { UserDefaults.standard.set(selectedDeviceID, forKey: Keys.selectedDevice) }
    }
    @Published private(set) var isScanning = false

    // Media
    @Published private(set) var mediaURL: URL?
    @Published private(set) var media: MediaInfo?
    @Published private(set) var plan: PlaybackPlan?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var ffmpegInstalled = MediaTools.isFFmpegInstalled
    @Published private(set) var cacheSize: Int64 = MediaTools.cacheSize()

    // Playback
    @Published private(set) var transportState = ""
    @Published private(set) var playingDevice: TVDevice?
    @Published var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var volume: Double = 0
    @Published private(set) var volumeAvailable = false
    var isSeeking = false

    private enum Keys {
        static let manualDevices = "manualDevices"
        static let selectedDevice = "selectedDeviceID"
    }

    private let server = MediaServer()
    private var manualDevices: [TVDevice] = []
    private var discoveredDevices: [TVDevice] = []
    private var client: DLNAClient?
    private var workTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var sleepActivity: NSObjectProtocol?

    init() {
        if let data = UserDefaults.standard.data(forKey: Keys.manualDevices),
           let saved = try? JSONDecoder().decode([TVDevice].self, from: data) {
            manualDevices = saved
        }
        selectedDeviceID = UserDefaults.standard.string(forKey: Keys.selectedDevice)
        rebuildDeviceList()
    }

    var selectedDevice: TVDevice? { devices.first { $0.id == selectedDeviceID } }
    var isPlaying: Bool { transportState == "PLAYING" }
    var isBusy: Bool {
        switch phase {
        case .probing, .converting, .starting: return true
        default: return false
        }
    }

    // MARK: - Devices

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        Task {
            let locations = await SSDP.search()
            var found: [TVDevice] = []
            await withTaskGroup(of: TVDevice?.self) { group in
                for location in locations {
                    group.addTask { try? await DeviceDescription.load(location) }
                }
                for await device in group {
                    if let device { found.append(device) }
                }
            }
            // Refresh manually added TVs too: their IP may still be valid while multicast is blocked.
            for device in manualDevices where !found.contains(where: { $0.id == device.id }) {
                if let fresh = try? await DeviceDescription.load(device.location) { found.append(fresh) }
            }
            discoveredDevices = found
            rebuildDeviceList()
            isScanning = false
        }
    }

    /// Adds a TV by IP address (Samsung default endpoint) or by a full description URL.
    func addDevice(address: String) async throws {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let location = trimmed.lowercased().hasPrefix("http")
            ? URL(string: trimmed)
            : DeviceDescription.samsungLocation(for: trimmed)
        guard let location else { throw DeviceError.badDescription }
        let device = try await DeviceDescription.load(location)
        manualDevices.removeAll { $0.id == device.id }
        manualDevices.append(device)
        saveManualDevices()
        rebuildDeviceList()
        selectedDeviceID = device.id
    }

    func isManual(_ device: TVDevice) -> Bool {
        manualDevices.contains { $0.id == device.id }
    }

    func removeDevice(_ device: TVDevice) {
        manualDevices.removeAll { $0.id == device.id }
        discoveredDevices.removeAll { $0.id == device.id }
        saveManualDevices()
        rebuildDeviceList()
    }

    private func rebuildDeviceList() {
        var list = discoveredDevices
        for device in manualDevices where !list.contains(where: { $0.id == device.id }) {
            list.append(device)
        }
        devices = list.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        if selectedDevice == nil { selectedDeviceID = devices.first?.id }
    }

    private func saveManualDevices() {
        if let data = try? JSONEncoder().encode(manualDevices) {
            UserDefaults.standard.set(data, forKey: Keys.manualDevices)
        }
    }

    // MARK: - Media

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .audiovisualContent]
            + ["mkv", "avi", "ts", "m2ts", "webm", "wmv", "flv"].compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK, let url = panel.url { openFile(url) }
    }

    func openFile(_ url: URL) {
        workTask?.cancel()
        mediaURL = url
        media = nil
        plan = nil
        ffmpegInstalled = MediaTools.isFFmpegInstalled
        guard ffmpegInstalled else {
            // Without ffprobe we can only try to stream the file as is.
            phase = .idle
            return
        }
        phase = .probing
        workTask = Task {
            do {
                let info = try await MediaTools.probe(url)
                guard mediaURL == url else { return }
                media = info
                plan = PlaybackPlan(media: info, fileExtension: url.pathExtension)
                phase = .idle
            } catch {
                guard mediaURL == url else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Playback

    func play() {
        guard let device = selectedDevice, let source = mediaURL else { return }
        workTask?.cancel()
        workTask = Task {
            do {
                var file = source
                if let plan, let media, !plan.direct {
                    phase = .converting(0)
                    file = try await MediaTools.convert(source, media: media, plan: plan) { value in
                        Task { @MainActor in
                            if case .converting = AppModel.shared.phase { AppModel.shared.phase = .converting(value) }
                        }
                    }
                    cacheSize = MediaTools.cacheSize()
                }
                try Task.checkCancellation()
                phase = .starting
                try await startPlayback(of: file, title: source.deletingPathExtension().lastPathComponent, on: device)
            } catch is CancellationError {
                phase = .idle
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func startPlayback(of file: URL, title: String, on device: TVDevice) async throws {
        let port = try await server.start()
        guard let ip = Net.localAddress(toward: device.host) else {
            throw UPnPError(code: nil, message: NSLocalizedString("Could not determine this Mac's address on the TV's network.", comment: ""))
        }
        let path = server.publish(file)
        guard let url = URL(string: "http://\(ip):\(port)\(path)") else { return }

        stopPolling()
        let client = DLNAClient(device: device)
        self.client = client
        try? await client.stop()
        try await client.setURI(url, title: title, mimeType: MediaServer.mimeType(for: file))

        // Samsung needs a moment after SetAVTransportURI before it accepts Play.
        var attempt = 0
        while true {
            try await Task.sleep(nanoseconds: 700_000_000)
            do { try await client.play(); break } catch {
                attempt += 1
                if attempt >= 5 { throw error }
            }
        }

        playingDevice = device
        position = 0
        duration = media?.duration ?? 0
        transportState = "TRANSITIONING"
        phase = .playing
        if let v = try? await client.volume() {
            volume = Double(v)
            volumeAvailable = true
        } else {
            volumeAvailable = false
        }
        beginPreventingSleep()
        startPolling(client)
    }

    func togglePause() {
        guard let client else { return }
        let wasPlaying = isPlaying
        transportState = wasPlaying ? "PAUSED_PLAYBACK" : "PLAYING"
        Task {
            do {
                if wasPlaying { try await client.pause() } else { try await client.play() }
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func seek(to seconds: Double) {
        guard let client else { return }
        let target = max(0, duration > 0 ? min(seconds, duration - 1) : seconds)
        position = target
        Task { try? await client.seek(to: target) }
    }

    func seek(by delta: Double) { seek(to: position + delta) }

    func commitVolume() {
        guard let client else { return }
        let value = Int(volume.rounded())
        Task { try? await client.setVolume(value) }
    }

    func stop() {
        workTask?.cancel()
        let client = self.client
        stopPolling()
        endPlaybackSession()
        phase = .idle
        Task { try? await client?.stop() }
    }

    /// Cancels probing or conversion.
    func cancel() {
        workTask?.cancel()
        phase = .idle
    }

    func clearCache() {
        MediaTools.clearCache()
        cacheSize = MediaTools.cacheSize()
    }

    private func startPolling(_ client: DLNAClient) {
        pollTask = Task {
            var sawPlayback = false
            var stoppedTicks = 0
            while !Task.isCancelled {
                if let info = try? await client.transportInfo() {
                    if info.status == "ERROR_OCCURRED" {
                        phase = .failed(NSLocalizedString("The TV could not play this file (unsupported format?).", comment: ""))
                        endPlaybackSession()
                        return
                    }
                    transportState = info.state
                    if ["PLAYING", "PAUSED_PLAYBACK"].contains(info.state) { sawPlayback = true }
                    if sawPlayback, ["STOPPED", "NO_MEDIA_PRESENT"].contains(info.state) {
                        stoppedTicks += 1
                        if stoppedTicks >= 3 {
                            // Finished, or stopped with the TV remote.
                            phase = .idle
                            endPlaybackSession()
                            return
                        }
                    } else {
                        stoppedTicks = 0
                    }
                }
                if let pos = try? await client.positionInfo(), !isSeeking {
                    if let p = pos.position { position = p }
                    if let d = pos.duration, d > 0 { duration = d }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func endPlaybackSession() {
        transportState = ""
        playingDevice = nil
        client = nil
        endPreventingSleep()
    }

    // The TV streams from this Mac, so it must not fall asleep mid-movie.
    private func beginPreventingSleep() {
        guard sleepActivity == nil else { return }
        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated],
            reason: "Streaming video to TV")
    }

    private func endPreventingSleep() {
        if let activity = sleepActivity { ProcessInfo.processInfo.endActivity(activity) }
        sleepActivity = nil
    }
}
