# A fake Sonos household: one HTTP port per player, answering the UPnP SOAP actions BonTon's
# DirectBackend uses, with live state. The layout covers a stereo pair (hidden partner), a
# home-theater satellite, a Bridge, a two-room group, a room whose volume query fails, and a
# Connect-style player with fixed line-level output, and a player that is in the layout but answers
# nothing else (going to sleep, rebooting, out of range).
# Usage: speaker.py BASE_PORT LOG     (players listen on BASE_PORT .. BASE_PORT+8)
import http.server, socketserver, sys, html, re, threading
BASE = int(sys.argv[1])
log = open(sys.argv[2], "a")
lock = threading.Lock()

# uuid: port offset, room, volume (None = query fails), mute, fixed output, invisible, bridge
PLAYERS = {
    "RINCON_K01400":      dict(port=0, room="Kitchen", volume=34, mute=False, fixed=False),
    "RINCON_TVL01400":    dict(port=1, room="TV Room", volume=45, mute=True, fixed=False),
    "RINCON_TVR01400":    dict(port=2, room="TV Room", volume=45, mute=True, fixed=False, invisible=True),
    "RINCON_SUB01400":    dict(port=3, room="TV Room", volume=0, mute=False, fixed=False, satellite=True),
    "RINCON_BED01400":    dict(port=4, room="Bedroom", volume=33, mute=False, fixed=False),
    "RINCON_BATH01400":   dict(port=5, room="Upstairs Bathroom", volume=None, mute=False, fixed=False),
    "RINCON_BRIDGE01400": dict(port=6, room="Bridge", volume=0, mute=False, fixed=False, bridge=True),
    "RINCON_BIG01400":    dict(port=7, room="Big Speakers", volume=100, mute=False, fixed=True),
    "RINCON_PATIO01400":  dict(port=8, room="Patio", volume=None, mute=False, fixed=False, silent=True),
}
# Group membership: player -> coordinator. Satellites and hidden partners follow their room.
COORD = {"RINCON_K01400": "RINCON_K01400", "RINCON_TVL01400": "RINCON_TVL01400", "RINCON_TVR01400": "RINCON_TVL01400",
         "RINCON_BED01400": "RINCON_BED01400", "RINCON_BATH01400": "RINCON_BED01400",
         "RINCON_BRIDGE01400": "RINCON_BRIDGE01400", "RINCON_BIG01400": "RINCON_BIG01400",
         "RINCON_PATIO01400": "RINCON_PATIO01400"}
MEDIA = {  # coordinator: [uri, title, transport state, metadata]
    "RINCON_K01400": ["x-sonos-vli:RINCON_K01400:2,spotify:abc", "Spotify", "PAUSED_PLAYBACK", None],
    "RINCON_TVL01400": ["x-rincon-stream:RINCON_TVL01400:0", "Line-In", "PAUSED_PLAYBACK", None],
    "RINCON_BED01400": ["x-sonosapi-stream:s1?sid=254", "Radio Woodstock 100.1", "PLAYING", None],
    "RINCON_BIG01400": ["x-sonosapi-stream:s2?sid=254", "Classic American Top 40", "STOPPED", None],
}
# Like real speakers: a stopped live stream ignores Play until it is reloaded with SetAVTransportURI.
RELOADED = set()
QUEUE = {}  # coordinator: [enqueued uris]
FAVORITES = [  # title, uri, upnp class
    ("WWNO", "x-sonosapi-stream:s3?sid=254&flags=8224&sn=0", "object.item.audioItem.audioBroadcast"),
    ("FIP", "x-rincon-mp3radio://https://example.com/fip-hifi.aac", "object.item.audioItem.audioBroadcast"),
    ("Radio Woodstock 100.1", "x-sonosapi-stream:s1?sid=254&flags=8224&sn=0", "object.item.audioItem.audioBroadcast"),
    ("Dinner Jazz", "x-rincon-cpcontainer:1006206cplaylist%3a123?sid=12&flags=8300&sn=1", "object.container.playlistContainer"),
]
def is_radio(uri): return uri.startswith(("x-sonosapi-stream:", "x-rincon-mp3radio:", "x-sonosapi-radio:", "hls-radio:"))
def resmd(title, cls): return f'<DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"><item id="F" parentID="F" restricted="true"><dc:title>{title}</dc:title><upnp:class>{cls}</upnp:class></item></DIDL-Lite>'
def title_of(metadata):
    m = re.search(r"<dc:title>(.*?)</dc:title>", metadata or "")
    return html.unescape(m.group(1)) if m else None
GROUP = {}  # coordinator: [volume, mute]

def loc(uuid): return f"http://127.0.0.1:{BASE + PLAYERS[uuid]['port']}/xml/device_description.xml"
def member_xml(uuid, inner=""):
    p = PLAYERS[uuid]
    attrs = f'UUID="{uuid}" Location="{loc(uuid)}" ZoneName="{p["room"]}"'
    if p.get("invisible"): attrs += ' Invisible="1" ChannelMapSet="RINCON_TVL01400:LF,LF;RINCON_TVR01400:RF,RF"'
    if p.get("bridge"): attrs += ' IsZoneBridge="1"'
    if uuid == "RINCON_TVL01400": attrs += ' ChannelMapSet="RINCON_TVL01400:LF,LF;RINCON_TVR01400:RF,RF"'
    return f"<ZoneGroupMember {attrs}>{inner}</ZoneGroupMember>"
def topology():
    groups = ""
    for coordinator in sorted(set(COORD.values())):
        members = ""
        for uuid, c in COORD.items():
            if c != coordinator: continue
            inner = f'<Satellite UUID="RINCON_SUB01400" Location="{loc("RINCON_SUB01400")}" ZoneName="TV Room" Invisible="1"/>' if uuid == "RINCON_TVL01400" else ""
            members += member_xml(uuid, inner)
        groups += f'<ZoneGroup Coordinator="{coordinator}" ID="{coordinator}">{members}</ZoneGroup>'
    return f"<ZoneGroupState><ZoneGroups>{groups}</ZoneGroups><VanishedDevices/></ZoneGroupState>"
def didl(title): return html.escape(f'<DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/"><item><dc:title>{title}</dc:title></item></DIDL-Lite>')
def arg(body, name):
    m = re.search(f"<{name}>(.*?)</{name}>", body, re.S)
    return html.unescape(m.group(1)) if m else ""

def handler_for(uuid):
    class H(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        def log_message(self, *a): pass
        def reply(self, action, fields=None, code=200):
            body = "".join(f"<{k}>{v}</{k}>" for k, v in (fields or {}).items())
            xml = f'<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:{action}Response xmlns:u="x">{body}</u:{action}Response></s:Body></s:Envelope>'.encode()
            self.send_response(code); self.send_header("Content-Type", "text/xml"); self.send_header("Content-Length", str(len(xml))); self.end_headers(); self.wfile.write(xml)
        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
            action = self.headers.get("SOAPACTION", "").strip('"').split("#")[-1]
            p = PLAYERS[uuid]
            log.write(f"{p['room']} {uuid} {action} {arg(body, 'DesiredVolume') or arg(body, 'DesiredMute') or arg(body, 'CurrentURI')}\n"); log.flush()
            with lock:
                coordinator = COORD.get(uuid, uuid)
                if action == "GetZoneGroupState": return self.reply(action, {"ZoneGroupState": html.escape(topology())})
                if p.get("silent"): return self.reply(action, {}, 500)
                if action == "GetTransportInfo": return self.reply(action, {"CurrentTransportState": MEDIA.get(uuid, ["", "", "STOPPED", None])[2]})
                if action == "GetMediaInfo":
                    if uuid in MEDIA:
                        uri, title, _, metadata = MEDIA[uuid]
                        return self.reply(action, {"CurrentURI": html.escape(uri), "CurrentURIMetaData": html.escape(metadata) if metadata else didl(title)})
                    return self.reply(action, {"CurrentURI": f"x-rincon:{coordinator}", "CurrentURIMetaData": ""})
                if action == "GetVolume":
                    return self.reply(action, {}, 500) if p["volume"] is None else self.reply(action, {"CurrentVolume": str(p["volume"])})
                if action == "GetMute": return self.reply(action, {"CurrentMute": "1" if p["mute"] else "0"})
                if action == "GetOutputFixed": return self.reply(action, {"CurrentFixed": "1" if p["fixed"] else "0"})
                if action == "GetGroupVolume": return self.reply(action, {"CurrentVolume": str(GROUP.get(uuid, [40, False])[0])})
                if action == "GetGroupMute": return self.reply(action, {"CurrentMute": "1" if GROUP.get(uuid, [40, False])[1] else "0"})
                if action == "Browse":
                    items = "".join(
                        f'<item id="FV:2/{i}" parentID="FV:2" restricted="false"><dc:title>{html.escape(t)}</dc:title>'
                        f'<upnp:class>object.itemobject.item.sonos-favorite</upnp:class><res protocolInfo="x">{html.escape(u)}</res>'
                        f'<r:resMD>{html.escape(resmd(t, c))}</r:resMD></item>'
                        for i, (t, u, c) in enumerate(FAVORITES))
                    result = f'<DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/">{items}</DIDL-Lite>'
                    return self.reply(action, {"Result": html.escape(result), "NumberReturned": str(len(FAVORITES))})
                # Commands. Like real speakers, transport commands only work on a coordinator.
                if action in ("Play", "Pause"):
                    if uuid not in MEDIA: return self.reply(action, {}, 500)
                    media = MEDIA[uuid]
                    if action == "Pause":
                        # Live radio can't pause: it stops, and needs reloading before Play works again.
                        media[2] = "STOPPED" if is_radio(media[0]) else "PAUSED_PLAYBACK"
                        RELOADED.discard(uuid)
                    elif media[2] == "STOPPED" and is_radio(media[0]) and uuid not in RELOADED:
                        pass  # accepted, but nothing starts
                    else:
                        media[2] = "PLAYING"
                    return self.reply(action)
                if action == "RemoveAllTracksFromQueue": QUEUE[uuid] = []; return self.reply(action)
                if action == "AddURIToQueue": QUEUE.setdefault(uuid, []).append(arg(body, "EnqueuedURI")); return self.reply(action)
                if action == "SetVolume":
                    if p["fixed"]: return self.reply(action, {}, 500)
                    p["volume"] = int(arg(body, "DesiredVolume")); return self.reply(action)
                if action == "SetMute": p["mute"] = arg(body, "DesiredMute") == "1"; return self.reply(action)
                if action == "SnapshotGroupVolume": return self.reply(action)
                if action == "SetGroupVolume": GROUP.setdefault(uuid, [40, False])[0] = int(arg(body, "DesiredVolume")); return self.reply(action)
                if action == "SetGroupMute": GROUP.setdefault(uuid, [40, False])[1] = arg(body, "DesiredMute") == "1"; return self.reply(action)
                if action == "SetAVTransportURI":
                    uri = arg(body, "CurrentURI")
                    if uri.startswith("x-rincon:"):
                        COORD[uuid] = uri[len("x-rincon:"):]
                        MEDIA.pop(uuid, None)
                        return self.reply(action)
                    metadata = arg(body, "CurrentURIMetaData")
                    title = "Queue" if uri.startswith("x-rincon-queue:") else (title_of(metadata) or "Stream")
                    MEDIA[uuid] = [uri, title, "STOPPED", metadata or None]
                    RELOADED.add(uuid)
                    return self.reply(action)
                if action == "BecomeCoordinatorOfStandaloneGroup":
                    COORD[uuid] = uuid
                    MEDIA.setdefault(uuid, ["", "", "STOPPED", None])
                    return self.reply(action)
            self.reply(action, {}, 500)
    return H

class S(socketserver.ThreadingMixIn, http.server.HTTPServer): daemon_threads = True
for uuid, p in PLAYERS.items():
    threading.Thread(target=S(("127.0.0.1", BASE + p["port"]), handler_for(uuid)).serve_forever, daemon=True).start()
threading.Event().wait()
