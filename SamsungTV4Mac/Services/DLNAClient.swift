import Foundation

struct UPnPError: LocalizedError {
    let code: Int?
    let message: String

    var errorDescription: String? {
        if let code { return "UPnP \(code): \(message)" }
        return message
    }
}

enum DeviceError: LocalizedError {
    case badDescription
    case notRenderer

    var errorDescription: String? {
        switch self {
        case .badDescription: return NSLocalizedString("The device returned an invalid description.", comment: "")
        case .notRenderer: return NSLocalizedString("The device is not a DLNA media renderer.", comment: "")
        }
    }
}

enum DeviceDescription {
    /// Default DLNA renderer endpoint of Samsung Tizen TVs.
    static func samsungLocation(for host: String) -> URL? {
        URL(string: "http://\(host):9197/dmr")
    }

    static func load(_ location: URL) async throws -> TVDevice {
        let request = URLRequest(url: location, timeoutInterval: 4)
        let (data, _) = try await URLSession.shared.data(for: request)
        let parser = DeviceDescriptionParser()
        guard parser.parse(data) else { throw DeviceError.badDescription }

        let base = parser.urlBase.flatMap { URL(string: $0) } ?? location
        func resolve(_ prefix: String) -> URL? {
            guard let s = parser.services.first(where: { $0.type.hasPrefix(prefix) }) else { return nil }
            return URL(string: s.controlURL, relativeTo: base)?.absoluteURL
        }
        guard let avTransport = resolve("urn:schemas-upnp-org:service:AVTransport") else {
            throw DeviceError.notRenderer
        }
        return TVDevice(
            id: parser.udn ?? location.absoluteString,
            name: parser.friendlyName ?? location.host ?? "TV",
            model: parser.modelName,
            manufacturer: parser.manufacturer,
            location: location,
            avTransportURL: avTransport,
            renderingControlURL: resolve("urn:schemas-upnp-org:service:RenderingControl")
        )
    }
}

/// UPnP AVTransport / RenderingControl client.
struct DLNAClient {
    static let avTransport = "urn:schemas-upnp-org:service:AVTransport:1"
    static let renderingControl = "urn:schemas-upnp-org:service:RenderingControl:1"

    let device: TVDevice

    struct TransportInfo { let state: String; let status: String }
    struct PositionInfo { let position: Double?; let duration: Double? }

    func setURI(_ url: URL, title: String, mimeType: String) async throws {
        let didl = """
        <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" \
        xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"><item id="1" parentID="0" restricted="1">\
        <dc:title>\(Self.escape(title))</dc:title><upnp:class>object.item.videoItem</upnp:class>\
        <res protocolInfo="http-get:*:\(mimeType):\(MediaServer.dlnaFeatures)">\(Self.escape(url.absoluteString))</res>\
        </item></DIDL-Lite>
        """
        try await transport("SetAVTransportURI", ["CurrentURI": url.absoluteString, "CurrentURIMetaData": didl])
    }

    func play() async throws { try await transport("Play", ["Speed": "1"]) }
    func pause() async throws { try await transport("Pause") }
    func stop() async throws { try await transport("Stop") }

    func seek(to seconds: Double) async throws {
        try await transport("Seek", ["Unit": "REL_TIME", "Target": Self.formatTime(seconds)])
    }

    func transportInfo() async throws -> TransportInfo {
        let r = try await transport("GetTransportInfo")
        return TransportInfo(state: r["CurrentTransportState"] ?? "", status: r["CurrentTransportStatus"] ?? "")
    }

    func positionInfo() async throws -> PositionInfo {
        let r = try await transport("GetPositionInfo")
        return PositionInfo(position: Self.parseTime(r["RelTime"]), duration: Self.parseTime(r["TrackDuration"]))
    }

    func volume() async throws -> Int? {
        guard let url = device.renderingControlURL else { return nil }
        let r = try await Self.call(url, service: Self.renderingControl, action: "GetVolume",
                                    args: [("InstanceID", "0"), ("Channel", "Master")])
        return Int(r["CurrentVolume"] ?? "")
    }

    func setVolume(_ value: Int) async throws {
        guard let url = device.renderingControlURL else { return }
        try await Self.call(url, service: Self.renderingControl, action: "SetVolume",
                            args: [("InstanceID", "0"), ("Channel", "Master"), ("DesiredVolume", String(value))])
    }

    // MARK: - SOAP

    @discardableResult
    private func transport(_ action: String, _ args: KeyValuePairs<String, String> = [:]) async throws -> [String: String] {
        try await Self.call(device.avTransportURL, service: Self.avTransport, action: action,
                            args: [("InstanceID", "0")] + args.map { ($0.key, $0.value) })
    }

    @discardableResult
    static func call(_ url: URL, service: String, action: String, args: [(String, String)]) async throws -> [String: String] {
        let argsXML = args.map { "<\($0.0)>\(escape($0.1))</\($0.0)>" }.joined()
        let body = """
        <?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:\(action) xmlns:u="\(service)">\
        \(argsXML)</u:\(action)></s:Body></s:Envelope>
        """
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(body.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let values = XMLLeafParser.parse(data)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UPnPError(code: Int(values["errorCode"] ?? ""),
                            message: values["errorDescription"] ?? "\(action): HTTP \(http.statusCode)")
        }
        return values
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static func formatTime(_ seconds: Double) -> String {
        let t = max(0, Int(seconds))
        return String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
    }

    /// Parses "H:MM:SS(.fff)"; returns nil for "NOT_IMPLEMENTED" and similar.
    static func parseTime(_ s: String?) -> Double? {
        guard let parts = s?.split(separator: ":"), parts.count == 3,
              let h = Double(parts[0]), let m = Double(parts[1]), let sec = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + sec
    }
}
