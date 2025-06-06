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
//  AppSettingsStore.swift
//


import Foundation
import Combine

@MainActor
final class AppSettingsStore: ObservableObject {
    static let shared = AppSettingsStore()

    private let iCloud = NSUbiquitousKeyValueStore.default
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Published Settings

    @Published var manualStations: [Station] = []
    @Published var remoteCSVURL: String? = nil

    // Transient state (not persisted)
    @Published var csvLoadError: Bool = false

    // MARK: - Keys

    private enum Keys {
        static let manualStations = "manualStations"
        static let remoteCSVURL = "remoteCSVURL"
    }

    private init() {
        syncFromStore()
        observeCloudUpdates()
        observeLocalChanges()
        iCloud.synchronize()
    }

    // MARK: - iCloud Sync In

    private func syncFromStore() {
        if let data = iCloud.data(forKey: Keys.manualStations),
           let decoded = try? JSONDecoder().decode([Station].self, from: data) {
            self.manualStations = decoded
        }

        self.remoteCSVURL = iCloud.string(forKey: Keys.remoteCSVURL)
    }

    private func observeCloudUpdates() {
            NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                                                   object: iCloud,
                                                   queue: .main) { [weak self] _ in
                guard let strongSelf = self else { return }
                
                DispatchQueue.main.async {
                    strongSelf.syncFromStore()
                }
            }
        }
    
    // MARK: - Local Change Observers

    private func observeLocalChanges() {
        $manualStations
            .sink { [weak self] stations in
                guard let self else { return }
                if let encoded = try? JSONEncoder().encode(stations) {
                    iCloud.set(encoded, forKey: Keys.manualStations)
                }
            }
            .store(in: &cancellables)

        $remoteCSVURL
            .sink { [weak self] url in
                self?.iCloud.set(url, forKey: Keys.remoteCSVURL)
            }
            .store(in: &cancellables)

    }
}

