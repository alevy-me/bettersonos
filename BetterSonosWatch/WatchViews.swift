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
    case presets(network: UUID, room: String)
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
                        description: Text("Add a network in BonTon on your iPhone. It syncs here through iCloud.")
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

    /// If the room reopened at launch isn't in the layout (asleep, unplugged or removed), show its
    /// network's room list instead of an empty room screen.
    private func leaveMissingLastRoom() {
        guard case .room(let id, let name)? = path.last, let config = model.config(id: id) else { return }
        let controller = model.controller(for: config)
        if controller.hasLoaded, controller.room(named: name) == nil {
            path.removeLast()
        }
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
        case .presets(let id, let room):
            if let config = model.config(id: id) {
                PresetsView(controller: model.controller(for: config), settings: model.settings, roomName: room)
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
        Task {
            await focusSolePlayingRoom()
            // The first reading can be slow (watch on its own Wi-Fi): wait for it before deciding.
            if case .room(let id, _)? = path.last, let config = model.config(id: id) {
                let controller = model.controller(for: config)
                let deadline = Date().addingTimeInterval(20)
                while controller.loadState == .loading, Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            leaveMissingLastRoom()
        }
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
            switch controller.loadState {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity)
            case .loaded:
                EmptyView()
            case .offline:
                OfflineMessage(alignment: .leading, hasServer: config.hasServer) { Task { await controller.refresh() } }
            case .stale(let message):
                ErrorRow(message: message, isStale: true) { Task { await controller.refresh() } }
            case .failed(let message):
                ErrorRow(message: message, isStale: false) { Task { await controller.refresh() } }
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

/// A local network whose speakers don't answer. The watch can't search for speakers itself, so if
/// you're home, the phone has to find them (new addresses reach the watch through iCloud).
private struct OfflineMessage: View {
    let alignment: HorizontalAlignment
    /// A merged network has a server too: then neither path answered, and the iPhone can't help.
    var hasServer = false
    let retry: () -> Void

    var body: some View {
        VStack(alignment: alignment, spacing: 4) {
            Label("Offline", systemImage: "wifi.slash")
                .font(.footnote)
            Text(hasServer
                 ? "Can't reach these speakers directly or through the server."
                 : "These speakers can't be reached from here. At home? Open BonTon on your iPhone to find them.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(alignment == .center ? .center : .leading)
            Button("Retry", action: retry)
                .font(.caption2)
        }
        .accessibilityElement(children: .combine)
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
    /// Set by a real Crown turn, so the settle at the end of it can send the final value.
    @State private var crownTurned = false
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

    /// Says why a volume can't be changed: a fixed output, or a speaker whose volume hasn't been read.
    private func volumeCaption(for room: RoomState) -> String {
        if controlsGroup && room.isGrouped { return volumeDisabled ? "Group volume unavailable" : "Group volume" }
        if room.isVolumeUnknown { return "Volume unavailable" }
        return volumeDisabled ? "Fixed volume" : "Volume"
    }

    var body: some View {
        Group {
            if let room {
                controls(for: room)
            } else {
                switch controller.loadState {
                case .loading:
                    ProgressView()
                case .offline:
                    OfflineMessage(alignment: .center, hasServer: controller.config.hasServer) { Task { await controller.refresh() } }
                case .failed(let message):
                    VStack(spacing: 8) {
                        Text(message).font(.footnote).multilineTextAlignment(.center)
                        Button("Retry") { Task { await controller.refresh() } }
                    }
                case .loaded, .stale:
                    // The layout no longer lists this room (asleep, unplugged or removed).
                    Text("\(roomName) isn't on this network right now.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }
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
            crownFocused = true
        }
        // The Crown's value follows the speaker. Only an actual turn sends a volume (see the Crown's
        // onChange below); values the app sets here never reach the speaker.
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
                Text(volumeCaption(for: room))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .focusable(!volumeDisabled)
            .focused($crownFocused)
            // Start from the speaker's real volume when the controls appear: they can appear well after
            // the screen opens, when the first reading is slow (the watch on its own Wi-Fi).
            .onAppear { crownValue = Double(displayedVolume) }
            .digitalCrownRotation(
                detent: $crownValue,
                from: 0,
                through: 100,
                by: 1,
                sensitivity: .medium,
                isContinuous: false,
                isHapticFeedbackEnabled: true,
                onChange: { event in
                    // A real turn has velocity. The control attaching, or the app setting the value to
                    // follow the speaker, doesn't, and must never send a volume (it once sent 0).
                    guard event.velocity != 0 else { return }
                    crownTurned = true
                    controller.setVolume(Int(event.offset.rounded()), for: target)
                },
                onIdle: {
                    // The settle at the end of a turn can arrive without velocity; send where it came to rest.
                    // Only after a real turn, so attaching the control can never send anything.
                    guard crownTurned else { return }
                    crownTurned = false
                    let final = Int(crownValue.rounded())
                    if final != displayedVolume { controller.setVolume(final, for: target) }
                }
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

                NavigationLink(value: Route.presets(network: networkID, room: room.name)) {
                    Image(systemName: "list.bullet")
                        .font(.title3)
                }
                .accessibilityLabel("Presets")
            }
        }
    }
}

// MARK: - Presets

struct PresetsView: View {
    @ObservedObject var controller: WatchNetworkController
    @ObservedObject var settings: AppSettingsStore
    let roomName: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let playing = controller.playingPreset(forRoom: roomName)
        ScrollViewReader { proxy in
            List {
                if let error = controller.presetsError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if controller.presets.isEmpty {
                    if controller.isLoadingPresets {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if controller.presetsError == nil {
                        Text("No presets for this network.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(controller.presets, id: \.self) { station in
                    Button {
                        controller.playPreset(station, inRoom: roomName)
                        dismiss()
                    } label: {
                        PresetRow(station: station, isPlaying: station == playing)
                    }
                    .id(station)
                }
            }
            .onAppear {
                if let playing { proxy.scrollTo(playing, anchor: .center) }
            }
        }
        .navigationTitle("Presets")
        .task {
            await controller.loadPresets(settings: settings)
        }
    }
}

private struct PresetRow: View {
    let station: Station
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .imageScale(.small)
                .frame(width: 16)
            Text(station.name)
                .lineLimit(2)
            Spacer(minLength: 0)
            if isPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(.green)
                    .imageScale(.small)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isPlaying ? .isSelected : [])
    }

    private var icon: String {
        if station.isFavorite { return "star.fill" }
        if station.isLineIn { return "cable.connector" }
        return "dot.radiowaves.left.and.right"
    }
}
