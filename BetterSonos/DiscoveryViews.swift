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
//  DiscoveryViews.swift
//

import SwiftUI
import BetterSonosCore

/// Shown when no network is configured. Discovery runs first; adding a server is the fallback.
struct NoNetworksView: View {
    @EnvironmentObject private var discovery: DiscoveryCoordinator
    let onAddNetwork: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            if discovery.isSearching || discovery.isFirstSearchPending {
                ProgressView()
                Text("Looking for Sonos speakers…")
                    .font(.headline)
            } else if discovery.permissionDenied {
                Image(systemName: "wifi.exclamationmark")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("BonTon needs local network access")
                    .font(.headline)
                Text("Allow Local Network for BonTon in Settings so it can find your Sonos speakers.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(.borderedProminent)
                Button("Add a Server Instead", action: onAddNetwork)
            } else {
                Image(systemName: "hifispeaker.2")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("No Sonos speakers found")
                    .font(.headline)
                Text("Join the same Wi-Fi as your Sonos system and search again, or add a node-sonos-http-api server.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Search Again") { discovery.searchAgain() }
                    .buttonStyle(.borderedProminent)
                Button("Add Network", action: onAddNetwork)
            }
            Spacer()
        }
        .padding(.horizontal)
    }
}

/// Offers a name for a newly found household before creating its network.
struct NameHouseholdSheet: View {
    @EnvironmentObject private var discovery: DiscoveryCoordinator
    let household: DiscoveredHousehold
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .onSubmit(add)
                } header: {
                    Text("Name")
                } footer: {
                    Text("BonTon controls these speakers directly while you're on this Wi-Fi.")
                }
                Section("Found \(household.roomNames.count) \(household.roomNames.count == 1 ? "room" : "rooms")") {
                    ForEach(household.roomNames, id: \.self) { room in
                        Label(room, systemImage: "hifispeaker")
                    }
                }
            }
            .navigationTitle("Sonos System Found")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not Now") { discovery.dismiss(household) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: add)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if name.isEmpty { name = discovery.suggestedName() }
            }
        }
        .interactiveDismissDisabled()
    }

    private func add() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        discovery.confirm(household, name: name)
    }
}

/// A local network whose speakers aren't reachable from here (usually: not on its Wi-Fi).
struct UnavailableNetworkRow: View {
    let config: NetworkConfig
    /// True during the first check after launch, so the row doesn't flash as unavailable.
    let isChecking: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(config.displayName)
                .font(.title2)
                .bold()
            HStack(spacing: 8) {
                if isChecking {
                    ProgressView().controlSize(.small)
                    Text("Looking for speakers…")
                } else {
                    Image(systemName: "wifi.slash")
                    Text("Not available on this network")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

/// Settings for a local network: there's no server address to edit.
struct LocalNetworkEditSheet: View {
    @EnvironmentObject private var networkStore: NetworkConfigStore
    @Environment(\.dismiss) private var dismiss
    let config: NetworkConfig
    @State private var name: String
    @State private var showDefaultPresets: Bool
    @State private var confirmDelete = false

    init(config: NetworkConfig) {
        self.config = config
        _name = State(initialValue: config.displayName)
        _showDefaultPresets = State(initialValue: config.showDefaultPresetsForThisNetwork)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Name", text: $name)
                }
                Section {
                    Toggle("Include Default Presets", isOn: $showDefaultPresets)
                } footer: {
                    Text("Controlled directly on this Wi-Fi. \(config.speakerAddresses.count) speakers known.")
                }
                Section {
                    Button("Remove Network", role: .destructive) { confirmDelete = true }
                } footer: {
                    Text("BonTon will offer to add it again the next time it finds these speakers.")
                }
            }
            .navigationTitle("Edit Network")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var updated = config
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { updated.displayName = trimmed }
                        updated.showDefaultPresetsForThisNetwork = showDefaultPresets
                        networkStore.update(updated)
                        dismiss()
                    }
                }
            }
            .alert("Remove \(config.displayName)?", isPresented: $confirmDelete) {
                Button("Remove", role: .destructive) {
                    networkStore.remove(config)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}
