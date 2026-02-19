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

enum Constants {
    static let defaultCSVURL = "https://raw.githubusercontent.com/alevy-me/sonos/refs/heads/main/default-stations.csv"
    static let sonosUPnPPort = 1400
    static let stationsPerPage = 6
    static let stationsPerRow = 3
    static let pollInterval: TimeInterval = 60
    static let sseTimeout: TimeInterval = 300
    static let maxRetryAttempts = 5
}

// MARK: - Network Configuration

struct NetworkConfig: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var displayName: String
    var baseURL: String
    var enabled: Bool
    var showDefaultPresetsForThisNetwork: Bool
    var explicitlyDisabledFavoriteURLs: Set<String> = []
    var lastKnownServerFavorites: [Station]? = nil
    var enabledLineInUUIDs: Set<String> = []
    var lineInCustomNames: [String: String] = [:] // UUID: Custom Name
    var manuallyDisabledVolumeUUIDs: Set<String> = []
    var lastModified: Date
    
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

    init(id: UUID, displayName: String, baseURL: String, enabled: Bool, showDefaultPresetsForThisNetwork: Bool, explicitlyDisabledFavoriteURLs: Set<String> = [], lastKnownServerFavorites: [Station]? = nil, enabledLineInUUIDs: Set<String> = [], lineInCustomNames: [String: String] = [:], manuallyDisabledVolumeUUIDs: Set<String> = [], lastModified: Date = Date()) {
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

    init(from decoder: Decoder) throws {
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
    
    static func == (lhs: NetworkConfig, rhs: NetworkConfig) -> Bool {
        lhs.id == rhs.id &&
        lhs.displayName == rhs.displayName &&
        lhs.baseURL == rhs.baseURL &&
        lhs.enabled == rhs.enabled &&
        lhs.showDefaultPresetsForThisNetwork == rhs.showDefaultPresetsForThisNetwork &&
        lhs.explicitlyDisabledFavoriteURLs == rhs.explicitlyDisabledFavoriteURLs &&
        lhs.lastKnownServerFavorites == rhs.lastKnownServerFavorites &&
        lhs.enabledLineInUUIDs == rhs.enabledLineInUUIDs &&
        lhs.lineInCustomNames == rhs.lineInCustomNames &&
        lhs.lastModified == rhs.lastModified &&
        lhs.manuallyDisabledVolumeUUIDs == rhs.manuallyDisabledVolumeUUIDs
    }
}

// MARK: - Network Status Enum

enum NetworkStatus: Equatable {
    case connected
    case connecting
    case error(String)
}

// MARK: - Models

enum StationType: String, Codable, Hashable {
    case stream
    case favorite
    case lineIn = "linein"
    case defaultCSVStream = "default_csv_stream"
    case customCSVStream = "custom_csv_stream"

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = StationType(rawValue: raw.lowercased()) ?? .stream
    }
}

struct Station: Hashable, Codable {
    let name: String
    let url: String
    let type: StationType

    var isFavorite: Bool { type == .favorite }
    var isLineIn: Bool { type == .lineIn }
    func matches(track: Track) -> Bool {
        let normalizedName = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedURL = url.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let stationName = track.stationName?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
           track.uri?.hasPrefix("x-sonosapi-stream:") == true {
            if stationName == normalizedName {
                return true
            }
            if stationName.contains(normalizedName) || normalizedName.contains(stationName) {
                return true
            }
        }
        let candidateURLs = [
            track.uri,
            track.trackUri
        ].compactMap { $0?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        if candidateURLs.contains(where: { $0.contains(normalizedURL) }) {
            return true
        }
        if isLineIn { // self.isLineIn is true. self.url is "x-rincon-stream:CONFIGURED_BARE_UUID"
                    for candidateTrackURI in candidateURLs { // candidateTrackURI is from track.uri, e.g., "x-rincon-stream:PLAYING_BARE_UUID"
                        if candidateTrackURI.hasPrefix("x-rincon-stream:") {
                            // Extract the bare UUID from the currently playing track's URI
                            let playingTrackBareUUID = candidateTrackURI
                                .replacingOccurrences(of: "x-rincon-stream:", with: "")
                                .components(separatedBy: ":")
                                .first ?? ""

                            // Extract the bare UUID from this Station instance's URL
                            let stationBareUUID = self.url // self.url is "x-rincon-stream:CONFIGURED_BARE_UUID" for LineIn stations
                                .replacingOccurrences(of: "x-rincon-stream:", with: "")
                                .components(separatedBy: ":")
                                .first ?? ""

                            // If both bare UUIDs match and are not empty, it's a match
                            if !playingTrackBareUUID.isEmpty && playingTrackBareUUID == stationBareUUID {
                                return true
                            }
                        }
                    }
                }
        return false
    }
}

struct SonosGroup: Identifiable, Hashable {
    var id: String { coordinator }
    let coordinator: String
    let joiners: [String]
}
struct Zone: Codable { let coordinator: Member; let members: [Member] }
struct Member: Codable {
    let roomName: String
    let uuid: String
    let state: PlayerState
    let host: String?
}
struct Track: Codable {
    let title: String?
    let artist: String?
    let stationName: String?
    let uri: String?
    let trackUri: String?
    let type: String?
    let albumArtUri: String?
    let absoluteAlbumArtUri: String?
}
struct PlayerState: Codable {
    let volume: Int
    let mute: Bool
    let currentTrack: Track?
    let playbackState: String
}

// MARK: - Redirect Handler

class RedirectHandler: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "RedirectHandler")
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
