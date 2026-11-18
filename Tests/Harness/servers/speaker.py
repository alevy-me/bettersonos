# A fake Sonos household: one HTTP port per player, answering the UPnP SOAP actions BonTon's
# DirectBackend uses. The layout covers a stereo pair (hidden partner), a home-theater satellite,
# a Bridge, a two-room group, and one room whose volume query fails.
# Usage: speaker.py BASE_PORT LOG     (players listen on BASE_PORT .. BASE_PORT+6)
import http.server, socketserver, sys, html, threading
BASE = int(sys.argv[1])
log = open(sys.argv[2], "a")
PLAYERS = {  # uuid: (port offset, room, volume, mute)
    "RINCON_K01400": (0, "Kitchen", 34, "0"),
    "RINCON_TVL01400": (1, "TV Room", 45, "1"),
    "RINCON_TVR01400": (2, "TV Room", 45, "1"),
    "RINCON_SUB01400": (3, "TV Room", 0, "0"),
    "RINCON_BED01400": (4, "Bedroom", 33, "0"),
    "RINCON_BATH01400": (5, "Upstairs Bathroom", None, "0"),  # volume query fails
    "RINCON_BRIDGE01400": (6, "Bridge", 0, "0"),
}
MEDIA = {  # coordinator uuid: (uri, title, state)
    "RINCON_K01400": ("x-sonos-vli:RINCON_K01400:2,spotify:abc", "Spotify", "PAUSED_PLAYBACK"),
    "RINCON_TVL01400": ("x-rincon-stream:RINCON_TVL01400:0", "Line-In", "PAUSED_PLAYBACK"),
    "RINCON_BED01400": ("x-sonosapi-stream:s1?sid=254", "Radio Woodstock 100.1", "PLAYING"),
}
def loc(uuid): return f"http://127.0.0.1:{BASE + PLAYERS[uuid][0]}/xml/device_description.xml"
TOPOLOGY = f"""<ZoneGroupState><ZoneGroups>
<ZoneGroup Coordinator="RINCON_K01400" ID="g1"><ZoneGroupMember UUID="RINCON_K01400" Location="{loc('RINCON_K01400')}" ZoneName="Kitchen"/></ZoneGroup>
<ZoneGroup Coordinator="RINCON_TVL01400" ID="g2">
  <ZoneGroupMember UUID="RINCON_TVR01400" Location="{loc('RINCON_TVR01400')}" ZoneName="TV Room" Invisible="1" ChannelMapSet="RINCON_TVL01400:LF,LF;RINCON_TVR01400:RF,RF"/>
  <ZoneGroupMember UUID="RINCON_TVL01400" Location="{loc('RINCON_TVL01400')}" ZoneName="TV Room" ChannelMapSet="RINCON_TVL01400:LF,LF;RINCON_TVR01400:RF,RF">
    <Satellite UUID="RINCON_SUB01400" Location="{loc('RINCON_SUB01400')}" ZoneName="TV Room" Invisible="1"/>
  </ZoneGroupMember></ZoneGroup>
<ZoneGroup Coordinator="RINCON_BED01400" ID="g3">
  <ZoneGroupMember UUID="RINCON_BATH01400" Location="{loc('RINCON_BATH01400')}" ZoneName="Upstairs Bathroom"/>
  <ZoneGroupMember UUID="RINCON_BED01400" Location="{loc('RINCON_BED01400')}" ZoneName="Bedroom"/></ZoneGroup>
<ZoneGroup Coordinator="RINCON_BRIDGE01400" ID="g4"><ZoneGroupMember UUID="RINCON_BRIDGE01400" Location="{loc('RINCON_BRIDGE01400')}" ZoneName="Bridge" IsZoneBridge="1"/></ZoneGroup>
</ZoneGroups><VanishedDevices/></ZoneGroupState>"""
def didl(title): return html.escape(f'<DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/"><item><dc:title>{title}</dc:title></item></DIDL-Lite>')

def handler_for(uuid):
    offset, room, volume, mute = PLAYERS[uuid]
    class H(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        def log_message(self, *a): pass
        def reply(self, action, fields, code=200):
            body = "".join(f"<{k}>{v}</{k}>" for k, v in fields.items())
            xml = f'<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:{action}Response xmlns:u="x">{body}</u:{action}Response></s:Body></s:Envelope>'.encode()
            self.send_response(code); self.send_header("Content-Type", "text/xml"); self.send_header("Content-Length", str(len(xml))); self.end_headers(); self.wfile.write(xml)
        def do_POST(self):
            self.rfile.read(int(self.headers.get("Content-Length", 0)))
            action = self.headers.get("SOAPACTION", "").strip('"').split("#")[-1]
            log.write(f"{room}/{uuid} {action}\n"); log.flush()
            if action == "GetZoneGroupState": return self.reply(action, {"ZoneGroupState": html.escape(TOPOLOGY)})
            if action == "GetTransportInfo": return self.reply(action, {"CurrentTransportState": MEDIA.get(uuid, ("", "", "STOPPED"))[2]})
            if action == "GetMediaInfo":
                uri, title, _ = MEDIA.get(uuid, (f"x-rincon:{uuid}", None, ""))
                return self.reply(action, {"CurrentURI": html.escape(uri), "CurrentURIMetaData": didl(title) if title else ""})
            if action == "GetVolume":
                return self.reply(action, {}, 500) if volume is None else self.reply(action, {"CurrentVolume": str(volume)})
            if action == "GetMute": return self.reply(action, {"CurrentMute": mute})
            if action == "GetGroupVolume": return self.reply(action, {"CurrentVolume": "40"})
            if action == "GetGroupMute": return self.reply(action, {"CurrentMute": "0"})
            if action == "Browse":
                items = "".join(f"<item><dc:title>{t}</dc:title></item>" for t in ["WWNO", "FIP", "Radio Woodstock 100.1"])
                return self.reply(action, {"Result": html.escape(f'<DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/">{items}</DIDL-Lite>'), "NumberReturned": "3"})
            self.reply(action, {}, 500)
    return H
class S(socketserver.ThreadingMixIn, http.server.HTTPServer): daemon_threads = True
for uuid, (offset, *_ ) in PLAYERS.items():
    threading.Thread(target=S(("127.0.0.1", BASE + offset), handler_for(uuid)).serve_forever, daemon=True).start()
threading.Event().wait()
