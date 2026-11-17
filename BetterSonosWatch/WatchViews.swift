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
//  WatchViews.swift
//

import SwiftUI
import BetterSonosCore

enum Route: Hashable {
    case network(UUID)
    case room(network: UUID, name: String)
}

// MARK: - Root

struct RootView: View {
    @EnvironmentObject private var model: WatchModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var path: [Route] = []
    @State private var didRestore = false
    @AppStorage("lastNetworkID") private var lastNetworkID = ""
    @AppStorage("lastRoomName") private var lastRoomName = ""

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                let configs = model.enabledConfigs
                if configs.isEmpty {
                    ContentUnavailableView(
                        "No Networks",
                        systemImage: "hifispeaker.2",
                        description: Text("Add a network in Better Sonos on your iPhone. It syncs here through iCloud.")
                    )
                } else if configs.count == 1 {
                    RoomListView(config: configs[0])
                } else {
                    List(configs) { config in
                        NavigationLink(config.displayName, value: Route.network(config.id))
                    }
                    .navigationTitle("Networks")
                }
            }
            .navigationDestination(for: Route.self) { route in
                destination(for: route)
            }
        }
        .onAppear(perform: restoreLastRoom)
        // Configs can arrive from iCloud after launch.
        .onChange(of: model.enabledConfigs.map(\.id)) { _, _ in restoreLastRoom() }
        // Coming back from the background counts as opening the app. A wrist-down only makes the
        // scene inactive, so a quick glance never moves you off the screen you were using.
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if oldPhase == .background && newPhase == .active {
                Task { await focusSolePlayingRoom() }
            }
        }
    }

    private func routes(to room: String, in network: NetworkConfig) -> [Route] {
        let route = Route.room(network: network.id, name: room)
        return model.enabledConfigs.count == 1 ? [route] : [.network(network.id), route]
    }

    /// When exactly one speaker or group is playing across all enabled networks, shows it.
    /// Otherwise leaves navigation alone.
    private func focusSolePlayingRoom() async {
        let networks = model.enabledConfigs
        let controllers = networks.map { model.controller(for: $0) }
        guard let sole = await WatchNetworkController.solePlayingRoom(
            across: controllers,
            lastNetworkID: UUID(uuidString: lastNetworkID),
            lastRoom: lastRoomName
        ), let network = networks.first(where: { $0.id == sole.networkID }) else { return }

        let target = routes(to: sole.room, in: network)
        if path != target { path = target }
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .network(let id):
            if let config = model.config(id: id) {
                RoomListView(config: config)
            } else {
                Text("This network is no longer configured.")
            }
        case .room(let id, let name):
            if let config = model.config(id: id) {
                RoomView(controller: model.controller(for: config), networkID: id, roomName: name)
            } else {
                Text("This network is no longer configured.")
            }
        }
    }

    /// At launch, reopens the last room right away, then switches to the playing group if exactly
    /// one is playing once fresh state arrives.
    private func restoreLastRoom() {
        let configs = model.enabledConfigs
        guard !didRestore, !configs.isEmpty else { return }
        didRestore = true
        if let id = UUID(uuidString: lastNetworkID),
           let network = configs.first(where: { $0.id == id }),
           !lastRoomName.isEmpty {
            path = routes(to: lastRoomName, in: network)
        }
        Task { await focusSolePlayingRoom() }
    }
}

// MARK: - Rooms

struct RoomListView: View {
    @EnvironmentObject private var model: WatchModel
    let config: NetworkConfig

    var body: some View {
        RoomList(controller: model.controller(for: config), config: config)
    }
}

private struct RoomList: View {
    @ObservedObject var controller: WatchNetworkController
    let config: NetworkConfig

    var body: some View {
        List {
            if let error = controller.errorMessage {
                ErrorRow(message: error, isStale: controller.hasLoaded) {
                    Task { await controller.refresh() }
                }
            }
            if !controller.hasLoaded && controller.errorMessage == nil {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
            ForEach(controller.rooms) { room in
                NavigationLink(value: Route.room(network: config.id, name: room.name)) {
                    RoomRow(room: room)
                }
            }
        }
        .navigationTitle(config.displayName)
    }
}

private struct RoomRow: View {
    let room: RoomState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(room.name)
                    .lineLimit(1)
                Spacer()
                if room.isPlaying {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(.green)
                        .imageScale(.small)
                }
            }
            if room.isGrouped {
                Text("With \(room.otherMembers.joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if room.isPlaying, let nowPlaying = room.nowPlaying {
                Text(nowPlaying)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct ErrorRow: View {
    let message: String
    /// True when rooms from an earlier refresh are still shown.
    let isStale: Bool
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
            if isStale {
                Text("Showing the last known state.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button("Retry", action: retry)
                .font(.caption2)
        }
    }
}

// MARK: - Room

struct RoomView: View {
    @ObservedObject var controller: WatchNetworkController
    let networkID: UUID
    let roomName: String

    @AppStorage("lastNetworkID") private var lastNetworkID = ""
    @AppStorage("lastRoomName") private var lastRoomName = ""
    @State private var controlsGroup = false
    @State private var crownValue: Double = 0
    @FocusState private var crownFocused: Bool

    private var room: RoomState? { controller.room(named: roomName) }

    private var target: ControlTarget {
        if controlsGroup, let room, room.isGrouped {
            return .group(coordinator: room.coordinator)
        }
        return .room(roomName)
    }

    private var displayedVolume: Int { controller.currentVolume(for: target) ?? 0 }
    private var volumeDisabled: Bool { controller.isVolumeDisabled(for: target) }
    private var displayedMute: Bool { controller.isMuted(target) ?? false }

    var body: some View {
        Group {
            if let room {
                controls(for: room)
            } else if let error = controller.errorMessage {
                VStack(spacing: 8) {
                    Text(error).font(.footnote).multilineTextAlignment(.center)
                    Button("Retry") { Task { await controller.refresh() } }
                }
            } else if controller.hasLoaded {
                Text("\(roomName) isn't on this network anymore.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(roomName)
        .toolbar {
            if let room, room.isGrouped {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        controlsGroup.toggle()
                    } label: {
                        Image(systemName: controlsGroup ? "hifispeaker.2.fill" : "hifispeaker.2")
                    }
                    .accessibilityLabel(controlsGroup ? "Control this room only" : "Control the whole group")
                }
            }
        }
        .onAppear {
            lastNetworkID = networkID.uuidString
            lastRoomName = roomName
            crownValue = Double(displayedVolume)
            crownFocused = true
        }
        // Crown turns become volume changes. setVolume ignores a value equal to the current one,
        // so the programmatic updates below never send a request.
        .onChange(of: crownValue) { _, value in
            controller.setVolume(Int(value.rounded()), for: target)
        }
        .onChange(of: displayedVolume) { _, volume in
            if Int(crownValue.rounded()) != volume { crownValue = Double(volume) }
        }
        .onChange(of: controlsGroup) { _, _ in
            crownValue = Double(displayedVolume)
        }
    }

    private func controls(for room: RoomState) -> some View {
        VStack(spacing: 6) {
            Text(room.nowPlaying ?? (room.isPlaying ? "Playing" : "Nothing playing"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)

            VStack(spacing: 0) {
                // "--" matches the iOS app's grayed-out volume for fixed-volume speakers.
                Text(volumeDisabled ? "--" : "\(displayedVolume)")
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(volumeDisabled ? .secondary : .primary)
                Text(volumeDisabled ? "Fixed volume" : (controlsGroup && room.isGrouped ? "Group volume" : "Volume"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .focusable(!volumeDisabled)
            .focused($crownFocused)
            .digitalCrownRotation(
                $crownValue,
                from: 0,
                through: 100,
                by: 1,
                sensitivity: .medium,
                isContinuous: false,
                isHapticFeedbackEnabled: true
            )
            .accessibilityLabel(controlsGroup && room.isGrouped ? "Group volume" : "Volume")
            .accessibilityValue(volumeDisabled ? "Fixed" : "\(displayedVolume)")

            HStack(spacing: 10) {
                Button {
                    controller.togglePlayback(room: room.name)
                } label: {
                    Image(systemName: room.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                }
                .accessibilityLabel(room.isPlaying ? "Pause" : "Play")

                Button {
                    controller.toggleMute(target)
                } label: {
                    Image(systemName: displayedMute ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.title3)
                        .foregroundStyle(displayedMute ? .orange : .primary)
                }
                .accessibilityLabel(displayedMute ? "Unmute" : "Mute")
            }
        }
    }
}
