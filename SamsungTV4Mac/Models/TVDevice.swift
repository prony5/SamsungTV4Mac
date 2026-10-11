import Foundation

/// A DLNA/UPnP media renderer (Samsung TV or any other device with an AVTransport service).
struct TVDevice: Identifiable, Hashable, Codable {
    /// UPnP UDN — stable across restarts and IP changes.
    let id: String
    var name: String
    var model: String?
    var manufacturer: String?
    var location: URL
    var avTransportURL: URL
    var renderingControlURL: URL?

    var host: String { location.host ?? "" }

    /// Samsung prefixes renderer names with "[TV] ".
    var displayName: String {
        name.hasPrefix("[TV] ") ? String(name.dropFirst(5)) : name
    }
}
