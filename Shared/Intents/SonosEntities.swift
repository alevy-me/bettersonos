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
//  SonosEntities.swift
//

import Foundation
import AppIntents
import BetterSonosCore

// MARK: - Room

/// One speaker on one network. The id is "<network UUID>|<room name>".
struct RoomEntity: AppEntity, Codable, Hashable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Room"
    static let defaultQuery = RoomQuery()

    let id: String
    let networkID: UUID
    let networkName: String
    let name: String
    /// Show the network under the room name when more than one network is enabled.
    let showNetwork: Bool

    init(networkID: UUID, networkName: String, name: String, showNetwork: Bool) {
        self.id = "\(networkID.uuidString)|\(name)"
        self.networkID = networkID
        self.networkName = networkName
        self.name = name
        self.showNetwork = showNetwork
    }

    var displayRepresentation: DisplayRepresentation {
        showNetwork
            ? DisplayRepresentation(title: "\(name)", subtitle: "\(networkName)")
            : DisplayRepresentation(title: "\(name)")
    }

    /// Rebuilds an entity from its id when the server is unreachable, so saved shortcuts still resolve.
    init?(id: String, configs: [NetworkConfig]) {
        let parts = id.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let networkID = UUID(uuidString: parts[0]),
              let config = configs.first(where: { $0.id == networkID }) else { return nil }
        self.init(networkID: networkID, networkName: config.displayName, name: parts[1], showNetwork: configs.count > 1)
    }

    private static let cacheKey = "siriRoomsCache"

    static func saveCache(_ rooms: [RoomEntity]) {
        if let data = try? JSONEncoder().encode(rooms) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }

    static func loadCache() -> [RoomEntity] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return [] }
        return (try? JSONDecoder().decode([RoomEntity].self, from: data)) ?? []
    }
}

struct RoomQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [RoomEntity] {
        let rooms = await SonosDirectory.allRoomsOrCached()
        let configs = SonosDirectory.enabledConfigs()
        return identifiers.compactMap { id in
            rooms.first { $0.id == id } ?? RoomEntity(id: id, configs: configs)
        }
    }

    func entities(matching string: String) async throws -> [RoomEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let rooms = await SonosDirectory.allRoomsOrCached()
        // Exact names first, so "Kitchen" never resolves to "Kitchen Patio".
        let exact = rooms.filter { $0.name.compare(query, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        return exact.isEmpty ? rooms.filter { $0.name.localizedCaseInsensitiveContains(query) } : exact
    }

    func suggestedEntities() async throws -> [RoomEntity] {
        await SonosDirectory.allRoomsOrCached()
    }
}

// MARK: - Preset

/// A preset on one network. The id is "<network UUID>|<station url>".
struct PresetEntity: AppEntity, Codable, Hashable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Preset"
    static let defaultQuery = PresetQuery()

    let id: String
    let networkID: UUID
    let station: Station

    init(networkID: UUID, station: Station) {
        self.id = "\(networkID.uuidString)|\(station.url)"
        self.networkID = networkID
        self.station = station
    }

    var name: String { station.name }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(station.name)")
    }

    private static func cacheKey(for id: UUID) -> String { "siriPresets_\(id.uuidString)" }

    static func saveCache(_ presets: [PresetEntity], for networkID: UUID) {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: cacheKey(for: networkID))
        }
    }

    static func loadCache(for networkID: UUID) -> [PresetEntity] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey(for: networkID)) else { return [] }
        return (try? JSONDecoder().decode([PresetEntity].self, from: data)) ?? []
    }
}

struct PresetQuery: EntityStringQuery {
    /// When the room is already chosen, offer only that network's presets.
    @IntentParameterDependency<PlayPresetIntent>(\.$room)
    var playIntent

    private func candidates() async -> [PresetEntity] {
        let configs = SonosDirectory.enabledConfigs()
        let scoped = playIntent?.room.networkID
        let networks = configs.filter { scoped == nil || $0.id == scoped }
        return await withTaskGroup(of: [PresetEntity].self) { group in
            for config in networks {
                group.addTask { await SonosDirectory.presets(for: config) }
            }
            var all: [PresetEntity] = []
            for await presets in group { all += presets }
            return all
        }
    }

    func entities(for identifiers: [String]) async throws -> [PresetEntity] {
        // Saved shortcuts resolve from the cache first, without a network round trip.
        let configs = SonosDirectory.enabledConfigs()
        let cached = configs.flatMap { PresetEntity.loadCache(for: $0.id) }
        let missing = identifiers.filter { id in !cached.contains { $0.id == id } }
        let all = missing.isEmpty ? cached : await candidates()
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    func entities(matching string: String) async throws -> [PresetEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let presets = await candidates()
        let exact = presets.filter { $0.name.compare(query, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        return exact.isEmpty ? presets.filter { $0.name.localizedCaseInsensitiveContains(query) } : exact
    }

    func suggestedEntities() async throws -> [PresetEntity] {
        await candidates()
    }
}
