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

// Logger accessible from nonisolated contexts (URLSessionDataDelegate)
private let sseLogger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "SonosViewModel.SSE")

// MARK: - ViewModel

@MainActor
class SonosViewModel: NSObject, ObservableObject {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "SonosViewModel")

    // Published State
    @Published var groups: [SonosGroup] = []
    @Published var volume: [String: Int] = [:]
    @Published var isMuted: [String: Bool] = [:]
    @Published var playbackState: [String: String] = [:]
    @Published var selectedStation: Station?
    @Published var selectedStationByRoom: [String: Station] = [:]
    @Published var deviceIPs: [String: String] = [:]
    @Published var currentTrackTitle: [String: String] = [:]
    @Published var remoteStations: [Station] = []
    @Published var volumeDisabled: [String: Bool] = [:]
    @Published var trackByRoom: [String: Track] = [:]
    @Published var uuidToRoomName: [String: String] = [:]
    @Published var accordionState: [String: Bool] = [:]
    @Published var status: NetworkStatus = .connecting

    private var retryAttempts = 0
    private let maxRetryAttempts = Constants.maxRetryAttempts
    private var reconnectWorkItem: DispatchWorkItem?
    
    private let networkStore: NetworkConfigStore
    private let settingsStore: AppSettingsStore // Declare type, will be initialized in init
    private var cancellables = Set<AnyCancellable>()   // To store Combine subscriptions
    
    private let baseURL: String

    private let connectUUIDs: Set<String> = [
        "RINCON_B8000000000000000"  // Example hardcoded Connect UUID
    ]
    
    var pagedStations: [[Station]] {
        let chunkSize = 12
        let total = remoteStations.count
        var pages: [[Station]] = []
        for start in stride(from: 0, to: total, by: chunkSize) {
            let end = min(start + chunkSize, total)
            pages.append(Array(remoteStations[start..<end]))
        }
        return pages
    }
    
    init(baseURL: String, networkStore: NetworkConfigStore, settingsStore: AppSettingsStore) { // Added settingsStore parameter
        self.baseURL = baseURL
        self.networkStore = networkStore
        self.settingsStore = settingsStore // Assign from parameter
        super.init()
        self.startListeningForEvents()
        self.initializeAsyncData()
        Task { @MainActor [weak self] in
                    // Ensure self is still around when this task executes
                    self?.observeAppSettings()
                }    }

    deinit {
        reconnectWorkItem?.cancel()
        sseTask?.cancel()
        pollTimer?.invalidate()
        cancellables.removeAll()
        NotificationCenter.default.removeObserver(self)
    }

    private func encode(_ component: String) -> String? {
        return component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
    }

    private func apiURL(_ pathComponents: String...) -> URL? {
        var path = baseURL
        for component in pathComponents {
            guard let encoded = component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
                return nil
            }
            path += "/\(encoded)"
        }
        return URL(string: path)
    }
    
    private func initializeAsyncData() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refresh()
            self.remoteStations = await self.buildRemoteStationList()
        }
    }
    
    private func orderedJoiners(for zone: Zone, excluding coordinator: String) -> [String] {
        let names = zone.members.map { $0.roomName }
        let filtered = names.filter { $0 != coordinator }
        return filtered.sorted { lhs, rhs in
            lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }
    
    private func processZones(_ zones: [Zone]) {
        // Initialize temporary local collections to build up the new state
        var ng: [SonosGroup] = []
        var nv: [String: Int] = [:]
        var nm: [String: Bool] = [:]
        var np: [String: String] = [:]
        var di: [String: String] = [:]
        var ct: [String: String] = [:]
        var newTrackByRoom: [String: Track] = [:]
        var newVolumeDisabledState: [String: Bool] = [:]
        var newUuidToRoomNameMap: [String: String] = [:]

        let config = self.networkStore.configs.first { $0.baseURL == self.baseURL }
        let manuallyDisabledUUIDs = config?.manuallyDisabledVolumeUUIDs ?? []

        for zone in zones {
            let coordDisplayName = zone.coordinator.roomName
            let coordUUID = zone.coordinator.uuid

            let isConnect = connectUUIDs.contains(coordUUID)

            newVolumeDisabledState[coordDisplayName] = isConnect || manuallyDisabledUUIDs.contains(coordUUID)

            let joiners = orderedJoiners(for: zone, excluding: coordDisplayName)
            ng.append(SonosGroup(coordinator: coordDisplayName, joiners: joiners))
            
            // Populate coordinator's own state into temporary dictionaries
            nv[coordDisplayName] = zone.coordinator.state.volume
            nm[coordDisplayName] = zone.coordinator.state.mute
            np[coordDisplayName] = zone.coordinator.state.playbackState
            if let h = zone.coordinator.host { di[coordDisplayName] = h }

            for m in zone.members {
                let memberDisplayName = m.roomName
                let memberUUID = m.uuid

    
                newVolumeDisabledState[memberDisplayName] = connectUUIDs.contains(memberUUID) || manuallyDisabledUUIDs.contains(memberUUID)
                
                // Populate member's state into temporary dictionaries
                nv[memberDisplayName] = m.state.volume
                nm[memberDisplayName] = m.state.mute
                np[memberDisplayName] = m.state.playbackState
                if let h = m.host { di[memberDisplayName] = h }
                if let track = m.state.currentTrack {
                    if let title = track.title, !title.isEmpty {
                        ct[memberDisplayName] = title
                    } else if let name = track.stationName, !name.isEmpty {
                        ct[memberDisplayName] = name
                    }
                    newTrackByRoom[memberDisplayName] = track
                }
            }
        }
          
        // Populate newUuidToRoomNameMap
        for zone in zones {
            newUuidToRoomNameMap[zone.coordinator.uuid] = zone.coordinator.roomName
            for m in zone.members {
                if newUuidToRoomNameMap[m.uuid] == nil {
                     newUuidToRoomNameMap[m.uuid] = m.roomName
                }
            }
        }
          
        // Assign all collected temporary data to the @Published properties
        self.groups = ng.sorted { $0.coordinator.localizedCaseInsensitiveCompare($1.coordinator) == .orderedAscending }
        self.volume = nv
        self.isMuted = nm
        self.playbackState = np
        self.deviceIPs = di
        self.currentTrackTitle = ct
        self.trackByRoom = newTrackByRoom
        self.volumeDisabled = newVolumeDisabledState
        self.uuidToRoomName = newUuidToRoomNameMap
            
        var sel: [String: Station] = [:]
        for room in ct.keys {
            if let match = matchedStation(for: room) {
                sel[room] = match
            }
        }
        self.selectedStationByRoom = sel
        
        self.loadAccordionStateFromDefaults()
    }
    
    private func refresh() async {
        guard let url = URL(string: "\(baseURL)/zones") else { return }
        do {
            Self.logger.debug("Fetching zones from \(self.baseURL)")

            let favoriteNames = try await fetchFavoriteNames()
            let favoriteStations = favoriteNames.map { Station(name: $0, url: $0, type: .favorite) }

            if let configID = networkStore.configs.first(where: { $0.baseURL == baseURL })?.id {
                networkStore.mergeFavorites(for: configID, newFavoritesFromServer: favoriteStations)
            }
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoder = JSONDecoder()
            let zones = try decoder.decode([Zone].self, from: data)
            processZones(zones)

            // On successful refresh, status is connected.
            if self.status != .connected {
                self.status = .connected
            }

        } catch {
            Self.logger.error("Error refreshing Sonos state: \(error)")
            // On failure, set status to error.
            self.status = .error("Failed to refresh speaker status. Please check your connection to the node-sonos-http-api server.")
        }
    }
    
    func filteredStations(for config: NetworkConfig) -> [Station] {
        // remoteStations is the fully built, deduplicated list from buildRemoteStationList()
        Self.logger.debug("[FilteredStations] Filtering for network: \(config.displayName)")
            Self.logger.debug("[FilteredStations] Config's explicitlyDisabledFavoriteURLs: \(config.explicitlyDisabledFavoriteURLs)")

            let filteredList = remoteStations.filter { station in
                if station.type == .favorite {
                    let isEnabled = !config.explicitlyDisabledFavoriteURLs.contains(station.url)
                    Self.logger.debug("[FilteredStations] FAVORITE station: Name='\(station.name)', URL='\(station.url)'. Is explicitly disabled: \(config.explicitlyDisabledFavoriteURLs.contains(station.url)). Should be included: \(isEnabled)")
                    return isEnabled
                } else {
                    return true
                }
            }
            Self.logger.debug("[FilteredStations] Final filtered list count for \(config.displayName): \(filteredList.count)")
            return filteredList
    }
    
    private func updateRemoteStations(with stations: [Station]) {
        self.remoteStations = stations
    }

    private func rebuildStationsAndRefreshUI() {
        Task {
            let newStations = await self.buildRemoteStationList()
            self.updateRemoteStations(with: newStations)
        }
    }

    private func observeAppSettings() {
        settingsStore.$manualStations
            .dropFirst() // Ignore the initial value, react only to changes
            .sink { [weak self] _ in
                self?.rebuildStationsAndRefreshUI()
            }
            .store(in: &cancellables)

        settingsStore.$remoteCSVURL
            .dropFirst() // Ignore the initial value
            .sink { [weak self] _ in
                self?.rebuildStationsAndRefreshUI()
            }
            .store(in: &cancellables)
    }
    
// MARK: - Station Source Aggregation
    
    private func fetchStations(from url: String) async -> [Station] {
        guard let csvURL = URL(string: url) else { return [] }
        var request = URLRequest(url: csvURL)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        let session = URLSession(configuration: .default, delegate: RedirectHandler(), delegateQueue: nil)
        do {
            let (data, _) = try await session.data(for: request)
            let csvString = String(decoding: data, as: UTF8.self)
            let lines = csvString.split(separator: "\n").dropFirst()
            return lines.compactMap { line in
                let parts = line.split(separator: ",", maxSplits: 2).map { String($0).trimmingCharacters(in: .whitespaces) }
                guard parts.count >= 2 else { return nil }
                let name = parts[0]
                let url = parts[1]
                let rawType = parts.count == 3 ? parts[2].trimmingCharacters(in: .whitespaces).lowercased() : "stream"
                let type = StationType(rawValue: rawType) ?? .stream
                return Station(name: name, url: url, type: type)
            }
        } catch {
            Self.logger.error("Failed to fetch stations: \(error)")
            return []
        }
    }
    
    /// Combines all user-defined station sources into a merged, deduplicated list:
    /// - Manual stations from AppSettingsStore
    /// - Remote CSV (user or default)
    /// - Enabled Sonos favorites
    /// - Enabled Line-In sources
    /// All sources are merged and deduplicated by URL.
    /// This is the definitive source for `remoteStations`.
    
    private func buildRemoteStationList() async -> [Station] {
        let settings = AppSettingsStore.shared
        guard let currentNetworkConfig = networkStore.configs.first(where: { $0.baseURL == self.baseURL }) else {
            Self.logger.error("[buildRemoteStationList] Could not find NetworkConfig for baseURL: \(self.baseURL)")
            return []
        }

        var allPotentialStations: [(station: Station, priority: Int, sourceOrder: Int)] = []
        var sourceCounter = 0

        let remoteCSV = settings.remoteCSVURL
        let manualStations = settings.manualStations
            let globalCustomCSVEmpty = remoteCSV == nil || remoteCSV?.isEmpty == true
            let globalManualStationsEmpty = manualStations.isEmpty
        
            let effectivelyEnabledFavoritesCount = (currentNetworkConfig.lastKnownServerFavorites ?? []).filter { favStation in
                !currentNetworkConfig.explicitlyDisabledFavoriteURLs.contains(favStation.url)
            }.count
            let networkFavoritesEmpty = effectivelyEnabledFavoritesCount == 0

            let isForcedDefault = globalCustomCSVEmpty && globalManualStationsEmpty && networkFavoritesEmpty

            let shouldUseDefaultCSV = isForcedDefault || currentNetworkConfig.showDefaultPresetsForThisNetwork

            if shouldUseDefaultCSV {
                let defaultCSVUrl = Constants.defaultCSVURL
                let defaultStations = await fetchStations(from: defaultCSVUrl)
                allPotentialStations.append(contentsOf: defaultStations.map { station in
                    sourceCounter += 1
                    return (station, 4, sourceCounter)
                })
            }

            // --- Requirement 2: User-Defined Remote Preset List (Custom CSV) ---
        if let customCSVUrl = remoteCSV, !customCSVUrl.isEmpty { // Uses the 'remoteCSV' fetched with await above
                let customStations = await fetchStations(from: customCSVUrl)
                allPotentialStations.append(contentsOf: customStations.map { station in
                    sourceCounter += 1
                    return (station, 2, sourceCounter)
                })
                settings.csvLoadError = customStations.isEmpty
            } else {
                settings.csvLoadError = false
            }

            // --- Requirement 3: Manually-Entered Remote Streams ---
            if !manualStations.isEmpty { // Uses the 'manualStations' array fetched with await above
                allPotentialStations.append(contentsOf: manualStations.map { station in
                    sourceCounter += 1
                    return (station, 1, sourceCounter) // Priority 1 for Manual Entry
                })
            }

            if let serverFavorites = currentNetworkConfig.lastKnownServerFavorites {
                allPotentialStations.append(contentsOf: serverFavorites.map { station in
                    sourceCounter += 1
                    return (station, 3, sourceCounter) // Priority 3 for Sonos Favorite
                })
            }

        // Filter out line-in stations unless explicitly enabled for this network
        allPotentialStations.removeAll { (stationItem) -> Bool in
            let station = stationItem.station
            let stationURL = station.url.lowercased()
            let isLineInType = station.type == .lineIn
            var isRinconStream = false
            var lineInUUID: String? = nil

            if stationURL.hasPrefix("x-rincon-stream:") {
                isRinconStream = true
                // Extract UUID: x-rincon-stream:UUID_HERE or x-rincon-stream:UUID_HERE:INSTANCE
                lineInUUID = String(stationURL.dropFirst("x-rincon-stream:".count).split(separator: ":").first ?? "")
            }
            if isLineInType || isRinconStream {
                // This station appears to be a Line-In source.
                // Keep it ONLY if its UUID is explicitly enabled for this network.
                if let uuid = lineInUUID, currentNetworkConfig.enabledLineInUUIDs.contains(uuid) {
                    return false // Do NOT remove, it's allowed by this network's config.
                }
                return true // Remove, it's an external Line-In not enabled for this network.
            }
            return false // Not a Line-In type from an external source, keep it.
        }

        // Add Line-In sources specifically enabled for this network.
        let lineInPriority = 1

        for uuid in currentNetworkConfig.enabledLineInUUIDs {
            sourceCounter += 1
            let defaultName = self.uuidToRoomName[uuid] ?? uuid

            let stationName = currentNetworkConfig.lineInCustomNames[uuid] ?? defaultName
            let lineInStation = Station(name: stationName, url: "x-rincon-stream:\(uuid)", type: .lineIn)

            allPotentialStations.append((station: lineInStation, priority: lineInPriority, sourceOrder: sourceCounter))
        }
         
        // --- Deduplication by URL with specified precedence ---
            var uniqueStationsByURL: [String: (station: Station, priority: Int, sourceOrder: Int)] = [:]

            for item in allPotentialStations {
                if let existing = uniqueStationsByURL[item.station.url] {
                    if item.priority < existing.priority { // Lower number means higher priority
                        uniqueStationsByURL[item.station.url] = item
                    } else if item.priority == existing.priority && item.sourceOrder < existing.sourceOrder {
                        uniqueStationsByURL[item.station.url] = item
                    }
                } else {
                    uniqueStationsByURL[item.station.url] = item
                }
            }

            let finalDedupedList = uniqueStationsByURL.values.map { $0.station }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            return finalDedupedList
    }
    
    private func fetchFavorites() async -> [Station] {
        guard let url = URL(string: "\(baseURL)/favorites") else { return [] }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode([String].self, from: data)

            return decoded.map {
                Station(name: $0, url: $0, type: .favorite)
            }

        } catch {
            Self.logger.error("Failed to fetch favorites: \(error)")
            return []
        }
    }
    
    private func fetchFavoriteNames() async throws -> [String] {
        guard let url = URL(string: "\(baseURL)/favorites") else { return [] }
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode([String].self, from: data)
    }
    
    func selectStation(_ s: Station, for room: String) {
        selectedStationByRoom[room] = s
    }
    
    func adjustVolume(room: String, delta: Int) {
        let cur = volume[room] ?? 50
        let nv = max(0, min(100, cur + delta))
        volume[room] = nv // Optimistic update
        guard let url = apiURL(room, "volume", "\(nv)") else { return }
        Task { [weak self] in
            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    await self?.refresh()
                    return
                }
            } catch {
                await self?.refresh()
            }
        }
    }

    func toggleMute(room: String) {
        if !(isMuted[room] ?? false) {
            isMuted[room] = true // Optimistic update
            guard let url = apiURL(room, "mute", "on") else { return }
            Task { [weak self] in
                _ = try? await URLSession.shared.data(from: url)
                await self?.refresh()
            }
        } else {
            isMuted[room] = false // Optimistic update
            Task { [weak self] in
                await self?.directUnmute(room: room)
                await self?.refresh()
            }
        }
    }

    private func sendStreamURL(to room: String, station: Station) async {
        let safeRoom = room.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? room
        let path: String

        if station.isFavorite {
            let encoded = station.url.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? station.url
            path = "\(baseURL)/\(safeRoom)/favorite/\(encoded)"
        } else if station.isLineIn {
            let encoded = station.url.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? station.url
            path = "\(baseURL)/\(safeRoom)/setavtransporturi/\(encoded)"
        } else {
            let raw = "x-rincon-mp3radio://\(station.url)"
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            let enc = raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
            path = "\(baseURL)/\(safeRoom)/setavtransporturi/\(enc)"
        }
        guard let url = URL(string: path) else { return }
        _ = try? await URLSession.shared.data(from: url)
        Self.logger.debug("Sent request to: \(path)")
    }

    func togglePlayback(group: SonosGroup) {
        let coord = group.coordinator
        Task { [weak self] in
            guard let self else { return }
            if self.playbackState[coord] == "PLAYING" {
                guard let url = self.apiURL(coord, "pause") else { return }
                _ = try? await URLSession.shared.data(from: url)
                await self.refresh()
            } else if let station = self.selectedStationByRoom[coord] {
                await self.sendStreamURL(to: coord, station: station)
                if let playURL = self.apiURL(coord, "play") {
                    _ = try? await URLSession.shared.data(from: playURL)
                }
                await self.refresh()
            } else if let track = self.trackByRoom[coord],
                      let uri = track.uri ?? track.trackUri,
                      !uri.isEmpty {
                let encodedURI: String
                if uri.starts(with: "x-rincon-stream:") || uri.starts(with: "x-sonosapi-stream:") || uri.starts(with: "x-rincon-mp3radio://") {
                    encodedURI = uri.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? uri
                } else {
                    encodedURI = "x-rincon-mp3radio://\(uri)".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? uri
                }
                let setURI = "\(self.baseURL)/\(coord)/setavtransporturi/\(encodedURI)"
                if let setURL = URL(string: setURI) {
                    _ = try? await URLSession.shared.data(from: setURL)
                }
                if let playURL = self.apiURL(coord, "play") {
                    _ = try? await URLSession.shared.data(from: playURL)
                }
                await self.refresh()
            } else {
                Self.logger.info("No preset selected and no known track URI. Cannot play.")
            }
        }
    }

    func isPlaying(group: SonosGroup) -> Bool {
        playbackState[group.coordinator] == "PLAYING"
    }

    func joinGroup(room: String, target: String) {
        guard let url = apiURL(room, "join", target) else { return }
        Task { [weak self] in
            _ = try? await URLSession.shared.data(from: url)
            await self?.refresh()
        }
    }

    func leaveGroup(coordinator: String) {
        guard let url = apiURL(coordinator, "leave") else { return }
        Task {
            _ = try? await URLSession.shared.data(from: url)
        }
    }

    func leaveGroup(room: String) {
        guard let url = apiURL(room, "leave") else { return }
        Task { [weak self] in
            _ = try? await URLSession.shared.data(from: url)
            await self?.refresh()
        }
    }

    private func directUnmute(room: String) async {
        guard let ip = deviceIPs[room] else { return }
        let soap = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
                    s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:SetMute xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1">
              <InstanceID>0</InstanceID>
              <Channel>Master</Channel>
              <DesiredMute>0</DesiredMute>
            </u:SetMute>
          </s:Body>
        </s:Envelope>
        """
        guard let url = URL(string: "http://\(ip):\(Constants.sonosUPnPPort)/MediaRenderer/RenderingControl/Control") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\"urn:schemas-upnp-org:service:RenderingControl:1#SetMute\"",
                     forHTTPHeaderField: "SOAPACTION")
        req.httpBody = soap.data(using: .utf8)
        _ = try? await URLSession.shared.data(for: req)
    }
    
    private func matchedStation(for room: String) -> Station? {
        guard let track = trackByRoom[room] else { return nil }
        return remoteStations.first { $0.matches(track: track) }
    }
    
    private func currentTrack(for room: String) -> Track? {
        let allRooms = groups.flatMap { [$0.coordinator] + $0.joiners }
        guard allRooms.contains(room),
              let title = currentTrackTitle[room] else {
            return nil
        }
        return Track(
            title: title,
            artist: nil,
            stationName: nil,
            uri: nil,
            trackUri: nil,
            type: nil,
            albumArtUri: nil,
            absoluteAlbumArtUri: nil
        )
    }
    
    func playStation(_ station: Station, in room: String) {
        Task { [weak self] in
            guard let self else { return }
            await self.sendStreamURL(to: room, station: station)
            if let playURL = self.apiURL(room, "play") {
                _ = try? await URLSession.shared.data(from: playURL)
            }
            for _ in 0..<3 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await self.refresh()
            }
        }
    }
    
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
        for group in groups {
            let key = accordionDefaultsKeyPrefix + group.coordinator
            let saved = UserDefaults.standard.object(forKey: key) as? Bool
            accordionState[group.coordinator] = saved ?? false
        }
    }
    
    func persistAccordionState(for room: String, expanded: Bool) {
        let key = accordionDefaultsKeyPrefix + room
        UserDefaults.standard.set(expanded, forKey: key)
    }
    
    func stationDisplay(for room: String) -> String {
        guard let track = trackByRoom[room] else {
                // If no track, check if a station is selected but not yet playing
                if let selected = selectedStationByRoom[room] {
                    // selected.name would have custom name if it's a LineIn from remoteStations (built with custom names)
                    return "\(selected.name) (Queued)"
                } else {
                    return "Nothing queued"
                }
            }

            // Priority 1: Check if the current track matches a known Station object.
            // This uses the corrected Station.matches, so Line-In stations with custom names from
            // buildRemoteStationList (via NetworkConfig) should be correctly identified here.
            if let matched = matchedStation(for: room) {
                return playbackState[room] == "PLAYING"
                ? matched.name // matched.name already incorporates the custom name for Line-In types
                : "\(matched.name) (Queued)"
            }

            // Priority 2: If no match with a Station object, but the URI is clearly Line-In.
            // This handles cases where Line-In is playing but might not have been
            // pre-configured in remoteStations, or if direct URI inspection is preferred.
            if let uri = track.trackUri ?? track.uri, uri.starts(with: "x-rincon-stream:") {
                let bareUUID = uri
                    .replacingOccurrences(of: "x-rincon-stream:", with: "")
                    .components(separatedBy: ":")
                    .first ?? ""

                if !bareUUID.isEmpty {
                    // Attempt to get custom name directly from NetworkConfig for this specific network
                    if let currentNetworkConfig = networkStore.configs.first(where: { $0.baseURL == self.baseURL }),
                       let customName = currentNetworkConfig.lineInCustomNames[bareUUID], !customName.isEmpty {
                        return playbackState[room] == "PLAYING" ? customName : "\(customName) (Queued)"
                    }

                    // Fallback to using the room name associated with the Line-In UUID
                    if let sourceRoomName = uuidToRoomName[bareUUID] {
                        let baseDisplayName = "Line In (\(sourceRoomName))"
                        return playbackState[room] == "PLAYING" ? baseDisplayName : "\(baseDisplayName) (Queued)"
                    }

                    // Ultimate fallback for a Line-In stream if its UUID isn't even in uuidToRoomName
                    return playbackState[room] == "PLAYING" ? "Line In" : "Line In (Queued)"
                }
            }

            // Priority 3: Generic fallbacks based on other track metadata if not Line-In or no match.
            if let candidate = track.stationName ?? track.artist ?? track.title, !candidate.isEmpty {
                return playbackState[room] == "PLAYING"
                ? candidate
                : "\(candidate) (Queued)"
            }

            return "Nothing queued" // Final fallback if no other information is available
    }
    
    private var sseTask: URLSessionDataTask?
    private var debounceWorkItem: DispatchWorkItem?
    private var isObservingAppState = false

    private func scheduleSseReconnect() {
        // Cancel any previously scheduled reconnect
        reconnectWorkItem?.cancel()

        guard retryAttempts < maxRetryAttempts else {
            Self.logger.info("[SSE] Maximum retry attempts reached. Halting reconnection attempts.")
            self.status = .error("Live connection to server lost. Status updates may be delayed.")
            return
        }

        // Calculate delay with exponential backoff
        let delay = pow(2.0, Double(retryAttempts))
        Self.logger.info("[SSE] Connection failed. Will attempt to reconnect in \(delay) seconds (Attempt \(self.retryAttempts + 1)/\(self.maxRetryAttempts)).")

        let workItem = DispatchWorkItem { [weak self] in
            self?.startListeningForEvents()
        }
        reconnectWorkItem = workItem

        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private var pollTimer: Timer?

    private func startListeningForEvents() {
        // 1. Cleanup any previous/pending tasks
        stopListeningForEvents()

        // 2. Set initial status
        self.status = .connecting

        Self.logger.info("[SSE] Attempting to start listening for events...")
        guard let url = URL(string: "\(baseURL)/events") else {
            Self.logger.error("[SSE] Invalid URL for /events endpoint: \(self.baseURL)/events")
            self.status = .error("Invalid server URL.")
            return
        }

        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Constants.sseTimeout

        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["Connection": "keep-alive"]
        let session = URLSession(configuration: config, delegate: self, delegateQueue: .main)

        sseTask = session.dataTask(with: request)
        sseTask?.resume()

        startPollingEvery60Seconds()
        observeAppLifecycle()
    }

    private func stopListeningForEvents() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil

        sseTask?.cancel()
        sseTask = nil

        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func observeAppLifecycle() {
        guard !isObservingAppState else { return }
        isObservingAppState = true
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.retryAttempts = 0
                self?.stopListeningForEvents()
            }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.retryAttempts = 0
                self?.startListeningForEvents()
                await self?.refresh()
            }
        }
    }

    private func debouncedRefresh() {
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    private func startPollingEvery60Seconds() {
        // Ensure we don't create multiple timers
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Constants.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }
    }

    private struct SSEEvent: Decodable {
        let type: String
    }
}

// MARK: - URLSessionDataDelegate for SSE

extension SonosViewModel: URLSessionDataDelegate {

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let chunk = String(data: data, encoding: .utf8) else {
            sseLogger.error("[SSE] Failed to decode data chunk to UTF8 string.")
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.retryAttempts > 0 || self.status != .connected {
                Self.logger.info("[SSE] Connection re-established.")
                self.retryAttempts = 0
                self.status = .connected
            }
        }

        // Process the event data to trigger debounced refreshes
        for line in chunk.components(separatedBy: "\n") {
            guard line.hasPrefix("data:") else { continue }
            let jsonString = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespacesAndNewlines)

            if let eventData = jsonString.data(using: .utf8),
               let event = try? JSONDecoder().decode(SSEEvent.self, from: eventData),
               (event.type == "topology-change" || event.type == "transport-state") {

                Task { @MainActor [weak self] in
                    self?.debouncedRefresh()
                }
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error as? URLError, error.code == .cancelled {
            sseLogger.info("[SSE] Task cancelled intentionally. No retry will be scheduled.")
            return
        }

        sseLogger.info("[SSE] Task didCompleteWithError: \(error?.localizedDescription ?? "Connection closed by server"). Scheduling reconnect.")

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.status = .connecting
            self.retryAttempts += 1
            self.scheduleSseReconnect()
        }
    }

    nonisolated func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        sseLogger.error("[SSE] Session became invalid with error: \(error?.localizedDescription ?? "Unknown error")")
        Task { @MainActor [weak self] in
            self?.status = .error("The connection session became invalid. Will attempt to restart on next app foreground.")
        }
    }
}
