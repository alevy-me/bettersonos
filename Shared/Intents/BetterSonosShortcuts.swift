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
//  BetterSonosShortcuts.swift
//
//  Siri phrases. Every phrase must include the app name; a phrase may name at most one parameter.

import AppIntents

struct BetterSonosShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PauseIntent(),
            phrases: [
                "Pause \(\.$room) in \(.applicationName)",
                "Pause the \(\.$room) in \(.applicationName)",
                "Pause \(.applicationName)",
                "Pause the music in \(.applicationName)",
            ],
            shortTitle: "Pause",
            systemImageName: "pause.fill"
        )
        AppShortcut(
            intent: ResumeIntent(),
            phrases: [
                "Resume \(\.$room) in \(.applicationName)",
                "Play \(\.$room) in \(.applicationName)",
                "Resume the \(\.$room) in \(.applicationName)",
            ],
            shortTitle: "Resume",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: VolumeUpIntent(),
            phrases: [
                "Turn up \(\.$room) in \(.applicationName)",
                "Turn up the \(\.$room) in \(.applicationName)",
                "Louder in \(\.$room) with \(.applicationName)",
            ],
            shortTitle: "Volume Up",
            systemImageName: "speaker.plus.fill"
        )
        AppShortcut(
            intent: VolumeDownIntent(),
            phrases: [
                "Turn down \(\.$room) in \(.applicationName)",
                "Turn down the \(\.$room) in \(.applicationName)",
                "Quieter in \(\.$room) with \(.applicationName)",
            ],
            shortTitle: "Volume Down",
            systemImageName: "speaker.minus.fill"
        )
        AppShortcut(
            intent: SetVolumeIntent(),
            phrases: [
                "Set the \(\.$room) volume in \(.applicationName)",
                "Set \(\.$room) volume in \(.applicationName)",
                "Set the volume in \(.applicationName)",
            ],
            shortTitle: "Set Volume",
            systemImageName: "speaker.wave.2.fill"
        )
        AppShortcut(
            intent: MuteIntent(),
            phrases: [
                "Mute \(\.$room) in \(.applicationName)",
                "Mute the \(\.$room) in \(.applicationName)",
            ],
            shortTitle: "Mute",
            systemImageName: "speaker.slash.fill"
        )
        AppShortcut(
            intent: UnmuteIntent(),
            phrases: [
                "Unmute \(\.$room) in \(.applicationName)",
                "Unmute the \(\.$room) in \(.applicationName)",
            ],
            shortTitle: "Unmute",
            systemImageName: "speaker.wave.2"
        )
        AppShortcut(
            intent: PlayPresetIntent(),
            phrases: [
                "Play \(\.$preset) with \(.applicationName)",
                "Put on \(\.$preset) with \(.applicationName)",
            ],
            shortTitle: "Play Preset",
            systemImageName: "dot.radiowaves.left.and.right"
        )
        AppShortcut(
            intent: WhatsPlayingIntent(),
            phrases: [
                "What's playing in \(.applicationName)",
                "What's playing on \(\.$room) in \(.applicationName)",
                "What's playing in the \(\.$room) with \(.applicationName)",
            ],
            shortTitle: "What's Playing",
            systemImageName: "music.note"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .orange
}

/// Keeps Siri's vocabulary of room and preset names current. Call when room names change.
enum SiriVocabulary {
    static func refresh() {
        BetterSonosShortcuts.updateAppShortcutParameters()
    }
}
