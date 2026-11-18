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
//  SonosDirectory.swift
//
//  Compiled into both the iOS and watchOS apps, so Siri works on either device.

import Foundation
import AppIntents
import BetterSonosCore

/// Finds rooms across every enabled network for Siri and Shortcuts. Always asks the servers for
/// live state; the room cache only feeds Siri's vocabulary and offline suggestions.
enum SonosDirectory {

    /// A room resolved against live state.
    struct Located {
        let config: NetworkConfig
        let member: Member
        let coordinator: Member

        var backend: any SonosBackend { config.backend }
        var roomName: String { member.roomName }
        var coordinatorName: String { coordinator.roomName }
        var isPlaying: Bool { SonosDirectory.isPlaying(coordinator) }
    }

    static func enabledConfigs() -> [NetworkConfig] {
        // Read-only: Siri must never write configs back to iCloud.
        NetworkConfigStore(cloudReadOnly: true).configs.filter(\.enabled)
    }

    static func isPlaying(_ member: Member) -> Bool {
        ["PLAYING", "TRANSITIONING"].contains(member.state.playbackState)
    }

    static func zones(for config: NetworkConfig) async throws -> [Zone] {
        do {
            return try await config.backend.zones()
        } catch {
            throw SonosIntentError.unreachable(config.displayName)
        }
    }

    /// Each zone's players, coordinator first, without duplicates.
    static func players(in zone: Zone) -> [Member] {
        var seen = Set<String>()
        return ([zone.coordinator] + zone.members).filter { seen.insert($0.roomName).inserted }
    }

    // MARK: - Rooms

    /// Every room on every enabled network. Networks that don't answer are skipped. Updates the cache.
    static func allRooms() async -> [RoomEntity] {
        let configs = enabledConfigs()
        let showNetwork = configs.count > 1
        let rooms = await withTaskGroup(of: [RoomEntity].self) { group in
            for config in configs {
                group.addTask {
                    guard let zones = try? await zones(for: config) else { return [] }
                    return zones.flatMap(players(in:)).map {
                        RoomEntity(networkID: config.id, networkName: config.displayName, name: $0.roomName, showNetwork: showNetwork)
                    }
                }
            }
            var all: [RoomEntity] = []
            for await rooms in group { all += rooms }
            return all
        }
        let sorted = rooms.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if !sorted.isEmpty { RoomEntity.saveCache(sorted) }
        return sorted
    }

    /// Live rooms, or the last cached list when no server answers.
    static func allRoomsOrCached() async -> [RoomEntity] {
        let live = await allRooms()
        return live.isEmpty ? RoomEntity.loadCache() : live
    }

    static func locate(_ room: RoomEntity) async throws -> Located {
        guard let config = enabledConfigs().first(where: { $0.id == room.networkID }) else {
            throw SonosIntentError.networkGone(room.networkName)
        }
        let zones = try await zones(for: config)
        for zone in zones {
            if let member = players(in: zone).first(where: { $0.roomName == room.name }) {
                return Located(config: config, member: member, coordinator: zone.coordinator)
            }
        }
        throw SonosIntentError.roomNotFound(room.name)
    }

    /// The coordinator of each playing group across every enabled network.
    static func playingGroups() async -> [Located] {
        let configs = enabledConfigs()
        return await withTaskGroup(of: [Located].self) { group in
            for config in configs {
                group.addTask {
                    guard let zones = try? await zones(for: config) else { return [] }
                    return zones.filter { isPlaying($0.coordinator) }.map {
                        Located(config: config, member: $0.coordinator, coordinator: $0.coordinator)
                    }
                }
            }
            var all: [Located] = []
            for await located in group { all += located }
            return all.sorted { $0.roomName.localizedCaseInsensitiveCompare($1.roomName) == .orderedAscending }
        }
    }

    // MARK: - Requests

    /// Turns a command's success into a thrown error Siri can speak.
    static func require(_ ok: Bool) throws {
        guard ok else { throw SonosIntentError.requestFailed }
    }

    /// Spoken description of a track, such as "So What by Miles Davis". Uses cached presets to name
    /// direct streams that carry no station name of their own.
    static func describe(_ track: Track?, on config: NetworkConfig) -> String? {
        guard let track else { return nil }
        let presets = PresetEntity.loadCache(for: config.id).map(\.station)
        let presetName = bestMatchingStation(in: presets, for: track)?.name
        return NowPlaying(track: track, presetName: presetName)?.spoken
    }

    // MARK: - Presets

    /// The visible presets for a network, built with the same sources and rules as the apps.
    static func presets(for config: NetworkConfig) async -> [PresetEntity] {
        let settings = await MainActor.run { () -> (String?, [Station]) in
            let store = AppSettingsStore(cloudReadOnly: true)
            return (store.remoteCSVURL, store.manualStations)
        }
        var uuidToRoomName: [String: String] = [:]
        if let zones = try? await zones(for: config) {
            for member in zones.flatMap(players(in:)) where uuidToRoomName[member.uuid] == nil {
                uuidToRoomName[member.uuid] = member.roomName
            }
        }
        let inputs = StationListInputs(config: config, remoteCSVURL: settings.0, manualStations: settings.1, uuidToRoomName: uuidToRoomName)
        let result = await StationListBuilder.build(inputs)
        let presets = StationListBuilder.visibleStations(result.stations, for: config).map {
            PresetEntity(networkID: config.id, station: $0)
        }
        if presets.isEmpty { return PresetEntity.loadCache(for: config.id) }
        PresetEntity.saveCache(presets, for: config.id)
        return presets
    }
}

// MARK: - Errors

enum SonosIntentError: Error, CustomLocalizedStringResourceConvertible {
    case unreachable(String)
    case networkGone(String)
    case roomNotFound(String)
    case fixedVolume(String)
    case requestFailed
    case nothingPlaying
    case presetOnOtherNetwork(preset: String, room: String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .unreachable(let network): return "Can't reach the \(network) speakers."
        case .networkGone(let network): return "The \(network) network isn't set up in BonTon anymore."
        case .roomNotFound(let room): return "I can't find \(room)."
        case .fixedVolume(let room): return "\(room) has a fixed volume."
        case .requestFailed: return "The speakers didn't respond."
        case .nothingPlaying: return "Nothing is playing."
        case .presetOnOtherNetwork(let preset, let room): return "\(preset) isn't available for \(room)."
        }
    }
}
