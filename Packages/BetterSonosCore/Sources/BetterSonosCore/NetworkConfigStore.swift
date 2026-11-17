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
//  NetworkConfigStore.swift
//

import Foundation
import Combine
import os.log

// MARK: - UserDefaults Storage

public final class NetworkConfigStore: ObservableObject {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "BetterSonosCore", category: "NetworkConfigStore")
    @Published public var configs: [NetworkConfig] = []

    /// When true, this store never writes to iCloud. The watch uses this so a stale copy can never
    /// overwrite configs edited on the phone. Local UserDefaults caching still happens.
    public let isCloudReadOnly: Bool

    static let key = "sonosNetworkConfigs"
    
    private static let iCloudKey = "sonosNetworkConfigs_iCloud" // Distinct key for iCloud
    private var ubiquitousStore: NSUbiquitousKeyValueStore {
        NSUbiquitousKeyValueStore.default
    }
    private var cancellables = Set<AnyCancellable>() // For observing iCloud changes
    
    public init(cloudReadOnly: Bool = false) {
        self.isCloudReadOnly = cloudReadOnly
        // Initial load prioritizes iCloud, then UserDefaults
        load()

        // Observe changes from iCloud
        NotificationCenter.default.publisher(for: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: ubiquitousStore)
            .sink { [weak self] notification in
                guard let self = self else { return }
                NetworkConfigStore.logger.info("iCloud store changed externally. Reason: \(String(describing: notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] ?? "Unknown"))")

                // Check which keys changed if needed, though for a single key we just reload.
                // let changedKeys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
                // if changedKeys?.contains(Self.iCloudKey) == true { ... }

                self.loadFromUbiquitousStore() // Reload data from iCloud
            }
            .store(in: &cancellables)

        // Attempt to synchronize iCloud store on init.
        // This can help ensure local changes are pushed or remote changes are pulled sooner.
        ubiquitousStore.synchronize()    }
    
    public func load() {
        // Try to load from iCloud first.
        // If iCloud has data, it's considered more authoritative.
        if let iCloudData = ubiquitousStore.data(forKey: Self.iCloudKey) {
            do {
                let decodedFromiCloud = try JSONDecoder().decode([NetworkConfig].self, from: iCloudData)
                    
                NetworkConfigStore.logger.info("Loaded configurations from iCloud.")
                self.configs = decodedFromiCloud
                // Also update UserDefaults to keep it as a local cache of the iCloud version.
                UserDefaults.standard.set(iCloudData, forKey: Self.key)
                return // Successfully loaded from iCloud
            } catch {
                    
                NetworkConfigStore.logger.info("Error decoding configurations from iCloud: \(error). Will try UserDefaults.")
                // Fall through to UserDefaults loading logic
            }
        }

        // If no iCloud data, fall back to UserDefaults (local cache).
        NetworkConfigStore.logger.info("No data in iCloud or failed to decode, trying UserDefaults.")
        if let localData = UserDefaults.standard.data(forKey: Self.key) {
            do {
                let decodedFromLocal = try JSONDecoder().decode([NetworkConfig].self, from: localData)
                self.configs = decodedFromLocal
                    
                NetworkConfigStore.logger.info("Loaded configurations from UserDefaults. Will attempt to sync to iCloud if empty there.")
                // If iCloud was empty but local wasn't, let's try to push local to iCloud.
                if !isCloudReadOnly, ubiquitousStore.data(forKey: Self.iCloudKey) == nil {
                    do {
                        let encoded = try JSONEncoder().encode(self.configs)
                        ubiquitousStore.set(encoded, forKey: Self.iCloudKey)
                        ubiquitousStore.synchronize() // Request a sync
                            
                        NetworkConfigStore.logger.info("Pushed UserDefaults data to iCloud.")
                    } catch {
                            
                        NetworkConfigStore.logger.info("Failed to encode configs for pushing to iCloud: \(error)")
                    }
                }
            } catch {
                    
                NetworkConfigStore.logger.info("Error decoding configurations from UserDefaults: \(error).")
                self.configs = [] // Start fresh
            }
        } else {
                
            NetworkConfigStore.logger.info("No configurations found in UserDefaults either. Starting fresh.")
            self.configs = [] // Ensure it's an empty array if nothing is loaded
        }
    }
    
    private func loadFromUbiquitousStore() {
        if let iCloudData = ubiquitousStore.data(forKey: Self.iCloudKey) {
            do {
                let cloudConfigs = try JSONDecoder().decode([NetworkConfig].self, from: iCloudData)

                // Merge rather than replace: per config, the more recently modified copy wins.
                DispatchQueue.main.async {
                    let localConfigs = self.configs
                    var mergedConfigs: [NetworkConfig] = []
                    var cloudConfigMap = Dictionary(cloudConfigs.map { ($0.id, $0) }, uniquingKeysWith: { (first, _) in first })
                    var localWon = false

                    // 1. Configs present locally: keep the newer copy. Configs missing from the cloud
                    //    were deleted on another device, so they are dropped.
                    for local in localConfigs {
                        guard let cloudVersion = cloudConfigMap.removeValue(forKey: local.id) else { continue }
                        if local.lastModified > cloudVersion.lastModified {
                            mergedConfigs.append(local)
                            localWon = true
                        } else {
                            mergedConfigs.append(cloudVersion)
                        }
                    }

                    // 2. Configs created on another device, in the cloud's order.
                    mergedConfigs.append(contentsOf: cloudConfigs.filter { cloudConfigMap.removeValue(forKey: $0.id) != nil })

                    self.configs = mergedConfigs

                    if localWon {
                        // Push the newer local copies back, so the other devices converge on them.
                        self.save()
                    } else if let mergedData = try? JSONEncoder().encode(mergedConfigs) {
                        UserDefaults.standard.set(mergedData, forKey: Self.key)
                    }

                    NetworkConfigStore.logger.info("Merged configurations from iCloud. Total: \(mergedConfigs.count), local won: \(localWon)")
                }
            } catch {
                NetworkConfigStore.logger.info("Error decoding configurations from iCloud after notification: \(error). Attempting to load from local UserDefaults.")
                self.loadFromLocalStoreAsFallback()
            }
        } else {
            NetworkConfigStore.logger.info("iCloud data for key \(Self.iCloudKey) is nil after notification. Checking local UserDefaults.")
            self.loadFromLocalStoreAsFallback()
        }
    }
    
    private func loadFromLocalStoreAsFallback() {
        if let localData = UserDefaults.standard.data(forKey: Self.key) {
            do {
                let decodedConfigs = try JSONDecoder().decode([NetworkConfig].self, from: localData)
                DispatchQueue.main.async {
                    self.configs = decodedConfigs

                    NetworkConfigStore.logger.info("Loaded from UserDefaults as iCloud was empty or failed to decode. Local data preserved.")
                }
            } catch {
                DispatchQueue.main.async {
                    self.configs = [] // Both iCloud and local are problematic
                    UserDefaults.standard.removeObject(forKey: Self.key) // Clear potentially corrupted local data

                    NetworkConfigStore.logger.info("Error decoding from UserDefaults as well. Starting with empty configurations.")
                }
            }
        } else {
            DispatchQueue.main.async {
                self.configs = []
                NetworkConfigStore.logger.info("No data in iCloud or UserDefaults. Starting with empty configurations.")
            }
        }
    }
    
    public func save() {
        do {
            let encoded = try JSONEncoder().encode(configs)
            // Save to UserDefaults (local cache)
            UserDefaults.standard.set(encoded, forKey: Self.key)

            guard !isCloudReadOnly else { return }

            // Save to iCloud
            ubiquitousStore.set(encoded, forKey: Self.iCloudKey)
            if !ubiquitousStore.synchronize() {
                    
                NetworkConfigStore.logger.info("ubiquitousStore.synchronize() returned false. Data will sync later.")
            } else {
                    
                NetworkConfigStore.logger.info("Saved configurations to UserDefaults and initiated iCloud sync.")
            }
        } catch {
                
            NetworkConfigStore.logger.info("Failed to encode configurations for saving: \(error)")
        }
    }
    
    public func add(_ config: NetworkConfig) {
        configs.append(config)
        save()
    }
    
    public func update(_ config: NetworkConfig) {
        if let idx = configs.firstIndex(where: { $0.id == config.id }) {
            // By creating a mutable copy and re-assigning it, we force @Published to notify its subscribers.
            var updatedConfig = config
            updatedConfig.lastModified = Date() // Set modification date on update

            var updatedConfigs = configs
            updatedConfigs[idx] = updatedConfig
            configs = updatedConfigs // This is the key change that triggers the UI update

            save()
        }
    }
    
    public func remove(_ config: NetworkConfig) {
        configs.removeAll { $0.id == config.id }
        save()
    }
    
    public func mergeFavorites(for configID: UUID, newFavoritesFromServer: [Station]) {
        guard let idx = configs.firstIndex(where: { $0.id == configID }) else { return }
        var currentConfig = configs[idx]

        // Sort by name for consistent storage.
        let sortedNewFavorites = newFavoritesFromServer.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        if currentConfig.lastKnownServerFavorites != sortedNewFavorites {
            currentConfig.lastKnownServerFavorites = sortedNewFavorites
            configs[idx] = currentConfig
            save()
        }
    }
    
}
