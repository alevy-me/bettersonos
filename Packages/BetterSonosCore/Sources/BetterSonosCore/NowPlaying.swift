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
//  NowPlaying.swift
//

import Foundation

/// What a room is playing, named by its source only: the station, preset or service, never the
/// track's title or artist. Track metadata from Sonos is too inconsistent to show cleanly (status
/// codes like "ZPSTR_BUFFERING" while loading, stream file names, packed fields), and the source is
/// what matters at a glance.
public struct NowPlaying: Equatable, Sendable {
    /// "Radio Woodstock 100.1", "WWOZ", "Spotify", "Line In · TV".
    public let source: String
    /// The line-in source's own name, such as "TV", when the room plays a line-in.
    public let lineInName: String?
    public let isLineIn: Bool

    /// - Parameter presetName: the matched preset, which wins so the name matches the presets list.
    public init?(track: Track?, presetName: String? = nil) {
        guard let track else { return nil }
        let uri = Self.clean(track.uri ?? track.trackUri) ?? ""
        let lowerURI = uri.lowercased()

        if lowerURI.hasPrefix("x-rincon-stream:") {
            let name = Self.clean(track.title)
            self.lineInName = name
            self.isLineIn = true
            self.source = name.map { "Line In · \($0)" } ?? "Line In"
            return
        }
        self.lineInName = nil
        self.isLineIn = false

        if let preset = Self.clean(presetName) {
            source = preset
        } else if let station = Self.clean(track.stationName) {
            source = station
        } else if let service = Self.serviceName(for: lowerURI) {
            source = service
        } else if lowerURI.hasPrefix("x-sonosapi-stream:") || track.type == "radio",
                  let name = Self.clean(track.artist), !name.uppercased().hasPrefix("ZPSTR_") {
            // Radio services sometimes put the station name in the artist field and leave stationName empty.
            source = name
        } else if let host = Self.streamHost(uri) {
            source = host
        } else {
            return nil
        }
    }

    /// One line for a screen.
    public var line: String { source }

    /// For speech: "Radio Woodstock 100.1", "Spotify", "the TV line in".
    public var spoken: String {
        if isLineIn { return lineInName.map { "the \($0) line in" } ?? "a line in" }
        return source
    }

    // MARK: - Rules

    static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Services recognizable from the track URI. Only names the URI states outright.
    static func serviceName(for lowerURI: String) -> String? {
        if lowerURI.contains("spotify") { return "Spotify" }
        if lowerURI.contains("apple") { return "Apple Music" }
        if lowerURI.hasPrefix("x-file-cifs:") || lowerURI.hasPrefix("x-smb:") { return "Music Library" }
        if lowerURI.hasPrefix("x-sonos-htastream:") { return "TV" }
        return nil
    }

    /// "x-rincon-mp3radio://https://s2.mexside.net/8014/stream" → "s2.mexside.net"
    static func streamHost(_ uri: String) -> String? {
        let lower = uri.lowercased()
        guard lower.hasPrefix("x-rincon-mp3radio://") || lower.hasPrefix("http") else { return nil }
        var url = uri
        if lower.hasPrefix("x-rincon-mp3radio://") { url = String(url.dropFirst("x-rincon-mp3radio://".count)) }
        if !url.contains("://") { url = "http://" + url }
        guard let host = URL(string: url)?.host, !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
