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
//  BetterSonosWatchApp.swift
//

import SwiftUI
import Combine
import BetterSonosCore

@main
struct BetterSonosWatchApp: App {
    @StateObject private var model = WatchModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
        }
        .onChange(of: scenePhase) { _, phase in
            model.setActive(phase == .active)
        }
    }
}

/// Owns the synced configs and one controller per network, shared by every screen.
@MainActor
final class WatchModel: ObservableObject {
    /// Reads the iOS app's configs from iCloud and never writes back.
    let store = NetworkConfigStore(cloudReadOnly: true)
    /// Manual stations and the custom CSV URL, for presets. Read-only, like the configs.
    let settings = AppSettingsStore(cloudReadOnly: true)

    private var controllers: [UUID: WatchNetworkController] = [:]
    private var isActive = true
    private var cancellables = Set<AnyCancellable>()

    init() {
        store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Push synced config changes (such as Disable Volume Control) into live controllers.
        store.$configs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] configs in
                guard let self else { return }
                for config in configs {
                    self.controllers[config.id]?.update(config: config)
                }
            }
            .store(in: &cancellables)
    }

    /// Every enabled network. Local (direct) networks use the speaker addresses the phone found,
    /// synced through iCloud; the watch doesn't browse for speakers itself.
    var enabledConfigs: [NetworkConfig] {
        store.configs.filter(\.enabled)
    }

    func config(id: UUID) -> NetworkConfig? {
        store.configs.first { $0.id == id }
    }

    /// Returns the controller for a network, replacing it if the server address changed.
    func controller(for config: NetworkConfig) -> WatchNetworkController {
        let baseURL = URLInput.normalizedBaseURL(config.baseURL)
        if let existing = controllers[config.id], existing.baseURL == baseURL {
            return existing
        }
        controllers[config.id]?.stop()
        let controller = WatchNetworkController(config: config)
        controllers[config.id] = controller
        if isActive { controller.start() }
        // Presets are needed to restart a stopped stream, so make sure a list exists before play is tapped.
        if controller.presets.isEmpty {
            let settings = self.settings
            Task { [weak controller] in
                // Let the first refresh land, so line-in names resolve.
                try? await Task.sleep(for: .seconds(1))
                await controller?.loadPresets(settings: settings)
            }
        }
        return controller
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        for controller in controllers.values {
            if active { controller.start() } else { controller.stop() }
        }
    }
}
