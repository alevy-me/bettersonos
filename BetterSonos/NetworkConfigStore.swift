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

class NetworkConfigStore: ObservableObject {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "NetworkConfigStore")
    @Published var configs: [NetworkConfig] = []
    
    static let key = "sonosNetworkConfigs"
    
    private static let iCloudKey = "sonosNetworkConfigs_iCloud" // Distinct key for iCloud
    private var ubiquitousStore: NSUbiquitousKeyValueStore {
        NSUbiquitousKeyValueStore.default
    }
    private var cancellables = Set<AnyCancellable>() // For observing iCloud changes
    
    init() {
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
    
    func load() {
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
                if ubiquitousStore.data(forKey: Self.iCloudKey) == nil {
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

                // Perform an intelligent merge instead of a simple replacement
                DispatchQueue.main.async {
                    let localConfigs = self.configs
                    var mergedConfigs: [NetworkConfig] = []
                    var cloudConfigMap = Dictionary(cloudConfigs.map { ($0.id, $0) }, uniquingKeysWith: { (first, _) in first })

                    // 1. Iterate through local configs to handle modifications and deletions
                    for local in localConfigs {
                        if let cloudVersion = cloudConfigMap[local.id] {
                            // MODIFY CASE: The config exists in both local and cloud.
                            // We take the one that was modified more recently.
                            if local.lastModified > cloudVersion.lastModified {
                                // Local is newer, keep it.
                                mergedConfigs.append(local)
                            } else {
                                // Cloud is newer or same, take cloud.
                                mergedConfigs.append(cloudVersion)
                            }
                            // Remove from cloud map to mark it as processed
                            cloudConfigMap.removeValue(forKey: local.id)
                        }
                        // DELETE CASE: If local config is not in cloud map, it was deleted elsewhere.
                        // By not adding it to mergedConfigs, we are deleting it locally.
                    }

                    // 2. ADD CASE: Add any remaining configs from the cloud map.
                    // These are new configs created on another device.
                    mergedConfigs.append(contentsOf: cloudConfigMap.values)

                    self.configs = mergedConfigs

                    // Also update UserDefaults to keep it as a local cache of the iCloud version.
                    if let mergedData = try? JSONEncoder().encode(mergedConfigs) {
                        UserDefaults.standard.set(mergedData, forKey: Self.key)
                    }

                    NetworkConfigStore.logger.info("Intelligently merged configurations from iCloud. Total: \(mergedConfigs.count)")
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
    
    func save() {
        do {
            let encoded = try JSONEncoder().encode(configs)
            // Save to UserDefaults (local cache)
            UserDefaults.standard.set(encoded, forKey: Self.key)

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
    
    func add(_ config: NetworkConfig) {
        configs.append(config)
        save()
    }
    
    func update(_ config: NetworkConfig) {
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
    
    func remove(_ config: NetworkConfig) {
        configs.removeAll { $0.id == config.id }
        save()
    }
    
    func mergeFavorites(for configID: UUID, newFavoritesFromServer: [Station]) {
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
