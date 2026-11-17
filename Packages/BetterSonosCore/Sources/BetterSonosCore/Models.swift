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
//  Models.swift
//

import Foundation
import os.log

// MARK: - Constants

public enum Constants {
    public static let defaultCSVURL = "https://raw.githubusercontent.com/alevy-me/sonos/refs/heads/main/default-stations.csv"
    public static let stationsPerPage = 6
    public static let stationsPerRow = 3
    public static let pollInterval: TimeInterval = 60
    /// Idle timeout for the SSE stream. A timeout means "quiet", not "broken", and is not counted as a failure.
    public static let sseTimeout: TimeInterval = 300
    /// Consecutive failures to establish the SSE stream before the UI reports the live connection as lost.
    public static let maxRetryAttempts = 5
    /// Upper bound on the SSE reconnect backoff, in seconds.
    public static let maxReconnectDelay: TimeInterval = 60
    /// Minimum interval between automatic retries of an incomplete station list.
    public static let stationRetryInterval: TimeInterval = 60
    /// Players whose volume is always fixed, such as a Connect on line-level output.
    public static let fixedVolumeUUIDs: Set<String> = [
        "RINCON_B8000000000000000"  // Example hardcoded Connect UUID
    ]
}

// MARK: - URL Input Helpers

/// Shared helpers for the scheme picker plus address field pattern used in the settings screens.
public enum URLInput {
    public static func split(_ fullURL: String?, defaultScheme: String) -> (scheme: String, address: String) {
        guard let urlString = fullURL?.trimmingCharacters(in: .whitespacesAndNewlines), !urlString.isEmpty else {
            return (defaultScheme, "")
        }
        let lower = urlString.lowercased()
        if lower.hasPrefix("http://") {
            return ("http://", String(urlString.dropFirst("http://".count)))
        } else if lower.hasPrefix("https://") {
            return ("https://", String(urlString.dropFirst("https://".count)))
        }
        return (defaultScheme, urlString)
    }

    /// Joins a scheme and address. Returns nil for an empty address. If the address already carries
    /// an http(s) scheme (a pasted full URL), the address is used as is.
    public static func join(scheme: String, address: String) -> String? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return trimmed
        }
        return scheme + trimmed
    }

    /// Trims whitespace and trailing slashes so request paths never start with "//".
    public static func normalizedBaseURL(_ url: String) -> String {
        var result = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }
}

// MARK: - Network Configuration

public struct NetworkConfig: Codable, Identifiable, Hashable {
    public let id: UUID
    public var displayName: String
    public var baseURL: String
    public var enabled: Bool
    public var showDefaultPresetsForThisNetwork: Bool
    public var explicitlyDisabledFavoriteURLs: Set<String> = []
    public var lastKnownServerFavorites: [Station]? = nil
    public var enabledLineInUUIDs: Set<String> = []
    public var lineInCustomNames: [String: String] = [:] // UUID: Custom Name
    public var manuallyDisabledVolumeUUIDs: Set<String> = []
    public var lastModified: Date

    enum CodingKeys: String, CodingKey {
        case id, displayName, baseURL, enabled
        case showDefaultPresetsForThisNetwork
        case explicitlyDisabledFavoriteURLs
        case lastKnownServerFavorites
        case enabledLineInUUIDs
        case lineInCustomNames
        case lastModified
        case manuallyDisabledVolumeUUIDs
    }

    public init(id: UUID, displayName: String, baseURL: String, enabled: Bool, showDefaultPresetsForThisNetwork: Bool, explicitlyDisabledFavoriteURLs: Set<String> = [], lastKnownServerFavorites: [Station]? = nil, enabledLineInUUIDs: Set<String> = [], lineInCustomNames: [String: String] = [:], manuallyDisabledVolumeUUIDs: Set<String> = [], lastModified: Date = Date()) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.enabled = enabled
        self.showDefaultPresetsForThisNetwork = showDefaultPresetsForThisNetwork
        self.explicitlyDisabledFavoriteURLs = explicitlyDisabledFavoriteURLs
        self.lastKnownServerFavorites = lastKnownServerFavorites
        self.enabledLineInUUIDs = enabledLineInUUIDs
        self.lineInCustomNames = lineInCustomNames
        self.manuallyDisabledVolumeUUIDs = manuallyDisabledVolumeUUIDs
        self.lastModified = lastModified
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        enabled = try container.decode(Bool.self, forKey: .enabled)

        // For data migration:
        showDefaultPresetsForThisNetwork = try container.decodeIfPresent(Bool.self, forKey: .showDefaultPresetsForThisNetwork) ?? false
        explicitlyDisabledFavoriteURLs = try container.decodeIfPresent(Set<String>.self, forKey: .explicitlyDisabledFavoriteURLs) ?? []
        lastKnownServerFavorites = try container.decodeIfPresent([Station].self, forKey: .lastKnownServerFavorites)
        enabledLineInUUIDs = try container.decodeIfPresent(Set<String>.self, forKey: .enabledLineInUUIDs) ?? []
        lineInCustomNames = try container.decodeIfPresent([String: String].self, forKey: .lineInCustomNames) ?? [:]
        lastModified = try container.decodeIfPresent(Date.self, forKey: .lastModified) ?? Date()
        manuallyDisabledVolumeUUIDs = try container.decodeIfPresent(Set<String>.self, forKey: .manuallyDisabledVolumeUUIDs) ?? []
    }

    /// True when the apps should gray out volume for this player: a known fixed-volume device,
    /// or one the user disabled for this network in Disable Volume Control.
    public func isVolumeDisabled(forPlayer uuid: String) -> Bool {
        Constants.fixedVolumeUUIDs.contains(uuid) || manuallyDisabledVolumeUUIDs.contains(uuid)
    }

    /// True when the station list for this network would otherwise be empty, which forces the default presets on.
    public static func isForcedDefault(remoteCSVURL: String?, manualStations: [Station], favorites: [Station]?, disabledFavoriteURLs: Set<String>) -> Bool {
        let customCSVEmpty = (remoteCSVURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
        let enabledFavorites = (favorites ?? []).filter { !disabledFavoriteURLs.contains($0.url) }
        return customCSVEmpty && manualStations.isEmpty && enabledFavorites.isEmpty
    }
}

// MARK: - Network Status Enum

public enum NetworkStatus: Equatable {
    case connected
    case connecting
    case error(String)
}

// MARK: - Models

/// Station type. Unknown raw values are preserved in `.other` so a type written by a newer
/// build round-trips through this build (and through iCloud) unchanged. `.other` plays as a stream.
public enum StationType: Hashable, Codable, RawRepresentable {
    case stream
    case favorite
    case lineIn
    case other(String)

    public init(rawValue: String) {
        switch rawValue.lowercased() {
        case "stream": self = .stream
        case "favorite": self = .favorite
        case "linein": self = .lineIn
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .stream: return "stream"
        case .favorite: return "favorite"
        case .lineIn: return "linein"
        case .other(let raw): return raw
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct Station: Hashable, Codable {
    public let name: String
    public let url: String
    public let type: StationType

    public init(name: String, url: String, type: StationType) {
        self.name = name
        self.url = url
        self.type = type
    }

    public var isFavorite: Bool { type == .favorite }
    public var isLineIn: Bool { type == .lineIn }

    /// How well this station matches the playing track. 0 means no match; higher is better.
    /// 4: exact URI or line-in UUID match. 3: exact station name match.
    /// 2: the track URI contains this station's URL. 1: substring name match on a TuneIn stream.
    public func matchScore(for track: Track) -> Int {
        let normalizedName = Self.normalize(name)
        let normalizedURL = Self.normalize(url)
        let candidateURIs = [track.uri, track.trackUri]
            .compactMap { $0.map(Self.normalize) }
            .filter { !$0.isEmpty }

        if isLineIn {
            guard let stationUUID = Self.lineInUUID(from: normalizedURL) else { return 0 }
            return candidateURIs.contains { Self.lineInUUID(from: $0) == stationUUID } ? 4 : 0
        }

        if !normalizedURL.isEmpty,
           candidateURIs.contains(where: { $0 == normalizedURL || $0 == "x-rincon-mp3radio://" + normalizedURL }) {
            return 4
        }

        let stationName = track.stationName.map(Self.normalize) ?? ""
        if !normalizedName.isEmpty, stationName == normalizedName {
            return 3
        }

        // Only URL-shaped values are used for containment, so a short or malformed url field
        // (for example "stream") cannot match every track.
        if normalizedURL.count >= 8, normalizedURL.contains(":"),
           candidateURIs.contains(where: { $0.contains(normalizedURL) }) {
            return 2
        }

        if !normalizedName.isEmpty, !stationName.isEmpty,
           track.uri?.hasPrefix("x-sonosapi-stream:") == true,
           stationName.contains(normalizedName) || normalizedName.contains(stationName) {
            return 1
        }
        return 0
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extracts the lowercased UUID from "x-rincon-stream:UUID" or "x-rincon-stream:UUID:INSTANCE".
    public static func lineInUUID(from uri: String) -> String? {
        let lower = uri.lowercased()
        let prefix = "x-rincon-stream:"
        guard lower.hasPrefix(prefix) else { return nil }
        let uuid = lower.dropFirst(prefix.count).split(separator: ":").first.map(String.init) ?? ""
        return uuid.isEmpty ? nil : uuid
    }
}

/// Picks the best-matching station for a track. Ties on score keep list order, except that among
/// substring name matches the longest (closest) name wins.
public func bestMatchingStation(in stations: [Station], for track: Track) -> Station? {
    var best: (station: Station, score: Int)? = nil
    for station in stations {
        let score = station.matchScore(for: track)
        guard score > 0 else { continue }
        if let current = best {
            if score > current.score || (score == 1 && current.score == 1 && station.name.count > current.station.name.count) {
                best = (station, score)
            }
        } else {
            best = (station, score)
        }
    }
    return best?.station
}

public struct SonosGroup: Identifiable, Hashable {
    public var id: String { coordinator }
    public let coordinator: String
    public let joiners: [String]

    public init(coordinator: String, joiners: [String]) {
        self.coordinator = coordinator
        self.joiners = joiners
    }
}

public struct Zone: Codable {
    public let coordinator: Member
    public let members: [Member]
}

public struct Member: Codable {
    public let roomName: String
    public let uuid: String
    public let state: PlayerState
    /// Volume and mute for the whole group this player belongs to. Optional so older servers still decode.
    public let groupState: GroupState?
}

public struct GroupState: Codable, Equatable {
    public let volume: Int
    public let mute: Bool
}

public struct Track: Codable, Equatable {
    public let title: String?
    public let artist: String?
    public let stationName: String?
    public let uri: String?
    public let trackUri: String?
    public let type: String?
    public let albumArtUri: String?
    public let absoluteAlbumArtUri: String?

    public init(title: String? = nil, artist: String? = nil, stationName: String? = nil, uri: String? = nil, trackUri: String? = nil, type: String? = nil, albumArtUri: String? = nil, absoluteAlbumArtUri: String? = nil) {
        self.title = title
        self.artist = artist
        self.stationName = stationName
        self.uri = uri
        self.trackUri = trackUri
        self.type = type
        self.albumArtUri = albumArtUri
        self.absoluteAlbumArtUri = absoluteAlbumArtUri
    }
}

public struct PlayerState: Codable {
    public let volume: Int
    public let mute: Bool
    public let currentTrack: Track?
    public let playbackState: String
}

// MARK: - Station CSV Parsing

public enum StationCSV {
    /// Parses a station CSV (header row, then name,url[,type]). Handles RFC 4180 quoting, escaped
    /// quotes, empty fields, a UTF-8 BOM, and LF, CRLF or CR line endings. Rows without a name and
    /// a URL are skipped. An empty or missing type means "stream".
    public static func parseStations(_ data: Data) -> [Station] {
        let text = String(decoding: data, as: UTF8.self)
        return parseRows(text).dropFirst().compactMap { fields in
            let trimmed = fields.map { $0.trimmingCharacters(in: .whitespaces) }
            guard trimmed.count >= 2, !trimmed[0].isEmpty, !trimmed[1].isEmpty else { return nil }
            let rawType = trimmed.count >= 3 && !trimmed[2].isEmpty ? trimmed[2] : "stream"
            return Station(name: trimmed[0], url: trimmed[1], type: StationType(rawValue: rawType))
        }
    }

    public static func parseRows(_ text: String) -> [[String]] {
        var scalars = Array(text.unicodeScalars)
        if scalars.first == "\u{FEFF}" { scalars.removeFirst() }

        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var inQuotes = false
        var fieldStarted = false
        var i = 0

        func endField() {
            row.append(String(field))
            field = String.UnicodeScalarView()
            fieldStarted = false
        }

        while i < scalars.count {
            let c = scalars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < scalars.count, scalars[i + 1] == "\"" {
                        field.append("\"")
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"" where !fieldStarted:
                    inQuotes = true
                    fieldStarted = true
                case ",":
                    endField()
                case "\r", "\n":
                    endField()
                    rows.append(row)
                    row = []
                    if c == "\r", i + 1 < scalars.count, scalars[i + 1] == "\n" { i += 1 }
                default:
                    if c != " " && c != "\t" { fieldStarted = true }
                    field.append(c)
                }
            }
            i += 1
        }
        if fieldStarted || !field.isEmpty || !row.isEmpty {
            endField()
            rows.append(row)
        }
        // Drop blank lines.
        return rows.filter { !($0.count == 1 && $0[0].trimmingCharacters(in: .whitespaces).isEmpty) }
    }
}

// MARK: - Redirect Handler

final class RedirectHandler: NSObject, URLSessionTaskDelegate {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "BetterSonosCore", category: "RedirectHandler")
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        if let url = request.url?.absoluteString.replacingOccurrences(of: "*/", with: "") {
            var modifiedRequest = request
            modifiedRequest.url = URL(string: url)
            Self.logger.debug("Redirecting to (sanitized): \(modifiedRequest.url?.absoluteString ?? "")")
            completionHandler(modifiedRequest)
        } else {
            completionHandler(request)
        }
    }
}
