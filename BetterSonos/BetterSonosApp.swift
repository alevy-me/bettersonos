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
        .sheet(isPresented: $showSettings) {
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
                    // Keyed by identity and server address only. The view model observes its own config,
                    // so edits and favorites merges no longer tear down the row and its state.
                    .id("\(config.id.uuidString)|\(config.baseURL)")
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
    @State private var isShowingErrorAlert = false
    @State private var isExpanded: Bool = true

    // The init now creates the ViewModel using the passed-in stores
    init(config: NetworkConfig, networkStore: NetworkConfigStore, settingsStore: AppSettingsStore) {
        self.config = config
        self._viewModel = StateObject(wrappedValue: SonosViewModel(
            configID: config.id,
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
                    if case .error = viewModel.status {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .onTapGesture {
                                isShowingErrorAlert = true
                            }
                    }
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .alert("Connection Error", isPresented: $isShowingErrorAlert) {
                    Button("OK", role: .cancel) { }
                } message: {
                    if case .error(let message) = viewModel.status {
                        Text(message)
                    }
                }
            }
            if isExpanded {
                GroupedRoomsListView(
                    viewModel: viewModel,
                    filteredStations: viewModel.filteredStations(for: config),
                    config: config
                )
            }
        }
    }
}

#Preview {
    BetterSonosView()
        .environmentObject(NetworkConfigStore())
        .environmentObject(AppSettingsStore.shared)
}
