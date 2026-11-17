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
//  Views.swift
//

import SwiftUI
import os.log

// MARK: - Network Subviews

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
                        config: config,
                        stations: filteredStations,
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
    let stations: [Station]
    @ObservedObject var viewModel: SonosViewModel
    let onInitiateJoinForSpeaker: (String) -> Void // Closure that takes the specific speaker's name
    @State private var isExpanded: Bool

    init(group: SonosGroup, viewModel: SonosViewModel, config: NetworkConfig, stations: [Station], onInitiateJoinForSpeaker: @escaping (String) -> Void) {
        self.group = group
        self.config = config
        self.stations = stations
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
                stations: stations,
                onAdjust: { d in viewModel.adjustVolume(room: group.coordinator, delta: d) },
                onToggleMute: { viewModel.toggleMute(room: group.coordinator) },
                onTogglePlay: { viewModel.togglePlayback(group: group) },
                onStartJoinProcessForRow: {
                    onInitiateJoinForSpeaker(group.coordinator)
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
                    stations: [], // Joiners show no presets
                    onAdjust: { d in viewModel.adjustVolume(room: room, delta: d) },
                    onToggleMute: { viewModel.toggleMute(room: room) },
                    onTogglePlay: nil,
                    onStartJoinProcessForRow: {
                        onInitiateJoinForSpeaker(room)
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
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "StationPresetAccordion")
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
        self.selectedStation = selectedStation
        self.onSelect = onSelect
        self._isExpanded = isExpanded
        self.stationDisplay = stationDisplay
        self.onExpansionChanged = onExpansionChanged

        let pages = Self.paginate(stations)
        self.pages = pages
        // Only the first seed is used for the view's lifetime; later selection changes are handled by onChange below.
        _currentPage = State(initialValue: Self.pageIndex(of: selectedStation, in: pages) ?? 0)
    }

    /// Pages of 2 rows by 3 buttons.
    private static func paginate(_ list: [Station]) -> [[[Station]]] {
        stride(from: 0, to: list.count, by: Constants.stationsPerPage).map { start in
            let slice = Array(list[start..<min(start + Constants.stationsPerPage, list.count)])
            return stride(from: 0, to: slice.count, by: Constants.stationsPerRow).map { rowStart in
                Array(slice[rowStart..<min(rowStart + Constants.stationsPerRow, slice.count)])
            }
        }
    }

    private static func pageIndex(of station: Station?, in pages: [[[Station]]]) -> Int? {
        guard let station else { return nil }
        return pages.firstIndex { $0.joined().contains(station) }
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
                                                Self.logger.debug("Selected station: \(station.name) | type: \(station.type.rawValue)")
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
        .onChange(of: selectedStation) { _, newValue in
            if let index = Self.pageIndex(of: newValue, in: pages) {
                currentPage = index
            }
        }
        .onChange(of: pages.count) { _, count in
            // Keep the TabView selection pointing at a page that exists.
            if currentPage >= count {
                currentPage = max(0, count - 1)
            }
        }
    }
}

struct RoomRowView: View {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "RoomRowView")
    @ObservedObject var viewModel: SonosViewModel
    let config: NetworkConfig
    let roomName: String
    let volume: Int
    let isMuted: Bool
    let isCoordinator: Bool
    let isPlaying: Bool
    let stationName: String?
    let isVolumeDisabled: Bool
    let stations: [Station]

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
                    stations: stations,
                    selectedStation: viewModel.selectedStationByRoom[roomName],
                    onSelect: { s in
                        Self.logger.debug("selectStation for room: \(roomName), station: \(s.name)")
                        viewModel.selectStation(s, for: roomName)
                        Self.logger.debug("playStation for room: \(roomName), station: \(s.name)")
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

// MARK: - Button Style Helper

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
