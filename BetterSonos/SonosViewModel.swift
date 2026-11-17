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
//  SonosViewModel.swift
//

import SwiftUI
import Foundation
import Combine
import os.log
import BetterSonosCore

private let log = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "SonosViewModel")

// MARK: - ViewModel

@MainActor
final class SonosViewModel: ObservableObject {

    // Published State
    @Published private(set) var groups: [SonosGroup] = []
    @Published private(set) var volume: [String: Int] = [:]
    @Published private(set) var isMuted: [String: Bool] = [:]
    @Published private(set) var playbackState: [String: String] = [:]
    @Published private(set) var selectedStationByRoom: [String: Station] = [:]
    @Published private(set) var remoteStations: [Station] = []
    @Published private(set) var volumeDisabled: [String: Bool] = [:]
    @Published private(set) var trackByRoom: [String: Track] = [:]
    @Published private(set) var uuidToRoomName: [String: String] = [:]
    @Published private(set) var accordionState: [String: Bool] = [:]
    @Published private(set) var status: NetworkStatus = .connecting

    let configID: UUID
    private let baseURL: String
    private let networkStore: NetworkConfigStore
    private let settingsStore: AppSettingsStore
    private var cancellables = Set<AnyCancellable>()

    private let connectUUIDs: Set<String> = [
        "RINCON_B8000000000000000"  // Example hardcoded Connect UUID
    ]

    // Status inputs. `status` is derived from these in updateStatus().
    private var hasLoadedZones = false
    private var refreshError: String?
    private var sseError: String?

    // Refresh ordering: a response is applied only if no newer refresh has already been applied.
    private var refreshGeneration = 0
    private var appliedRefreshGeneration = 0
    private var lastZones: [Zone] = []

    // Station list rebuilds: one in flight at a time; stale results are discarded.
    private var stationRebuildTask: Task<Void, Never>?
    private var stationRebuildGeneration = 0
    private var hasBuiltStations = false
    private var stationsIncomplete = false
    private var lastStationBuildStart: Date = .distantPast
    private var lastConfigSnapshot: NetworkConfig?

    // Live updates. Every long-lived task captures self weakly, so the view model can deallocate.
    private let sseSession: URLSession
    private var sseTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var retryAttempts = 0

    private static let refreshEventTypes: Set<String> = ["topology-change", "transport-state", "volume-change", "mute-change"]

    init(configID: UUID, baseURL: String, networkStore: NetworkConfigStore, settingsStore: AppSettingsStore) {
        self.configID = configID
        self.baseURL = URLInput.normalizedBaseURL(baseURL)
        self.networkStore = networkStore
        self.settingsStore = settingsStore
        self.lastConfigSnapshot = networkStore.configs.first { $0.id == configID }

        let sseConfig = URLSessionConfiguration.default
        sseConfig.timeoutIntervalForRequest = Constants.sseTimeout
        sseConfig.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.sseSession = URLSession(configuration: sseConfig)

        observeAppSettings()
        observeConfig()
        observeAppLifecycle()
        startListeningForEvents()
        startPolling()

        Task { [weak self] in
            await self?.refresh()
            self?.scheduleStationRebuild()
        }
    }

    deinit {
        sseTask?.cancel()
        reconnectTask?.cancel()
        pollTask?.cancel()
        debounceTask?.cancel()
        stationRebuildTask?.cancel()
        sseSession.invalidateAndCancel()
    }

    private var currentConfig: NetworkConfig? {
        networkStore.configs.first { $0.id == configID }
    }

    private func apiURL(_ pathComponents: String...) -> URL? {
        SonosHTTP.url(base: baseURL, pathComponents)
    }

    private func updateStatus() {
        let newStatus: NetworkStatus
        if let refreshError {
            newStatus = .error(refreshError)
        } else if let sseError {
            newStatus = .error(sseError)
        } else if hasLoadedZones {
            newStatus = .connected
        } else {
            newStatus = .connecting
        }
        if status != newStatus { status = newStatus }
    }

    // MARK: - Zones

    private func orderedJoiners(for zone: Zone, excluding coordinator: String) -> [String] {
        zone.members
            .map(\.roomName)
            .filter { $0 != coordinator }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func processZones(_ zones: [Zone]) {
        lastZones = zones
        var newGroups: [SonosGroup] = []
        var newVolume: [String: Int] = [:]
        var newMuted: [String: Bool] = [:]
        var newPlayback: [String: String] = [:]
        var newTrackByRoom: [String: Track] = [:]
        var newVolumeDisabled: [String: Bool] = [:]
        var newUUIDToRoomName: [String: String] = [:]

        let manuallyDisabledUUIDs = currentConfig?.manuallyDisabledVolumeUUIDs ?? []

        for zone in zones {
            let coordinator = zone.coordinator
            newGroups.append(SonosGroup(coordinator: coordinator.roomName, joiners: orderedJoiners(for: zone, excluding: coordinator.roomName)))

            for member in [coordinator] + zone.members {
                let room = member.roomName
                newVolumeDisabled[room] = connectUUIDs.contains(member.uuid) || manuallyDisabledUUIDs.contains(member.uuid)
                newVolume[room] = member.state.volume
                newMuted[room] = member.state.mute
                newPlayback[room] = member.state.playbackState
                if let track = member.state.currentTrack {
                    newTrackByRoom[room] = track
                }
                if newUUIDToRoomName[member.uuid] == nil {
                    newUUIDToRoomName[member.uuid] = room
                }
            }
        }

        let sortedGroups = newGroups.sorted { $0.coordinator.localizedCaseInsensitiveCompare($1.coordinator) == .orderedAscending }
        // Assign only on change, so unchanged polls do not re-render the whole network.
        if groups != sortedGroups { groups = sortedGroups }
        if volume != newVolume { volume = newVolume }
        if isMuted != newMuted { isMuted = newMuted }
        if playbackState != newPlayback { playbackState = newPlayback }
        if trackByRoom != newTrackByRoom { trackByRoom = newTrackByRoom }
        if volumeDisabled != newVolumeDisabled { volumeDisabled = newVolumeDisabled }

        let roomNamesChanged = uuidToRoomName != newUUIDToRoomName
        if roomNamesChanged { uuidToRoomName = newUUIDToRoomName }

        updateSelections()
        loadAccordionStateFromDefaults()

        // Line-in preset names default to room names, so a rename (or the first successful load) needs a rebuild.
        if roomNamesChanged, hasBuiltStations, !(currentConfig?.enabledLineInUUIDs.isEmpty ?? true) {
            scheduleStationRebuild()
        }
    }

    private func updateSelections() {
        var selections: [String: Station] = [:]
        for room in trackByRoom.keys {
            if let match = matchedStation(for: room) {
                selections[room] = match
            }
        }
        if selectedStationByRoom != selections { selectedStationByRoom = selections }
    }

    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration

        guard let zonesURL = URL(string: "\(baseURL)/zones"),
              let favoritesURL = URL(string: "\(baseURL)/favorites") else {
            refreshError = "Invalid server URL."
            updateStatus()
            return
        }

        log.debug("Refreshing \(self.baseURL, privacy: .public)")
        // /zones drives the UI; /favorites is independent, so a favorites failure never blocks zone state.
        async let zonesResult = SonosHTTP.fetchJSON([Zone].self, from: zonesURL)
        async let favoritesResult = SonosHTTP.fetchJSON([String].self, from: favoritesURL)
        let zones = await zonesResult
        let favorites = await favoritesResult

        switch zones {
        case .success(let zones):
            if generation > appliedRefreshGeneration {
                appliedRefreshGeneration = generation
                processZones(zones)
            }
            hasLoadedZones = true
            refreshError = nil
        case .failure(let error):
            log.error("Error refreshing Sonos state: \(error.localizedDescription, privacy: .public)")
            if generation > appliedRefreshGeneration {
                refreshError = "Failed to refresh speaker status. Please check your connection to the node-sonos-http-api server."
            }
        }

        switch favorites {
        case .success(let names):
            let stations = names.map { Station(name: $0, url: $0, type: .favorite) }
            networkStore.mergeFavorites(for: configID, newFavoritesFromServer: stations)
        case .failure(let error):
            log.error("Error fetching favorites: \(error.localizedDescription, privacy: .public)")
        }

        updateStatus()

        if case .success = zones { retryIncompleteStationsIfDue() }
    }

    // MARK: - Stations

    func filteredStations(for config: NetworkConfig) -> [Station] {
        remoteStations.filter { station in
            !(station.isFavorite && config.explicitlyDisabledFavoriteURLs.contains(station.url))
        }
    }

    private func scheduleStationRebuild() {
        guard let config = currentConfig else {
            log.error("No NetworkConfig for id \(self.configID.uuidString, privacy: .public)")
            return
        }
        stationRebuildTask?.cancel()
        stationRebuildGeneration += 1
        let generation = stationRebuildGeneration
        lastStationBuildStart = Date()

        let inputs = StationListInputs(
            config: config,
            remoteCSVURL: settingsStore.remoteCSVURL,
            manualStations: settingsStore.manualStations,
            uuidToRoomName: uuidToRoomName
        )
        stationRebuildTask = Task { [weak self] in
            let result = await StationListBuilder.build(inputs)
            guard !Task.isCancelled, let self, generation == self.stationRebuildGeneration else { return }
            self.stationRebuildTask = nil
            self.hasBuiltStations = true
            self.stationsIncomplete = result.incomplete
            if self.remoteStations != result.stations { self.remoteStations = result.stations }
            if let failed = result.customCSVFailed {
                self.settingsStore.csvLoadError = failed
            } else {
                self.settingsStore.csvLoadError = false
            }
            self.updateSelections()
        }
    }

    /// Retries a station list that failed to load (network down at launch, unresolved line-in names), throttled.
    private func retryIncompleteStationsIfDue() {
        guard stationsIncomplete, stationRebuildTask == nil,
              Date().timeIntervalSince(lastStationBuildStart) >= Constants.stationRetryInterval else { return }
        scheduleStationRebuild()
    }

    private func observeAppSettings() {
        // The CSV field writes on every keystroke, so settle before rebuilding.
        Publishers.Merge(
            settingsStore.$manualStations.dropFirst().removeDuplicates().map { _ in () },
            settingsStore.$remoteCSVURL.dropFirst().removeDuplicates().map { _ in () }
        )
        .debounce(for: .milliseconds(600), scheduler: DispatchQueue.main)
        .sink { [weak self] in
            self?.scheduleStationRebuild()
        }
        .store(in: &cancellables)
    }

    /// The row for this network is keyed by id, so the view model observes its own config instead of being rebuilt.
    private func observeConfig() {
        let id = configID
        networkStore.$configs
            .map { configs in configs.first { $0.id == id } }
            .removeDuplicates()
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] config in
                self?.configDidChange(config)
            }
            .store(in: &cancellables)
    }

    private func configDidChange(_ config: NetworkConfig?) {
        guard let config else { return }
        let previous = lastConfigSnapshot
        lastConfigSnapshot = config
        guard let previous else {
            scheduleStationRebuild()
            return
        }

        if previous.manuallyDisabledVolumeUUIDs != config.manuallyDisabledVolumeUUIDs {
            processZones(lastZones)
        }
        let stationInputsChanged =
            previous.enabledLineInUUIDs != config.enabledLineInUUIDs ||
            previous.lineInCustomNames != config.lineInCustomNames ||
            previous.showDefaultPresetsForThisNetwork != config.showDefaultPresetsForThisNetwork ||
            previous.lastKnownServerFavorites != config.lastKnownServerFavorites ||
            previous.explicitlyDisabledFavoriteURLs != config.explicitlyDisabledFavoriteURLs
        if stationInputsChanged {
            scheduleStationRebuild()
        }
    }

    // MARK: - Actions

    func selectStation(_ s: Station, for room: String) {
        selectedStationByRoom[room] = s
    }

    func adjustVolume(room: String, delta: Int) {
        let newVolume = max(0, min(100, (volume[room] ?? 50) + delta))
        volume[room] = newVolume // Optimistic update
        let url = apiURL(room, "volume", "\(newVolume)")
        Task { [weak self] in
            await SonosHTTP.get(url)
            // Always reconcile: fixed-volume outputs accept the request without changing anything.
            await self?.refresh()
        }
    }

    func toggleMute(room: String) {
        let mute = !(isMuted[room] ?? false)
        isMuted[room] = mute // Optimistic update
        let url = apiURL(room, mute ? "mute" : "unmute")
        Task { [weak self] in
            await SonosHTTP.get(url)
            await self?.refresh()
        }
    }

    @discardableResult
    private func sendStreamURL(to room: String, station: Station) async -> Bool {
        let url: URL?
        if station.isFavorite {
            url = apiURL(room, "favorite", station.url)
        } else if station.isLineIn {
            url = apiURL(room, "setavtransporturi", station.url)
        } else {
            url = apiURL(room, "setavtransporturi", "x-rincon-mp3radio://\(station.url)")
        }
        log.debug("Sending \(station.name, privacy: .public) to \(room, privacy: .public)")
        return await SonosHTTP.get(url)
    }

    func togglePlayback(group: SonosGroup) {
        let coordinator = group.coordinator
        Task { [weak self] in
            guard let self else { return }
            if self.playbackState[coordinator] == "PLAYING" {
                await SonosHTTP.get(self.apiURL(coordinator, "pause"))
            } else {
                // Resume whatever the transport holds. Only reload the selected preset if there is nothing to resume.
                let resumed = await SonosHTTP.get(self.apiURL(coordinator, "play"))
                if !resumed, let station = self.selectedStationByRoom[coordinator] {
                    await self.sendStreamURL(to: coordinator, station: station)
                    await SonosHTTP.get(self.apiURL(coordinator, "play"))
                }
            }
            await self.refresh()
        }
    }

    func isPlaying(group: SonosGroup) -> Bool {
        playbackState[group.coordinator] == "PLAYING"
    }

    func joinGroup(room: String, target: String) {
        let url = apiURL(room, "join", target)
        Task { [weak self] in
            await SonosHTTP.get(url)
            await self?.refresh()
        }
    }

    func leaveGroup(room: String) {
        let url = apiURL(room, "leave")
        Task { [weak self] in
            await SonosHTTP.get(url)
            await self?.refresh()
        }
    }

    func playStation(_ station: Station, in room: String) {
        Task { [weak self] in
            guard let self else { return }
            await self.sendStreamURL(to: room, station: station)
            await SonosHTTP.get(self.apiURL(room, "play"))
            for _ in 0..<3 {
                try? await Task.sleep(for: .seconds(1))
                await self.refresh()
            }
        }
    }

    private func matchedStation(for room: String) -> Station? {
        guard let track = trackByRoom[room] else { return nil }
        return bestMatchingStation(in: remoteStations, for: track)
    }

    // MARK: - Accordion State

    func isAccordionExpanded(for room: String) -> Bool {
        if playbackState[room] == "PLAYING" {
            return true
        }
        return accordionState[room] ?? false
    }

    func setAccordionState(for room: String, expanded: Bool) {
        accordionState[room] = expanded
        persistAccordionState(for: room, expanded: expanded)
    }

    private let accordionDefaultsKeyPrefix = "accordionState_"

    func loadAccordionStateFromDefaults() {
        var newState = accordionState
        for group in groups {
            let key = accordionDefaultsKeyPrefix + group.coordinator
            newState[group.coordinator] = UserDefaults.standard.object(forKey: key) as? Bool ?? false
        }
        if accordionState != newState { accordionState = newState }
    }

    func persistAccordionState(for room: String, expanded: Bool) {
        UserDefaults.standard.set(expanded, forKey: accordionDefaultsKeyPrefix + room)
    }

    // MARK: - Display

    func stationDisplay(for room: String) -> String {
        let isPlaying = playbackState[room] == "PLAYING"
        func label(_ name: String) -> String { isPlaying ? name : "\(name) (Queued)" }

        guard let track = trackByRoom[room] else {
            if let selected = selectedStationByRoom[room] {
                return "\(selected.name) (Queued)"
            }
            return "Nothing queued"
        }

        // 1. A known preset (line-in presets already carry their custom names).
        if let matched = matchedStation(for: room) {
            return label(matched.name)
        }

        // 2. A line-in that is not configured as a preset.
        if let uri = track.trackUri ?? track.uri, uri.hasPrefix("x-rincon-stream:") {
            let bareUUID = String(uri.dropFirst("x-rincon-stream:".count).split(separator: ":").first ?? "")
            if !bareUUID.isEmpty {
                if let customName = currentConfig?.lineInCustomNames[bareUUID], !customName.isEmpty {
                    return label(customName)
                }
                if let sourceRoomName = uuidToRoomName[bareUUID] {
                    return label("Line In (\(sourceRoomName))")
                }
                return label("Line In")
            }
        }

        // 3. Whatever metadata the track has.
        if let candidate = track.stationName ?? track.artist ?? track.title, !candidate.isEmpty {
            return label(candidate)
        }
        return "Nothing queued"
    }

    // MARK: - Live Updates (SSE)

    private func startListeningForEvents() {
        reconnectTask?.cancel()
        reconnectTask = nil
        sseTask?.cancel()

        guard let url = URL(string: "\(baseURL)/events") else {
            log.error("[SSE] Invalid URL for /events endpoint: \(self.baseURL, privacy: .public)/events")
            sseError = "Invalid server URL."
            updateStatus()
            return
        }

        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let session = sseSession

        log.info("[SSE] Connecting to \(url.absoluteString, privacy: .public)")
        sseTask = Task { [weak self] in
            var established = false
            do {
                let (bytes, response) = try await session.bytes(for: request)
                try SonosHTTP.validate(response)
                // node-sonos-http-api marks the stream text/event-stream. Anything else (an HTML error page,
                // a different web server) is not a live stream.
                if let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"),
                   !contentType.lowercased().contains("text/event-stream") {
                    throw SonosHTTP.RequestError.badStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
                }
                established = true
                self?.sseDidConnect()

                // `lines` buffers across network chunks, so events split over several reads stay intact.
                for try await line in bytes.lines {
                    guard let self else { return }
                    self.handleSSELine(line)
                }
                if Task.isCancelled { return }
                self?.sseDidEnd(established: true, error: nil)
            } catch {
                if Task.isCancelled { return }
                self?.sseDidEnd(established: established, error: error)
            }
        }
    }

    private func stopListeningForEvents() {
        reconnectTask?.cancel()
        reconnectTask = nil
        sseTask?.cancel()
        sseTask = nil
    }

    private func sseDidConnect() {
        log.info("[SSE] Connected.")
        retryAttempts = 0
        if sseError != nil {
            sseError = nil
            updateStatus()
        }
    }

    private func handleSSELine(_ line: String) {
        guard line.hasPrefix("data:") else { return }
        let json = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard let data = json.data(using: .utf8),
              let event = try? JSONDecoder().decode(SSEEvent.self, from: data),
              Self.refreshEventTypes.contains(event.type) else { return }
        debouncedRefresh()
    }

    private func sseDidEnd(established: Bool, error: Error?) {
        let delay: TimeInterval
        let isIdleTimeout = (error as? URLError)?.code == .timedOut
        if established || isIdleTimeout {
            // A stream that was up, or one that was merely quiet, is not a failure. Reconnect promptly.
            log.info("[SSE] Stream ended (\(error?.localizedDescription ?? "closed by server", privacy: .public)). Reconnecting.")
            retryAttempts = 0
            delay = 1
        } else {
            retryAttempts += 1
            delay = min(pow(2.0, Double(retryAttempts)), Constants.maxReconnectDelay)
            log.info("[SSE] Connection failed (\(error?.localizedDescription ?? "unknown", privacy: .public)). Attempt \(self.retryAttempts), retrying in \(delay)s.")
            if retryAttempts >= Constants.maxRetryAttempts {
                // Keep retrying at the capped delay, but tell the user live updates are down.
                sseError = "Live connection to server lost. Status updates may be delayed."
                updateStatus()
            }
        }

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.startListeningForEvents()
        }
    }

    private func debouncedRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    /// Polls independently of SSE, so a flapping stream can never starve the poll.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Constants.pollInterval))
                if Task.isCancelled { return }
                guard let self else { return }
                await self.refresh()
            }
        }
    }

    private func observeAppLifecycle() {
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                self.stopListeningForEvents()
                self.pollTask?.cancel()
                self.pollTask = nil
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                self.retryAttempts = 0
                self.startListeningForEvents()
                self.startPolling()
                Task { [weak self] in await self?.refresh() }
            }
            .store(in: &cancellables)
    }

    private struct SSEEvent: Decodable {
        let type: String
    }
}
