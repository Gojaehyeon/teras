# Teras Wire Protocol v1

Status: normative for `pv = 1`. This is the single contract shared by the Mac
host (`MacHost/`), the iOS receiver (`Receivers/iOS/`) and the Android
receiver (`Receivers/Android/`). Change this document first, code second.

## 0. Vocabulary

* **Host** – the machine whose desktop is extended. Today: the Mac app.
* **Receiver** – the device that shows the extra display. Today: iPhone/iPad
  app and Android app.
* **Session** – one TCP connection = one virtual display on the host.

## 1. Roles and transport

* The **receiver listens** on TCP port **41777** and the **host dials**.
  This single rule makes USB and WiFi identical above the socket:
  * iPhone/iPad over USB: host asks macOS's built‑in `usbmuxd`
    (`/var/run/usbmuxd`) to `Connect` to port 41777 on the device. After the
    `Result 0` reply the same socket is a transparent byte pipe.
  * Android over USB: host runs `adb forward tcp:0 tcp:41777` (adb prints the
    allocated local port) and dials `127.0.0.1:<local>`.
  * WiFi/LAN: receiver advertises Bonjour/DNS‑SD service `_teras._tcp`;
    host browses and dials the resolved address.
* One TCP stream carries video, control and input in both directions.
  Implementations MUST set `TCP_NODELAY`.
* A receiver serves **one host session at a time**. A new inbound
  connection replaces the old one (receiver cancels the old, resets decoder).
* Byte order on the wire is **big‑endian** for all fixed‑width integers.

### 1.1 Bonjour TXT record (WiFi only)

| key   | value                          | meaning |
|-------|--------------------------------|---------|
| `pv`  | `"1"`                          | protocol version |
| `id`  | UUID string                    | stable per‑install receiver identity (same as `hello_ack.deviceId`) |
| `plat`| `ios` \| `android`             | platform |
| `name`| UTF‑8 string                   | display‑only device name |

## 2. Framing

Every message in both directions:

```
[u32 length][u8 type][payload …]
```

* `length` = number of bytes after the length field (i.e. `1 + payload`).
* `length` MUST be in `1 … 16 MiB`. Anything else is a protocol error;
  the peer MUST close the connection.
* TCP has no message boundaries; both ends MUST buffer and reassemble.

### 2.1 Encrypted envelope (type `0x7F`)

After a successful `AUTH_OK` on a LAN transport, **every** subsequent frame
in both directions MUST be wrapped:

```
type = 0x7F
payload = [u64 counter][ciphertext][16‑byte GCM tag]
```

* `ciphertext = AES‑256‑GCM(key_dir, nonce, plaintext = [u8 innerType][innerPayload])`
* `nonce` (12 bytes) = `[u32 0x00000000][u64 counter]`; counter starts at 0 and
  increments by 1 per frame per direction. A receiver of a counter that is
  not strictly increasing MUST close the connection.
* AAD = the single byte `0x7F`.
* Two keys: `key_h2r = HKDF‑SHA256(secret, salt = hostNonce‖deviceNonce, info = "teras-v1-h2r", 32)`,
  `key_r2h = … info = "teras-v1-r2h"`.
* USB transports MAY skip encryption (`hello.encrypt = false`). Hosts SHOULD
  encrypt on LAN and MUST NOT encrypt when no `secret` exists.

## 3. Message types

Direction: H→R = host to receiver, R→H = receiver to host. JSON payloads are
UTF‑8, unknown keys MUST be ignored (additive evolution).

| type | name | dir | payload |
|------|------|-----|---------|
| 0x01 | HELLO | H→R | JSON |
| 0x02 | HELLO_ACK | R→H | JSON |
| 0x03 | PAIR_REQUIRED | R→H | JSON `{ "attemptsLeft": n }` |
| 0x04 | PAIR | H→R | JSON `{ "proof": base64 }` |
| 0x05 | PAIR_OK | R→H | JSON `{ "box": base64 }` |
| 0x06 | PAIR_FAIL | R→H | JSON `{ "attemptsLeft": n, "locked": bool }` |
| 0x07 | AUTH | H→R | JSON `{ "proof": base64 }` |
| 0x08 | AUTH_OK | R→H | JSON `{ "proof": base64 }` |
| 0x09 | AUTH_FAIL | R→H | JSON `{ "reason": string }` (receiver forgets nothing; host should offer re‑pair) |
| 0x10 | STREAM_CONFIG | H→R | JSON |
| 0x11 | READY | R→H | JSON `{}` |
| 0x12 | VIDEO | H→R | binary (§4) |
| 0x13 | KEYFRAME_REQUEST | R→H | empty |
| 0x14 | DEVICE_CONFIG | R→H | JSON (§5.2) |
| 0x20 | TOUCH | R→H | binary (§6.1) |
| 0x21 | SCROLL | R→H | binary (§6.2) |
| 0x22 | KEY | R→H | JSON (§6.3) |
| 0x23 | POINTER | R→H | binary (§6.4) hover/mouse from tablets with trackpad/mouse |
| 0x30 | PING | both | `[u64 t_send_us]` |
| 0x31 | PONG | both | `[u64 t_echo_us][u64 t_recv_us]` |
| 0x32 | STATS | R→H | JSON (§7) |
| 0x40 | BYE | both | JSON `{ "reason": string }` |
| 0x7F | ENC | both | encrypted envelope (§2.1) |

### 3.1 HELLO (H→R)

```json
{
  "pv": 1,
  "hostId": "UUID",            // stable per‑install host identity
  "hostName": "Go’s MacBook Pro",
  "transport": "usb" | "lan",
  "hostNonce": "base64(16 bytes)",
  "encrypt": true | false,     // host wants the ENC envelope after AUTH_OK
  "app": { "name": "Teras", "version": "1.0.0", "build": 12 }
}
```

### 3.2 HELLO_ACK (R→H)

```json
{
  "pv": 1,
  "deviceId": "UUID",
  "deviceName": "Go’s iPhone",
  "platform": "ios" | "android",
  "model": "iPhone16,1",
  "deviceNonce": "base64(16 bytes)",
  "screen": { "wPx": 1179, "hPx": 2556, "scale": 3.0, "refreshHz": 120,
              "safeInsets": { "top": 59, "bottom": 34, "left": 0, "right": 0 } },
  "orientation": "portrait" | "landscapeLeft" | "landscapeRight" | "portraitUpsideDown",
  "codecs": ["hevc", "h264"],          // preference order
  "maxDecode": { "w": 4096, "h": 2304 },
  "features": ["touch", "pencil", "keyboard", "scroll", "hover"],
  "paired": true | false,              // receiver already holds a secret for hostId
  "authRequired": true | false         // true on lan, false on usb
}
```

### 3.3 Pairing and authentication (LAN only)

`authRequired = false` (USB): host proceeds directly to `STREAM_CONFIG`.
A receiver MUST set `authRequired = true` unless the connection arrived from
loopback (the usbmuxd / adb path); the host's `transport` claim alone never
waives authentication.

`authRequired = true, paired = false`:
1. Receiver shows a 6‑digit PIN on screen and sends `PAIR_REQUIRED`.
2. Host UI asks the user for the PIN and sends `PAIR`:
   `pinKey = SHA256(pin ‖ deviceId ‖ hostId)`,
   `proof = HMAC‑SHA256(pinKey, "pair" ‖ hostNonce ‖ deviceNonce)`.
3. Receiver verifies. On failure: `PAIR_FAIL`; after 3 failures the receiver
   rotates the PIN and closes. On success the receiver generates
   `secret = 32 random bytes`, stores `(hostId → secret)`, and replies
   `PAIR_OK` with `box = AES‑256‑GCM(key = HKDF(pinKey, salt = hostNonce‖deviceNonce, info = "teras-v1-pairbox", 32), nonce = 12 zero bytes, plaintext = secret)` (ciphertext ‖ tag).
   Host decrypts, stores `(deviceId → secret)`. Both then continue with AUTH
   on the same connection using the fresh nonces already exchanged.

`authRequired = true, paired = true` (or right after PAIR_OK):
1. Host sends `AUTH` with `proof = HMAC‑SHA256(secret, "auth" ‖ hostNonce ‖ deviceNonce)`.
2. Receiver verifies, replies `AUTH_OK` with `proof = HMAC‑SHA256(secret, "auth-ack" ‖ hostNonce ‖ deviceNonce)`; host verifies (mutual).
3. If `hello.encrypt`, both switch to the ENC envelope starting with the
   very next frame each side sends.
4. `AUTH_FAIL` if the host's proof is wrong (e.g. receiver was reset). Host
   should drop its stored secret and offer to pair again.

### 3.4 STREAM_CONFIG (H→R)

Sent after auth (or immediately after HELLO_ACK on USB), and again whenever
the stream geometry or codec changes. Receiver MUST reset its decoder when
`codec`, `wPx` or `hPx` change and reply `READY`.

```json
{
  "codec": "hevc" | "h264",
  "wPx": 2556, "hPx": 1179,          // encoded frame size (physical px)
  "fps": 60,
  "desktop": { "w": 1278, "h": 589 },  // logical desktop size of the virtual display (for info/UI)
  "orientation": "landscapeLeft",     // the orientation the host is assuming
  "mode": "extend" | "mirror",
  "cursorBaked": true                  // cursor is drawn into the video
}
```

## 4. VIDEO (H→R, type 0x12)

```
[u8 flags][u64 captureTimestampUs][u32 seq][Annex‑B access unit]
```

* `flags` bit0 = keyframe (IDR/CRA). bit1 = contains parameter sets. bit2 = stream discontinuity (decoder MUST flush).
* `captureTimestampUs` = host monotonic clock in microseconds at capture (for latency stats, combined with PING/PONG offset).
* `seq` = increasing per session; gaps are allowed (host may drop frames).
* Payload is one encoded picture, Annex‑B with **4‑byte start codes only**.
  Keyframes MUST be prefixed with VPS/SPS/PPS (HEVC) or SPS/PPS (H.264).
  No B‑frames; receivers display in arrival order immediately.

## 5. Geometry

### 5.1 Coordinates
Input coordinates from the receiver are **normalized** to `[0,1]` over the
encoded video frame (`STREAM_CONFIG.wPx/hPx`), origin top‑left, x right, y
down. The host maps them into the virtual display's global CG coordinates.

### 5.2 DEVICE_CONFIG (R→H)
Receiver sends when orientation or usable screen area changes:
```json
{ "orientation": "portrait", "screen": { …same as HELLO_ACK.screen… } }
```
Host rebuilds the virtual display and sends a new `STREAM_CONFIG`.

## 6. Input

### 6.1 TOUCH (0x20)
```
[u8 phase][u8 pointerCount] then pointerCount × [u32 pointerId][u8 tool][f32 x][f32 y][f32 pressure][f32 tiltX][f32 tiltY][f32 azimuth]
```
* `phase`: 0 began, 1 moved, 2 ended, 3 cancelled.
* `tool`: 0 finger, 1 stylus.
* Host gesture policy (v1): 1 finger = left mouse down/drag/up; 2‑finger drag → SCROLL is generated by the receiver, not the host. Long press = right click (receiver decides and sends POINTER down/up with button=1, i.e. right per §6.4).

### 6.2 SCROLL (0x21)
```
[f32 x][f32 y][f32 dx][f32 dy][u8 phase]   // dx,dy in points, phase 0 begin 1 changed 2 ended
```

### 6.3 KEY (0x22)
```json
{ "down": true, "keyCode": 0, "text": "a", "mods": ["cmd","shift","alt","ctrl"] }
```
`keyCode` is a macOS virtual key code if the receiver knows it, else 0 and
`text` is inserted via unicode key events.

### 6.4 POINTER (0x23)
```
[u8 kind][u8 button][f32 x][f32 y]   // kind 0 move, 1 down, 2 up; button 0 left 1 right 2 middle
```

## 7. Liveness and stats

* Either side sends `PING` every 1 s; the peer MUST answer `PONG` within
  3 s or the sender closes the connection.
* Receiver sends `STATS` every 1 s:
```json
{ "fpsDecoded": 59.8, "fpsDropped": 0, "decodeMsP50": 3.1, "queued": 1,
  "rttMs": 2.4, "e2eMsP50": 18.5 }
```
Host may adapt bitrate/fps from these.

## 8. Session lifecycle

```
connect → HELLO → HELLO_ACK → [PAIR_REQUIRED → PAIR → PAIR_OK] → [AUTH → AUTH_OK]
        → STREAM_CONFIG → READY → VIDEO/TOUCH/… ↔ … → BYE / close
```
On any close the host destroys that session's virtual display within 1 s and
the receiver returns to its idle/QR screen. Hosts auto‑reconnect to USB
devices as long as they are attached, and to paired LAN devices when the user
selects them.

## 9. Versioning

`pv` is negotiated by the minimum of the two `pv` values; unknown message
types MUST be skipped (the length prefix makes that safe). Breaking changes
bump `pv`.
