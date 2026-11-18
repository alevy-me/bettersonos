# Direct Speaker Control: Plan

## Goal

A user with no node-sonos-http-api server installs BonTon, and it works on their home network with no setup. Away from home it does nothing for them, by design. Users with a server keep everything they have today.

## Discovery and what the user sees

Autodiscovery runs first, and keeps running in the background of the app's life.

**When discovery runs:** at launch, on returning to the foreground, and when the phone changes networks (joining the home Wi-Fi brings the speakers back without reopening the app). Throttled to once every 10 minutes or so, except after a network change. Each run is a Bonjour browse of a second or two, then one layout request.

**What the user sees depends on whether any network exists, not on first run:**

- **No networks configured, and discovery finds a household:** BonTon creates a network for it and shows it. Adding a server network is then available only in Settings.
- **No networks configured, and discovery finds nothing:** the empty state offers Add a Network (a server), with an explanation and a Search Again button. It appears every time until a network exists. Local network permission denied gets its own message, with a link to Settings.
- **Networks already exist:** discovery is invisible. A new household is added with a brief "Found a new Sonos system" note. Changed speaker addresses update quietly.

**A direct network away from home stays visible, marked unavailable.** Its row reads "Not available on this network" ("Offline" on the watch, where space is short). Its rooms and controls aren't shown, so there's no stale state. It returns as soon as its household is reachable again. A server network that fails still shows its error as today, because that's a real fault rather than being away.

A direct network is reachable when Bonjour finds its household or a cached speaker address answers. The watch, which can't browse, uses cached addresses only. At launch, a brief spinner covers the first check, so a network doesn't flash between states.

## What the network checks established

All checks were read-only, on a real home network on 2026-11-18.

| Finding | Evidence | Consequence |
|---|---|---|
| Bonjour finds every speaker | `_sonos._tcp` listed all 8 speakers within a second | No multicast entitlement; one local network prompt |
| Each Bonjour record carries the control address | TXT `location=http://192.168.1.166:1400/xml/device_description.xml` | No extra lookup |
| Each record names its household | TXT `hhid=Sonos_XXXX…` | One network per household, created automatically |
| Any one speaker reports the whole layout | ZoneGroupTopology `GetZoneGroupState` returned all 5 groups | Discovery only has to reach one speaker |
| Stereo pairs and satellites are marked | The TV Room's right speaker is `Invisible="1"` with a `ChannelMapSet` | Show visible members only; Bonjour's duplicate TV Room is dropped |
| Speakers span subnets | two subnets | Bonjour saw both from the Mac; watch for a phone that can't |
| The loaded source's name is exact | `GetMediaInfo` title: "Spotify", "Line-In", station names | Source-only display with no guessing |
| Stopped streams keep their metadata | Stopped TuneIn station still returns full DIDL in `CurrentURIMetaData` | Any stopped station restarts, preset or not |
| Track metadata is unusable | `GetPositionInfo` titles were ad-bumper URLs and HLS file names | Confirms source-only display |
| Fixed volume is detectable | `GetOutputFixed` is 1 for the Connect, 0 elsewhere | Replaces the hard-coded fixed-volume list |

## Network model

`NetworkConfig` gains a kind:

- **Server:** as today, with a `baseURL`.
- **Local:** a Sonos household, identified by `hhid`, with a cache of speaker addresses (`uuid` to `host:port`).

Existing configs decode as Server, so there is no migration step.

A local network's `id` is derived from its `hhid`, so the phone and an iPad that both discover the same household produce the same config, and the iCloud merge treats them as one. Without this, every device would create its own copy.

The speaker address cache syncs through iCloud with the config, which is how the watch learns where the speakers are.

## Backend layer

A `SonosBackend` protocol in `BetterSonosCore`, with two implementations:

- **ServerBackend:** the current `SonosHTTP` calls, unchanged.
- **DirectBackend:** SOAP over HTTP to port 1400.

Both return the existing `Zone` model, so the iOS view model, the watch controller, presets, `NowPlaying` and Siri keep working. Each consumer asks the config for its backend instead of building server URLs.

### Direct command set

| App action | Direct call |
|---|---|
| Rooms and groups | ZoneGroupTopology `GetZoneGroupState` |
| Playback state | AVTransport `GetTransportInfo` (coordinator) |
| Source name | AVTransport `GetMediaInfo`, title from `CurrentURIMetaData` |
| Play, pause | AVTransport `Play`, `Pause` (coordinator) |
| Restart a stopped stream | AVTransport `SetAVTransportURI` with the current URI and metadata, then `Play` |
| Room volume and mute | RenderingControl `SetVolume`, `SetMute` (the room's visible speaker) |
| Group volume and mute | GroupRenderingControl `SetGroupVolume`, `SetGroupMute` (coordinator) |
| Fixed volume | RenderingControl `GetOutputFixed` |
| Join, leave | AVTransport `SetAVTransportURI` to `x-rincon:<coordinator>`; `BecomeCoordinatorOfStandaloneGroup` |
| Sonos favorites | ContentDirectory `Browse` on `FV:2`, then `SetAVTransportURI` with the favorite's URI and metadata |
| CSV and manual streams | `SetAVTransportURI` to `x-rincon-mp3radio://…` with minimal DIDL |
| Line-in | `SetAVTransportURI` to `x-rincon-stream:<uuid>` |

A refresh costs one topology call, plus transport and media for each coordinator, plus volume and mute for each visible speaker, all concurrent. For a household of 7 visible speakers in 5 groups, that's about 25 small requests.

### Updates

No push. The speakers' event subscriptions need the app to run an HTTP server, which iOS won't allow in the background. The iOS app polls direct networks every 5 seconds while it's in the foreground and refreshes after every action. The watch keeps its 15-second poll.

## Watch

The watch doesn't browse for speakers. It uses the synced address cache and sends SOAP requests with `URLSession`, as it sends HTTP today.

If the cached addresses go stale, the watch asks any address that still answers for the layout, which refreshes the rest. If none answers, it shows "Open BonTon on your iPhone to find your speakers."

Port 1400 from the watch is not yet verified; the network test only reached the node server. That's the first check in phase 4.

## Siri

`SonosDirectory` resolves rooms through each network's backend. A direct-only network that isn't reachable makes Siri say "BonTon can't reach your speakers from here."

## Server and direct for the same household

A household can have both a server config and a discovered local network. They're matched by overlapping player IDs, since `/zones` doesn't report the household ID, and merged into one network entry.

**Precedence (decided): direct when reachable, server otherwise, as a hybrid.**

- **At home:** state and commands go direct, which skips the round trip through the public hostname and gives exact source names and restart for any stopped stream. If the server is also reachable, its SSE stream stays open purely as a "something changed" signal that triggers a direct refresh, so live updates survive without the server carrying any commands. If the server is down, direct polling takes over.
- **Away:** everything goes through the server, as today.
- **Choosing the path:** at launch, on foreground and on network change. If a cached speaker answers within about a second, direct; otherwise server. The choice holds for the session, so it can't flap. A direct request that fails switches to the server immediately and re-probes later.
- **Visibility:** no indicator on the main screens; the current path shows in Settings for troubleshooting.

## Platform requirements

- iOS Info.plist: `NSLocalNetworkUsageDescription`, and `NSBonjourServices` with `_sonos._tcp`.
- ATS: plain HTTP to speaker IPs is already covered by `NSAllowsArbitraryLoads`.
- No new entitlements.

## Phases

Each phase ends with a build, a test on real speakers, and a commit.

0. **Backend layer.** Introduce `SonosBackend` and move the current calls into `ServerBackend`. No behavior change.
1. **Discovery and reading.** Bonjour browsing, topology, and state into `Zone`; local `NetworkConfig`; the onboarding rule. Rooms and sources appear; controls can still be inactive.
2. **Direct commands.** Play, pause, volume, mute, group volume and mute, join, leave; automatic fixed volume.
3. **Direct presets.** Favorites with metadata, CSV and manual streams, line-in, restarting any stopped stream.
4. **Watch and Siri on direct networks.** Verify port 1400 from the watch first.
5. **Merge server and direct networks** for the same household, with the hybrid precedence above.

## Decisions needed

- **Name for a discovered household.** Sonos doesn't publish one. Recommend "Home", renamable, and "Home 2" for a second household.
- **The hard-coded fixed-volume list.** Recommend removing it once phase 2 lands. It holds only a placeholder ID, and server networks keep Disable Volume Control.
- **iOS poll interval for direct networks.** Recommend 5 seconds in the foreground, when no server event stream is available.

Decided: a direct network away from home shows as "Not available on this network", not hidden; a household with both modes is one merged network, direct-first with the server's SSE as a change signal.

## Risks

- **Unofficial API.** Sonos's local UPnP control has been stable for years and other projects depend on it, but Sonos could change it. Server networks are unaffected.
- **Subnets.** A phone on a subnet that Bonjour doesn't reach would find nothing. Cached speaker addresses still answer across subnets if the network routes them; otherwise the empty state (Add a Network) covers it.
- **App Store review**, if BonTon is ever published: the local network prompt needs a clear reason, and the reviewer has to be on a network with Sonos speakers to see the app work.
- **S1 speakers.** Untested. They use the same UPnP services, but expect differences.
