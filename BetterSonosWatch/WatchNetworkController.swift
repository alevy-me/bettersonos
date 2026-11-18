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
//  WatchNetworkController.swift
//

import Foundation
import Combine
import BetterSonosCore
import os.log

private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "BetterSonosWatch", category: "WatchNetworkController")

/// One speaker, flattened for the watch. Playback and now-playing belong to the speaker's group.
struct RoomState: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let coordinator: String
    /// Every room in this room's group, including itself, sorted.
    let groupMembers: [String]
    var volume: Int
    var isMuted: Bool
    var groupVolume: Int
    var isGroupMuted: Bool
    var isPlaying: Bool
    /// True when the group's transport is stopped, as live radio is after a pause.
    let isStopped: Bool
    let nowPlaying: String?
    /// The group's current track, for matching the playing preset.
    let track: Track?
    /// Matches the iOS app's grayed-out volume controls.
    let isVolumeDisabled: Bool
    /// Group volume is disabled only when every member's volume is.
    let isGroupVolumeDisabled: Bool

    var isGrouped: Bool { groupMembers.count > 1 }
    var otherMembers: [String] { groupMembers.filter { $0 != name } }
}

/// What a volume or mute control acts on.
enum ControlTarget: Hashable {
    case room(String)
    case group(coordinator: String)
}

/// Talks to one node-sonos-http-api server. No SSE: it refreshes on demand, every 15 s while
/// active, and after every action. User changes are shown immediately and held over stale server
/// values until a refresh that started after the request completed confirms them.
@MainActor
final class WatchNetworkController: ObservableObject {
    @Published private(set) var rooms: [RoomState] = []
    @Published private(set) var hasLoaded = false
    @Published private(set) var errorMessage: String?
    /// Visible presets for this network, cached on the watch so the list appears instantly.
    @Published private(set) var presets: [Station] = []
    @Published private(set) var isLoadingPresets = false
    @Published private(set) var presetsError: String?

    let configID: UUID
    let baseURL: String
    /// The latest synced config, for per-speaker settings such as disabled volume.
    private(set) var config: NetworkConfig

    private var backend: any SonosBackend { config.backend }

    static let pollInterval: Duration = .seconds(15)
    static let volumeSendDelay: Duration = .milliseconds(300)

    private struct Pending<Value: Equatable> {
        var value: Value
        /// nil while the request is unsent or in flight. Once set, the first refresh with a higher
        /// generation reflects the server after the change, and the override is dropped.
        var clearAfterGeneration: Int?
    }

    private var lastZones: [Zone] = []
    private var refreshGeneration = 0
    private var appliedGeneration = 0
    private var pollTask: Task<Void, Never>?
    private var pendingVolume: [ControlTarget: Pending<Int>] = [:]
    private var pendingMute: [ControlTarget: Pending<Bool>] = [:]
    private var pendingPlaying: [String: Pending<Bool>] = [:] // keyed by coordinator
    private var volumeTasks: [ControlTarget: Task<Void, Never>] = [:]

    init(config: NetworkConfig) {
        self.configID = config.id
        self.baseURL = URLInput.normalizedBaseURL(config.baseURL)
        self.config = config
        self.presets = Self.loadCachedPresets(for: config.id)
    }

    /// Applies a newer synced copy of this network's config.
    func update(config: NetworkConfig) {
        guard config.id == configID, config != self.config else { return }
        self.config = config
        publishRooms()
    }

    deinit {
        pollTask?.cancel()
        volumeTasks.values.forEach { $0.cancel() }
    }

    func room(named name: String) -> RoomState? {
        rooms.first { $0.name == name }
    }

    /// Coordinators of the groups currently playing on this network. A lone speaker is its own group.
    var playingCoordinators: Set<String> {
        Set(rooms.filter(\.isPlaying).map(\.coordinator))
    }

    /// Refreshes every network concurrently, then returns the room to show if exactly one speaker or
    /// group is playing across all of them. nil when nothing, or more than one, is playing.
    static func solePlayingRoom(
        across controllers: [WatchNetworkController],
        lastNetworkID: UUID?,
        lastRoom: String?
    ) async -> (networkID: UUID, room: String)? {
        // Concurrent, so the slowest server sets the delay rather than the sum of all of them.
        await withTaskGroup(of: Void.self) { group in
            for controller in controllers {
                group.addTask { await controller.refresh() }
            }
        }

        var playing: [(controller: WatchNetworkController, coordinator: String)] = []
        for controller in controllers {
            for coordinator in controller.playingCoordinators {
                playing.append((controller, coordinator))
            }
        }
        guard playing.count == 1, let sole = playing.first else { return nil }

        let preferred = sole.controller.configID == lastNetworkID ? lastRoom : nil
        let room = sole.controller.roomToShow(forGroup: sole.coordinator, preferring: preferred)
        return (sole.controller.configID, room)
    }

    /// The room to show for a group: `preferred` when it belongs to that group, otherwise the coordinator.
    func roomToShow(forGroup coordinator: String, preferring preferred: String?) -> String {
        if let preferred, room(named: preferred)?.coordinator == coordinator {
            return preferred
        }
        return coordinator
    }

    // MARK: - Lifecycle

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                // Optional chaining holds self only for the refresh, never across the sleep.
                await self?.refresh()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Refresh

    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        let backend = self.backend
        switch await Result(asyncCatching: { try await backend.zones() }) {
        case .success(let zones):
            guard generation > appliedGeneration else { return }
            appliedGeneration = generation
            lastZones = zones
            dropConfirmedOverrides(upTo: generation)
            publishRooms()
            hasLoaded = true
            errorMessage = nil
        case .failure(let error):
            log.error("Refresh failed: \(error.localizedDescription, privacy: .public)")
            if generation > appliedGeneration {
                errorMessage = "Can't reach \(URL(string: baseURL)?.host ?? baseURL)."
            }
        }
    }

    private func dropConfirmedOverrides(upTo generation: Int) {
        pendingVolume = pendingVolume.filter { !Self.isConfirmed($0.value.clearAfterGeneration, by: generation) }
        pendingMute = pendingMute.filter { !Self.isConfirmed($0.value.clearAfterGeneration, by: generation) }
        pendingPlaying = pendingPlaying.filter { !Self.isConfirmed($0.value.clearAfterGeneration, by: generation) }
    }

    private static func isConfirmed(_ clearAfter: Int?, by generation: Int) -> Bool {
        guard let clearAfter else { return false }
        return generation > clearAfter
    }

    /// Rebuilds `rooms` from the last server snapshot with pending user changes laid over it.
    private func publishRooms() {
        var result: [RoomState] = []
        for zone in lastZones {
            let coordinator = zone.coordinator
            let members = Array(Set(zone.members.map(\.roomName) + [coordinator.roomName]))
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            let groupTarget = ControlTarget.group(coordinator: coordinator.roomName)
            let serverPlaying = ["PLAYING", "TRANSITIONING"].contains(coordinator.state.playbackState)
            let groupVolume = pendingVolume[groupTarget]?.value ?? coordinator.groupState?.volume ?? coordinator.state.volume
            let groupMuted = pendingMute[groupTarget]?.value ?? coordinator.groupState?.mute ?? coordinator.state.mute
            let isPlaying = pendingPlaying[coordinator.roomName]?.value ?? serverPlaying
            let track = coordinator.state.currentTrack
            let presetName = track.flatMap { bestMatchingStation(in: presets, for: $0)?.name }
            let nowPlaying = NowPlaying(track: track, presetName: presetName)?.line

            var seen = Set<String>()
            let players = ([coordinator] + zone.members).filter { seen.insert($0.roomName).inserted }
            let groupVolumeDisabled = players.allSatisfy { config.isVolumeDisabled(forPlayer: $0.uuid) }
            for member in players {
                let roomTarget = ControlTarget.room(member.roomName)
                result.append(RoomState(
                    name: member.roomName,
                    coordinator: coordinator.roomName,
                    groupMembers: members,
                    volume: pendingVolume[roomTarget]?.value ?? member.state.volume,
                    isMuted: pendingMute[roomTarget]?.value ?? member.state.mute,
                    groupVolume: groupVolume,
                    isGroupMuted: groupMuted,
                    isPlaying: isPlaying,
                    isStopped: coordinator.state.isStopped,
                    nowPlaying: nowPlaying,
                    track: coordinator.state.currentTrack,
                    isVolumeDisabled: config.isVolumeDisabled(forPlayer: member.uuid),
                    isGroupVolumeDisabled: groupVolumeDisabled
                ))
            }
        }
        result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let namesChanged = rooms.map(\.name) != result.map(\.name)
        if rooms != result { rooms = result }
        if namesChanged { SiriVocabulary.refresh() }
    }

    // MARK: - Actions

    func currentVolume(for target: ControlTarget) -> Int? {
        switch target {
        case .room(let name): return room(named: name)?.volume
        case .group(let coordinator): return rooms.first { $0.coordinator == coordinator }?.groupVolume
        }
    }

    func isVolumeDisabled(for target: ControlTarget) -> Bool {
        switch target {
        case .room(let name): return room(named: name)?.isVolumeDisabled ?? false
        case .group(let coordinator): return rooms.first { $0.coordinator == coordinator }?.isGroupVolumeDisabled ?? false
        }
    }

    func isMuted(_ target: ControlTarget) -> Bool? {
        switch target {
        case .room(let name): return room(named: name)?.isMuted
        case .group(let coordinator): return rooms.first { $0.coordinator == coordinator }?.isGroupMuted
        }
    }

    /// Shows the new volume immediately and sends only the value the Crown settles on.
    func setVolume(_ requested: Int, for target: ControlTarget) {
        let value = max(0, min(100, requested))
        guard !isVolumeDisabled(for: target), value != currentVolume(for: target) else { return }
        pendingVolume[target] = Pending(value: value)
        publishRooms()

        volumeTasks[target]?.cancel()
        volumeTasks[target] = Task { [weak self] in
            try? await Task.sleep(for: Self.volumeSendDelay)
            guard !Task.isCancelled, let self else { return }
            let ok: Bool
            switch target {
            case .room(let name): ok = await self.backend.setVolume(value, room: name)
            case .group(let coordinator): ok = await self.backend.setGroupVolume(value, coordinator: coordinator)
            }
            // A newer value set while this was in flight keeps its own override.
            if self.pendingVolume[target]?.value == value {
                if ok {
                    self.pendingVolume[target]?.clearAfterGeneration = self.refreshGeneration
                } else {
                    self.pendingVolume[target] = nil
                }
            }
            await self.refresh()
        }
    }

    func toggleMute(_ target: ControlTarget) {
        guard let muted = isMuted(target) else { return }
        let newValue = !muted
        pendingMute[target] = Pending(value: newValue)
        publishRooms()

        let backend = self.backend
        Task { [weak self] in
            let ok: Bool
            switch target {
            case .room(let name): ok = await backend.setMute(newValue, room: name)
            case .group(let coordinator): ok = await backend.setGroupMute(newValue, coordinator: coordinator)
            }
            guard let self else { return }
            if ok {
                self.pendingMute[target]?.clearAfterGeneration = self.refreshGeneration
            } else {
                self.pendingMute[target] = nil
            }
            await self.refresh()
        }
    }

    // MARK: - Presets

    private static func presetsCacheKey(for id: UUID) -> String { "watchPresets_\(id.uuidString)" }

    private static func loadCachedPresets(for id: UUID) -> [Station] {
        guard let data = UserDefaults.standard.data(forKey: presetsCacheKey(for: id)) else { return [] }
        return (try? JSONDecoder().decode([Station].self, from: data)) ?? []
    }

    /// Rebuilds the preset list with the same sources and rules as the iOS app, keeping the cached
    /// list on screen meanwhile. A failed build never replaces a good cached list.
    func loadPresets(settings: AppSettingsStore) async {
        guard !isLoadingPresets else { return }
        isLoadingPresets = true
        defer { isLoadingPresets = false }

        var uuidToRoomName: [String: String] = [:]
        for zone in lastZones {
            for member in [zone.coordinator] + zone.members where uuidToRoomName[member.uuid] == nil {
                uuidToRoomName[member.uuid] = member.roomName
            }
        }
        let inputs = StationListInputs(
            config: config,
            remoteCSVURL: settings.remoteCSVURL,
            manualStations: settings.manualStations,
            uuidToRoomName: uuidToRoomName
        )
        let result = await StationListBuilder.build(inputs)
        let visible = StationListBuilder.visibleStations(result.stations, for: config)

        if visible.isEmpty && result.incomplete {
            presetsError = presets.isEmpty ? "Couldn't load presets." : "Couldn't refresh presets."
            return
        }
        presetsError = nil
        if presets != visible { presets = visible }
        if let data = try? JSONEncoder().encode(visible) {
            UserDefaults.standard.set(data, forKey: Self.presetsCacheKey(for: configID))
        }
    }

    /// The preset playing in this room's group, matched the same way as the iOS app.
    func playingPreset(forRoom name: String) -> Station? {
        guard let room = room(named: name), room.isPlaying else { return nil }
        return matchedPreset(forRoom: name)
    }

    /// The preset matching whatever the room's group holds, playing or not.
    func matchedPreset(forRoom name: String) -> Station? {
        guard let track = room(named: name)?.track else { return nil }
        return bestMatchingStation(in: presets, for: track)
    }

    /// Loads a preset into the room's group and plays it.
    func playPreset(_ station: Station, inRoom name: String) {
        guard let room = room(named: name) else { return }
        let coordinator = room.coordinator
        pendingPlaying[coordinator] = Pending(value: true)
        publishRooms()

        let backend = self.backend
        Task { [weak self] in
            let loaded = await backend.loadPreset(station, coordinator: coordinator)
            let ok = await backend.play(coordinator: coordinator) && loaded
            guard let self else { return }
            if ok {
                self.pendingPlaying[coordinator]?.clearAfterGeneration = self.refreshGeneration
            } else {
                self.pendingPlaying[coordinator] = nil
            }
            await self.refresh()
            // The new track's metadata can take a moment to appear.
            try? await Task.sleep(for: .seconds(2))
            await self.refresh()
        }
    }

    // MARK: - Playback

    /// Play and pause act on the room's group, through its coordinator.
    func togglePlayback(room name: String) {
        guard let room = room(named: name) else { return }
        let coordinator = room.coordinator
        let play = !room.isPlaying

        // A stopped stream (live radio after a pause) restarts by reloading its preset.
        if play, room.isStopped, let preset = matchedPreset(forRoom: name) {
            playPreset(preset, inRoom: name)
            return
        }

        pendingPlaying[coordinator] = Pending(value: play)
        publishRooms()

        let backend = self.backend
        Task { [weak self] in
            let ok = play ? await backend.play(coordinator: coordinator) : await backend.pause(coordinator: coordinator)
            guard let self else { return }
            if ok {
                self.pendingPlaying[coordinator]?.clearAfterGeneration = self.refreshGeneration
            } else {
                self.pendingPlaying[coordinator] = nil
            }
            await self.refresh()
            // Transport state can lag the command (TRANSITIONING, then PLAYING), so check again shortly.
            try? await Task.sleep(for: .seconds(2))
            await self.refresh()

            // If play was accepted but nothing started, reload the matching preset as a fallback.
            if play, self.room(named: name)?.isPlaying == false, let preset = self.matchedPreset(forRoom: name) {
                self.playPreset(preset, inRoom: name)
            }
        }
    }
}
