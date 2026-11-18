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
//  Backend.swift
//

import Foundation

/// How the apps read state from and send commands to one Sonos system. Rooms are named as the
/// speakers name them; play, pause and presets go to a group's coordinator.
///
/// Commands report success rather than throwing, matching how every caller already treats them:
/// as hints for whether to keep an optimistic UI update.
public protocol SonosBackend: Sendable {
    /// Every group with its members and their current state.
    func zones() async throws -> [Zone]
    /// The household's Sonos favorites, by name.
    func favoriteNames() async throws -> [String]

    @discardableResult func play(coordinator: String) async -> Bool
    @discardableResult func pause(coordinator: String) async -> Bool
    @discardableResult func setVolume(_ level: Int, room: String) async -> Bool
    @discardableResult func setGroupVolume(_ level: Int, coordinator: String) async -> Bool
    @discardableResult func setMute(_ muted: Bool, room: String) async -> Bool
    @discardableResult func setGroupMute(_ muted: Bool, coordinator: String) async -> Bool
    @discardableResult func join(room: String, to target: String) async -> Bool
    @discardableResult func leave(room: String) async -> Bool
    /// Loads a preset into a group without starting it. Follow with `play(coordinator:)`.
    @discardableResult func loadPreset(_ station: Station, coordinator: String) async -> Bool
}

/// A node-sonos-http-api server.
public struct ServerBackend: SonosBackend {
    public let baseURL: String

    public init(baseURL: String) {
        self.baseURL = URLInput.normalizedBaseURL(baseURL)
    }

    private func url(_ components: String...) -> URL? {
        SonosHTTP.url(base: baseURL, components)
    }

    public func zones() async throws -> [Zone] {
        guard let url = URL(string: "\(baseURL)/zones") else { throw SonosHTTP.RequestError.notHTTP }
        return try await SonosHTTP.fetchJSON([Zone].self, from: url).get()
    }

    public func favoriteNames() async throws -> [String] {
        guard let url = URL(string: "\(baseURL)/favorites") else { throw SonosHTTP.RequestError.notHTTP }
        return try await SonosHTTP.fetchJSON([String].self, from: url).get()
    }

    @discardableResult public func play(coordinator: String) async -> Bool {
        await SonosHTTP.get(url(coordinator, "play"))
    }

    @discardableResult public func pause(coordinator: String) async -> Bool {
        await SonosHTTP.get(url(coordinator, "pause"))
    }

    @discardableResult public func setVolume(_ level: Int, room: String) async -> Bool {
        await SonosHTTP.get(url(room, "volume", "\(level)"))
    }

    @discardableResult public func setGroupVolume(_ level: Int, coordinator: String) async -> Bool {
        await SonosHTTP.get(url(coordinator, "groupvolume", "\(level)"))
    }

    @discardableResult public func setMute(_ muted: Bool, room: String) async -> Bool {
        await SonosHTTP.get(url(room, muted ? "mute" : "unmute"))
    }

    @discardableResult public func setGroupMute(_ muted: Bool, coordinator: String) async -> Bool {
        await SonosHTTP.get(url(coordinator, muted ? "groupmute" : "groupunmute"))
    }

    @discardableResult public func join(room: String, to target: String) async -> Bool {
        await SonosHTTP.get(url(room, "join", target))
    }

    @discardableResult public func leave(room: String) async -> Bool {
        await SonosHTTP.get(url(room, "leave"))
    }

    @discardableResult public func loadPreset(_ station: Station, coordinator: String) async -> Bool {
        await SonosHTTP.get(SonosHTTP.presetURL(base: baseURL, room: coordinator, station: station))
    }
}

extension NetworkConfig {
    /// The backend for this network. Every network is a server network until direct control lands.
    public var backend: any SonosBackend {
        ServerBackend(baseURL: baseURL)
    }
}

extension Result where Failure == Error {
    /// Captures an async throwing call, for use with `async let`.
    public init(asyncCatching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
