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
//  BetterSonosApp.swift
//

import SwiftUI
import Foundation
import Combine
import os.log

// MARK: - Network Configuration

struct NetworkConfig: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var displayName: String
    var baseURL: String
    var enabled: Bool
    var showDefaultPresetsForThisNetwork: Bool
    var explicitlyDisabledFavoriteURLs: Set<String> = []
    var lastKnownServerFavorites: [Station]? = nil
    var enabledLineInUUIDs: Set<String> = []
    var lineInCustomNames: [String: String] = [:] // UUID: Custom Name
    var manuallyDisabledVolumeUUIDs: Set<String> = []
    
    enum CodingKeys: String, CodingKey {
        case id, displayName, baseURL, enabled
        // enabledFavoriteNames is removed
        case showDefaultPresetsForThisNetwork
        case explicitlyDisabledFavoriteURLs
        case lastKnownServerFavorites
        case enabledLineInUUIDs
        case lineInCustomNames
        case manuallyDisabledVolumeUUIDs
    }

    init(id: UUID, displayName: String, baseURL: String, enabled: Bool, showDefaultPresetsForThisNetwork: Bool, explicitlyDisabledFavoriteURLs: Set<String> = [], lastKnownServerFavorites: [Station]? = nil, enabledLineInUUIDs: Set<String> = [], lineInCustomNames: [String: String] = [:],manuallyDisabledVolumeUUIDs: Set<String> = []) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.enabled = enabled
        self.showDefaultPresetsForThisNetwork = showDefaultPresetsForThisNetwork
        self.explicitlyDisabledFavoriteURLs = explicitlyDisabledFavoriteURLs
        self.lastKnownServerFavorites = lastKnownServerFavorites
        self.enabledLineInUUIDs = enabledLineInUUIDs
        self.lineInCustomNames = lineInCustomNames
        self.manuallyDisabledVolumeUUIDs = manuallyDisabledVolumeUUIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        enabled = try container.decode(Bool.self, forKey: .enabled)

        // For data migration:
        showDefaultPresetsForThisNetwork = try container.decodeIfPresent(Bool.self, forKey: .showDefaultPresetsForThisNetwork) ?? false
        explicitlyDisabledFavoriteURLs = try container.decodeIfPresent(Set<String>.self, forKey: .explicitlyDisabledFavoriteURLs) ?? []
        lastKnownServerFavorites = try container.decodeIfPresent([Station].self, forKey: .lastKnownServerFavorites)
        enabledLineInUUIDs = try container.decodeIfPresent(Set<String>.self, forKey: .enabledLineInUUIDs) ?? []
        lineInCustomNames = try container.decodeIfPresent([String: String].self, forKey: .lineInCustomNames) ?? [:]
        manuallyDisabledVolumeUUIDs = try container.decodeIfPresent(Set<String>.self, forKey: .manuallyDisabledVolumeUUIDs) ?? []

        // If 'enabledFavoriteNames' was a key in older data and needs to be explicitly ignored,
        // you might not need to do anything special if it's simply removed from CodingKeys.
        // If it could cause decoding errors, you might need to decode and discard it.
        // For now, assuming its absence in CodingKeys is sufficient.
    }
    
    static func == (lhs: NetworkConfig, rhs: NetworkConfig) -> Bool {
        lhs.id == rhs.id &&
        lhs.displayName == rhs.displayName &&
        lhs.baseURL == rhs.baseURL &&
        lhs.enabled == rhs.enabled &&
        lhs.showDefaultPresetsForThisNetwork == rhs.showDefaultPresetsForThisNetwork &&
        lhs.explicitlyDisabledFavoriteURLs == rhs.explicitlyDisabledFavoriteURLs &&
        lhs.lastKnownServerFavorites == rhs.lastKnownServerFavorites &&
        lhs.enabledLineInUUIDs == rhs.enabledLineInUUIDs &&
        lhs.lineInCustomNames == rhs.lineInCustomNames &&
        lhs.manuallyDisabledVolumeUUIDs == rhs.manuallyDisabledVolumeUUIDs
    }
}

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
                let decodedConfigs = try JSONDecoder().decode([NetworkConfig].self, from: iCloudData)
                // Update the published property on the main thread
                DispatchQueue.main.async {
                    self.configs = decodedConfigs
                    // Also update UserDefaults to keep it as a local cache of the iCloud version.
                    UserDefaults.standard.set(iCloudData, forKey: Self.key)
                    NetworkConfigStore.logger.info("Refreshed configurations from iCloud due to external changes.")
                }
            } catch {
                    // Replace print with OSLog once implemented (see section 3)
                NetworkConfigStore.logger.info("Error decoding configurations from iCloud after notification: \(error). Attempting to load from local UserDefaults.")
                    // Attempt to load from local as a fallback
                    self.loadFromLocalStoreAsFallback()
                }
            } else {
                // iCloud data is nil. Check local UserDefaults instead of clearing immediately.
                // Replace print with OSLog once implemented (see section 3)
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
                    // Replace print with OSLog once implemented (see section 3)
                    NetworkConfigStore.logger.info("Loaded from UserDefaults as iCloud was empty or failed to decode. Local data preserved.")
                    // Optional: If iCloud was empty and local data was loaded,
                    // you might want to trigger a save to push this data to iCloud.
                    // if ubiquitousStore.data(forKey: Self.iCloudKey) == nil {
                    //    self.save()
                    // }
                }
            } catch {
                DispatchQueue.main.async {
                    self.configs = [] // Both iCloud and local are problematic
                    UserDefaults.standard.removeObject(forKey: Self.key) // Clear potentially corrupted local data
                    // Replace print with OSLog once implemented (see section 3)
                    NetworkConfigStore.logger.info("Error decoding from UserDefaults as well. Starting with empty configurations.")
                }
            }
        } else {
            DispatchQueue.main.async {
                self.configs = [] // Both iCloud and local are empty
                // Replace print with OSLog once implemented (see section 3)
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
            var updatedConfigs = configs
            updatedConfigs[idx] = config
            configs = updatedConfigs // This is the key change that triggers the UI update
            
            save()
        }
    }
    
    func remove(_ config: NetworkConfig) {
        configs.removeAll { $0.id == config.id }
        save()
    }
    
    // In BetterSonosApp.swift, class NetworkConfigStore
    // Modify mergeFavorites()

    func mergeFavorites(for configID: UUID, newFavoritesFromServer: [Station]) {
        guard let idx = configs.firstIndex(where: { $0.id == configID }) else { return }
        var currentConfig = configs[idx]

        // Primary Role: Updates configs[idx].lastKnownServerFavorites with newFavoritesFromServer.
        // Does NOT modify configs[idx].explicitlyDisabledFavoriteURLs.
        // Does NOT modify configs[idx].showDefaultPresetsForThisNetwork.

        // Sort by name for consistent storage and potential display.
        let sortedNewFavorites = newFavoritesFromServer.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        if currentConfig.lastKnownServerFavorites != sortedNewFavorites {
            currentConfig.lastKnownServerFavorites = sortedNewFavorites
            configs[idx] = currentConfig
            save()
            // print("[NetworkConfigStore] Updated lastKnownServerFavorites for \(currentConfig.displayName). Count: \(currentConfig.lastKnownServerFavorites?.count ?? 0)")
        }
    }
    
}

// MARK: - Main App

@main
struct BetterSonosApp: App {
    @StateObject private var networkStore = NetworkConfigStore()
    @StateObject private var settingsStore = AppSettingsStore.shared

    var body: some Scene {
        WindowGroup {
            BetterSonosView()
                .environmentObject(networkStore)
                .environmentObject(settingsStore)
        }
    }
}

// MARK: - Main View

struct BetterSonosView: View {
    @EnvironmentObject var networkStore: NetworkConfigStore
    @EnvironmentObject var settingsStore: AppSettingsStore
    @State private var showSettings = false
    @State private var configForEditingModal: NetworkConfig? = nil // Used to present NetworkEditModal for add/edit

    var enabledConfigs: [NetworkConfig] {
        networkStore.configs.filter { $0.enabled }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                HStack {
                    Spacer()
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .imageScale(.large)
                            .padding(8)
                    }
                    .accessibilityLabel("Settings")
                }
                .padding(.horizontal) // Add this modifier to the HStack

                if networkStore.configs.isEmpty {
                    Spacer() // Pushes content to center
                    VStack(spacing: 16) {
                        Text("No Sonos networks configured.")
                            .font(.headline)
                            .multilineTextAlignment(.center)
                        Text("Add a node-sonos-http-api server to get started.")
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .foregroundColor(.gray)
                        Button {
                            // Prepare a new NetworkConfig for adding
                            configForEditingModal = NetworkConfig(
                                id: UUID(), // New ID for a new network
                                displayName: "",
                                baseURL: "", // User will fill this in
                                enabled: true, // Default to enabled
                                showDefaultPresetsForThisNetwork: true, // Default as per previous discussions
                                explicitlyDisabledFavoriteURLs: [],
                                lastKnownServerFavorites: nil
                            )
                        } label: {
                            Text("Add Network")
                                .padding(.horizontal)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.horizontal)
                    Spacer() // Pushes content to center
                } else {
                    networkList // Show the list if networks exist
                }
            }
        }
        .sheet(isPresented: $showSettings) { // <<<< ADD THIS BLOCK
                NetworkSettingsModal(isPresented: $showSettings)
                // EnvironmentObjects (networkStore and settingsStore)
                // should be automatically passed down from BetterSonosView.
            }
        
        .sheet(item: $configForEditingModal) { configItem in // Triggered when configForEditingModal is not nil
                    NetworkEditModal(
                        initialConfig: configItem,
                        // isEditing should be true if the config.id already exists in the store
                        // For a brand new config, its ID won't be in the store yet.
                        isEditing: networkStore.configs.contains(where: { $0.id == configItem.id }),
                        onSave: { savedConfig in
                            if networkStore.configs.contains(where: { $0.id == savedConfig.id }) {
                                networkStore.update(savedConfig)
                            } else {
                                networkStore.add(savedConfig)
                            }
                            configForEditingModal = nil // Dismiss the sheet
                        },
                        onCancel: {
                                configForEditingModal = nil // Dismisses the sheet
                            },
                        onDelete: {
                            // This onDelete makes sense if used for editing an existing config.
                            // For a brand new config (isEditing will be false), NetworkEditModal won't show delete button.
                            // But if we were to use this sheet for editing, this would be the delete action.
                            networkStore.remove(configItem)
                            configForEditingModal = nil // Dismiss the sheet
                        }
                    )
                }

    }

    private var networkList: some View {
        ScrollView {
            LazyVStack(spacing: 24) {
                ForEach(enabledConfigs) { config in
                    NetworkAccordionView(
                        config: config,
                        networkStore: networkStore,
                        settingsStore: settingsStore
                    )
                    .id(config) // This forces a full recreation of the view when the config changes
                }
            }
            .padding(.horizontal)
        }
    }

}

// MARK: - Accordion For Each Network

struct NetworkAccordionView: View {
    let config: NetworkConfig
    @StateObject private var viewModel: SonosViewModel
    @State private var isExpanded: Bool = true

    // The init now creates the ViewModel using the passed-in stores
    init(config: NetworkConfig, networkStore: NetworkConfigStore, settingsStore: AppSettingsStore) {
        self.config = config
        self._viewModel = StateObject(wrappedValue: SonosViewModel(
            baseURL: config.baseURL,
            networkStore: networkStore,
            settingsStore: settingsStore
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation { isExpanded.toggle() }
            } label: {
                HStack {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .foregroundColor(.primary)
                    Text(config.displayName)
                        .font(.title2)
                        .bold()
                        .foregroundColor(.primary)
                    Spacer()
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            if isExpanded {
                // The GroupedRoomsListView now gets its dependencies from the viewModel and config
                GroupedRoomsListView(
                    viewModel: viewModel,
                    filteredStations: viewModel.filteredStations(for: config),
                    config: config
                )
            }
        }
    }
}

// MARK: - Edit/Add Network Modal

struct NetworkEditModal: View {
    // Passed from parent
    let initialConfig: NetworkConfig
    let isEditing: Bool
    var onSave: (NetworkConfig) -> Void
    var onCancel: () -> Void
    var onDelete: (() -> Void)?   // Only non-nil if editing existing

    @EnvironmentObject var settingsStore: AppSettingsStore // To access
    @State private var baseScheme: String
    @State private var baseAddress: String // For the host and path part of the baseURL
    @State private var error: String?
    // fetchedFavorites will represent the names/URLs from the server for display
    // lastKnownServerFavorites from NetworkConfig will be the source for fetchedFavorites initially
    @State private var showDeleteAlert = false
    @State private var fetchedFavorites: [String] = []
    @State private var isLoadingFavorites = false
    @State private var favoritesError: Bool = false
    // State for Line-In sources
    @State private var potentialLineInSources: [(uuid: String, name: String, disambiguatedName: String)] = []
    @State private var isLoadingLineInSources: Bool = false
    @State private var lineInSourcesError: String? = nil
    @State private var editedConfig: NetworkConfig // To manage all edits including Line-In

    // ✅ Properly initialize @State variables
    init(
        initialConfig: NetworkConfig,
        isEditing: Bool,
        onSave: @escaping (NetworkConfig) -> Void,
        onCancel: @escaping () -> Void,
        onDelete: (() -> Void)? = nil
    ) {
        self.initialConfig = initialConfig // Keep a copy of the original
        self.isEditing = isEditing
        self.onSave = onSave
        self.onCancel = onCancel
        self.onDelete = onDelete

        // Initialize all @State properties directly or from initialConfig
        // Main config being edited:
        _editedConfig = State(initialValue: initialConfig)

        // For properties directly bound to UI elements not covered by editedConfig directly
        // (or if you prefer to keep them separate for clarity during editing, then consolidate on save)
        // For now, we assume direct editing of editedConfig's properties where possible,
        // or bind to sub-properties of editedConfig.

        // Base URL parsing for scheme/address pickers
        let (scheme, address) = NetworkEditModal.splitURL(initialConfig.baseURL)
        _baseScheme = State(initialValue: scheme) // This will drive editedConfig.baseURL on save
        _baseAddress = State(initialValue: address) // This will drive editedConfig.baseURL on save

        // DisplayName can be bound directly to editedConfig.displayName
        // Enabled can be bound directly to editedConfig.enabled
        // showDefaultPresetsForThisNetwork to editedConfig.showDefaultPresetsForThisNetwork
        // explicitlyDisabledFavoriteURLs to editedConfig.explicitlyDisabledFavoriteURLs

        // Other @State vars for modal's own logic, not directly part of NetworkConfig
        _error = State(initialValue: nil)
        _showDeleteAlert = State(initialValue: false)
        _fetchedFavorites = State(initialValue: initialConfig.lastKnownServerFavorites?.map { $0.url } ?? [])
        _isLoadingFavorites = State(initialValue: false)
        _favoritesError = State(initialValue: false)

        // The new Line-In @State vars are already declared with default initializers:
        // _potentialLineInSources = State(initialValue: [])
        // _isLoadingLineInSources = State(initialValue: false)
        // _lineInSourcesError = State(initialValue: nil)
    }

    private var isForcedDefaultNetwork: Bool {
        // Definition of "Zero Presets" for a given Network (Evaluated Dynamically):
        // 1. Global Custom CSV: AppSettingsStore.remoteCSVURL is nil or empty.
        let globalCustomCSVEmpty = settingsStore.remoteCSVURL == nil || settingsStore.remoteCSVURL?.isEmpty == true

        // 2. Global Manual Stations: AppSettingsStore.manualStations is empty.
        let globalManualStationsEmpty = settingsStore.manualStations.isEmpty

        // 3. This Specific Network's Sonos Favorites:
        // The list of effectively enabled Sonos favorites for this specific network is empty.
        // An "enabled" favorite means its URL is present in thisNetwork.lastKnownServerFavorites
        // (represented by fetchedFavorites here for the current view) AND its URL
        // is not in thisNetwork.explicitlyDisabledFavoriteURLs.

        let effectivelyEnabledFavoritesCount = (initialConfig.lastKnownServerFavorites ?? []).filter { station in
            !editedConfig.explicitlyDisabledFavoriteURLs.contains(station.url) // station.url is the favorite name/key
        }.count

        let networkFavoritesEmpty = effectivelyEnabledFavoritesCount == 0

        // "Forced Default" Rule:
        return globalCustomCSVEmpty && globalManualStationsEmpty && networkFavoritesEmpty
    }

    private var effectiveShowDefaultPresetsForThisNetwork: Bool {
        if isForcedDefaultNetwork {
            return true // Forced ON
        }
        return editedConfig.showDefaultPresetsForThisNetwork // User's preference
    }
    
    // Helper functions for URL parsing
    private static func splitURL(_ fullURL: String?) -> (scheme: String, address: String) {
        guard let urlString = fullURL, !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ("http://", "") // Sonos HTTP API often defaults to http, and usually has an address
        }
        if urlString.lowercased().hasPrefix("http://") {
            return ("http://", String(urlString.dropFirst("http://".count)))
        } else if urlString.lowercased().hasPrefix("https://") {
            return ("https://", String(urlString.dropFirst("https://".count)))
        } else {
            // If no scheme, assume http for Sonos API and treat full string as address
            return ("http://", urlString)
        }
    }

    private static func joinURL(scheme: String, address: String) -> String? {
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedAddress.isEmpty {
            // For base URLs, an empty address might mean the URL is invalid or incomplete.
            // Let's still form it, validation will happen later.
            // Or return nil if an address is strictly required. For now, form it.
            return scheme // e.g., "http://" which is likely invalid alone for a base URL
        }
        // Ensure address doesn't accidentally start with another scheme
        if trimmedAddress.lowercased().hasPrefix("http://") || trimmedAddress.lowercased().hasPrefix("https://") {
            return trimmedAddress // Address itself is a full URL, use it. This is a fallback.
        }
        return scheme + trimmedAddress
    }
    
    private var constructedFullBaseURL: String? {
        NetworkEditModal.joinURL(scheme: baseScheme, address: baseAddress.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Display Name")) {
                    TextField("e.g. Home, Country, Beach", text: $editedConfig.displayName)
                }
                Section(header: Text("Base URL")) {
                    HStack(spacing: 0) {
                                        Picker("Scheme", selection: $baseScheme) {
                                            Text("https://").tag("https://")
                                            Text("http://").tag("http://")
                                        }
                                        .pickerStyle(.menu)
                                        .labelsHidden()
                                        .frame(width: 100, alignment: .leading)

                                        TextField("pi.local:5005", text: $baseAddress)
                                            .keyboardType(.URL)
                                            .textInputAutocapitalization(.never)
                                            .disableAutocorrection(true)
                                    }
                }
                Section(header: Text("Default Presets")) {
                                Toggle("Include Default Presets", isOn: Binding(
                                    get: { effectiveShowDefaultPresetsForThisNetwork },
                                    set: { newValue in
                                        // Only allow update if not forced
                                        if !isForcedDefaultNetwork {
                                            editedConfig.showDefaultPresetsForThisNetwork = newValue
                                        }
                                    }
                                ))
                                .disabled(isForcedDefaultNetwork) // UI shows disabled if forced
                                if isForcedDefaultNetwork {
                                    Text("Default presets are required for this network as no other presets or favorites are configured or enabled.")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                            }

                if !baseAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { // Or use constructedFullBaseURL != nil
                    Section(header: Text("Sonos Favorites")) {
                        if isLoadingFavorites {
                            ProgressView("Loading favorites...")
                        } else if favoritesError {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Could not load favorites from this network's server.", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                                Text("Ensure the Base URL is correct and the Sonos HTTP API is reachable.")
                                    .font(.caption)
                                Button("Try Again") {
                                    Task { await fetchFavoritesIfNeeded() }
                                }
                            }
                        } else if fetchedFavorites.isEmpty && !baseAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("No Sonos favorites found on this server, or they could not be loaded. Try refreshing if the Base URL is correct.")
                                .font(.caption)
                                .foregroundColor(.gray)
                            Button("Refresh Favorites") { // Renamed for clarity
                                Task { await fetchFavoritesIfNeeded() }
                            }
                        } else {
                            // Display list from fetchedFavorites (which are strings: favorite names/URLs)
                            ForEach(fetchedFavorites.sorted(), id: \.self) { favoriteURLOrName in
                                Toggle(favoriteURLOrName, isOn: Binding(
                                    get: { !editedConfig.explicitlyDisabledFavoriteURLs.contains(favoriteURLOrName) },
                                    set: { isOn in
                                        if isOn {
                                            editedConfig.explicitlyDisabledFavoriteURLs.remove(favoriteURLOrName)
                                        } else {
                                            editedConfig.explicitlyDisabledFavoriteURLs.insert(favoriteURLOrName)
                                        }
                                    }                                ))
                            }
                            // Refresh button always available if base URL is present
                            if !baseAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Button("Refresh Favorites") { // Renamed for clarity
                                    Task { await fetchFavoritesIfNeeded() }
                                }
                            }
                        }
                    }
                }
                Section(header: Text("Line-In Sources")) {
                                    if isLoadingLineInSources {
                                        ProgressView("Loading Line-In sources...")
                                    } else if let errorMsg = lineInSourcesError {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Label("Could not load Line-In sources.", systemImage: "exclamationmark.triangle.fill")
                                                .foregroundColor(.red)
                                            Text(errorMsg)
                                                .font(.caption)
                                            Button("Try Again") {
                                                Task { await fetchLineInSources() }
                                            }
                                        }
                                    } else if potentialLineInSources.isEmpty {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text("No Line-In sources found for this network's Sonos system.")
                                                .font(.caption)
                                                .foregroundColor(.gray)
                                            if !baseAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                                Button("Refresh Line-In Sources") {
                                                    Task { await fetchLineInSources() }
                                                }
                                            }
                                        }
                                    } else {
                                        ForEach(potentialLineInSources, id: \.uuid) { source in
                                            VStack(alignment: .leading) {
                                                Toggle(source.disambiguatedName, isOn: Binding(
                                                    get: { editedConfig.enabledLineInUUIDs.contains(source.uuid) },
                                                    set: { isOn in
                                                        if isOn {
                                                            editedConfig.enabledLineInUUIDs.insert(source.uuid)
                                                        } else {
                                                            editedConfig.enabledLineInUUIDs.remove(source.uuid)
                                                            // Optionally remove custom name when disabled
                                                            // editedConfig.lineInCustomNames.removeValue(forKey: source.uuid)
                                                        }
                                                    }
                                                ))

                                                if editedConfig.enabledLineInUUIDs.contains(source.uuid) {
                                                    HStack {
                                                        Text("Custom Name:")
                                                            .font(.caption)
                                                            .foregroundColor(.secondary)
                                                        TextField("Optional (e.g., \(source.name))", text: Binding(
                                                            get: { editedConfig.lineInCustomNames[source.uuid] ?? "" },
                                                            set: { newValue in
                                                                let trimmedValue = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                                                if trimmedValue.isEmpty {
                                                                    editedConfig.lineInCustomNames.removeValue(forKey: source.uuid)
                                                                } else {
                                                                    editedConfig.lineInCustomNames[source.uuid] = trimmedValue
                                                                }
                                                            }
                                                        ))
                                                        .font(.caption)
                                                    }
                                                    .padding(.leading, 20) // Indent custom name field
                                                }
                                            }
                                        }
                                        // Refresh button always available if base URL is present and sources were loaded
                                        if !baseAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                            Button("Refresh Line-In Sources") {
                                                Task { await fetchLineInSources() }
                                            }
                                        }
                                    }
                                }
                Section(header: Text("Disable Volume Control")) {
                    if isLoadingLineInSources {
                        ProgressView()
                    } else if potentialLineInSources.isEmpty {
                        Text("No speakers found. Refresh to try again.")
                            .font(.caption)
                            .foregroundColor(.gray)
                    } else {
                        Text("Enable this for speakers connected to an external amplifier (e.g., Sonos Port or Connect).")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        ForEach(potentialLineInSources, id: \.uuid) { source in
                            Toggle(source.disambiguatedName, isOn: Binding(
                                get: { editedConfig.manuallyDisabledVolumeUUIDs.contains(source.uuid) },
                                set: { isDisabled in
                                    if isDisabled {
                                        editedConfig.manuallyDisabledVolumeUUIDs.insert(source.uuid)
                                    } else {
                                        editedConfig.manuallyDisabledVolumeUUIDs.remove(source.uuid)
                                    }
                                }
                            ))
                        }
                    }
                }
                if let error = error {
                    Section {
                        Text(error)
                            .foregroundColor(.red)
                    }
                }
                // ✅ Show Delete button reliably
                if isEditing, let onDelete = onDelete {
                    Section {
                        Button(role: .destructive) {
                            showDeleteAlert = true
                        } label: {
                            Label("Delete Network", systemImage: "trash")
                        }
                        .alert("Delete Network?", isPresented: $showDeleteAlert) {
                            Button("Delete", role: .destructive) { onDelete() }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("This cannot be undone.")
                        }
                    }
                }
            }
            .onAppear {
                        // Initialize fetchedFavorites from lastKnownServerFavorites if available
                        if let knownFavorites = initialConfig.lastKnownServerFavorites {
                            self.fetchedFavorites = knownFavorites.map { $0.url } // $0.url is the favorite name/key
                        }
                        // Then, if baseURL is present, try to fetch fresh ones (or for the first time)
                        if !baseAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { // Check baseAddress instead
                            // Only fetch if fetchedFavorites is still empty OR if a refresh is desired on every appear
                            // For now, let's assume we always try to refresh to get latest.
                            // If lastKnownServerFavorites was used, this fetch will update it.
                            Task { await fetchFavoritesIfNeeded() }
                        }
                    }
            .navigationTitle(isEditing ? "Edit Network" : "Add Network")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        guard !editedConfig.displayName.trimmingCharacters(in: .whitespaces).isEmpty else {
                            error = "Display name is required."
                            return
                        }
                        let finalBaseAddress = baseAddress.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !finalBaseAddress.isEmpty else {
                                error = "Base address (e.g., pi.local:5005) is required."
                                return
                            }

                            // The scheme picker ensures it starts with http or https.
                            // No need for baseURL.starts(with: "http") validation if using scheme picker.
                            guard let constructedBaseURL = NetworkEditModal.joinURL(scheme: baseScheme, address: finalBaseAddress),
                                  URL(string: constructedBaseURL) != nil else { // Basic URL validation
                                error = "Invalid Base URL constructed."
                                return
                            }

                            error = nil
                            var finalConfigToSave = editedConfig // Start with the edited copy
                            finalConfigToSave.baseURL = constructedBaseURL // Update its baseURL from the scheme/address pickers

                            // Properties like displayName, showDefaultPresetsForThisNetwork,
                            // explicitlyDisabledFavoriteURLs, enabledLineInUUIDs, and lineInCustomNames
                            // are already up-to-date within 'editedConfig' due to direct UI bindings.
                            // The 'enabled' property of the config was set from initialConfig.enabled
                            // and is not changed by this modal's UI, so it's correctly preserved in editedConfig.

                            onSave(finalConfigToSave)
                    }
                }
            }
        }
    }
    
    // In BetterSonosApp.swift, struct NetworkEditModal
    // Modify fetchFavoritesIfNeeded()

    func fetchFavoritesIfNeeded() async {
        guard let currentFullBaseURL = constructedFullBaseURL, // Use the computed property
                  let url = URL(string: "\(currentFullBaseURL)/favorites") else {
            await MainActor.run { // Ensure UI updates are on main actor
                self.favoritesError = true // Indicate error
                self.isLoadingFavorites = false
                self.fetchedFavorites = [] // Clear previously fetched items on error
            }
            return
        }

        // Set loading state on main actor before async operation
        await MainActor.run {
            self.isLoadingFavorites = true
            self.favoritesError = false
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let serverFavoriteNames = try JSONDecoder().decode([String].self, from: data) // Names from server

            await MainActor.run {
                self.fetchedFavorites = serverFavoriteNames.sorted() // Update the list used to RENDER the toggles.
                self.isLoadingFavorites = false
                self.favoritesError = false

                // CRITICAL: We are NOT modifying self.enabledFavoriteNames here based on serverFavoriteNames.
                // self.enabledFavoriteNames was initialized from initialConfig.enabledFavoriteNames.
                // The ForEach loop binds toggles to self.enabledFavoriteNames for items in self.fetchedFavorites.
                // If a favorite name is in self.enabledFavoriteNames (user had it ON) but is NOT in
                // self.fetchedFavorites (server doesn't list it now), its toggle simply won't be displayed
                // in this specific refresh of the modal's list. However, its "enabled" status in
                // self.enabledFavoriteNames is preserved.
                Task { await self.fetchLineInSources() } // Also refresh player list for Line-In
            }
        } catch {
            await MainActor.run {
                self.favoritesError = true
                self.isLoadingFavorites = false
                self.fetchedFavorites = [] // Clear fetched items on error
                 print("Error fetching favorites in NetworkEditModal: \(error)") // Log the error
            }
        }
    }
    
    private func fetchLineInSources() async {
        guard let currentFullBaseURL = constructedFullBaseURL, // Use the computed property for base URL
              let url = URL(string: "\(currentFullBaseURL)/zones") else {
            await MainActor.run {
                self.lineInSourcesError = "Invalid Base URL for Sonos API."
                self.isLoadingLineInSources = false
                self.potentialLineInSources = []
            }
            return
        }

        await MainActor.run {
            self.isLoadingLineInSources = true
            self.lineInSourcesError = nil
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw URLError(.badServerResponse) // Or a custom error
            }

            let zones = try JSONDecoder().decode([Zone].self, from: data) // Assumes Zone struct is defined globally or accessible

            var uniquePlayers: [String: String] = [:] // UUID: roomName
            for zone in zones {
                for member in zone.members {
                    uniquePlayers[member.uuid] = member.roomName // Last name wins for a UUID if somehow duplicated
                }
            }

            // Disambiguate names
            var counts = [String: Int]()
            for player in uniquePlayers.values {
                counts[player, default: 0] += 1
            }

            let finalPotentialSources = uniquePlayers.map { uuid, name -> (uuid: String, name: String, disambiguatedName: String) in
                let isAmbiguous = (counts[name] ?? 0) > 1
                let disambiguatedName: String
                if isAmbiguous {
                    let shortUUID = String(uuid.suffix(6))
                    disambiguatedName = "\(name) (\(shortUUID))"
                } else {
                    disambiguatedName = name
                }
                return (uuid: uuid, name: name, disambiguatedName: disambiguatedName)
            }.sorted { $0.disambiguatedName.localizedCaseInsensitiveCompare($1.disambiguatedName) == .orderedAscending }


            await MainActor.run {
                self.potentialLineInSources = finalPotentialSources
                self.isLoadingLineInSources = false
            }

        } catch {
            await MainActor.run {
                self.lineInSourcesError = error.localizedDescription
                self.isLoadingLineInSources = false
                self.potentialLineInSources = []
                print("Error fetching potential Line-In sources: \(error)")
            }
        }
    }
    
}

// MARK: - ViewModel & Models (FULL)

class SonosViewModel: NSObject, ObservableObject {
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
    @Published private var roomNameEncodingMap: [String: String] = [:]
    @Published var accordionState: [String: Bool] = [:]
    
    private let networkStore: NetworkConfigStore
    private let settingsStore: AppSettingsStore // Declare type, will be initialized in init
    private var cancellables = Set<AnyCancellable>()   // To store Combine subscriptions
    
    let baseURL: String
    
    let connectUUIDs: Set<String> = [
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

    private func encode(_ component: String) -> String? {
        return component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
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
    
    // In SonosViewModel class in BetterSonosApp.swift
    // Replace the entire processZones function with this updated version

    @MainActor
    private func processZones(_ zones: [Zone]) {
        // Initialize temporary local collections to build up the new state
        var ng: [SonosGroup] = []
        var nv: [String: Int] = [:]
        var nm: [String: Bool] = [:]
        var np: [String: String] = [:]
        var di: [String: String] = [:]
        var ct: [String: String] = [:]
        var newTrackByRoom: [String: Track] = [:]
        var newRoomNameEncodingMap: [String: String] = [:]
        var newVolumeDisabledState: [String: Bool] = [:]
        var newUuidToRoomNameMap: [String: String] = [:]

        // --- ADD THIS BLOCK to get the current network's config ---
        let config = self.networkStore.configs.first { $0.baseURL == self.baseURL }
        let manuallyDisabledUUIDs = config?.manuallyDisabledVolumeUUIDs ?? []
        // --- END BLOCK ---

        for zone in zones {
            let coordDisplayName = zone.coordinator.roomName
            let coordUUID = zone.coordinator.uuid

            if newRoomNameEncodingMap[coordDisplayName] == nil {
                if let encoded = encode(coordDisplayName) {
                    newRoomNameEncodingMap[coordDisplayName] = encoded
                } else {
                    newRoomNameEncodingMap[coordDisplayName] = coordDisplayName // Fallback
                }
            }

            let isConnect = connectUUIDs.contains(coordUUID)
            // --- UPDATE THIS LINE ---
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

                if newRoomNameEncodingMap[memberDisplayName] == nil {
                    if let encoded = encode(memberDisplayName) {
                        newRoomNameEncodingMap[memberDisplayName] = encoded
                    } else {
                        newRoomNameEncodingMap[memberDisplayName] = memberDisplayName // Fallback
                    }
                }
                
                // --- UPDATE THIS LINE ---
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
        self.roomNameEncodingMap = newRoomNameEncodingMap
            
        var sel: [String: Station] = [:]
        for room in ct.keys {
            if let match = matchedStation(for: room) {
                sel[room] = match
            }
        }
        self.selectedStationByRoom = sel
        
        self.loadAccordionStateFromDefaults()
    }
    
    @MainActor
    func refresh() async {
        guard let url = URL(string: "\(baseURL)/zones") else { return }
        do {
            print("🌐 Fetching zones from \(baseURL)")

            let favoriteNames = try await fetchFavoriteNames()  // ✅ NEW
            // Convert favorite names (Strings) to Station objects
                    let favoriteStations = favoriteNames.map { Station(name: $0, url: $0, type: "favorite") }

                    if let configID = networkStore.configs.first(where: { $0.baseURL == baseURL })?.id {
                        networkStore.mergeFavorites(for: configID, newFavoritesFromServer: favoriteStations)
                    }
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoder = JSONDecoder()
            let zones = try decoder.decode([Zone].self, from: data)
            processZones(zones)
        } catch {
            print("Error refreshing Sonos state: \(error)")
        }
    }
    
    func filteredStations(for config: NetworkConfig) -> [Station] {
        // remoteStations is the fully built, deduplicated list from buildRemoteStationList()
        print("[FilteredStations] Filtering for network: \(config.displayName)")
            print("[FilteredStations] Config's explicitlyDisabledFavoriteURLs: \(config.explicitlyDisabledFavoriteURLs)")

            let filteredList = remoteStations.filter { station in
                // Log details for every station being considered
                // print("[FilteredStations] Considering station: Name='\(station.name)', URL='\(station.url)', Type='\(station.type)'")

                if station.type.lowercased() == "favorite" {
                    let isEnabled = !config.explicitlyDisabledFavoriteURLs.contains(station.url)
                    print("[FilteredStations] FAVORITE station: Name='\(station.name)', URL='\(station.url)'. Is explicitly disabled: \(config.explicitlyDisabledFavoriteURLs.contains(station.url)). Should be included: \(isEnabled)")
                    return isEnabled
                } else {
                    // Log why non-favorite is included (it's automatic)
                    // print("[FilteredStations] NON-FAVORITE station: Name='\(station.name)', URL='\(station.url)', Type='\(station.type)'. Included by default.")
                    return true
                }
            }
            print("[FilteredStations] Final filtered list count for \(config.displayName): \(filteredList.count)")
            // For more detail on what IS included:
            // print("[FilteredStations] Final included stations for \(config.displayName): \(filteredList.map { $0.name + " (" + $0.type + ")" })")
            return filteredList
    }
    
    @MainActor // Helper to ensure @Published remoteStations is updated on main actor
    private func updateRemoteStations(with stations: [Station]) {
        self.remoteStations = stations
        // print("[SonosViewModel] Updated remoteStations due to AppSettingsStore change. Count: \(stations.count)")
    }

    private func rebuildStationsAndRefreshUI() {
        Task {
            // print("[SonosViewModel] AppSettingsStore change detected, rebuilding remoteStations...")
            let newStations = await self.buildRemoteStationList()
            await self.updateRemoteStations(with: newStations)

            // It might also be beneficial to trigger a broader refresh of the ViewModel's state,
            // as buildRemoteStationList might also affect matched stations, etc.
            // However, avoid creating refresh loops if refresh() itself triggers settings changes.
            // For now, just updating remoteStations. If other parts of UI depend on a full
            // refresh after station list changes, consider if await self.refresh() is needed
            // and safe here. For this specific issue, updating remoteStations is key.
        }
    }

    @MainActor
    private func observeAppSettings() {
        settingsStore.$manualStations
            .dropFirst() // Ignore the initial value, react only to changes
            .sink { [weak self] _ in
                // print("[SonosViewModel] manualStations changed.")
                self?.rebuildStationsAndRefreshUI()
            }
            .store(in: &cancellables)

        settingsStore.$remoteCSVURL
            .dropFirst() // Ignore the initial value
            .sink { [weak self] _ in
                // print("[SonosViewModel] remoteCSVURL changed.")
                self?.rebuildStationsAndRefreshUI()
            }
            .store(in: &cancellables)
    }
    
// MARK: - Station Source Aggregation
    
    func fetchStations(from url: String) async -> [Station] {
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
                let type = parts.count == 3 ? parts[2].trimmingCharacters(in: .whitespaces).lowercased() : "stream"
                return Station(name: name, url: url, type: type)
            }
        } catch {
            print("Failed to fetch stations: \(error)")
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
    
    func buildRemoteStationList() async -> [Station] {
        let settings = await AppSettingsStore.shared
            guard let currentNetworkConfig = networkStore.configs.first(where: { $0.baseURL == self.baseURL }) else {
                print("[SonosViewModel buildRemoteStationList] ERROR: Could not find NetworkConfig for baseURL: \(self.baseURL)")
                return []
            }

            var allPotentialStations: [(station: Station, priority: Int, sourceOrder: Int)] = []
            var sourceCounter = 0 // To maintain original order within the same priority if needed later

            // --- Requirement 1: Default Remote Preset List (Per Network) ---
            // "Forced Default" Rule (Dynamic, Per Network):
            let remoteCSV = await settings.remoteCSVURL
            let manualStations = await settings.manualStations // Fetch the array
            let globalCustomCSVEmpty = remoteCSV == nil || remoteCSV?.isEmpty == true
            let globalManualStationsEmpty = manualStations.isEmpty
        
            let effectivelyEnabledFavoritesCount = (currentNetworkConfig.lastKnownServerFavorites ?? []).filter { favStation in
                !currentNetworkConfig.explicitlyDisabledFavoriteURLs.contains(favStation.url)
            }.count
            let networkFavoritesEmpty = effectivelyEnabledFavoritesCount == 0

            let isForcedDefault = globalCustomCSVEmpty && globalManualStationsEmpty && networkFavoritesEmpty

            let shouldUseDefaultCSV = isForcedDefault || currentNetworkConfig.showDefaultPresetsForThisNetwork

            if shouldUseDefaultCSV {
                let defaultCSVUrl = "https://raw.githubusercontent.com/alevy-me/sonos/refs/heads/main/default-stations.csv"
                let defaultStations = await fetchStations(from: defaultCSVUrl) // Assuming fetchStations adds type "stream" or similar
                allPotentialStations.append(contentsOf: defaultStations.map { station in
                    sourceCounter += 1
                    var modStation = station
                    if modStation.type.isEmpty { modStation = Station(name: station.name, url: station.url, type: "default_csv_stream")} // Ensure type
                    return (modStation, 4, sourceCounter) // Priority 4 for Default CSV
                })
                // print("[SonosViewModel buildRemoteStationList] Using Default CSV. Count: \(defaultStations.count)")
            }

            // --- Requirement 2: User-Defined Remote Preset List (Custom CSV) ---
        if let customCSVUrl = remoteCSV, !customCSVUrl.isEmpty { // Uses the 'remoteCSV' fetched with await above
                let customStations = await fetchStations(from: customCSVUrl)
                allPotentialStations.append(contentsOf: customStations.map { station in
                    sourceCounter += 1
                    var modStation = station
                    if modStation.type.isEmpty { modStation = Station(name: station.name, url: station.url, type: "custom_csv_stream")} // Ensure type
                    return (modStation, 2, sourceCounter) // Priority 2 for Custom CSV
                })
                // print("[SonosViewModel buildRemoteStationList] Using Custom CSV. Count: \(customStations.count)")
                DispatchQueue.main.async { // Update CSV load error status
                    settings.csvLoadError = customStations.isEmpty
                }
            } else {
                 DispatchQueue.main.async { // No custom CSV URL, so no load error from it.
                    settings.csvLoadError = false
                }
            }

            // --- Requirement 3: Manually-Entered Remote Streams ---
            if !manualStations.isEmpty { // Uses the 'manualStations' array fetched with await above
                allPotentialStations.append(contentsOf: manualStations.map { station in
                    sourceCounter += 1
                    return (station, 1, sourceCounter) // Priority 1 for Manual Entry
                })
                // print("[SonosViewModel buildRemoteStationList] Added Manual Stations. Count: \(settings.manualStations.count)")
            }

            // --- Requirement 4: Sonos Favorites (Per Network) ---
            // These are from currentNetworkConfig.lastKnownServerFavorites
            // These are already [Station] with type "favorite"
            if let serverFavorites = currentNetworkConfig.lastKnownServerFavorites {
                allPotentialStations.append(contentsOf: serverFavorites.map { station in
                    sourceCounter += 1
                    return (station, 3, sourceCounter) // Priority 3 for Sonos Favorite
                })
                // print("[SonosViewModel buildRemoteStationList] Added Server Favorites for this network. Count: \(serverFavorites.count)")
            }

        // --- Filtering and Adding Network-Specific Line-In Sources ---

        // Rule #7: Filter out any station from other sources (CSV, manual, favorites)
        // if its type is "linein" or its URL pattern matches a line-in,
        // UNLESS its UUID is in currentNetworkConfig.enabledLineInUUIDs.
        allPotentialStations.removeAll { (stationItem) -> Bool in
            let station = stationItem.station
            let stationURL = station.url.lowercased()
            let isLineInType = station.type.lowercased() == "linein"
            var isRinconStream = false
            var lineInUUID: String? = nil

            if stationURL.hasPrefix("x-rincon-stream:") {
                isRinconStream = true
                // Extract UUID: x-rincon-stream:UUID_HERE or x-rincon-stream:UUID_HERE:INSTANCE
                lineInUUID = String(stationURL.dropFirst("x-rincon-stream:".count).split(separator: ":").first ?? "")
            }
            // Add similar checks if other Line-In URL patterns exist, e.g., "x-sonosapi-stream:" if relevant for presets

            if isLineInType || isRinconStream {
                // This station appears to be a Line-In source.
                // Keep it ONLY if its UUID is explicitly enabled for this network.
                if let uuid = lineInUUID, currentNetworkConfig.enabledLineInUUIDs.contains(uuid) {
                    return false // Do NOT remove, it's allowed by this network's config.
                }
                // print("[SonosViewModel buildRemoteStationList] Filtering out external Line-In: \(station.name) (\(station.url))")
                return true // Remove, it's an external Line-In not enabled for this network.
            }
            return false // Not a Line-In type from an external source, keep it.
        }

        // Add Line-In sources specifically enabled for this network.
        // Suggestion: Let's assign them a high priority, e.g., 1, making them appear prominently.
        // You can adjust this priority as needed.
        let lineInPriority = 1 // Higher priority than Custom CSV (2), Sonos Fav (3), Default CSV (4)

        for uuid in currentNetworkConfig.enabledLineInUUIDs {
            sourceCounter += 1
            let defaultName = self.uuidToRoomName[uuid] ?? uuid // Use previously fetched room name, fallback to UUID
            // Disambiguation for defaultName isn't strictly needed here if uuidToRoomName is accurate,
            // as NetworkEditModal handles disambiguation for selection.
            // However, if uuidToRoomName could have non-unique names from bad data, add it.
            // For now, assume uuidToRoomName provides best available name.

            let stationName = currentNetworkConfig.lineInCustomNames[uuid] ?? defaultName
            let lineInStation = Station(name: stationName, url: "x-rincon-stream:\(uuid)", type: "linein")

            allPotentialStations.append((station: lineInStation, priority: lineInPriority, sourceOrder: sourceCounter))
            // print("[SonosViewModel buildRemoteStationList] Added Network Enabled Line-In: \(lineInStation.name)")
        }
         
        // --- Deduplication by URL with specified precedence ---
            var uniqueStationsByURL: [String: (station: Station, priority: Int, sourceOrder: Int)] = [:]

            for item in allPotentialStations {
                if let existing = uniqueStationsByURL[item.station.url] {
                    if item.priority < existing.priority { // Lower number means higher priority
                        uniqueStationsByURL[item.station.url] = item
                    } else if item.priority == existing.priority && item.sourceOrder < existing.sourceOrder {
                         // Optional: if priorities are same, take the one added earlier from its original list
                        uniqueStationsByURL[item.station.url] = item
                    }
                } else {
                    uniqueStationsByURL[item.station.url] = item
                }
            }

            // Extract the station objects, sort by original source order for stability if priorities were same, then by name.
            // Or just sort by name for the final list. Let's sort by name.
            let finalDedupedList = uniqueStationsByURL.values.map { $0.station }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            // print("[SonosViewModel buildRemoteStationList] Final Deduped List (count: \(finalDedupedList.count)): \(finalDedupedList.map { "\($0.name) [\($0.type)] (\($0.url))" })")
            return finalDedupedList
    }
    
    func fetchFavorites() async -> [Station] {
        guard let url = URL(string: "\(baseURL)/favorites") else { return [] }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode([String].self, from: data)

            return decoded.map {
                Station(name: $0, url: $0, type: "favorite")
            }

        } catch {
            print("Failed to fetch favorites: \(error)")
            return []
        }
    }
    
    func fetchFavoriteNames() async throws -> [String] {
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
        URLSession.shared.dataTask(with: URL(string: "\(baseURL)/\(room)/volume/\(nv)")!) { _, _, _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }.resume()
    }
    
    func toggleMute(room: String) {
        if !(isMuted[room] ?? false) {
            isMuted[room] = true // Optimistic update
            URLSession.shared.dataTask(with: URL(string: "\(baseURL)/\(room)/mute/on")!) { _, _, _ in
                Task { @MainActor [weak self] in
                    await self?.refresh()
                }
            }.resume()
        } else {
            isMuted[room] = false // Optimistic update
            // directUnmute itself is fire-and-forget. To refresh after it,
            // you'd ideally make directUnmute async or have a completion.
            // For now, we'll call refresh immediately after initiating directUnmute.
            directUnmute(room: room)
            Task { @MainActor [weak self] in // Refresh after initiating directUnmute
                await self?.refresh()
            }
        }
    }
    
    func sendStreamURL(to room: String, station: Station, completion: (() -> Void)? = nil) {
        let safeRoom = room.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? room
        let path: String
        
        if station.isFavorite {
            let encoded = station.url.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? station.url
            path = "\(baseURL)/\(safeRoom)/favorite/\(encoded)"
        } else if station.isLineIn {
            path = "\(baseURL)/\(safeRoom)/setavtransporturi/x-rincon-stream:\(station.url)"
        } else {
            let raw = "x-rincon-mp3radio://\(station.url)"
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            let enc = raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
            path = "\(baseURL)/\(safeRoom)/setavtransporturi/\(enc)"
        }
        URLSession.shared.dataTask(with: URL(string: path)!) { _,_,_ in completion?() }.resume()
        print("🔗 Sent request to: \(path)")
    }
    
    func togglePlayback(group: SonosGroup) {
        let coord = group.coordinator
        if playbackState[coord] == "PLAYING" {
            URLSession.shared.dataTask(with: URL(string: "\(baseURL)/\(coord)/pause")!) { _,_,_ in
                Task { await self.refresh() }
            }.resume()
        } else {
            if let station = selectedStationByRoom[coord] {
                sendStreamURL(to: coord, station: station) {
                    URLSession.shared.dataTask(with: URL(string: "\(self.baseURL)/\(coord)/play")!) { _,_,_ in
                        Task { await self.refresh() }
                    }.resume()
                }
            } else if let track = trackByRoom[coord],
                      let uri = track.uri ?? track.trackUri,
                      !uri.isEmpty {
                let encodedURI: String
                if uri.starts(with: "x-rincon-stream:") || uri.starts(with: "x-sonosapi-stream:") || uri.starts(with: "x-rincon-mp3radio://") {
                    encodedURI = uri.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? uri
                } else {
                    encodedURI = "x-rincon-mp3radio://\(uri)".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? uri
                }
                
                let setURI = "\(baseURL)/\(coord)/setavtransporturi/\(encodedURI)"
                URLSession.shared.dataTask(with: URL(string: setURI)!) { _,_,_ in
                    URLSession.shared.dataTask(with: URL(string: "\(self.baseURL)/\(coord)/play")!) { _,_,_ in
                        Task { await self.refresh() }
                    }.resume()
                }.resume()
            } else {
                print("⚠️ No preset selected and no known track URI. Cannot play.")
            }
        }
    }
    
    func isPlaying(group: SonosGroup) -> Bool {
        playbackState[group.coordinator] == "PLAYING"
    }
    
    func joinGroup(room: String, target: String) {
        URLSession.shared.dataTask(with: URL(string: "\(baseURL)/\(room)/join/\(target)")!) { _, _, _ in
            Task { @MainActor [weak self] in // Ensure refresh is on main actor
                await self?.refresh()
            }
        }.resume()
    }
    
    func leaveGroup(coordinator: String) {
        URLSession.shared.dataTask(with: URL(string: "\(baseURL)/\(coordinator)/leave")!).resume()
    }
    func leaveGroup(room: String) {
        guard let url = URL(string: "\(baseURL)/\(room)/leave") else { return }
        URLSession.shared.dataTask(with: url).resume()
        Task { await refresh() }
    }
    
    func directUnmute(room: String) {
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
        var req = URLRequest(url: URL(string: "http://\(ip):1400/MediaRenderer/RenderingControl/Control")!)
        req.httpMethod = "POST"
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\"urn:schemas-upnp-org:service:RenderingControl:1#SetMute\"",
                     forHTTPHeaderField: "SOAPACTION")
        req.httpBody = soap.data(using: .utf8)
        URLSession.shared.dataTask(with: req).resume()
    }
    
    func matchedStation(for room: String) -> Station? {
        guard let track = trackByRoom[room] else { return nil }
        return remoteStations.first { $0.matches(track: track) }
    }
    
    func currentTrack(for room: String) -> Track? {
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
        sendStreamURL(to: room, station: station) {
            URLSession.shared.dataTask(
                with: URL(string: "\(self.baseURL)/\(room)/play")!
            ) { _,_,_ in
                Task {
                    for _ in 0..<3 {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        await self.refresh()
                    }
                }
            }.resume()
        }
    }
    
    func isAccordionExpanded(for room: String) -> Bool {
        if playbackState[room] == "PLAYING" {
            return true
        }
        return accordionState[room] ?? false
    }
    
    @MainActor
    func setAccordionState(for room: String, expanded: Bool) {
        accordionState[room] = expanded
        persistAccordionState(for: room, expanded: expanded)
    }
    
    private let accordionDefaultsKeyPrefix = "accordionState_"
    
    @MainActor
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
    
    // MARK: - SSE Event Listener for /events
    
    private var sseTask: URLSessionDataTask?
    private var debounceWorkItem: DispatchWorkItem?
    private var isObservingAppState = false
    private var pollTimer: Timer?
    
    private func startListeningForEvents() {
        // Ensure any existing task is properly stopped first
        if sseTask != nil {
            print("SonosViewModel: [SSE] startListeningForEvents called while sseTask was not nil. Stopping existing task first.")
            stopListeningForEvents()
        }

        print("SonosViewModel: [SSE] Attempting to start listening for events...")
        guard let url = URL(string: "\(baseURL)/events") else {
            print("SonosViewModel: [SSE] Invalid URL for /events endpoint: \(baseURL)/events")
            return
        }

        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = TimeInterval(integerLiteral: 300) // Longer timeout for SSE

        let config = URLSessionConfiguration.default
        // Ensure keep-alive, though default is usually fine
        config.httpAdditionalHeaders = ["Connection": "keep-alive"]

        let session = URLSession(configuration: config, delegate: self, delegateQueue: .main) // delegateQueue: .main is important if you update UI directly from delegate methods, but here we dispatch via Task to @MainActor

        sseTask = session.dataTask(with: request)
        print("SonosViewModel: [SSE] New sseTask created with ID: \(sseTask?.taskIdentifier ?? 0). Resuming...")
        sseTask?.resume()
        // You can check task state immediately after resume, but it might not have transitioned to .running instantly
        // A slight delay might be needed to log a meaningful .state
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard let state = self.sseTask?.state else { print("SonosViewModel: [SSE] sseTask is nil after 0.1s."); return }
            switch state {
                case .running: print("SonosViewModel: [SSE] sseTask state: running")
                case .suspended: print("SonosViewModel: [SSE] sseTask state: suspended")
                case .canceling: print("SonosViewModel: [SSE] sseTask state: canceling")
                case .completed: print("SonosViewModel: [SSE] sseTask state: completed")
                @unknown default: print("SonosViewModel: [SSE] sseTask state: unknown")
            }
        }

        startPollingEvery60Seconds() // This seems okay
        observeAppLifecycle()       // This seems okay
    }

    private func stopListeningForEvents() {
        print("SonosViewModel: [SSE] Attempting to stop listening for events. Current sseTask ID: \(sseTask?.taskIdentifier ?? 0)")
        sseTask?.cancel()
        // According to Apple docs, a session should be invalidated if no longer needed or if its delegate is going away.
        // If you reuse the same URLSession object, don't invalidate. If you create a new one each time in startListeningForEvents,
        // then the old one's session might need invalidation. The current code creates a new session each time.
        // sseTask?.session.invalidateAndCancel() // Consider this if you don't reuse the session.
        sseTask = nil
        pollTimer?.invalidate() // This is correct
        pollTimer = nil         // This is correct
        print("SonosViewModel: [SSE] Event listening stopped.")
    }
    
    private func observeAppLifecycle() {
        guard !isObservingAppState else { return }
        isObservingAppState = true
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stopListeningForEvents()
            }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.startListeningForEvents()
                
                // Add this line to explicitly call refresh:
                print("App entered foreground. Explicitly refreshing SonosViewModel.") // Optional: for logging
                await self?.refresh() // This will ensure each ViewModel fetches fresh data
            }
        }
    }
    
    @MainActor
    private func debouncedRefresh() {
        print("🔁 debouncedRefresh() triggered")
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            Task { @MainActor [weak self] in
                print("🔁 Debounce: immediate refresh")
                await self?.refresh()
                
                try? await Task.sleep(nanoseconds: 2_000_000_000)  // 2s retry
                print("🔁 Debounce: 2s retry")
                await self?.refresh()
                
                // try? await Task.sleep(nanoseconds: 3_000_000_000)  // 3s after that = 5s total
                // print("🔁 Debounce: 5s retry")
                // await self?.refresh()
            }
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }
    
    private func startPollingEvery60Seconds() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
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

    // Called when the data task receives data.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let chunk = String(data: data, encoding: .utf8) else {
            print("SonosViewModel: [SSE] FATAL: Failed to decode data chunk to UTF8 string. Task ID: \(dataTask.taskIdentifier)")
            return
        }

        let receivedTimestamp = Date()
        // Log the entire raw chunk to see exactly what's coming in
        print("SonosViewModel: [SSE] Raw data chunk received at \(receivedTimestamp). Task ID: \(dataTask.taskIdentifier)\n---CHUNK START---\n\(chunk.trimmingCharacters(in: .whitespacesAndNewlines))\n---CHUNK END---")

        for line in chunk.components(separatedBy: "\n") {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            // print("SonosViewModel: [SSE] Processing line: '\(trimmedLine)'") // Enable for extremely verbose line-by-line processing

            // Standard SSE format: lines starting with "data:" contain event data.
            // Lines starting with ":" are comments and should be ignored.
            // Empty lines can be used as separators.
            guard trimmedLine.hasPrefix("data:") else {
                if !trimmedLine.isEmpty && !trimmedLine.starts(with: ":") {
                    print("SonosViewModel: [SSE] Skipping line (no 'data:' prefix or not an SSE comment): '\(trimmedLine)'. Task ID: \(dataTask.taskIdentifier)")
                }
                continue
            }

            // Extract the JSON string part after "data:"
            let jsonString = String(trimmedLine.dropFirst("data:".count)).trimmingCharacters(in: .whitespacesAndNewlines)

            if jsonString.isEmpty {
                print("SonosViewModel: [SSE] Skipping line: 'data:' prefix found but JSON content is empty. Task ID: \(dataTask.taskIdentifier)")
                continue
            }
            
            print("SonosViewModel: [SSE] Attempting to decode JSON: '\(jsonString)'. Task ID: \(dataTask.taskIdentifier)")
            if let eventData = jsonString.data(using: .utf8) {
                do {
                    let event = try JSONDecoder().decode(SSEEvent.self, from: eventData) // Assumes SSEEvent is defined
                    print("SonosViewModel: [SSE] Successfully decoded event: TYPE='\(event.type)'. Task ID: \(dataTask.taskIdentifier)")
                    
                    // Handle specific event types
                    if event.type == "topology-change" || event.type == "transport-state" {
                        Task { @MainActor [weak self] in
                            print("SonosViewModel: [SSE] Relevant event '\(event.type)' received. Triggering debounced refresh. Task ID: \(dataTask.taskIdentifier)")
                            self?.debouncedRefresh()
                        }
                    }
                } catch {
                    print("SonosViewModel: [SSE] JSON DECODING ERROR: \(error.localizedDescription) for string: '\(jsonString)'. Task ID: \(dataTask.taskIdentifier)")
                }
            } else {
                print("SonosViewModel: [SSE] Could not convert JSON string to Data: '\(jsonString)'. Task ID: \(dataTask.taskIdentifier)")
            }
        }
    }

    // Called when a task finishes transferring data, either successfully or with an error.
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let completionTimestamp = Date()
        if let error = error {
            // This is a critical log. If you see this, the SSE stream has stopped due to an error.
            print("SonosViewModel: [SSE] Task \(task.taskIdentifier) didCompleteWithError at \(completionTimestamp): \(error.localizedDescription)")
            print("SonosViewModel: [SSE] Underlying error details: \(error as NSError)")

            // Optional: Implement a retry mechanism here if desired.
            // Task { @MainActor [weak self] in
            //     print("SonosViewModel: [SSE] Will try to restart SSE in 5 seconds due to error on task \(task.taskIdentifier).")
            //     try? await Task.sleep(nanoseconds: 5_000_000_000) // 5-second delay
            //     self?.stopListeningForEvents() // Ensure clean state
            //     self?.startListeningForEvents()
            // }
        } else {
            // This means the task completed without an error object.
            // For an SSE stream, this might mean the connection was closed cleanly by the server
            // or by the client (e.g., calling sseTask.cancel()).
            print("SonosViewModel: [SSE] Task \(task.taskIdentifier) didCompleteWithError: nil (completed without an explicit error object, connection closed) at \(completionTimestamp).")
        }
        // Since the task is complete (either with or without error),
        // you might want to ensure that this specific SSE task is no longer considered active.
        // If `stopListeningForEvents()` isn't called, and `startListeningForEvents()` creates a new task, this might be okay.
        // However, if the error is transient, a robust retry mechanism in `startListeningForEvents` or here would be good.
        // The current `startListeningForEvents` called on foregrounding acts as a form of retry.
    }

    // Called when the session becomes invalid.
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        let invalidationTimestamp = Date()
        if let error = error {
            print("SonosViewModel: [SSE] Session became invalid with error at \(invalidationTimestamp): \(error.localizedDescription)")
        } else {
            print("SonosViewModel: [SSE] Session became invalid without an explicit error at \(invalidationTimestamp).")
        }
        // When a session becomes invalid, all tasks within it are cancelled.
        // You might want to ensure cleanup or attempt to re-establish a new session and tasks.
        // Task { @MainActor [weak self] in
        //     print("SonosViewModel: [SSE] Session invalidated. Ensuring event listening is stopped and attempting restart.")
        //     self?.stopListeningForEvents()
        //     // Consider if an immediate restart is appropriate or should be delayed/conditional
        //     // self?.startListeningForEvents()
        // }
    }
}

// MARK: - Models

struct Station: Hashable, Codable {
    let name: String
    let url: String
    let type: String  // "stream" or "favorite"

    var isFavorite: Bool {
        type.lowercased() == "favorite"
    }
    var isLineIn: Bool {
        type.lowercased() == "linein"
    }
    func matches(track: Track) -> Bool {
        let normalizedName = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedURL = url.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let stationName = track.stationName?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
           track.uri?.hasPrefix("x-sonosapi-stream:") == true {
            if stationName == normalizedName {
                return true
            }
            if stationName.contains(normalizedName) || normalizedName.contains(stationName) {
                return true
            }
        }
        let candidateURLs = [
            track.uri,
            track.trackUri
        ].compactMap { $0?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        if candidateURLs.contains(where: { $0.contains(normalizedURL) }) {
            return true
        }
        if isLineIn { // self.isLineIn is true. self.url is "x-rincon-stream:CONFIGURED_BARE_UUID"
                    for candidateTrackURI in candidateURLs { // candidateTrackURI is from track.uri, e.g., "x-rincon-stream:PLAYING_BARE_UUID"
                        if candidateTrackURI.hasPrefix("x-rincon-stream:") {
                            // Extract the bare UUID from the currently playing track's URI
                            let playingTrackBareUUID = candidateTrackURI
                                .replacingOccurrences(of: "x-rincon-stream:", with: "")
                                .components(separatedBy: ":")
                                .first ?? ""

                            // Extract the bare UUID from this Station instance's URL
                            let stationBareUUID = self.url // self.url is "x-rincon-stream:CONFIGURED_BARE_UUID" for LineIn stations
                                .replacingOccurrences(of: "x-rincon-stream:", with: "")
                                .components(separatedBy: ":")
                                .first ?? ""

                            // If both bare UUIDs match and are not empty, it's a match
                            if !playingTrackBareUUID.isEmpty && playingTrackBareUUID == stationBareUUID {
                                return true
                            }
                        }
                    }
                }
        return false
    }
}

struct SonosGroup: Identifiable, Hashable {
    var id: String { coordinator }
    let coordinator: String
    let joiners: [String]
}
struct Zone: Codable { let coordinator: Member; let members: [Member] }
struct Member: Codable {
    let roomName: String
    let uuid: String
    let state: PlayerState
    let host: String?
}
struct Track: Codable {
    let title: String?
    let artist: String?
    let stationName: String?
    let uri: String?
    let trackUri: String?
    let type: String?
    let albumArtUri: String?
    let absoluteAlbumArtUri: String?
}
struct PlayerState: Codable {
    let volume: Int
    let mute: Bool
    let currentTrack: Track?
    let playbackState: String
}

// MARK: - Redirect Handler

class RedirectHandler: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        if let url = request.url?.absoluteString.replacingOccurrences(of: "*/", with: "") {
            var modifiedRequest = request
            modifiedRequest.url = URL(string: url)
            print("🔁 Redirecting to (sanitized): \(modifiedRequest.url?.absoluteString ?? "")")
            completionHandler(modifiedRequest)
        } else {
            completionHandler(request)
        }
    }
}

// MARK: - Subviews (your originals, unchanged, below...)

struct GroupedRoomsListView: View {
    @ObservedObject var viewModel: SonosViewModel
    var filteredStations: [Station]
    let config: NetworkConfig
    @State private var showingJoinDialog = false
    @State private var joinSourceRoom = ""
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(viewModel.groups) { group in
                    SonosGroupView(
                        group: group,
                        viewModel: viewModel,
                        config:config,
                        onInitiateJoinForSpeaker: { specificSpeakerName in // This closure receives the actual speaker
                            self.joinSourceRoom = specificSpeakerName // Set the specific speaker as the source
                            self.showingJoinDialog = true
                        }
                    )
                }
            }
            .padding(.horizontal, 0)
            .padding(.vertical, 8)
            .confirmationDialog(
                "Join “\(joinSourceRoom)” to…",
                isPresented: $showingJoinDialog,
                titleVisibility: .visible
            ) {
                ForEach(viewModel.groups.map(\.coordinator)
                    .filter { $0 != joinSourceRoom }, id: \.self) { target in
                    Button(target) {
                        viewModel.joinGroup(room: joinSourceRoom, target: target)
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

struct SonosGroupView: View {
    let group: SonosGroup
    let config: NetworkConfig
    @ObservedObject var viewModel: SonosViewModel
    let onInitiateJoinForSpeaker: (String) -> Void // Closure that takes the specific speaker's name
    @State private var isExpanded: Bool

    init(group: SonosGroup, viewModel: SonosViewModel, config: NetworkConfig, onInitiateJoinForSpeaker: @escaping (String) -> Void) {
        self.group = group
        self.config = config
        self._viewModel = ObservedObject(wrappedValue: viewModel)
        self.onInitiateJoinForSpeaker = onInitiateJoinForSpeaker
        self._isExpanded = State(initialValue: viewModel.isAccordionExpanded(for: group.coordinator))
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // RoomRowView for the COORDINATOR
            RoomRowView(
                viewModel: viewModel,
                config: config,
                roomName: group.coordinator,
                volume: viewModel.volume[group.coordinator] ?? 0,
                isMuted: viewModel.isMuted[group.coordinator] ?? false,
                isCoordinator: true,
                isPlaying: viewModel.isPlaying(group: group),
                stationName: viewModel.stationDisplay(for: group.coordinator),
                isVolumeDisabled: viewModel.volumeDisabled[group.coordinator] ?? false,
                stations: viewModel.filteredStations(for: config),
                onAdjust: { d in viewModel.adjustVolume(room: group.coordinator, delta: d) },
                onToggleMute: { viewModel.toggleMute(room: group.coordinator) },
                onTogglePlay: { viewModel.togglePlayback(group: group) },
                // ---- CORRECTED: onStartJoinProcessForRow is now listed only ONCE ----
                onStartJoinProcessForRow: {
                    onInitiateJoinForSpeaker(group.coordinator) // Pass coordinator's name
                },
                onLeaveRequest: group.joiners.isEmpty
                    ? nil
                    : { viewModel.leaveGroup(room: group.coordinator) },
                isExpanded: $isExpanded
            )
            
            // RoomRowViews for the MEMBERS
            ForEach(group.joiners, id: \.self) { room in // 'room' is the member's name
                RoomRowView(
                    viewModel: viewModel,
                    config: config,
                    roomName: room,
                    volume: viewModel.volume[room] ?? 0,
                    isMuted: viewModel.isMuted[room] ?? false,
                    isCoordinator: false,
                    isPlaying: false,
                    stationName: nil,
                    isVolumeDisabled: viewModel.volumeDisabled[room] ?? false,
                    stations: viewModel.filteredStations(for: config),
                    onAdjust: { d in viewModel.adjustVolume(room: room, delta: d) },
                    onToggleMute: { viewModel.toggleMute(room: room) },
                    onTogglePlay: nil,
                    // ---- CORRECTED: onStartJoinProcessForRow is now listed only ONCE ----
                    onStartJoinProcessForRow: {
                        onInitiateJoinForSpeaker(room) // Pass this member's name
                    },
                    onLeaveRequest: { viewModel.leaveGroup(room: room) },
                    isExpanded: $isExpanded
                )
            }
        }
        .padding()
        .background(.thinMaterial)
        .cornerRadius(8)
    }
}

struct StationPresetAccordion: View {
    let stations: [Station]
    let selectedStation: Station?
    let onSelect: (Station) -> Void
    @Binding var isExpanded: Bool
    let stationDisplay: String
    let onExpansionChanged: ((Bool) -> Void)?

    @State private var currentPage: Int
    private let pages: [[[Station]]]

    init(
        stations: [Station],
        selectedStation: Station?,
        onSelect: @escaping (Station) -> Void,
        isExpanded: Binding<Bool>,
        onExpansionChanged: ((Bool) -> Void)? = nil,
        stationDisplay: String
    ) {
        self.stations = stations
        self.selectedStation = selectedStation
        self.onSelect = onSelect
        self._isExpanded = isExpanded
        self.stationDisplay = stationDisplay
        self.onExpansionChanged = onExpansionChanged  // ✅ this was missing

        self.pages = stride(from: 0, to: stations.count, by: 6).map { start in
            let slice = Array(stations[start..<min(start + 6, stations.count)])
            return stride(from: 0, to: slice.count, by: 3).map { rowStart in
                Array(slice[rowStart..<min(rowStart + 3, slice.count)])
            }
        }

        if let selected = selectedStation {
            if let index = pages.firstIndex(where: { $0.flatMap { $0 }.contains(selected) }) {
                _currentPage = State(initialValue: index)
            } else {
                _currentPage = State(initialValue: 0)
            }
        } else {
            _currentPage = State(initialValue: 0)
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Station line with toggle chevron
            HStack(spacing: 8) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .foregroundColor(.secondary)

                Text(stationDisplay)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation {
                    isExpanded.toggle()
                    onExpansionChanged?(isExpanded)
                }
            }
            if isExpanded {
                VStack(spacing: 8) {
                    TabView(selection: $currentPage) {
                        ForEach(pages.indices, id: \.self) { index in
                            let page = pages[index]
                            VStack(spacing: 8) {
                                ForEach(page, id: \.self) { row in
                                    HStack(spacing: 8) {
                                        ForEach(row, id: \.self) { station in
                                            Button(action: {
                                                print("Selected station: \(station.name) | type: \(station.type)")
                                                onSelect(station)
                                            }) {
                                                Text(station.name)
                                                    .font(.caption)
                                                    .multilineTextAlignment(.center)
                                                    .lineLimit(2)
                                                    .frame(height: 48)
                                                    .frame(maxWidth: 0.33 * UIScreen.main.bounds.width)
                                                    .background(
                                                        Capsule().fill(
                                                            station == selectedStation
                                                            ? Color.blue.opacity(0.25)
                                                            : Color.gray.opacity(0.1)
                                                        )
                                                    )
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                            }
                            .tag(index)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .frame(height: 112)

                    HStack(spacing: 6) {
                        ForEach(pages.indices, id: \.self) { i in
                            Circle()
                                .fill(i == currentPage ? Color.primary : Color.secondary.opacity(0.3))
                                .frame(width: 6, height: 6)
                        }
                    }
                }
                .padding(8)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
            }
        }
    }
    
    // Break into pages of 2 rows × 3 buttons = 6 per page
    func pagedStations(_ list: [Station]) -> [[[Station]]] {
        stride(from: 0, to: list.count, by: 6).map { start in
            let slice = Array(list[start..<min(start + 6, list.count)])
            return stride(from: 0, to: slice.count, by: 3).map { rowStart in
                Array(slice[rowStart..<min(rowStart + 3, slice.count)])
            }
        }
    }
}

struct RoomRowView: View {
    @ObservedObject var viewModel: SonosViewModel
    let config: NetworkConfig
    let roomName: String
    let volume: Int
    let isMuted: Bool
    let isCoordinator: Bool
    let isPlaying: Bool
    let stationName: String?
    let isVolumeDisabled: Bool
    let stations: [Station] // ✅ NEW

    let onAdjust: (Int) -> Void
    let onToggleMute: () -> Void
    let onTogglePlay: (() -> Void)?
    let onStartJoinProcessForRow: (() -> Void)?
    let onLeaveRequest: (() -> Void)?

    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(roomName)
                    .font(isCoordinator ? .headline : .body)
                Spacer()
                controlCluster
            }

            if isCoordinator {
                StationPresetAccordion(
                    stations: stations, // ✅ Use pre-filtered stations
                    selectedStation: viewModel.selectedStationByRoom[roomName],
                    onSelect: { s in
                        print(">>> selectStation for room: \(roomName), station: \(s.name)")
                        viewModel.selectStation(s, for: roomName)
                        print(">>> playStation for room: \(roomName), station: \(s.name)")
                        viewModel.playStation(s, in: roomName)
                    },
                    isExpanded: $isExpanded,
                    onExpansionChanged: { expanded in
                        viewModel.setAccordionState(for: roomName, expanded: expanded)
                    },
                    stationDisplay: stationName ?? "Nothing queued"
                )
            }
        }
    }

    @ViewBuilder
    private var controlCluster: some View {
        HStack(spacing: 16) {
            if let play = onTogglePlay {
                Button(action: play) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 30, height: 30)
                        .styledControlButton(disabled: false)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 0) {
                Button { if !isVolumeDisabled { onAdjust(-5) } } label: {
                    Image(systemName: "speaker.minus.fill")
                        .font(.system(size: 14))
                        .frame(width: 30, height: 30)
                        .styledControlButton(disabled: isVolumeDisabled)
                }
                .buttonStyle(.plain)

                Text(isVolumeDisabled ? "--" : "\(volume)")
                    .monospacedDigit()
                    .frame(width: 40)

                Button { if !isVolumeDisabled { onAdjust(5) } } label: {
                    Image(systemName: "speaker.plus.fill")
                        .font(.system(size: 14))
                        .frame(width: 30, height: 30)
                        .styledControlButton(disabled: isVolumeDisabled)
                }
                .buttonStyle(.plain)
            }

            Button(action: onToggleMute) {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.slash")
                    .font(.system(size: 14))
                    .frame(width: 30, height: 30)
                    .styledControlButton(disabled: false)
            }
            .buttonStyle(.plain)

            GroupControlButton(
                isJoinable: onStartJoinProcessForRow != nil,
                isLeavable: onLeaveRequest != nil,
                onJoin: { onStartJoinProcessForRow?() },
                onLeave: { onLeaveRequest?() }
            )
        }
    }
}

struct VolumeStepper: View {
    let room: String
    let volume: Int
    let isMuted: Bool
    let onAdjust: (Int) -> Void
    let onToggleMute: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button { onAdjust(-5) } label: { Image(systemName: "minus.square") }
            Text("\(volume)%").frame(width: 40)
            Button { onAdjust(5) } label: { Image(systemName: "plus.square") }
            Button { onToggleMute() } label: {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
        }
        .font(.title2)
    }
}

struct GroupControlButton: View {
    let isJoinable: Bool
    let isLeavable: Bool
    let onJoin: () -> Void
    let onLeave: () -> Void

    var body: some View {
        Menu {
            if isJoinable {
                Button("Join Group", action: onJoin)
            }
            if isLeavable {
                Button("Leave Group", action: onLeave)
            }
        } label: {
            Image(systemName: "airplayaudio")
                .frame(width: 30, height: 30)
                .styledControlButton(disabled: false)
        }
        .buttonStyle(.plain)
    }
}

struct RoomControlRow: View {
    let roomName: String
    let volume: Int
    let isMuted: Bool
    let onAdjust: (Int) -> Void
    let onToggleMute: () -> Void

    var body: some View {
        HStack {
            Text(roomName)
            Spacer()
            VolumeStepper(room: roomName, volume: volume,
                          isMuted: isMuted, onAdjust: onAdjust,
                          onToggleMute: onToggleMute)
        }
    }
}

// MARK: - Button Style Helper

// After: Using adaptive system colors
extension View {
    func styledControlButton(disabled: Bool) -> some View {
        self
            // Use adaptive colors that produce an inverted effect.
            // Icon color: white in light mode, black in dark mode.
            // Background color: black in light mode, white in dark mode.
            .foregroundColor(disabled ? .gray : Color(uiColor: .systemBackground))
            .background(Circle().fill(disabled ? Color(uiColor: .systemGray3) : Color(uiColor: .label)))
    }
}

#Preview {
    BetterSonosView()
}
