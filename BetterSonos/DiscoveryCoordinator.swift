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
//  DiscoveryCoordinator.swift
//
//  When discovery runs:
//  - Immediately, bypassing the throttle: at launch; on any real edit to the network list (add,
//    remove, enable, disable, address change, including edits synced from another device); on any
//    network change (gaining, losing or switching Wi-Fi); when a local network fails to refresh
//    (speaker addresses may have changed); on Search Again; and on returning to the foreground
//    while something is unresolved (no networks, permission denied, a local network unavailable).
//  - Throttled to once every 10 minutes: returning to the foreground with everything working.
//  Triggers arriving together are folded into one run.
//
//  What it changes: a newly found household is offered for naming ("Home", "Home 2", ...);
//  known local networks get fresh speaker addresses and are marked reachable or not.

import SwiftUI
import Network
import Combine
import BetterSonosCore

@MainActor
final class DiscoveryCoordinator: ObservableObject {
    /// True until the first discovery and reachability check finish, so the UI can avoid
    /// flashing a local network as unavailable at launch.
    @Published private(set) var isFirstSearchPending = true
    @Published private(set) var isSearching = false
    @Published private(set) var permissionDenied = false
    /// A household waiting for the user to name it.
    @Published var householdToName: DiscoveredHousehold?

    /// A server network that was just merged with its household (server first, then discovery), so the
    /// user can be told once, on this device, and pointed at the switch.
    struct MergeNotice: Identifiable, Equatable {
        let id: UUID
        let networkName: String
    }
    @Published var mergeNotice: MergeNotice?
    /// Household IDs of local networks reachable right now.
    @Published private(set) var reachableHouseholds: Set<String> = []

    private let networkStore: NetworkConfigStore
    /// The discovery step, injectable so tests can stand in for Bonjour and real speakers.
    private let discover: @MainActor () async -> DiscoveryOutcome
    private var lastRun: Date = .distantPast
    /// The most recent discovery results, so a list edit can be re-evaluated without a new browse.
    private var lastFound: [DiscoveredHousehold] = []
    private var queuedHouseholds: [DiscoveredHousehold] = []
    /// Households the user chose "Not Now" for, until the app is relaunched.
    private var dismissedHouseholds: Set<String> = []
    private let pathMonitor = NWPathMonitor()
    private var lastPathSignature: String?
    private var cancellables = Set<AnyCancellable>()
    private var pendingRun: Task<Void, Never>?
    private var rerunAfterSearch = false
    private var lastFailureTriggered: Date = .distantPast
    /// A confirmed outage reported inside the rate limit still gets its run, once the limit allows.
    private var deferredFailureRun: Task<Void, Never>?

    static let throttle: TimeInterval = 10 * 60
    static let coalesceDelay: Duration = .milliseconds(500)
    /// Minimum time between discovery runs triggered by outage reports. 30 s in the app; tests shorten it.
    private let failureRetryInterval: TimeInterval
    /// Posted by a local network's view model once its speakers' silence is confirmed (three failed
    /// scheduled polls). `object` is the household ID.
    static let localNetworkUnreachable = Notification.Name("BonTonLocalNetworkUnreachable")
    /// Posted when those speakers answer again.
    static let localNetworkReachable = Notification.Name("BonTonLocalNetworkReachable")
    /// Households whose view model has confirmed silence. Only these may go from available to
    /// unavailable: a single failed discovery probe never makes a loaded network flicker.
    private var confirmedUnreachable: Set<String> = []

    init(networkStore: NetworkConfigStore, failureRetryInterval: TimeInterval = 30,
         discover: @escaping @MainActor () async -> DiscoveryOutcome = { await SonosDiscovery.discover() }) {
        self.networkStore = networkStore
        self.failureRetryInterval = failureRetryInterval
        self.discover = discover

        // Network changes. Gateways change when switching Wi-Fi networks even though the interface
        // (en0) doesn't, so they're part of the signature.
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let gateways = path.gateways.map { "\($0)" }.sorted().joined(separator: ",")
            let interfaces = path.availableInterfaces.map(\.name).joined(separator: ",")
            let signature = "\(path.status)|\(interfaces)|\(gateways)"
            Task { @MainActor in
                guard let self else { return }
                defer { self.lastPathSignature = signature }
                if let last = self.lastPathSignature, last != signature {
                    // Home or away may have changed: hybrid networks choose their path afresh.
                    HybridPathCache.shared.invalidateAll()
                    self.request(force: true)
                }
            }
        }
        pathMonitor.start(queue: .main)

        // Real edits to the network list. The signature leaves out favorites and modification dates,
        // so the app's own routine writes (favorites merges) don't retrigger discovery.
        networkStore.$configs
            .map { configs in
                configs.map { "\($0.id)|\($0.enabled)|\($0.baseURL)|\($0.householdID ?? "")|\($0.speakerAddresses.keys.sorted())" }
            }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { await self.evaluate(self.lastFound) }
                self.request(force: true)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                HybridPathCache.shared.invalidateAll()
                self.request(force: self.needsAttention)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: Self.localNetworkUnreachable)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self else { return }
                if let householdID = note.object as? String { self.confirmedUnreachable.insert(householdID) }
                let wait = self.failureRetryInterval - Date().timeIntervalSince(self.lastFailureTriggered)
                if wait <= 0 {
                    self.lastFailureTriggered = Date()
                    self.request(force: true)
                } else if self.deferredFailureRun == nil {
                    // Rate-limited: a view model reports an outage once, so it must not be dropped.
                    self.deferredFailureRun = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(wait))
                        guard let self, !Task.isCancelled else { return }
                        self.deferredFailureRun = nil
                        self.lastFailureTriggered = Date()
                        self.request(force: true)
                    }
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: Self.localNetworkReachable)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self, let householdID = note.object as? String else { return }
                self.confirmedUnreachable.remove(householdID)
                self.reachableHouseholds.insert(householdID)
            }
            .store(in: &cancellables)
    }

    deinit { pathMonitor.cancel() }

    func isAvailable(_ config: NetworkConfig) -> Bool {
        guard config.isLocal, let householdID = config.householdID else { return true }
        return reachableHouseholds.contains(householdID)
    }

    /// Something the user is waiting on: discovery shouldn't wait out the throttle.
    private var needsAttention: Bool {
        networkStore.configs.isEmpty || permissionDenied
            || networkStore.configs.contains { $0.enabled && !isAvailable($0) }
    }

    /// Launch and Search Again.
    func run(force: Bool) {
        request(force: force)
    }

    /// Asks for a discovery run. Requests arriving together are folded into one; a request during a
    /// run schedules exactly one more run afterwards.
    private func request(force: Bool) {
        guard force || Date().timeIntervalSince(lastRun) >= Self.throttle else { return }
        if isSearching {
            rerunAfterSearch = true
            return
        }
        pendingRun?.cancel()
        pendingRun = Task { [weak self] in
            try? await Task.sleep(for: Self.coalesceDelay)
            guard !Task.isCancelled, let self, !self.isSearching else { return }
            self.isSearching = true
            self.lastRun = Date()
            await self.search()
            if self.rerunAfterSearch {
                self.rerunAfterSearch = false
                self.request(force: true)
            }
        }
    }

    private func search() async {
        defer {
            isSearching = false
            isFirstSearchPending = false
        }
        switch await discover() {
        case .permissionDenied:
            permissionDenied = true
            lastFound = []
        case .nothingFound:
            permissionDenied = false
            lastFound = []
        case .found(let households):
            permissionDenied = false
            lastFound = households
        }
        await evaluate(lastFound)
    }

    /// Applies discovery results to the network list: updates known local networks, offers new
    /// households, and works out which local networks are reachable. Safe to call again with the
    /// same results after the list changes.
    private func evaluate(_ households: [DiscoveredHousehold]) async {
        var reachable = Set<String>()
        let serverPlayers = await playersByServerNetwork()
        let covered = serverPlayers.reduce(into: Set<String>()) { $0.formUnion($1.players) }
        for household in households {
            reachable.insert(household.householdID)
            // Found by Bonjour: whatever confirmed an outage before, the speakers are answering now.
            confirmedUnreachable.remove(household.householdID)
            let householdPlayers = Set(household.speakers.keys)
            // A server network whose every speaker belongs to this household is the same system: merge it
            // (it keeps its name and settings, and gains direct control at home). The first match wins.
            // Only once per household: if a server network already holds it (merged earlier, even with
            // direct control switched off), other matching servers are left alone.
            let alreadyMerged = networkStore.configs.contains { $0.hasServer && $0.householdID == household.householdID }
            let match = alreadyMerged ? nil : serverPlayers.first { NetworkConfig.serverMatches(serverPlayers: $0.players, householdPlayers: householdPlayers) }
            if let match, var server = networkStore.configs.first(where: { $0.id == match.id }), server.householdID == nil {
                server.householdID = household.householdID
                server.speakerAddresses = household.speakers
                server.directControlEnabled = true
                networkStore.update(server)
                // A separate local network for the same household (both existed) folds into the server one.
                for local in networkStore.configs where local.isLocal && local.householdID == household.householdID {
                    networkStore.remove(local)
                }
                mergeNotice = MergeNotice(id: server.id, networkName: server.displayName)
                continue
            }
            if var existing = networkStore.configs.first(where: { $0.householdID == household.householdID }) {
                // Merge rather than replace: a speaker missing from this read (rebooting, asleep) keeps
                // its saved address. New and changed addresses win.
                let merged = existing.speakerAddresses.merging(household.speakers) { _, new in new }
                if existing.speakerAddresses != merged {
                    existing.speakerAddresses = merged
                    networkStore.update(existing)
                }
            } else if !covered.isDisjoint(with: household.speakers.keys) {
                // Some speakers are reachable through a server network, but not all of its speakers are in
                // this household: not provably the same system, so neither merge nor offer a duplicate.
                continue
            } else if !dismissedHouseholds.contains(household.householdID),
                      !queuedHouseholds.contains(household), householdToName?.householdID != household.householdID {
                queuedHouseholds.append(household)
            }
        }

        // Known local networks Bonjour didn't report may still answer at their cached addresses.
        for config in networkStore.configs where config.isLocal {
            guard let householdID = config.householdID, !reachable.contains(householdID) else { continue }
            if (try? await DirectBackend(speakers: config.speakerAddresses).topology()) != nil {
                reachable.insert(householdID)
                confirmedUnreachable.remove(householdID)
            } else if reachableHouseholds.contains(householdID), !confirmedUnreachable.contains(householdID) {
                // Available until its view model confirms the silence; one missed probe isn't evidence.
                reachable.insert(householdID)
            }
        }
        reachableHouseholds = reachable
        presentNextHousehold()
    }

    /// Player IDs of every speaker that an enabled server network can see right now.
    /// Each enabled server-only network's speakers, as its server reports them right now. A server that
    /// doesn't answer reports nothing, so it can't be matched (no guessing from saved data). Networks
    /// already holding a household, or with direct control switched off, are left alone.
    private func playersByServerNetwork() async -> [(id: UUID, players: Set<String>)] {
        let servers = networkStore.configs.filter { $0.enabled && $0.hasServer && $0.householdID == nil }
        let order = servers.map(\.id)
        let found = await withTaskGroup(of: (UUID, Set<String>).self) { group in
            for config in servers {
                let backend = ServerBackend(baseURL: config.baseURL)
                let id = config.id
                group.addTask {
                    let zones = (try? await backend.zones()) ?? []
                    return (id, Set(zones.flatMap { [$0.coordinator.uuid] + $0.members.map(\.uuid) }))
                }
            }
            var result: [UUID: Set<String>] = [:]
            for await (id, players) in group where !players.isEmpty { result[id] = players }
            return result
        }
        // Keep the network list's order, so "the first match" is stable.
        return order.compactMap { id in found[id].map { (id, $0) } }
    }

    // MARK: - Naming

    private func presentNextHousehold() {
        guard householdToName == nil, !queuedHouseholds.isEmpty else { return }
        householdToName = queuedHouseholds.removeFirst()
    }

    /// "Home", or "Home 2", "Home 3"... if that name is taken.
    func suggestedName() -> String {
        let names = Set(networkStore.configs.map(\.displayName))
        if !names.contains("Home") { return "Home" }
        var n = 2
        while names.contains("Home \(n)") { n += 1 }
        return "Home \(n)"
    }

    func confirm(_ household: DiscoveredHousehold, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let config = NetworkConfig.local(
            householdID: household.householdID,
            name: trimmed.isEmpty ? suggestedName() : trimmed,
            speakers: household.speakers
        )
        if !networkStore.configs.contains(where: { $0.id == config.id }) {
            networkStore.add(config)
        }
        reachableHouseholds.insert(household.householdID)
        householdToName = nil
        presentNextHousehold()
    }

    /// The empty screen's Search Again: forgets "Not Now" choices and searches immediately.
    func searchAgain() {
        dismissedHouseholds.removeAll()
        run(force: true)
    }

    func dismiss(_ household: DiscoveredHousehold) {
        dismissedHouseholds.insert(household.householdID)
        householdToName = nil
        presentNextHousehold()
    }
}
