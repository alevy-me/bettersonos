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
//  SonosIntents.swift
//
//  Play and pause act on the room's group, like the apps. Volume and mute act on the room.

import Foundation
import AppIntents
import BetterSonosCore

// MARK: - Playback

struct PauseIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause"
    static let description = IntentDescription("Pauses a room's group. With no room, pauses the only group playing.")

    @Parameter(title: "Room")
    var room: RoomEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Pause \(\.$room)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let target: SonosDirectory.Located
        if let room {
            target = try await SonosDirectory.locate(room)
        } else {
            let playing = await SonosDirectory.playingGroups()
            switch playing.count {
            case 0: throw SonosIntentError.nothingPlaying
            case 1: target = playing[0]
            default: throw $room.needsValueError("Which room?")
            }
        }
        try SonosDirectory.require(await target.backend.pause(coordinator: target.coordinatorName))
        return .result(dialog: "Paused \(target.roomName).")
    }
}

struct ResumeIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume"
    static let description = IntentDescription("Resumes playback in a room's group.")

    @Parameter(title: "Room")
    var room: RoomEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Resume \(\.$room)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let target = try await SonosDirectory.locate(room)
        // A stopped stream (live radio after a pause) restarts by reloading its preset.
        if target.coordinator.state.isStopped, let track = target.coordinator.state.currentTrack {
            let presets = await SonosDirectory.presets(for: target.config).map(\.station)
            if let preset = bestMatchingStation(in: presets, for: track) {
                try SonosDirectory.require(await target.backend.loadPreset(preset, coordinator: target.coordinatorName))
            }
        }
        try SonosDirectory.require(await target.backend.play(coordinator: target.coordinatorName))
        return .result(dialog: "Playing \(target.roomName).")
    }
}

struct PlayPresetIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Preset"
    static let description = IntentDescription("Plays a preset in a room's group.")

    @Parameter(title: "Preset")
    var preset: PresetEntity

    @Parameter(title: "Room")
    var room: RoomEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$preset) in \(\.$room)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard preset.networkID == room.networkID else {
            throw SonosIntentError.presetOnOtherNetwork(preset: preset.name, room: room.name)
        }
        let target = try await SonosDirectory.locate(room)
        try SonosDirectory.require(await target.backend.loadPreset(preset.station, coordinator: target.coordinatorName))
        try SonosDirectory.require(await target.backend.play(coordinator: target.coordinatorName))
        return .result(dialog: "Playing \(preset.name) in \(target.roomName).")
    }
}

struct WhatsPlayingIntent: AppIntent {
    static let title: LocalizedStringResource = "What's Playing"
    static let description = IntentDescription("Says what's playing in a room, or everywhere when no room is given.")

    @Parameter(title: "Room")
    var room: RoomEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("What's playing in \(\.$room)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let answer: String
        if let room {
            let target = try await SonosDirectory.locate(room)
            if target.coordinator.state.isPlaybackUnread == true {
                throw SonosIntentError.notResponding(target.roomName)
            }
            if target.isPlaying {
                let track = SonosDirectory.describe(target.coordinator.state.currentTrack, on: target.config) ?? "something"
                answer = "\(target.roomName) is playing \(track)."
            } else {
                answer = "\(target.roomName) is paused."
            }
        } else {
            let playing = await SonosDirectory.playingGroups()
            if playing.isEmpty {
                answer = "Nothing is playing."
            } else {
                answer = playing.map { group in
                    let track = SonosDirectory.describe(group.coordinator.state.currentTrack, on: group.config) ?? "something"
                    return "\(group.roomName) is playing \(track)."
                }.joined(separator: " ")
            }
        }
        return .result(value: answer, dialog: "\(answer)")
    }
}

// MARK: - Volume

/// Shared by the volume intents: checks fixed volume, then sets an absolute level.
private func setVolume(_ located: SonosDirectory.Located, to level: Int) async throws -> Int {
    // A room that didn't answer has no current volume to adjust from; say so, not "fixed volume".
    guard located.member.state.isLevelUnread != true else {
        throw SonosIntentError.notResponding(located.roomName)
    }
    guard !located.config.isVolumeDisabled(for: located.member) else {
        throw SonosIntentError.fixedVolume(located.roomName)
    }
    let value = max(0, min(100, level))
    try SonosDirectory.require(await located.backend.setVolume(value, room: located.roomName))
    return value
}

struct VolumeUpIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Volume Up"
    static let description = IntentDescription("Turns up a room's volume.")

    @Parameter(title: "Room")
    var room: RoomEntity

    @Parameter(title: "Amount", default: 10, inclusiveRange: (1, 50))
    var amount: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Turn up \(\.$room) by \(\.$amount)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let target = try await SonosDirectory.locate(room)
        let value = try await setVolume(target, to: target.member.state.volume + amount)
        return .result(dialog: "\(target.roomName) volume \(value).")
    }
}

struct VolumeDownIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Volume Down"
    static let description = IntentDescription("Turns down a room's volume.")

    @Parameter(title: "Room")
    var room: RoomEntity

    @Parameter(title: "Amount", default: 10, inclusiveRange: (1, 50))
    var amount: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Turn down \(\.$room) by \(\.$amount)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let target = try await SonosDirectory.locate(room)
        let value = try await setVolume(target, to: target.member.state.volume - amount)
        return .result(dialog: "\(target.roomName) volume \(value).")
    }
}

struct SetVolumeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Volume"
    static let description = IntentDescription("Sets a room's volume from 0 to 100.")

    @Parameter(title: "Room")
    var room: RoomEntity

    @Parameter(title: "Level", inclusiveRange: (0, 100))
    var level: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Set \(\.$room) volume to \(\.$level)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let target = try await SonosDirectory.locate(room)
        let value = try await setVolume(target, to: level)
        return .result(dialog: "\(target.roomName) volume \(value).")
    }
}

// MARK: - Mute

struct MuteIntent: AppIntent {
    static let title: LocalizedStringResource = "Mute"
    static let description = IntentDescription("Mutes a room.")

    @Parameter(title: "Room")
    var room: RoomEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Mute \(\.$room)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let target = try await SonosDirectory.locate(room)
        try SonosDirectory.require(await target.backend.setMute(true, room: target.roomName))
        return .result(dialog: "Muted \(target.roomName).")
    }
}

struct UnmuteIntent: AppIntent {
    static let title: LocalizedStringResource = "Unmute"
    static let description = IntentDescription("Unmutes a room.")

    @Parameter(title: "Room")
    var room: RoomEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Unmute \(\.$room)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let target = try await SonosDirectory.locate(room)
        try SonosDirectory.require(await target.backend.setMute(false, room: target.roomName))
        return .result(dialog: "Unmuted \(target.roomName).")
    }
}
