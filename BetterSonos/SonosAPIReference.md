# Sonos App Action → Server API Mapping

This document tracks the exact backend HTTP calls needed to support various user actions in the BetterSonos app.

---

## Playback Controls

### ▶️ Play
**Call:** `GET /<room>/play`

### ⏸️ Pause
**Call:** `GET /<room>/pause`

### 📡 Set Stream URL
**Call:** 
```
GET /<room>/setavtransporturi/x-rincon-mp3radio:<encoded_stream_url>
```

Example:
```
GET /Kitchen/setavtransporturi/x-rincon-mp3radio:%2F%2Fhttps%3A%2F%2Ficecast.radiofrance.fr%2Ffip-hifi.aac
```

---

## Volume Controls

### 🔼 Increment Volume
**Flow:**
1. `GET /<room>/volume` (retrieve current)
2. Calculate `current + delta`
3. `GET /<room>/volume/<new_value>`

### 🔽 Decrement Volume
**Flow:**
1. `GET /<room>/volume`
2. Calculate `current - delta`
3. `GET /<room>/volume/<new_value>`

### 🎚️ Set Volume
**Call:** `GET /<room>/volume/<int>`

### 📊 Get Current Volume
**Call:** `GET /<room>/volume`

Returns: integer (0–100)

---

## Mute Controls

### 🔇 Mute Room
**Call:** `GET /<room>/mute`

### 🔊 Unmute Room
**Call:** `GET /<room>/unmute`

### 🔁 Toggle Mute
**Flow:**
1. `GET /<room>/state`
2. Check `mute` value
3. Call `/mute` or `/unmute` accordingly

---

## Group Controls

### ➕ Join Room to Group
**Call:** `GET /<coordinator>/group/<joiner>`

### ➖ Leave Group
**Call:** `GET /<room>/leave`

---

## State & Metadata

### 📡 Get All Zones
**Call:** `GET /zones`

Returns JSON list of groups, coordinators, members.

### 🧾 Get Current Track Info
**Call:** `GET /<room>/state`

Returns JSON with:
- `currentTrack` (including stream URI)
- `volume`, `mute`
- `playbackState` (e.g. PLAYING, STOPPED)

---

## 🚀 App Lifecycle Actions

### When the App Launches (Cold Start)
1. **Get Current Zones**
   ```
   GET /zones
   ```
2. **For each zone or room:**
   - Fetch full state (volume, mute, stream, play state)
     ```
     GET /<room>/state
     ```

3. Optionally, **ping the server** to confirm it's alive or log version
   ```
   GET /
   ```

### When App Returns to Foreground
(Same as above, but skip optional call)
1. `GET /zones`
2. For each room:
   - `GET /<room>/state`

---

## 🔘 Preset Button Tap

If you tap a preset (like "FIP to Kitchen + Living Room at 40%"):
1. **Set Stream URL on Coordinator**
   ```
   GET /<coordinator>/setavtransporturi/x-rincon-mp3radio:<encoded_url>
   ```
2. **Join Rooms**
   For each room in the group except coordinator:
   ```
   GET /<coordinator>/group/<room>
   ```
3. **Set Volume for Each Room**
   ```
   GET /<room>/volume/<int>
   ```
4. **Play Coordinator**
   ```
   GET /<coordinator>/play
   ```

---

## 🧼 Optional Housekeeping

### Ungroup a Room
```
GET /<room>/leave
```

### Stop Playback
```
GET /<room>/pause
```

---

## 🧪 Ideas You May Want to Support

### Reboot a Room (diagnostic)
```
GET /<room>/reboot
```
> Requires supported hardware / API extensions

### List All Saved Presets (if server supports it)
```
GET /presets
```

### Trigger a Rescan of Music Library
```
GET /rescan
```

### Get System Diagnostics / Healthcheck
```
GET /status
```
