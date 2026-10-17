"""Isolated CDP transport fixture. Never connects to a real client/account."""
import base64
import hashlib
import json
from pathlib import Path
import socket
import socketserver
import struct
import sys
import threading
import time

port_path = Path(sys.argv[1])
count_lock = threading.Lock()
discovery_count = 0


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        line = self.rfile.readline()
        if not line:
            return
        headers = {}
        while True:
            value = self.rfile.readline().strip()
            if not value:
                break
            key, value = value.split(b":", 1)
            headers[key.lower()] = value.strip()
        if headers.get(b"upgrade", b"").lower() != b"websocket":
            global discovery_count
            with count_lock:
                discovery_count += 1
                port_path.with_suffix('.requests').write_text(str(discovery_count))
            if port_path.with_suffix('.offline').exists():
                self.wfile.write(b"HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                return
            port = self.server.server_address[1]
            body = json.dumps([
                {"id": "main", "type": "page", "url": "app://-/index.html", "webSocketDebuggerUrl": f"ws://127.0.0.1:{port}/socket"},
                {"id": "pet", "type": "page", "url": "app://-/index.html?%6fverlay=pet"},
                {"id": "web", "type": "page", "url": "https://example.com/index.html"},
            ]).encode()
            self.wfile.write(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " + str(len(body)).encode() + b"\r\nConnection: close\r\n\r\n" + body)
            return
        accept = base64.b64encode(hashlib.sha1(headers[b"sec-websocket-key"] + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest())
        self.wfile.write(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + b"\r\n\r\n")
        lock = threading.Lock()

        def reply(message, delay=0):
            time.sleep(delay)
            payload = json.dumps(message).encode()
            frame = bytes([0x81, len(payload)]) if len(payload) < 126 else b"\x81\x7e" + struct.pack("!H", len(payload))
            try:
                with lock:
                    self.wfile.write(frame + payload)
            except (OSError, ValueError):
                pass

        try:
            while True:
                head = self.rfile.read(2)
                if len(head) != 2 or head[0] & 0x0F == 8:
                    return
                length = head[1] & 0x7F
                if length == 126:
                    length = struct.unpack("!H", self.rfile.read(2))[0]
                elif length == 127:
                    length = struct.unpack("!Q", self.rfile.read(8))[0]
                if length > 1_000_000:
                    return
                mask = self.rfile.read(4) if head[1] & 0x80 else b""
                payload = self.rfile.read(length)
                if mask:
                    payload = bytes(value ^ mask[i % 4] for i, value in enumerate(payload))
                request = json.loads(payload)
                expression = request.get("params", {}).get("expression")
                result = {"id": request["id"], "result": {}}
                if expression == "timeout":
                    continue
                if expression == "rpc-error":
                    result = {"id": request["id"], "error": {"message": "fixture error"}}
                elif expression == "exception":
                    result["result"] = {"exceptionDetails": {"text": "fixture exception"}}
                elif expression:
                    result["result"] = {"result": {"value": {"ok": True}}}
                threading.Thread(target=reply, args=(result, 0.05 if expression == "slow" else 0), daemon=True).start()
        except (OSError, ValueError, json.JSONDecodeError):
            return


class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True


with Server(("127.0.0.1", 0), Handler) as server:
    Path(sys.argv[1]).write_text(str(server.server_address[1]))
    server.serve_forever()
