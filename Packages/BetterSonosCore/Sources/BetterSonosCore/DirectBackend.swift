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
        /// No speaker answered the layout request. `reasons` says why each one failed, for diagnostics.
        case noSpeakerAnswered(reasons: [String] = [])
        /// The request was cancelled (polling paused or the app moved on). Says nothing about the network.
        case cancelled
        case roomNotFound(String)
        case favoriteNotFound(String)
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
        guard !hosts.isEmpty else { throw DirectError.noSpeakerAnswered(reasons: ["no known speaker addresses"]) }
        return try await withThrowingTaskGroup(of: Result<SonosSOAP.Topology, Error>.self) { group in
            for host in hosts {
                group.addTask { await Result(asyncCatching: { try await Self.topology(from: host) }) }
            }
            var reasons: [String] = []
            var cancelled = 0
            for try await result in group {
                switch result {
                case .success(let topology):
                    group.cancelAll()
                    return topology
                case .failure(let error):
                    if Self.isCancellation(error) { cancelled += 1 }
                    reasons.append(Self.describe(error))
                }
            }
            // Cancelled requests aren't evidence the speakers are gone, so don't report them as silence.
            if cancelled > 0 || Task.isCancelled { throw DirectError.cancelled }
            throw DirectError.noSpeakerAnswered(reasons: reasons)
        }
    }

    public static func topology(from host: String) async throws -> SonosSOAP.Topology {
        let response = try await SonosSOAP.call(host, SonosSOAP.zoneGroupTopology, "GetZoneGroupState", timeout: SonosSOAP.layoutTimeout)
        guard let state = response["ZoneGroupState"] else { throw SonosSOAP.SOAPError.malformed }
        return try SonosSOAP.parseTopology(state)
    }

    /// Cancellation, as opposed to a failure: the task was cancelled, or URLSession cancelled the request (-999).
    public static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        if case DirectError.cancelled = error { return true }
        return false
    }

    /// A short failure reason for diagnostics, such as "timed out (-1001)" or "SOAP fault 500".
    public static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return "timed out (-1001)"
            case .networkConnectionLost: return "connection lost (-1005)"
            case .notConnectedToInternet: return "not connected (-1009)"
            case .cannotConnectToHost: return "cannot connect (-1004)"
            case .cannotFindHost: return "cannot find host (-1003)"
            case .cancelled: return "cancelled (-999)"
            default: return "URLError \(urlError.code.rawValue)"
            }
        }
        if case SonosSOAP.SOAPError.fault(let status) = error { return "SOAP fault \(status)" }
        return "\(error)"
    }

    // MARK: - State

    public func zones() async throws -> [Zone] {
        try await snapshot().zones
    }

    /// The layout as the speakers report it, with each group's state, plus every speaker address the
    /// layout listed (for saving, so new speakers and changed addresses are remembered).
    ///
    /// Throws only when no speaker answers at all (`DirectError.noSpeakerAnswered`): the one case where
    /// there's no layout to report. A speaker that doesn't answer its state queries keeps its place in
    /// the layout, with those values marked unread.
    public func snapshot() async throws -> (zones: [Zone], addresses: [String: String]) {
        let topology = try await topology()
        let zones = await withTaskGroup(of: (Int, Zone?).self) { group in
            for (index, topologyGroup) in topology.groups.enumerated() {
                group.addTask { (index, await Self.zone(for: topologyGroup)) }
            }
            var zones: [(Int, Zone)] = []
            for await (index, zone) in group {
                if let zone { zones.append((index, zone)) }
            }
            return zones.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return (zones, topology.addresses)
    }

    /// One group's state: transport, source and group volume from the coordinator, volume and
    /// mute from each room. Stereo-pair partners, satellites and bridges are not rooms.
    static func zone(for group: SonosSOAP.Topology.Group) async -> Zone? {
        let rooms = group.members.filter(\.isRoom)
        guard let coordinator = rooms.first(where: { $0.uuid == group.coordinator }) else { return nil }
        let instance = [("InstanceID", "0")]
        let master = [("InstanceID", "0"), ("Channel", "Master")]

        let timeout = SonosSOAP.readTimeout
        async let transport = try? SonosSOAP.call(coordinator.host, SonosSOAP.avTransport, "GetTransportInfo", instance, timeout: timeout)
        async let media = try? SonosSOAP.call(coordinator.host, SonosSOAP.avTransport, "GetMediaInfo", instance, timeout: timeout)
        async let groupVolume = try? SonosSOAP.call(coordinator.host, SonosSOAP.groupRenderingControl, "GetGroupVolume", instance, timeout: timeout)
        async let groupMute = try? SonosSOAP.call(coordinator.host, SonosSOAP.groupRenderingControl, "GetGroupMute", instance, timeout: timeout)

        // Each room's level, or nil when it didn't answer (its values are then marked unread).
        let levels = await withTaskGroup(of: (String, (volume: Int, mute: Bool, fixed: Bool)?).self) { tasks in
            for room in rooms {
                tasks.addTask {
                    async let volume = try? SonosSOAP.call(room.host, SonosSOAP.renderingControl, "GetVolume", master, timeout: timeout)
                    async let mute = try? SonosSOAP.call(room.host, SonosSOAP.renderingControl, "GetMute", master, timeout: timeout)
                    // Line-level outputs such as a Connect report a fixed volume the apps must not offer to change.
                    async let fixed = try? SonosSOAP.call(room.host, SonosSOAP.renderingControl, "GetOutputFixed", instance, timeout: timeout)
                    guard let volumeReply = await volume, let level = Int(volumeReply["CurrentVolume"] ?? ""),
                          let muteReply = await mute else { return (room.uuid, nil) }
                    return (room.uuid, (level, muteReply["CurrentMute"] == "1", await fixed?["CurrentFixed"] == "1"))
                }
            }
            var result: [String: (volume: Int, mute: Bool, fixed: Bool)] = [:]
            for await (uuid, level) in tasks { if let level { result[uuid] = level } }
            return result
        }

        let transportInfo = await transport
        let mediaInfo = await media
        let playbackRead = transportInfo != nil && mediaInfo != nil
        let track = Self.track(uri: mediaInfo?["CurrentURI"], metadata: mediaInfo?["CurrentURIMetaData"])
        let playback = transportInfo?["CurrentTransportState"] ?? "STOPPED"
        let coordinatorLevel = levels[coordinator.uuid]
        let groupState = GroupState(
            volume: Int(await groupVolume?["CurrentVolume"] ?? "") ?? coordinatorLevel?.volume ?? 0,
            mute: (await groupMute?["CurrentMute"]).map { $0 == "1" } ?? coordinatorLevel?.mute ?? false
        )

        func member(_ room: SonosSOAP.Topology.Member) -> Member {
            let level = levels[room.uuid]
            return Member(
                roomName: room.roomName,
                uuid: room.uuid,
                state: PlayerState(volume: level?.volume ?? 0, mute: level?.mute ?? false, currentTrack: playbackRead ? track : nil,
                                   playbackState: playback, isOutputFixed: level?.fixed ?? false,
                                   isPlaybackUnread: playbackRead ? nil : true, isLevelUnread: level == nil ? true : nil),
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

    /// The household's Sonos favorites, with what's needed to play each one.
    public func favorites() async throws -> [SonosSOAP.Favorite] {
        let topology = try await topology()
        guard let host = topology.groups.flatMap(\.members).first(where: \.isRoom)?.host else {
            throw DirectError.noSpeakerAnswered(reasons: ["layout listed no speakers"])
        }
        let response = try await SonosSOAP.call(host, SonosSOAP.contentDirectory, "Browse", [
            ("ObjectID", "FV:2"),
            ("BrowseFlag", "BrowseDirectChildren"),
            ("Filter", "*"),
            ("StartingIndex", "0"),
            ("RequestedCount", "200"),
            ("SortCriteria", ""),
        ])
        return SonosSOAP.parseFavorites(response["Result"] ?? "")
    }

    public func favoriteNames() async throws -> [String] {
        try await favorites().map(\.title)
    }

    // MARK: - Commands

    /// A room's speaker and its group's coordinator, from the current layout. Rooms are named as the
    /// speakers name them; the visible speaker of a stereo pair is the one that takes commands.
    private func locate(_ roomName: String) async throws -> (room: SonosSOAP.Topology.Member, coordinator: SonosSOAP.Topology.Member, topology: SonosSOAP.Topology) {
        let topology = try await topology()
        for group in topology.groups {
            let rooms = group.members.filter(\.isRoom)
            if let room = rooms.first(where: { $0.roomName == roomName }),
               let coordinator = rooms.first(where: { $0.uuid == group.coordinator }) {
                return (room, coordinator, topology)
            }
        }
        throw DirectError.roomNotFound(roomName)
    }

    /// Runs a command and reports success; failures are logged by the caller's refresh, not thrown.
    private func attempt(_ body: () async throws -> Void) async -> Bool {
        do { try await body(); return true } catch { return false }
    }

    private static let instance = ("InstanceID", "0")
    private static let master = ("Channel", "Master")

    /// Plays the group. A stopped stream (live radio after a pause) is first reloaded with the URI
    /// and metadata the speaker still holds, since Play alone may not restart it. This works for any
    /// station, preset or not.
    @discardableResult public func play(coordinator: String) async -> Bool {
        await attempt {
            let target = try await locate(coordinator).coordinator
            let transport = try await SonosSOAP.call(target.host, SonosSOAP.avTransport, "GetTransportInfo", [Self.instance])
            if transport["CurrentTransportState"] == "STOPPED" {
                let media = try await SonosSOAP.call(target.host, SonosSOAP.avTransport, "GetMediaInfo", [Self.instance])
                if let uri = media["CurrentURI"], !uri.isEmpty, !uri.hasPrefix("x-rincon:"), !uri.hasPrefix("x-rincon-queue:") {
                    try await setTransport(target.host, uri: uri, metadata: media["CurrentURIMetaData"] ?? "")
                }
            }
            _ = try await SonosSOAP.call(target.host, SonosSOAP.avTransport, "Play", [Self.instance, ("Speed", "1")])
        }
    }

    private func setTransport(_ host: String, uri: String, metadata: String) async throws {
        _ = try await SonosSOAP.call(host, SonosSOAP.avTransport, "SetAVTransportURI",
                                     [Self.instance, ("CurrentURI", uri), ("CurrentURIMetaData", metadata)])
    }

    @discardableResult public func pause(coordinator: String) async -> Bool {
        await attempt {
            let target = try await locate(coordinator).coordinator
            _ = try await SonosSOAP.call(target.host, SonosSOAP.avTransport, "Pause", [Self.instance])
        }
    }

    @discardableResult public func setVolume(_ level: Int, room: String) async -> Bool {
        await attempt {
            let target = try await locate(room).room
            _ = try await SonosSOAP.call(target.host, SonosSOAP.renderingControl, "SetVolume",
                                         [Self.instance, Self.master, ("DesiredVolume", "\(max(0, min(100, level)))")])
        }
    }

    @discardableResult public func setGroupVolume(_ level: Int, coordinator: String) async -> Bool {
        await attempt {
            let target = try await locate(coordinator).coordinator
            // The snapshot records each member's share, so the group keeps its balance as it scales.
            _ = try await SonosSOAP.call(target.host, SonosSOAP.groupRenderingControl, "SnapshotGroupVolume", [Self.instance])
            _ = try await SonosSOAP.call(target.host, SonosSOAP.groupRenderingControl, "SetGroupVolume",
                                         [Self.instance, ("DesiredVolume", "\(max(0, min(100, level)))")])
        }
    }

    @discardableResult public func setMute(_ muted: Bool, room: String) async -> Bool {
        await attempt {
            let target = try await locate(room).room
            _ = try await SonosSOAP.call(target.host, SonosSOAP.renderingControl, "SetMute",
                                         [Self.instance, Self.master, ("DesiredMute", muted ? "1" : "0")])
        }
    }

    @discardableResult public func setGroupMute(_ muted: Bool, coordinator: String) async -> Bool {
        await attempt {
            let target = try await locate(coordinator).coordinator
            _ = try await SonosSOAP.call(target.host, SonosSOAP.groupRenderingControl, "SetGroupMute",
                                         [Self.instance, ("DesiredMute", muted ? "1" : "0")])
        }
    }

    @discardableResult public func join(room: String, to target: String) async -> Bool {
        await attempt {
            let joiner = try await locate(room).room
            // Join the target room's group, through that group's coordinator.
            let leader = try await locate(target).coordinator
            guard joiner.uuid != leader.uuid else { return }
            _ = try await SonosSOAP.call(joiner.host, SonosSOAP.avTransport, "SetAVTransportURI",
                                         [Self.instance, ("CurrentURI", "x-rincon:\(leader.uuid)"), ("CurrentURIMetaData", "")])
        }
    }

    @discardableResult public func leave(room: String) async -> Bool {
        await attempt {
            let target = try await locate(room).room
            _ = try await SonosSOAP.call(target.host, SonosSOAP.avTransport, "BecomeCoordinatorOfStandaloneGroup", [Self.instance])
        }
    }

    /// Loads a preset into the group without starting it:
    /// - a Sonos favorite with the URI and metadata the speakers store for it (playlists and albums
    ///   replace the queue);
    /// - a line-in by its `x-rincon-stream:` URI;
    /// - a CSV or manual stream as `x-rincon-mp3radio://`, with metadata naming it, so the speaker
    ///   reports the preset's name as the source.
    @discardableResult public func loadPreset(_ station: Station, coordinator: String) async -> Bool {
        await attempt {
            let target = try await locate(coordinator).coordinator
            if station.isFavorite {
                let favorites = try await favorites()
                guard let favorite = favorites.first(where: { $0.title == station.url })
                        ?? favorites.first(where: { $0.title.caseInsensitiveCompare(station.url) == .orderedSame }) else {
                    throw DirectError.favoriteNotFound(station.url)
                }
                if favorite.isContainer {
                    _ = try await SonosSOAP.call(target.host, SonosSOAP.avTransport, "RemoveAllTracksFromQueue", [Self.instance])
                    _ = try await SonosSOAP.call(target.host, SonosSOAP.avTransport, "AddURIToQueue", [
                        Self.instance, ("EnqueuedURI", favorite.uri), ("EnqueuedURIMetaData", favorite.metadata),
                        ("DesiredFirstTrackNumberEnqueued", "0"), ("EnqueueAsNext", "0"),
                    ])
                    try await setTransport(target.host, uri: "x-rincon-queue:\(target.uuid)#0", metadata: "")
                } else {
                    try await setTransport(target.host, uri: favorite.uri, metadata: favorite.metadata)
                }
            } else if station.isLineIn {
                try await setTransport(target.host, uri: station.url, metadata: "")
            } else {
                let uri = station.url.lowercased().hasPrefix("x-") ? station.url : "x-rincon-mp3radio://\(station.url)"
                try await setTransport(target.host, uri: uri, metadata: SonosSOAP.streamMetadata(title: station.name))
            }
        }
    }
}
