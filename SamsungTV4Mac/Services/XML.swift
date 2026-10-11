import Foundation

/// Flattens an XML document into `[localName: text]` for leaf elements.
/// Good enough for SOAP responses, where every interesting value is a uniquely named leaf.
final class XMLLeafParser: NSObject, XMLParserDelegate {
    private var values: [String: String] = [:]
    private var text = ""

    static func parse(_ data: Data) -> [String: String] {
        let delegate = XMLLeafParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.parse()
        return delegate.values
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if values[elementName] == nil || !value.isEmpty {
            values[elementName] = value
        }
        text = ""
    }
}

/// Parses a UPnP device description (`LOCATION` document).
final class DeviceDescriptionParser: NSObject, XMLParserDelegate {
    struct Service { var type: String; var controlURL: String }

    private(set) var friendlyName: String?
    private(set) var modelName: String?
    private(set) var manufacturer: String?
    private(set) var udn: String?
    private(set) var urlBase: String?
    private(set) var services: [Service] = []

    private var text = ""
    private var pendingType: String?
    private var pendingControl: String?

    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = self
        return parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
        if elementName == "service" { pendingType = nil; pendingControl = nil }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only the first occurrence belongs to the root device; embedded devices come later.
        switch elementName {
        case "friendlyName" where friendlyName == nil: friendlyName = value
        case "modelName" where modelName == nil: modelName = value
        case "manufacturer" where manufacturer == nil: manufacturer = value
        case "UDN" where udn == nil: udn = value
        case "URLBase": urlBase = value
        case "serviceType": pendingType = value
        case "controlURL": pendingControl = value
        case "service":
            if let t = pendingType, let c = pendingControl { services.append(Service(type: t, controlURL: c)) }
        default: break
        }
        text = ""
    }
}
