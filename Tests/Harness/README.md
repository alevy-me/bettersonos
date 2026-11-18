# Fake-server tests

These tests run the real app code (the shared package, the iOS view model, the watch controller and the Siri intents) on the Mac against small Python servers that imitate node-sonos-http-api. No speakers, simulators or devices are involved.

Run them with:

```
Tests/Harness/run_all.sh
```

The script builds everything from the current sources into a temporary folder, starts the fake servers, runs each test with a 90-second timeout, and ends with `ALL TESTS PASSED` or `SOME TESTS FAILED` (exit status 1). A test that fails to build is reported, never run from an old binary.

## What's covered

| Test | Checks |
|---|---|
| `models` | CSV parsing, station matching, URL encoding, unknown station types, read-only stores |
| `vm` | The iOS view model connects, loads rooms, and deallocates (closing its SSE stream) |
| `watch` | Watch volume (immediate display, single send, stale polls ignored), group volume and mute, pause, fixed volume |
| `watch-dealloc` | The watch controller deallocates after polling and actions |
| `sole-playing` | Opening to the only speaker or group playing, across networks |
| `presets` | Watch presets: sources, cache, playing, highlighting, failed rebuilds |
| `radio-watch`, `radio-siri` | Restarting stopped live radio by reloading its preset |
| `intents` | All Siri intents, including ambiguous rooms, fixed volume and unreachable networks |
| `now-playing` | Source-only now-playing text, against metadata recorded from real speakers |

## Fixtures and tools

- `fixtures/captured-states.jsonl`: every distinct track-metadata state recorded from two real Sonos systems while stations loaded and switched. Speaker IDs are replaced with placeholders.
- `tools/capture.py`: the read-only recorder that produced it. `capture.py OUT.jsonl SECONDS home=http://host:5005 [name=url ...]`

## Adding a test

Add a folder with a `main.swift` that prints `PASS` or `FAIL` lines, then add a `build` and a `run` line to `run_all.sh`. App sources are copied in by the script, so the test sees current code.
