// BetterSonos: A native SwiftUI client for the node-sonos-http-api.
// Copyright (C) 2025 Andrew Levy
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.
//
//  SonosSOAP.swift
//
//  The UPnP control protocol Sonos speakers serve on port 1400.

import Foundation

public enum SonosSOAP {
    public struct Service: Sendable {
        public let path: String
        public let urn: String
    }

    public static let avTransport = Service(path: "/MediaRenderer/AVTransport/Control", urn: "urn:schemas-upnp-org:service:AVTransport:1")
    public static let renderingControl = Service(path: "/MediaRenderer/RenderingControl/Control", urn: "urn:schemas-upnp-org:service:RenderingControl:1")
    public static let groupRenderingControl = Service(path: "/MediaRenderer/GroupRenderingControl/Control", urn: "urn:schemas-upnp-org:service:GroupRenderingControl:1")
    public static let zoneGroupTopology = Service(path: "/ZoneGroupTopology/Control", urn: "urn:schemas-upnp-org:service:ZoneGroupTopology:1")
    public static let contentDirectory = Service(path: "/MediaServer/ContentDirectory/Control", urn: "urn:schemas-upnp-org:service:ContentDirectory:1")

    public enum SOAPError: Error {
        case badAddress(String)
        case fault(Int)
        case malformed
    }

    /// Short timeouts: speakers on the local network answer in milliseconds, and an unreachable
    /// address should fail fast so another speaker can be tried.
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// Calls an action on a speaker ("192.168.1.20:1400") and returns the response's arguments by name.
    public static func call(_ host: String, _ service: Service, _ action: String, _ arguments: [(String, String)] = []) async throws -> [String: String] {
        guard let url = URL(string: "http://\(host)\(service.path)") else { throw SOAPError.badAddress(host) }
        let args = arguments.map { "<\($0.0)>\(escape($0.1))</\($0.0)>" }.joined()
        let body = """
        <?xml version="1.0" encoding="utf-8"?>\
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\
        <s:Body><u:\(action) xmlns:u="\(service.urn)">\(args)</u:\(action)></s:Body></s:Envelope>
        """
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service.urn)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(body.utf8)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw SOAPError.fault(http.statusCode)
        }
        return try LeafCollector.collect(data)
    }

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Layout

    public struct Topology: Sendable, Equatable {
        public struct Member: Sendable, Equatable {
            public let uuid: String
            public let host: String
            public let roomName: String
            /// The hidden half of a stereo pair, or a home-theater satellite: not a room of its own.
            public let isInvisible: Bool
            /// A Bridge or Boost: on the network but not a speaker.
            public let isBridge: Bool
            public var isRoom: Bool { !isInvisible && !isBridge }
        }
        public struct Group: Sendable, Equatable {
            public let coordinator: String
            public let members: [Member]
        }
        public let groups: [Group]

        /// Every speaker's address, including hidden ones, for refreshing the cache.
        public var addresses: [String: String] {
            var result: [String: String] = [:]
            for member in groups.flatMap(\.members) { result[member.uuid] = member.host }
            return result
        }
    }

    /// Parses the XML inside ZoneGroupTopology's `ZoneGroupState` result.
    public static func parseTopology(_ zoneGroupState: String) throws -> Topology {
        let parser = TopologyParser()
        let xml = XMLParser(data: Data(zoneGroupState.utf8))
        xml.delegate = parser
        guard xml.parse() else { throw SOAPError.malformed }
        return Topology(groups: parser.groups)
    }

    /// The first `dc:title` in a DIDL-Lite metadata string, such as a station or service name.
    public static func didlTitle(_ metadata: String?) -> String? {
        guard let metadata, metadata.contains("<"), metadata != "NOT_IMPLEMENTED" else { return nil }
        return DIDLTitles.parse(metadata).first
    }

    /// Every item `dc:title` in a DIDL-Lite result, such as a favorites browse.
    public static func didlTitles(_ metadata: String) -> [String] {
        DIDLTitles.parse(metadata)
    }

    /// "http://192.168.1.20:1400/xml/device_description.xml" → "192.168.1.20:1400"
    public static func host(fromLocation location: String) -> String? {
        guard let url = URL(string: location), let host = url.host else { return nil }
        return "\(host):\(url.port ?? 1400)"
    }
}

// MARK: - XML helpers

/// Collects the text of every leaf element, keyed by local name. SOAP response arguments are leaves.
private final class LeafCollector: NSObject, XMLParserDelegate {
    private var values: [String: String] = [:]
    private var text = ""
    private var depthWithChildren: [Bool] = []

    static func collect(_ data: Data) throws -> [String: String] {
        let collector = LeafCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        guard parser.parse() else { throw SonosSOAP.SOAPError.malformed }
        return collector.values
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if !depthWithChildren.isEmpty { depthWithChildren[depthWithChildren.count - 1] = true }
        depthWithChildren.append(false)
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let hadChildren = depthWithChildren.popLast() ?? false
        if !hadChildren {
            let local = name.split(separator: ":").last.map(String.init) ?? name
            values[local] = text
        }
        text = ""
    }
}

private final class TopologyParser: NSObject, XMLParserDelegate {
    var groups: [SonosSOAP.Topology.Group] = []
    private var coordinator: String?
    private var members: [SonosSOAP.Topology.Member] = []

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        switch name {
        case "ZoneGroup":
            coordinator = attributes["Coordinator"]
            members = []
        case "ZoneGroupMember":
            guard let uuid = attributes["UUID"], let location = attributes["Location"],
                  let host = SonosSOAP.host(fromLocation: location) else { return }
            members.append(.init(
                uuid: uuid,
                host: host,
                roomName: attributes["ZoneName"] ?? uuid,
                isInvisible: attributes["Invisible"] == "1",
                isBridge: attributes["IsZoneBridge"] == "1"
            ))
        default:
            break // Satellites (surrounds, subs) are nested inside a member and never rooms.
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "ZoneGroup", let coordinator {
            groups.append(.init(coordinator: coordinator, members: members))
            self.coordinator = nil
        }
    }
}

private final class DIDLTitles: NSObject, XMLParserDelegate {
    private var titles: [String] = []
    private var inTitle = false
    private var text = ""

    static func parse(_ didl: String) -> [String] {
        let collector = DIDLTitles()
        let parser = XMLParser(data: Data(didl.utf8))
        parser.delegate = collector
        parser.shouldProcessNamespaces = false
        _ = parser.parse()
        return collector.titles
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "dc:title" || name == "title" { inTitle = true; text = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { if inTitle { text += string } }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if inTitle && (name == "dc:title" || name == "title") {
            let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { titles.append(title) }
            inTitle = false
        }
    }
}
