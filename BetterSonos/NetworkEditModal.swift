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
//  NetworkEditModal.swift
//

import SwiftUI
import Foundation
import os.log

// MARK: - Edit/Add Network Modal

struct NetworkEditModal: View {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "NetworkEditModal")
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
            return scheme
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
                        if !baseAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
            // Also update the edited config's lastKnownServerFavorites
            // This ensures that if new favorites were added on the server, we save them.
            let serverFavoriteStations = serverFavoriteNames.map { Station(name: $0, url: $0, type: .favorite) }
            editedConfig.lastKnownServerFavorites = serverFavoriteStations.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            await MainActor.run {
                self.fetchedFavorites = serverFavoriteNames.sorted() // Update the list used to RENDER the toggles.
                self.isLoadingFavorites = false
                self.favoritesError = false

                Task { await self.fetchLineInSources() }
            }
        } catch {
            await MainActor.run {
                self.favoritesError = true
                self.isLoadingFavorites = false
                self.fetchedFavorites = [] // Clear fetched items on error
                 Self.logger.error("Error fetching favorites: \(error)")
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
                Self.logger.error("Error fetching potential Line-In sources: \(error)")
            }
        }
    }
    
}
