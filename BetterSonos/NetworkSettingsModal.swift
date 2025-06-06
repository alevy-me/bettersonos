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
//  NetworkSettingsModal.swift
//

import SwiftUI

struct NetworkSettingsModal: View {
    @EnvironmentObject var networkStore: NetworkConfigStore
    @EnvironmentObject var settings: AppSettingsStore
    @Binding var isPresented: Bool

    @State private var selectedConfig: NetworkConfig? = nil
    @State private var newStationName: String = ""
    @State private var newStationScheme: String = "https://"
    @State private var newStationAddress: String = "" // Renamed from newStationURL
    @State private var csvScheme: String = "https://"
    @State private var csvAddress: String = ""

    var body: some View {
        NavigationView {
            Form {
                networkConfigsSection
                csvSection
                manualStationsSection
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        selectedConfig = NetworkConfig(
                            id: UUID(),
                            displayName: "",
                            baseURL: "",
                            enabled: true,
                            showDefaultPresetsForThisNetwork: true, // Default for a brand new config
                            explicitlyDisabledFavoriteURLs: [],
                            lastKnownServerFavorites: nil
                         )
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $selectedConfig) { config in
                NetworkEditModal(
                    initialConfig: config,
                    isEditing: networkStore.configs.contains(where: { $0.id == config.id }),
                    onSave: { newConfig in
                        if let i = networkStore.configs.firstIndex(where: { $0.id == newConfig.id }) {
                            networkStore.configs[i] = newConfig
                        } else {
                            networkStore.add(newConfig)
                        }
                        networkStore.save()
                        selectedConfig = nil
                    },
                    onCancel: {
                        selectedConfig = nil
                    },
                    onDelete: {
                        if let i = networkStore.configs.firstIndex(where: { $0.id == config.id }) {
                            networkStore.remove(networkStore.configs[i])
                        }
                        selectedConfig = nil
                    }
                )
            }
        
    }

    private var csvSection: some View {
        Section(header: Text("Remote Station CSV")) {
            HStack(spacing: 0) {
                Picker("Scheme", selection: $csvScheme) {
                    Text("https://").tag("https://")
                    Text("http://").tag("http://")
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 100, alignment: .leading) // Adjust width as needed
                // .labelsHidden() // Use if the "Scheme" label is not desired visually

                TextField("example.com/stations.csv", text: $csvAddress)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
            }
            .onAppear {
                let (scheme, address) = splitURL(settings.remoteCSVURL)
                self.csvScheme = scheme
                self.csvAddress = address
            }
            .onChange(of: csvScheme) { _, newScheme in
                settings.remoteCSVURL = joinURL(scheme: newScheme, address: csvAddress)
            }
            .onChange(of: csvAddress) { _, newAddress in
                settings.remoteCSVURL = joinURL(scheme: csvScheme, address: newAddress)
            }
            // This onChange handles external changes to remoteCSVURL or clearing it
            .onChange(of: settings.remoteCSVURL) { _, newFullURL in
                let (scheme, address) = splitURL(newFullURL)
                if self.csvScheme != scheme || self.csvAddress != address {
                    self.csvScheme = scheme
                    self.csvAddress = address
                }
            }

            if let url = settings.remoteCSVURL, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("Clear Custom CSV URL") { // Clarified button text
                    settings.remoteCSVURL = nil // This will trigger the onChange above to clear local state
                }
            }

            if settings.csvLoadError {
                Label("Failed to load CSV", systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
            }
        }
    }

    private var manualStationsSection: some View {
        Section(header: Text("Manually Added Stations")) {
            ForEach(settings.manualStations, id: \.self) { station in
                HStack {
                    Text(station.name)
                    Spacer()
                    Text(station.url)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .onDelete { indexSet in
                print("Before:", settings.manualStations.map(\.name))
                settings.manualStations.remove(atOffsets: indexSet)
                settings.manualStations = settings.manualStations
                print("After:", settings.manualStations.map(\.name))            }

            VStack {
                TextField("Station Name", text: $newStationName)
                HStack(spacing: 0) {
                    Picker("Scheme", selection: $newStationScheme) {
                        Text("https://").tag("https://")
                        Text("http://").tag("http://")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 100, alignment: .leading)
                    
                    TextField("example.com/stream", text: $newStationAddress)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                }
                
                Button("Add Station") {
                    let trimmedName = newStationName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let trimmedAddress = newStationAddress.trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    guard !trimmedName.isEmpty, !trimmedAddress.isEmpty else { return }
                    // The scheme ensures it starts with http or https
                    
                    if let fullStationURL = joinURL(scheme: newStationScheme, address: trimmedAddress) {
                        let newStation = Station(name: trimmedName, url: fullStationURL, type: "stream")
                        if !settings.manualStations.contains(where: { $0.url == newStation.url }) {
                            settings.manualStations.append(newStation)
                        }
                        
                        newStationName = ""
                        newStationAddress = "" // Clear the address part
                        newStationScheme = "https://" // Reset scheme to default
                    }
                }
            }
        }
    }



    private var networkConfigsSection: some View {
        Section(header: Text("Sonos Networks")) {
            
            ForEach(networkStore.configs) { config in
                HStack {
                    Toggle(isOn: Binding(
                        get: { config.enabled },
                        set: { newValue in
                            if let i = networkStore.configs.firstIndex(where: { $0.id == config.id }) {
                                networkStore.configs[i].enabled = newValue
                                networkStore.save()
                            }
                        }
                    )) {
                        VStack(alignment: .leading) {
                            Text(config.displayName)
                                .font(.headline)
                            Text(config.baseURL)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    Button {
                        selectedConfig = config
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(BorderlessButtonStyle())
                    
                }
            }
            Button {
                    selectedConfig = NetworkConfig(
                        id: UUID(),
                        displayName: "",
                        baseURL: "",
                        enabled: true,
                        showDefaultPresetsForThisNetwork: true, // Default for a brand new config
                        explicitlyDisabledFavoriteURLs: [],
                        lastKnownServerFavorites: nil
                     )
                } label: {
                    Text("Add Network") // Changed from Image(systemName: "plus")
                }
        }
    }
    
    // Helper functions (can be placed in an extension or locally)
    private func splitURL(_ fullURL: String?) -> (scheme: String, address: String) {
        guard let urlString = fullURL, !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ("https://", "") // Default scheme if URL is nil or empty
        }
        if urlString.lowercased().hasPrefix("http://") {
            return ("http://", String(urlString.dropFirst("http://".count)))
        } else if urlString.lowercased().hasPrefix("https://") {
            return ("https://", String(urlString.dropFirst("https://".count)))
        } else {
            // If no recognizable scheme, assume it's the address part and default to https
            return ("https://", urlString)
        }
    }

    private func joinURL(scheme: String, address: String) -> String? {
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedAddress.isEmpty {
            return nil // If the address part is empty, consider the full URL nil (or empty)
        }
        return scheme + trimmedAddress
    }
    
}
