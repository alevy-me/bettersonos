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
//  Networking.swift
//

import Foundation
import os.log

private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "BetterSonosCore", category: "Networking")

// MARK: - HTTP Helpers

/// Nonisolated networking helpers, so request work and decoding never run on the main actor.
public enum SonosHTTP {
    /// Only RFC 3986 unreserved characters pass through, so "/", ":", "?", "#" and "%" inside a
    /// single path segment are escaped. node-sonos-http-api splits the raw path on "/" before decoding.
    public static let pathSegmentAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    public static func url(base: String, _ components: [String]) -> URL? {
        var path = base
        for component in components {
            guard let encoded = component.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed) else { return nil }
            path += "/" + encoded
        }
        return URL(string: path)
    }

    /// The request that loads a preset into a room: favorites by name, line-ins by their
    /// x-rincon-stream URI, and everything else as an x-rincon-mp3radio stream.
    /// Follow it with `<room>/play`.
    public static func presetURL(base: String, room: String, station: Station) -> URL? {
        if station.isFavorite {
            return url(base: base, [room, "favorite", station.url])
        } else if station.isLineIn {
            return url(base: base, [room, "setavtransporturi", station.url])
        }
        return url(base: base, [room, "setavtransporturi", "x-rincon-mp3radio://\(station.url)"])
    }

    public enum RequestError: Error {
        case badStatus(Int)
        case notHTTP
    }

    /// Sends a GET and reports whether the server answered 2xx.
    @discardableResult
    public static func get(_ url: URL?) async -> Bool {
        guard let url else { return false }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            try validate(response)
            return true
        } catch {
            log.error("Request failed for \(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    public static func fetchJSON<T: Decodable>(_ type: T.Type, from url: URL) async -> Result<T, Error> {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            try validate(response)
            return .success(try JSONDecoder().decode(T.self, from: data))
        } catch {
            return .failure(error)
        }
    }

    public static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw RequestError.notHTTP }
        guard (200...299).contains(http.statusCode) else { throw RequestError.badStatus(http.statusCode) }
    }
}

// MARK: - Station List Builder

/// Snapshot of everything the station list depends on, taken on the main actor.
public struct StationListInputs: Sendable {
    public let config: NetworkConfig
    public let remoteCSVURL: String?
    public let manualStations: [Station]
    public let uuidToRoomName: [String: String]

    public init(config: NetworkConfig, remoteCSVURL: String?, manualStations: [Station], uuidToRoomName: [String: String]) {
        self.config = config
        self.remoteCSVURL = remoteCSVURL
        self.manualStations = manualStations
        self.uuidToRoomName = uuidToRoomName
    }
}

public struct StationListResult: Sendable {
    public let stations: [Station]
    /// nil when no custom CSV is configured.
    public let customCSVFailed: Bool?
    /// True when a fetch failed or a line-in name could not be resolved, so a later retry may improve it.
    public let incomplete: Bool
}

public enum StationListBuilder {
    /// One shared session for all CSV fetches, so connections are reused and nothing leaks per call.
    private static let csvSession = URLSession(configuration: .default, delegate: RedirectHandler(), delegateQueue: nil)

    /// Fetches and parses a station CSV. Returns nil on any transport, HTTP status or content-type failure.
    public static func fetchStations(from url: String) async -> [Station]? {
        guard let csvURL = URL(string: url) else { return nil }
        var request = URLRequest(url: csvURL)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        do {
            let (data, response) = try await csvSession.data(for: request)
            try SonosHTTP.validate(response)
            if let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"),
               contentType.lowercased().contains("text/html") {
                log.error("Station CSV at \(url, privacy: .public) returned HTML, not CSV.")
                return nil
            }
            return StationCSV.parseStations(data)
        } catch {
            log.error("Failed to fetch stations from \(url, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The stations to offer for a network: the built list minus favorites disabled for it.
    /// (The build keeps disabled favorites so the forced-default rule counts them correctly.)
    public static func visibleStations(_ stations: [Station], for config: NetworkConfig) -> [Station] {
        stations.filter { !($0.isFavorite && config.explicitlyDisabledFavoriteURLs.contains($0.url)) }
    }

    /// Merges every station source into one deduplicated, name-sorted list. Lower priority wins on a URL clash:
    /// 1 manual entries and enabled line-ins, 2 custom CSV, 3 Sonos favorites, 4 default CSV.
    public static func build(_ inputs: StationListInputs) async -> StationListResult {
        let config = inputs.config
        var incomplete = false
        var candidates: [(station: Station, priority: Int, order: Int)] = []
        var order = 0
        func add(_ stations: [Station], priority: Int) {
            for station in stations {
                order += 1
                candidates.append((station, priority, order))
            }
        }

        let customURL = inputs.remoteCSVURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let forcedDefault = NetworkConfig.isForcedDefault(
            remoteCSVURL: customURL,
            manualStations: inputs.manualStations,
            favorites: config.lastKnownServerFavorites,
            disabledFavoriteURLs: config.explicitlyDisabledFavoriteURLs
        )

        // Fetch both CSVs concurrently.
        let wantsDefault = forcedDefault || config.showDefaultPresetsForThisNetwork
        async let defaultFetch: [Station]? = wantsDefault ? fetchStations(from: Constants.defaultCSVURL) : []
        async let customFetch: [Station]? = customURL.isEmpty ? [] : fetchStations(from: customURL)
        let defaultStations = await defaultFetch
        let customStations = await customFetch

        if let defaultStations {
            add(defaultStations, priority: 4)
        } else {
            incomplete = true
        }

        var customCSVFailed: Bool? = nil
        if !customURL.isEmpty {
            if let customStations {
                add(customStations, priority: 2)
                customCSVFailed = customStations.isEmpty
            } else {
                customCSVFailed = true
                incomplete = true
            }
        }

        add(inputs.manualStations, priority: 1)
        add(config.lastKnownServerFavorites ?? [], priority: 3)

        // Line-ins from any other source are dropped; only those enabled for this network are offered.
        candidates.removeAll { $0.station.isLineIn || Station.lineInUUID(from: $0.station.url) != nil }
        for uuid in config.enabledLineInUUIDs.sorted() {
            let name: String
            if let custom = config.lineInCustomNames[uuid], !custom.isEmpty {
                name = custom
            } else if let room = inputs.uuidToRoomName[uuid] {
                name = room
            } else {
                name = uuid
                incomplete = true
            }
            add([Station(name: name, url: "x-rincon-stream:\(uuid)", type: .lineIn)], priority: 1)
        }

        var uniqueByURL: [String: (station: Station, priority: Int, order: Int)] = [:]
        for item in candidates {
            if let existing = uniqueByURL[item.station.url],
               existing.priority < item.priority || (existing.priority == item.priority && existing.order < item.order) {
                continue
            }
            uniqueByURL[item.station.url] = item
        }

        let stations = uniqueByURL.values
            .map(\.station)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return StationListResult(stations: stations, customCSVFailed: customCSVFailed, incomplete: incomplete)
    }
}
