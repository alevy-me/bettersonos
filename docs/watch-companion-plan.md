# Apple Watch Companion: Plan

## Scope

From the wrist: pick a room or group, play and pause, and set volume with the Digital Crown. Presets come in a second phase.

Out of scope: grouping and ungrouping, network settings, line-in setup, custom CSV editing, live updates over SSE.

## What the network test established

Tested on a Series 11 against `192.168.1.13`, `home.example.com` and `second.example.com`, with `WatchNetTest/`.

| Finding | Evidence | Consequence |
|---|---|---|
| The watch reaches the servers directly | 28 to 109 ms on watch Wi-Fi with the phone in Airplane Mode | No WatchConnectivity relay for commands |
| It also works through the iPhone | 600 to 850 ms per request, phone nearby | Volume needs local-first handling (below) |
| With the phone nearby, the watch routes through it even with its own Wi-Fi on | Runs 1 and 2 identical | Expect the slow path most of the time at home |
| Configs sync through iCloud key-value storage | "2 config(s)" on every run, store `9J857XHJMC.show.nola.BetterSonos` | No setup on the watch |
| ATS must be `NSAllowsArbitraryLoads` alone | `NSAllowsLocalNetworking` made the system ignore it and block the public hosts (URLError -1022) | Copy the iOS app's Info.plist setting exactly |
| `NWPathMonitor` is wrong on watchOS | Reported "down" on every run while every request succeeded | Never gate a request on path status |
| The first request after a network change is slow | 5.7 s and 9.1 s internet checks right after switching | Timeout around 10 s; show progress, not an error, for the first few seconds |
| The config hostnames are public IPs behind a port forward | `203.0.113.10`, `203.0.113.20` | Works away from home whenever the watch has internet |

## Architecture

### Targets

Add a watchOS app target to `BetterSonos.xcodeproj` as a companion of the iOS app (`WKCompanionAppBundleIdentifier = show.nola.BetterSonos`), with `WKRunsIndependentlyOfCompanionApp = true`, since it never needs the phone app running. Bundle ID `show.nola.BetterSonos.watchkitapp`. It installs alongside the iOS app.

Entitlement: `com.apple.developer.ubiquity-kvstore-identifier = $(TeamIdentifierPrefix)show.nola.BetterSonos`, the same store as the iOS app. This is already proven to sign and sync.

### Shared package: `BetterSonosCore`

A local Swift package in the repo (`Packages/BetterSonosCore`), used by both targets. It holds the code that is already Foundation-only and free of main-actor ties after the last round of fixes:

- `Models.swift`: `NetworkConfig`, `Station`, `StationType`, `Zone`, `Track`, `StationCSV`, `URLInput`, `bestMatchingStation`
- `SonosHTTP` and `StationListBuilder`, moved out of `SonosViewModel.swift`
- `NetworkConfigStore`
- `AppSettingsStore` (needed for presets)
- `RedirectHandler`

Most of the extraction cost is access control: these types, their initializers and their properties all need `public`.

`SonosViewModel` stays in the iOS target. It carries SSE, station rebuild orchestration, accordion state and UIKit lifecycle hooks that the watch does not need.

### The watch must not write to iCloud

`NetworkConfigStore` writes in three places: `save()` from edits, `mergeFavorites` after each refresh, and the push-back in the iCloud merge when a local copy wins. A watch holding a stale copy could overwrite the phone's configs. Give the store a read-only mode, used by the watch, that disables every write path. `AppSettingsStore` needs the same, since its sinks write to iCloud on every change, including the initial load.

### Watch view model

A small `WatchRoomController` (`@MainActor`, `ObservableObject`) per selected network:

- Fetches `/zones` when the app becomes active (`scenePhase == .active`), when a room screen appears, and after every action.
- While the app is frontmost, polls every 15 s. Stops when inactive. No SSE: watch apps are suspended too quickly for a stream to be worth holding.
- Uses `SonosHTTP` for every request, with a 10 s timeout and `waitsForConnectivity = false`.
- Applies optimistic updates for play, pause and volume, then reconciles from the next `/zones`.

### Volume and the Digital Crown

Through the phone, each request costs 600 to 850 ms, so one request per Crown detent would lag badly and arrive out of order.

- Bind `digitalCrownRotation` to a local value and update the on-screen number immediately.
- Send `/<room>/volume/<n>` 300 ms after the Crown stops, with only the final value.
- While a change is pending or in flight, ignore server volume for that room, so a poll cannot snap the number back mid-turn.
- Refresh after the request completes.

For a group, the Crown should probably drive group volume. node-sonos-http-api has a `groupVolume` action, but it is not in `SonosAPIReference.md`; confirm the endpoint against the server before building on it.

### Fast path to pause

Persist the last network and room in `UserDefaults` and launch straight into that room. The common case, pausing whatever is playing, is then one tap after raising the wrist.

## Screens

1. **Networks.** A list of enabled configs. Skipped when only one is enabled.
2. **Rooms.** Groups by coordinator, with joiner count, now-playing line and a play state icon.
3. **Room.** Now playing, a large play/pause button and the volume value driven by the Crown. Phase 2 adds a Presets button.
4. **Presets (phase 2).** The filtered station list for the network; tap to play. Built on the watch with `StationListBuilder` (the test shows the watch can fetch CSVs directly), and cached in `UserDefaults` so it appears instantly on the next launch.

## Phases

Each phase ends with a build, a test on the real watch, and a commit.

0. **Extract `BetterSonosCore`.** Move the shared code, add `public`, add read-only modes. The iOS app must build and behave identically. No watch code yet.
1. **Watch app: rooms, play/pause, Crown volume.** Test on watch Wi-Fi alone and through the phone, using the same two cases as the network test.
2. **Presets.**
3. **Optional: a Smart Stack widget** with play/pause for the last room, using App Intents. The same intents would give Siri ("pause the kitchen") on both devices.

## Decisions needed

- **Companion or watch-only app.** Recommend companion with `WKRunsIndependentlyOfCompanionApp`, so it installs with the iOS app and still works without the phone.
- **Group volume or coordinator volume** on the Crown when a room is grouped. Recommend group volume, pending the endpoint check.
- **Mute on the watch.** Cheap to add with `/mute` and `/unmute`, but not in the stated scope.
- **Minimum watchOS.** The test used watchOS 10. Recommend 10 unless a later API is needed, most likely for the widget in phase 3.
- **`WatchNetTest/`.** Delete it once phase 1 works, or keep it as a diagnostic tool.

## Risks

- **Extraction churn.** Making the shared code public touches every model file. Phase 0 is isolated so any regression shows up in the iOS app before watch code exists.
- **Stale config overwrite.** Covered by read-only mode; worth a deliberate test: edit a config on the phone, open the watch app, and confirm the phone's edit survives.
- **Relay latency.** Covered by the volume design. Play and pause will still take most of a second through the phone; the optimistic update hides it.
