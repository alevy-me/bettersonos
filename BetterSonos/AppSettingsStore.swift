//
//  AppSettingsStore.swift
//  BetterSonos
//
//  Created by Andrew Levy on 5/30/25.
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

