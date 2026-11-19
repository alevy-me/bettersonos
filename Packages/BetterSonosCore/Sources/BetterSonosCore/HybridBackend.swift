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
//  HybridBackend.swift
//
//  A server network merged with its household: the speakers directly when they answer (at home),
//  the server otherwise (away).

import Foundation

/// Which way a hybrid network is reaching its speakers right now.
public enum HybridPath: String, Sendable {
    case direct
    case server
}

/// The current path per hybrid network, shared by every backend instance for it (backends are
/// rebuilt from the config on each use, so the choice can't live in one of them).
public final class HybridPathCache: @unchecked Sendable {
    public static let shared = HybridPathCache()

    /// While on the server, how often a read re-checks whether the speakers answer directly.
    public var directRecheckInterval: TimeInterval = 60
    /// When both paths are tried at once and the server answers first, how long to wait for the
    /// speakers before settling on the server.
    public var directPreferenceWindow: TimeInterval = 1.5

    private struct Entry {
        var path: HybridPath
        var lastDirectCheck: Date
    }
    private var entries: [UUID: Entry] = [:]
    private let lock = NSLock()

    /// The app uses `shared`; tests make their own.
    public init() {}

    public func path(for id: UUID) -> HybridPath? {
        lock.withLock { entries[id]?.path }
    }

    func entry(for id: UUID) -> (path: HybridPath, lastDirectCheck: Date)? {
        lock.withLock { entries[id].map { ($0.path, $0.lastDirectCheck) } }
    }

    func set(_ path: HybridPath, for id: UUID, checkedDirect: Bool) {
        lock.withLock {
            let lastCheck = checkedDirect ? Date() : (entries[id]?.lastDirectCheck ?? .distantPast)
            entries[id] = Entry(path: path, lastDirectCheck: lastCheck)
        }
    }

    /// Forget every choice, so the next read chooses afresh: after a network change or returning
    /// to the app, when being home or away may have changed.
    public func invalidateAll() {
        lock.withLock { entries.removeAll() }
    }
}

public struct HybridBackend: SonosBackend {
    public let networkID: UUID
    public let direct: DirectBackend
    public let server: ServerBackend
    let cache: HybridPathCache

    public init(networkID: UUID, direct: DirectBackend, server: ServerBackend, cache: HybridPathCache = .shared) {
        self.networkID = networkID
        self.direct = direct
        self.server = server
        self.cache = cache
    }

    public var currentPath: HybridPath? { cache.path(for: networkID) }

    // MARK: - Reads

    /// Zones from whichever path answers, plus, when it was the speakers, every address the layout
    /// listed (for saving).
    public func snapshot() async throws -> (zones: [Zone], addresses: [String: String]?) {
        switch cache.entry(for: networkID) {
        case nil:
            return try await choose()
        case (.direct, _)?:
            do {
                let snapshot = try await direct.snapshot()
                cache.set(.direct, for: networkID, checkedDirect: true)
                return (snapshot.zones, snapshot.addresses)
            } catch where DirectBackend.isCancellation(error) {
                throw error
            } catch {
                // The speakers stopped answering directly (left home?): switch to the server at once.
                return try await serverOrFail(directReasons: Self.reasons(error))
            }
        case (.server, let lastCheck)?:
            if Date().timeIntervalSince(lastCheck) >= cache.directRecheckInterval {
                return try await choose()
            }
            return try await serverOrFail(directReasons: [])
        }
    }

    public func zones() async throws -> [Zone] {
        try await snapshot().zones
    }

    /// Asks the speakers and the server at once, preferring the speakers: if the server answers
    /// first, the speakers get a short window to answer too before the server is chosen.
    private func choose() async throws -> (zones: [Zone], addresses: [String: String]?) {
        enum Outcome {
            case direct(Result<(zones: [Zone], addresses: [String: String]), Error>)
            case server(Result<[Zone], Error>)
            case windowClosed
        }
        let direct = self.direct, server = self.server, window = cache.directPreferenceWindow
        let outcome: (zones: [Zone], addresses: [String: String]?, path: HybridPath)? = try await withThrowingTaskGroup(of: Outcome.self) { group in
            group.addTask { .direct(await Result(asyncCatching: { try await direct.snapshot() })) }
            group.addTask { .server(await Result(asyncCatching: { try await server.zones() })) }
            var directResult: Result<(zones: [Zone], addresses: [String: String]), Error>?
            var serverZones: [Zone]?
            var serverError: Error?
            for try await next in group {
                switch next {
                case .direct(let result):
                    directResult = result
                    if case .success(let snapshot) = result {
                        group.cancelAll()
                        return (snapshot.zones, snapshot.addresses, .direct)
                    }
                    if let serverZones { group.cancelAll(); return (serverZones, nil, .server) }
                case .server(let result):
                    switch result {
                    case .success(let zones):
                        serverZones = zones
                        if directResult != nil { group.cancelAll(); return (zones, nil, .server) }
                        // Give the speakers a moment: at home they usually answer first anyway.
                        group.addTask {
                            try? await Task.sleep(for: .seconds(window))
                            return .windowClosed
                        }
                    case .failure(let error):
                        serverError = error
                    }
                case .windowClosed:
                    if let serverZones { group.cancelAll(); return (serverZones, nil, .server) }
                }
                if case .failure? = directResult, serverError != nil { break }
            }
            // Neither answered.
            if case .failure(let error)? = directResult, DirectBackend.isCancellation(error) { throw error }
            throw DirectBackend.DirectError.noSpeakerAnswered(reasons: Self.reasons(directResult?.failure) + Self.serverReasons(serverError))
        }
        guard let outcome else { throw DirectBackend.DirectError.noSpeakerAnswered() }
        cache.set(outcome.path, for: networkID, checkedDirect: true)
        return (outcome.zones, outcome.addresses)
    }

    private func serverOrFail(directReasons: [String]) async throws -> (zones: [Zone], addresses: [String: String]?) {
        do {
            let zones = try await server.zones()
            cache.set(.server, for: networkID, checkedDirect: !directReasons.isEmpty)
            return (zones, nil)
        } catch {
            if DirectBackend.isCancellation(error) { throw error }
            // Neither path answered: report it as silence, so the apps' missed-poll counting applies.
            throw DirectBackend.DirectError.noSpeakerAnswered(reasons: directReasons + Self.serverReasons(error))
        }
    }

    private static func reasons(_ error: Error?) -> [String] {
        guard let error else { return [] }
        if case DirectBackend.DirectError.noSpeakerAnswered(let reasons) = error { return reasons }
        return [DirectBackend.describe(error)]
    }

    private static func serverReasons(_ error: Error?) -> [String] {
        error.map { ["server: \(DirectBackend.describe($0))"] } ?? []
    }

    public func favoriteNames() async throws -> [String] {
        try await route { try await $0.favoriteNames() }
    }

    // MARK: - Commands, on whichever path reads are using

    private var active: any SonosBackend {
        cache.path(for: networkID) == .server ? server : direct
    }

    private func route<T>(_ body: (any SonosBackend) async throws -> T) async throws -> T {
        try await body(active)
    }

    @discardableResult public func play(coordinator: String) async -> Bool { await active.play(coordinator: coordinator) }
    @discardableResult public func pause(coordinator: String) async -> Bool { await active.pause(coordinator: coordinator) }
    @discardableResult public func setVolume(_ level: Int, room: String) async -> Bool { await active.setVolume(level, room: room) }
    @discardableResult public func setGroupVolume(_ level: Int, coordinator: String) async -> Bool { await active.setGroupVolume(level, coordinator: coordinator) }
    @discardableResult public func setMute(_ muted: Bool, room: String) async -> Bool { await active.setMute(muted, room: room) }
    @discardableResult public func setGroupMute(_ muted: Bool, coordinator: String) async -> Bool { await active.setGroupMute(muted, coordinator: coordinator) }
    @discardableResult public func join(room: String, to target: String) async -> Bool { await active.join(room: room, to: target) }
    @discardableResult public func leave(room: String) async -> Bool { await active.leave(room: room) }
    @discardableResult public func loadPreset(_ station: Station, coordinator: String) async -> Bool { await active.loadPreset(station, coordinator: coordinator) }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
