# Accepts connections and never answers, so a request stays in flight until it's cancelled or times out.
# Usage: hang.py PORT
import socket, sys, threading, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(16)
held = []
while True:
    conn, _ = s.accept(); held.append(conn)
