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
//  WatchDiagnostics.swift
//
//  Debug builds only: a log of every poll, refresh and command, with duration and failure reason,
//  written to Documents/diagnostics.log. watchOS gives apps no network-change events, so the outcomes
//  of our own requests are the only record of what the network did. Pull it from a Mac with:
//    xcrun devicectl device copy from --device <watch> --domain-type appDataContainer \
//      --domain-identifier show.nola.BetterSonos.watchkitapp --source Documents/diagnostics.log --destination .

import Foundation

enum WatchDiagnostics {
    #if DEBUG
    private static let maxBytes = 256 * 1024
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withTime, .withColonSeparatorInTime, .withFractionalSeconds]
        return f
    }()
    private static var fileURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("diagnostics.log")
    }

    static func record(_ line: @autoclosure () -> String) {
        guard let url = fileURL else { return }
        let entry = Data("\(formatter.string(from: Date())) \(line())\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            if let size = try? handle.seekToEnd(), size > maxBytes {
                // Keep the newest half rather than growing without bound.
                try? handle.close()
                if let data = try? Data(contentsOf: url) {
                    try? data.suffix(maxBytes / 2).write(to: url)
                }
                if let reopened = try? FileHandle(forWritingTo: url) {
                    _ = try? reopened.seekToEnd()
                    try? reopened.write(contentsOf: entry)
                    try? reopened.close()
                }
                return
            }
            try? handle.write(contentsOf: entry)
        } else {
            try? entry.write(to: url)
        }
    }
    #else
    static func record(_ line: @autoclosure () -> String) {}
    #endif

    static func milliseconds(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }
}
