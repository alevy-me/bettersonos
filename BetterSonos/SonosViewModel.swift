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
    /// Reads state and sends commands. Built from the current config each time, so speaker addresses
    /// learned or rediscovered later take effect. The SSE stream below is server-specific and separate.
    private var backend: any SonosBackend { currentConfig?.backend ?? fallbackBackend }
    private let fallbackBackend: any SonosBackend
    /// What triggered a refresh. Only scheduled polls count toward unavailable: refreshes after
    /// actions come in bursts and would trip it in seconds.
    enum RefreshKind { case scheduled, action }

    /// Consecutive scheduled polls where no local speaker answered. Any success, including an
    /// accepted command, resets it.
    private var failedScheduledPolls = 0
    /// Unavailable after this many failed scheduled polls in a row: 10 to 15 s at 5 s polls.
    static let unavailableAfterFailedPolls = 3
    /// True once this view model has told discovery the network is unreachable, until it answers again.
    private var reportedUnreachable = false
    /// A local network talks to the speakers directly: no server, so no SSE, and a faster poll instead.
    private let isLocal: Bool
    /// Local or hybrid: the speakers are reached directly at least some of the time, so reachability
    /// follows their answers (missed-poll counting). Read live, since a server network can gain its
    /// household while this view model is running.
    private var usesDirectControl: Bool { currentConfig?.usesDirectControl ?? isLocal }
    /// The server's live event stream is connected. A hybrid network then polls only as a backstop.
    private var sseConnected = false
    private let networkStore: NetworkConfigStore
    private let settingsStore: AppSettingsStore
    private var cancellables = Set<AnyCancellable>()

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
        let config = networkStore.configs.first { $0.id == configID }
        self.lastConfigSnapshot = config
        self.fallbackBackend = config?.backend ?? ServerBackend(baseURL: baseURL)
        self.isLocal = config?.isLocal ?? false

        let sseConfig = URLSessionConfiguration.default
        sseConfig.timeoutIntervalForRequest = Constants.sseTimeout
        sseConfig.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.sseSession = URLSession(configuration: sseConfig)

        observeAppSettings()
        observeConfig()
        observeAppLifecycle()
        if !isLocal { startListeningForEvents() }
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

        let config = currentConfig

        for zone in zones {
            let coordinator = zone.coordinator
            newGroups.append(SonosGroup(coordinator: coordinator.roomName, joiners: orderedJoiners(for: zone, excluding: coordinator.roomName)))

            for member in [coordinator] + zone.members {
                let room = member.roomName
                newVolumeDisabled[room] = config?.isVolumeDisabled(for: member) ?? (Constants.fixedVolumeUUIDs.contains(member.uuid) || member.state.isOutputFixed == true)
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
        if roomNamesChanged {
            uuidToRoomName = newUUIDToRoomName
            SiriVocabulary.refresh()
        }

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

    func refresh(kind: RefreshKind = .action) async {
        refreshGeneration += 1
        let generation = refreshGeneration

        let backend = self.backend
        log.debug("Refreshing \(self.baseURL, privacy: .public)")
        // Zones drive the UI; favorites are independent, so a favorites failure never blocks zone state.
        // Reading the speakers directly also reports every address their layout lists, for saving.
        async let zonesResult = Result(asyncCatching: { () -> (zones: [Zone], addresses: [String: String]?) in
            if let direct = backend as? DirectBackend {
                let snapshot = try await direct.snapshot()
                return (snapshot.zones, snapshot.addresses)
            }
            if let hybrid = backend as? HybridBackend {
                return try await hybrid.snapshot()
            }
            return (try await backend.zones(), nil)
        })
        async let favoritesResult = Result(asyncCatching: { try await backend.favoriteNames() })
        let zones = await zonesResult
        let favorites = await favoritesResult

        switch zones {
        case .success(let snapshot):
            if generation > appliedRefreshGeneration {
                appliedRefreshGeneration = generation
                // A speaker that didn't answer keeps its last reported values rather than defaults.
                processZones(snapshot.zones.carryingForward(from: lastZones))
            }
            if let addresses = snapshot.addresses { saveLearnedAddresses(addresses) }
            noteContact()
            hasLoadedZones = true
            refreshError = nil
        case .failure(let error) where DirectBackend.isCancellation(error):
            // Cancelled (polling paused, the app moved on): neither a success nor a failure.
            log.debug("Refresh cancelled")
        case .failure(let error):
            log.error("Error refreshing Sonos state: \(error.localizedDescription, privacy: .public)")
            // Report what the speakers report. On a local network, a failed refresh changes nothing until
            // the silence is confirmed: three failed scheduled polls in a row. Refreshes after actions
            // never count.
            if usesDirectControl {
                if kind == .scheduled { failedScheduledPolls += 1 }
                let confirmed = failedScheduledPolls >= Self.unavailableAfterFailedPolls
                if confirmed, generation > appliedRefreshGeneration {
                    refreshError = isLocal
                        ? "Can't reach your speakers. Make sure you're on the same Wi-Fi as your Sonos system."
                        : "Can't reach your speakers directly or through the server."
                }
                // Confirmed silence: speakers may have new addresses, or you've left. Discovery looks again
                // and decides availability (it debounces).
                if isLocal, confirmed, !reportedUnreachable, let householdID = currentConfig?.householdID {
                    reportedUnreachable = true
                    NotificationCenter.default.post(name: DiscoveryCoordinator.localNetworkUnreachable, object: householdID)
                }
            } else if generation > appliedRefreshGeneration {
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

    /// The speakers answered something (a read or an accepted command): they're there.
    private func noteContact() {
        failedScheduledPolls = 0
        if reportedUnreachable, let householdID = currentConfig?.householdID {
            reportedUnreachable = false
            NotificationCenter.default.post(name: DiscoveryCoordinator.localNetworkReachable, object: householdID)
        }
    }

    /// Saves speaker addresses the layout reported, only when they changed, so new speakers and new
    /// addresses reach the watch and other devices without waiting for discovery. Merged, not replaced:
    /// a speaker missing from one read (rebooting, asleep) keeps its saved address.
    private func saveLearnedAddresses(_ addresses: [String: String]) {
        guard usesDirectControl, !addresses.isEmpty, var config = currentConfig else { return }
        let merged = config.speakerAddresses.merging(addresses) { _, new in new }
        guard merged != config.speakerAddresses else { return }
        config.speakerAddresses = merged
        networkStore.update(config)
    }

    // MARK: - Stations

    func filteredStations(for config: NetworkConfig) -> [Station] {
        StationListBuilder.visibleStations(remoteStations, for: config)
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
        let backend = self.backend
        Task { [weak self] in
            if await backend.setVolume(newVolume, room: room) { self?.noteContact() }
            // Always reconcile: fixed-volume outputs accept the request without changing anything.
            await self?.refresh()
        }
    }

    func toggleMute(room: String) {
        let mute = !(isMuted[room] ?? false)
        isMuted[room] = mute // Optimistic update
        let backend = self.backend
        Task { [weak self] in
            if await backend.setMute(mute, room: room) { self?.noteContact() }
            await self?.refresh()
        }
    }

    @discardableResult
    private func sendStreamURL(to room: String, station: Station) async -> Bool {
        log.debug("Sending \(station.name, privacy: .public) to \(room, privacy: .public)")
        return await backend.loadPreset(station, coordinator: room)
    }

    func togglePlayback(group: SonosGroup) {
        let coordinator = group.coordinator
        Task { [weak self] in
            guard let self else { return }
            if self.playbackState[coordinator] == "PLAYING" {
                await self.backend.pause(coordinator: coordinator)
            } else {
                // Resume whatever the transport holds. A stopped stream (live radio after a pause) or a failed
                // resume reloads the selected preset instead.
                let reloadFirst = self.playbackState[coordinator] == "STOPPED" && self.selectedStationByRoom[coordinator] != nil
                let resumed = reloadFirst ? false : await self.backend.play(coordinator: coordinator)
                if !resumed, let station = self.selectedStationByRoom[coordinator] {
                    await self.sendStreamURL(to: coordinator, station: station)
                    await self.backend.play(coordinator: coordinator)
                }
            }
            await self.refresh()
        }
    }

    func isPlaying(group: SonosGroup) -> Bool {
        playbackState[group.coordinator] == "PLAYING"
    }

    func joinGroup(room: String, target: String) {
        let backend = self.backend
        Task { [weak self] in
            if await backend.join(room: room, to: target) { self?.noteContact() }
            await self?.refresh()
        }
    }

    func leaveGroup(room: String) {
        let backend = self.backend
        Task { [weak self] in
            if await backend.leave(room: room) { self?.noteContact() }
            await self?.refresh()
        }
    }

    func playStation(_ station: Station, in room: String) {
        Task { [weak self] in
            guard let self else { return }
            await self.sendStreamURL(to: room, station: station)
            await self.backend.play(coordinator: room)
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

        // 3. Whatever metadata the track has, cleaned (status codes, file names, repeats; see NowPlaying).
        if let nowPlaying = NowPlaying(track: track), !nowPlaying.line.isEmpty {
            return label(nowPlaying.line)
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
        if !sseConnected {
            sseConnected = true
            if usesDirectControl { startPolling() } // relax to the backstop interval
        }
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
        if sseConnected {
            sseConnected = false
            if usesDirectControl { startPolling() } // no change signal now: poll at the fast pace
        }
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
    /// Server networks get live updates over SSE and poll only as a backstop; local networks rely on polling.
    /// Local: always the fast poll (no event stream). Hybrid: the slow backstop while the server's event
    /// stream is connected (it signals changes; reads still go direct at home), the fast poll otherwise.
    /// Server: the slow backstop.
    private var pollInterval: TimeInterval {
        if isLocal { return Constants.localPollInterval }
        if usesDirectControl { return sseConnected ? Constants.pollInterval : Constants.localPollInterval }
        return Constants.pollInterval
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.pollInterval ?? Constants.pollInterval))
                if Task.isCancelled { return }
                guard let self else { return }
                await self.refresh(kind: .scheduled)
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
                if !self.isLocal { self.startListeningForEvents() }
                self.startPolling()
                Task { [weak self] in await self?.refresh() }
            }
            .store(in: &cancellables)
    }

    private struct SSEEvent: Decodable {
        let type: String
    }
}
