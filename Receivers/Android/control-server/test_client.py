#!/usr/bin/env python3
"""Exercises a running Teras control server over an adb-forwarded TCP port.

Usage:
    python3 test_client.py <port> [--no-click]

Speaks protocol v1 from docs/CONTROL.md: HELLO, a two-second pointer circle,
a right-button click, a scroll, KEYCODE_BACK, the text "teras", then BYE.
Every inbound frame is printed; ERROR frames are counted and reported at the
end so a silent injection failure cannot pass as success.
"""

import math
import socket
import struct
import sys
import threading
import time

HELLO = 0x01
POINTER_MOVE = 0x10
BUTTON = 0x11
SCROLL = 0x12
KEY = 0x20
TEXT = 0x21
GET_DISPLAY = 0x30
SET_POINTER_VISIBLE = 0x31
PING = 0x32
BYE = 0x40

DISPLAY_INFO = 0x80
ERROR = 0x81
PONG = 0x82
READY = 0x8F

KEYCODE_BACK = 4

state = {
    "display": None,
    "ready": None,
    "errors": [],
    "stop": False,
}


def frame(msg_type, payload=b""):
    return struct.pack(">HB", 1 + len(payload), msg_type) + payload


def recv_exactly(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


def reader(sock):
    while not state["stop"]:
        head = recv_exactly(sock, 3)
        if head is None:
            print("<- stream closed by server")
            return
        length, msg_type = struct.unpack(">HB", head)
        payload = recv_exactly(sock, length - 1) if length > 1 else b""
        if payload is None:
            print("<- truncated payload")
            return
        describe(msg_type, payload)


def describe(msg_type, payload):
    if msg_type == DISPLAY_INFO:
        width, height, rotation, density = struct.unpack(">IIBf", payload)
        state["display"] = (width, height, rotation, density)
        print(f"<- DISPLAY_INFO width={width} height={height} "
              f"rotation={rotation} density={density:.4f}")
    elif msg_type == READY:
        api, flags = payload[0], payload[1]
        state["ready"] = (api, flags)
        print(f"<- READY apiLevel={api} flags=0x{flags:02x} "
              f"(injection works: {bool(flags & 1)})")
    elif msg_type == PONG:
        (echo,) = struct.unpack(">Q", payload)
        print(f"<- PONG echo={echo}")
    elif msg_type == ERROR:
        message = payload.decode("utf-8", "replace")
        state["errors"].append(message)
        print(f"<- ERROR {message}")
    else:
        print(f"<- unknown type 0x{msg_type:02x} payload={payload!r}")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    port = int(sys.argv[1])
    click = "--no-click" not in sys.argv

    sock = socket.create_connection(("127.0.0.1", port), timeout=10)
    sock.settimeout(None)
    threading.Thread(target=reader, args=(sock,), daemon=True).start()

    def send(msg_type, payload=b""):
        sock.sendall(frame(msg_type, payload))

    print("-> HELLO")
    send(HELLO, bytes([1]))

    deadline = time.time() + 5
    while time.time() < deadline and state["ready"] is None:
        time.sleep(0.05)
    if state["ready"] is None:
        print("!! no READY within 5 s")
        return 1
    if state["display"] is None:
        print("!! no DISPLAY_INFO")
        return 1

    width, height, _rotation, _density = state["display"]
    cx, cy = width / 2.0, height / 2.0

    print("-> PING")
    send(PING, struct.pack(">Q", 0x0123456789ABCDEF))
    time.sleep(0.3)

    print(f"-> POINTER_MOVE circle around ({cx:.0f}, {cy:.0f}) for 2 s")
    radius = min(width, height) * 0.25
    start = time.time()
    frames = 0
    while time.time() - start < 2.0:
        t = (time.time() - start) / 2.0
        angle = t * 4 * math.pi
        send(POINTER_MOVE, struct.pack(">ff",
                                       cx + radius * math.cos(angle),
                                       cy + radius * math.sin(angle)))
        frames += 1
        time.sleep(1 / 60.0)
    print(f"   sent {frames} POINTER_MOVE frames")

    if click:
        print("-> BUTTON right down/up at centre")
        send(BUTTON, struct.pack(">BBff", 1, 1, cx, cy))
        time.sleep(0.08)
        send(BUTTON, struct.pack(">BBff", 1, 0, cx, cy))
        time.sleep(0.4)
    else:
        print("   (click skipped)")

    print("-> SCROLL 3 notches down, then 3 up")
    for _ in range(3):
        send(SCROLL, struct.pack(">ffff", cx, cy, 0.0, -1.0))
        time.sleep(0.05)
    time.sleep(0.3)
    for _ in range(3):
        send(SCROLL, struct.pack(">ffff", cx, cy, 0.0, 1.0))
        time.sleep(0.05)
    time.sleep(0.3)

    print("-> KEY KEYCODE_BACK down/up")
    send(KEY, struct.pack(">BIII", 1, KEYCODE_BACK, 0, 0))
    time.sleep(0.05)
    send(KEY, struct.pack(">BIII", 0, KEYCODE_BACK, 0, 0))
    time.sleep(0.4)

    print('-> TEXT "teras"')
    send(TEXT, "teras".encode("utf-8"))
    time.sleep(0.5)

    print("-> SET_POINTER_VISIBLE 0")
    send(SET_POINTER_VISIBLE, bytes([0]))
    time.sleep(0.2)
    print("-> SET_POINTER_VISIBLE 1")
    send(SET_POINTER_VISIBLE, bytes([1]))
    time.sleep(0.2)

    print("-> GET_DISPLAY")
    send(GET_DISPLAY)
    time.sleep(0.3)

    print("-> BYE")
    send(BYE)
    time.sleep(0.3)
    state["stop"] = True
    sock.close()

    print()
    print("==== summary ====")
    print(f"DISPLAY_INFO : {state['display']}")
    api, flags = state["ready"]
    print(f"READY        : apiLevel={api} flags=0x{flags:02x} bit0={flags & 1}")
    print(f"ERROR frames : {len(state['errors'])}")
    for message in state["errors"]:
        print(f"  - {message}")
    return 0 if not state["errors"] and (flags & 1) else 1


if __name__ == "__main__":
    sys.exit(main())
