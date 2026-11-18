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
//  DirectBackend.swift
//
//  Talks to the speakers themselves, with no server. Works only on the speakers' network.

import Foundation

public struct DirectBackend: SonosBackend {
    public enum DirectError: Error {
        case noSpeakerAnswered
    }

    /// Known speaker addresses ("192.168.1.20:1400") by player ID. Any one that answers is enough.
    public let speakers: [String: String]

    public init(speakers: [String: String]) {
        self.speakers = speakers
    }

    // MARK: - Layout

    /// Asks every known speaker at once and takes the first answer.
    public func topology() async throws -> SonosSOAP.Topology {
        let hosts = Array(Set(speakers.values))
        guard !hosts.isEmpty else { throw DirectError.noSpeakerAnswered }
        return try await withThrowingTaskGroup(of: SonosSOAP.Topology?.self) { group in
            for host in hosts {
                group.addTask { try? await Self.topology(from: host) }
            }
            for try await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            throw DirectError.noSpeakerAnswered
        }
    }

    public static func topology(from host: String) async throws -> SonosSOAP.Topology {
        let response = try await SonosSOAP.call(host, SonosSOAP.zoneGroupTopology, "GetZoneGroupState")
        guard let state = response["ZoneGroupState"] else { throw SonosSOAP.SOAPError.malformed }
        return try SonosSOAP.parseTopology(state)
    }

    // MARK: - State

    public func zones() async throws -> [Zone] {
        let topology = try await topology()
        return try await withThrowingTaskGroup(of: (Int, Zone?).self) { group in
            for (index, topologyGroup) in topology.groups.enumerated() {
                group.addTask { (index, try await Self.zone(for: topologyGroup)) }
            }
            var zones: [(Int, Zone)] = []
            for try await (index, zone) in group {
                if let zone { zones.append((index, zone)) }
            }
            return zones.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// One group's state: transport, source and group volume from the coordinator, volume and
    /// mute from each room. Stereo-pair partners, satellites and bridges are not rooms.
    static func zone(for group: SonosSOAP.Topology.Group) async throws -> Zone? {
        let rooms = group.members.filter(\.isRoom)
        guard let coordinator = rooms.first(where: { $0.uuid == group.coordinator }) else { return nil }
        let instance = [("InstanceID", "0")]
        let master = [("InstanceID", "0"), ("Channel", "Master")]

        async let transport = SonosSOAP.call(coordinator.host, SonosSOAP.avTransport, "GetTransportInfo", instance)
        async let media = SonosSOAP.call(coordinator.host, SonosSOAP.avTransport, "GetMediaInfo", instance)
        async let groupVolume = try? SonosSOAP.call(coordinator.host, SonosSOAP.groupRenderingControl, "GetGroupVolume", instance)
        async let groupMute = try? SonosSOAP.call(coordinator.host, SonosSOAP.groupRenderingControl, "GetGroupMute", instance)

        // One room failing to answer shouldn't hide the whole group; it shows defaults until the next refresh.
        let levels = await withTaskGroup(of: (String, Int, Bool).self) { tasks in
            for room in rooms {
                tasks.addTask {
                    async let volume = try? SonosSOAP.call(room.host, SonosSOAP.renderingControl, "GetVolume", master)
                    async let mute = try? SonosSOAP.call(room.host, SonosSOAP.renderingControl, "GetMute", master)
                    return (room.uuid, Int(await volume?["CurrentVolume"] ?? "") ?? 0, await mute?["CurrentMute"] == "1")
                }
            }
            var result: [String: (Int, Bool)] = [:]
            for await (uuid, volume, muted) in tasks { result[uuid] = (volume, muted) }
            return result
        }

        let transportInfo = try await transport
        let mediaInfo = try await media
        let track = Self.track(uri: mediaInfo["CurrentURI"], metadata: mediaInfo["CurrentURIMetaData"])
        let playback = transportInfo["CurrentTransportState"] ?? "STOPPED"
        let groupState = GroupState(
            volume: Int(await groupVolume?["CurrentVolume"] ?? "") ?? levels[coordinator.uuid]?.0 ?? 0,
            mute: (await groupMute?["CurrentMute"]).map { $0 == "1" } ?? levels[coordinator.uuid]?.1 ?? false
        )

        func member(_ room: SonosSOAP.Topology.Member) -> Member {
            Member(
                roomName: room.roomName,
                uuid: room.uuid,
                state: PlayerState(volume: levels[room.uuid]?.0 ?? 0, mute: levels[room.uuid]?.1 ?? false, currentTrack: track, playbackState: playback),
                groupState: groupState
            )
        }
        return Zone(coordinator: member(coordinator), members: rooms.map(member))
    }

    /// The loaded source, named by the title in its metadata ("Spotify", a station name). Track
    /// titles are deliberately not read: the apps show sources only.
    static func track(uri: String?, metadata: String?) -> Track? {
        guard let uri, !uri.isEmpty else { return nil }
        let lower = uri.lowercased()
        let type: String
        if lower.hasPrefix("x-rincon-stream:") {
            type = "line_in"
        } else if lower.hasPrefix("x-sonosapi-stream:") || lower.hasPrefix("x-rincon-mp3radio:")
                    || lower.hasPrefix("x-sonosapi-radio:") || lower.hasPrefix("hls-radio:") || lower.hasPrefix("aac:") {
            type = "radio"
        } else {
            type = "track"
        }
        let name = type == "line_in" ? nil : SonosSOAP.didlTitle(metadata)
        return Track(stationName: name, uri: uri, type: type)
    }

    public func favoriteNames() async throws -> [String] {
        let topology = try await topology()
        guard let host = topology.groups.flatMap(\.members).first(where: \.isRoom)?.host else {
            throw DirectError.noSpeakerAnswered
        }
        let response = try await SonosSOAP.call(host, SonosSOAP.contentDirectory, "Browse", [
            ("ObjectID", "FV:2"),
            ("BrowseFlag", "BrowseDirectChildren"),
            ("Filter", "dc:title"),
            ("StartingIndex", "0"),
            ("RequestedCount", "200"),
            ("SortCriteria", ""),
        ])
        return SonosSOAP.didlTitles(response["Result"] ?? "")
    }

    // MARK: - Commands (phase 2)

    // Not yet implemented: direct networks are read-only until direct commands land.
    @discardableResult public func play(coordinator: String) async -> Bool { false }
    @discardableResult public func pause(coordinator: String) async -> Bool { false }
    @discardableResult public func setVolume(_ level: Int, room: String) async -> Bool { false }
    @discardableResult public func setGroupVolume(_ level: Int, coordinator: String) async -> Bool { false }
    @discardableResult public func setMute(_ muted: Bool, room: String) async -> Bool { false }
    @discardableResult public func setGroupMute(_ muted: Bool, coordinator: String) async -> Bool { false }
    @discardableResult public func join(room: String, to target: String) async -> Bool { false }
    @discardableResult public func leave(room: String) async -> Bool { false }
    @discardableResult public func loadPreset(_ station: Station, coordinator: String) async -> Bool { false }
}
