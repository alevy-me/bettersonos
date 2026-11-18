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
//  SonosDiscovery.swift
//
//  Finds Sonos speakers on the local network with Bonjour (_sonos._tcp). Each speaker's TXT record
//  carries its control address (`location`), player ID (`uuid`) and household (`hhid`).

import Foundation
import Network
import os.log
import BetterSonosCore

private let log = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "SonosDiscovery")

/// One Sonos system found on the network.
struct DiscoveredHousehold: Identifiable, Equatable {
    var id: String { householdID }
    let householdID: String
    /// Every speaker's address by player ID, from the speakers' own layout when it could be read.
    let speakers: [String: String]
    /// Room names, for showing the user what was found.
    let roomNames: [String]
}

enum DiscoveryOutcome {
    case found([DiscoveredHousehold])
    case nothingFound
    case permissionDenied
}

enum SonosDiscovery {
    /// Browses for `seconds`, then confirms each household by reading its layout from one speaker.
    @MainActor
    static func discover(for seconds: Double = 2.5) async -> DiscoveryOutcome {
        let browse = await browse(for: seconds)
        guard case .found(let raw) = browse else { return browse == .denied ? .permissionDenied : .nothingFound }

        var households: [DiscoveredHousehold] = []
        for (householdID, speakers) in raw {
            let backend = DirectBackend(speakers: speakers)
            if let topology = try? await backend.topology() {
                let rooms = topology.groups.flatMap(\.members).filter(\.isRoom).map(\.roomName)
                let unique = Array(Set(rooms)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                households.append(DiscoveredHousehold(householdID: householdID, speakers: topology.addresses, roomNames: unique))
            } else {
                log.info("Household \(householdID, privacy: .public) advertised but its layout couldn't be read")
            }
        }
        return households.isEmpty ? .nothingFound : .found(households)
    }

    private enum BrowseResult: Equatable {
        case found([String: [String: String]]) // household ID -> (player ID -> address)
        case nothing
        case denied
    }

    @MainActor
    private static func browse(for seconds: Double) async -> BrowseResult {
        await withCheckedContinuation { continuation in
            BrowseSession(seconds: seconds) { continuation.resume(returning: $0) }.start()
        }
    }

    /// One Bonjour browse. Every callback runs on the main queue, which is the only place state changes;
    /// that confinement is what makes the unchecked Sendable conformance sound.
    private final class BrowseSession: @unchecked Sendable {
        private let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_sonos._tcp", domain: nil), using: .tcp)
        private let seconds: Double
        private let completion: (BrowseResult) -> Void
        private var households: [String: [String: String]] = [:]
        private var denied = false
        private var finished = false

        init(seconds: Double, completion: @escaping (BrowseResult) -> Void) {
            self.seconds = seconds
            self.completion = completion
        }

        func start() {
            browser.stateUpdateHandler = { [self] state in handle(state) }
            browser.browseResultsChangedHandler = { [self] results, _ in collect(results) }
            browser.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [self] in finish() }
        }

        private func handle(_ state: NWBrowser.State) {
            switch state {
            case .waiting(let error), .failed(let error):
                // Local network permission denied surfaces as a DNS-SD policy error.
                if case .dns(let code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
                    denied = true
                    finish()
                } else if case .failed = state {
                    finish()
                }
            default:
                break
            }
        }

        private func collect(_ results: Set<NWBrowser.Result>) {
            for result in results {
                guard case .bonjour(let txt) = result.metadata else { continue }
                let fields = txt.dictionary
                guard let householdID = fields["hhid"], let uuid = fields["uuid"],
                      let location = fields["location"], let host = SonosSOAP.host(fromLocation: location) else { continue }
                households[householdID, default: [:]][uuid] = host
            }
        }

        private func finish() {
            guard !finished else { return }
            finished = true
            browser.cancel()
            if !households.isEmpty {
                completion(.found(households))
            } else {
                completion(denied ? .denied : .nothing)
            }
        }
    }
}
