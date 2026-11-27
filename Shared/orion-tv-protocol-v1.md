# Orion TV Link Protocol v1

This is an original Orion protocol. It does not reuse SARD endpoints, credentials, relay infrastructure, or proprietary message implementations.

## Transport and pairing

- Local-network TCP connection from iPad to Android TV.
- Default receiver port: `38641`.
- UTF-8 JSON Lines: one JSON object followed by one newline.
- The TV displays a QR payload and also shows its LAN IP, port, and pairing token for manual entry in the iPad's TV Mode.
- The first message must be `hello` with the token. The TV replies with `hello.ack` and protocol version 1.
- Only one active sender is needed for the initial release. Keep the receiver on a trusted local network; do not expose its port to the public internet.
- This initial prototype uses a local-network token but not TLS. Add transport encryption and expiring/revocable pairing credentials before any public or untrusted-network use.

## Message envelope

Every message has a string `type`. Unknown message types are ignored for forward compatibility.

### Authenticate

```json
{"type":"hello","protocol":1,"token":"<pairing-token>"}
{"type":"hello.ack","protocol":1}
```

### Show or replace a translated line

```json
{
  "type":"subtitle.show",
  "id":"line-uuid",
  "text":"النص العربي",
  "backgroundColor":"#342A22",
  "rect":{"x":0.12,"y":0.18,"width":0.32,"height":0.08},
  "ttlMs":3000
}
```

- `rect` is normalized to the original 16:9 Remote Play frame.
- All coordinates are in the range 0...1.
- Origin is bottom-left, matching Vision and the existing iPad `TranslationEntry.boundingBox`.
- The iPad restores crop-relative OCR coordinates to full-frame coordinates before publishing.
- The TV maps the rectangle into its displayed 16:9 video area and converts bottom-left Y to Android's top-left screen coordinates.
- The overlay uses a cover behind the Arabic text so the original English is obscured.
- `backgroundColor` is sampled from pixels immediately surrounding the source text; older senders may omit it and the TV falls back to the global style.
- `subtitle.replace` has the same payload and replaces the existing entry with the same ID.

### Keep and clear

```json
{"type":"subtitle.keep","id":"line-uuid","ttlMs":3000}
{"type":"subtitle.clear","id":"line-uuid"}
```

A subtitle expires automatically if keep messages stop arriving. The initial TV receiver clamps TTL to 250...15000 ms.

### Global style

```json
{
  "type":"style.set",
  "style":{
    "textColor":"#FFFFFFFF",
    "backgroundColor":"#FF000000",
    "backgroundAlpha":1.0,
    "fontScale":0.68
  }
}
```

### Keepalive

```json
{"type":"ping","nonce":"123"}
{"type":"pong","nonce":"123"}
```

## Current implementation boundaries

- The Android TV receiver and the iPad TCP sender are implemented as a first integration slice.
- The iPad currently supports manual IP/port/token entry; in-app QR scanning is a follow-up.
- No game video or audio is sent to the TV.
- No cloud relay or SARD backend is used.
- The Android `SYSTEM_ALERT_WINDOW` overlay path must be tested on the actual TV firmware while an HDMI input is active. An APK build alone cannot prove that HDMI overlay composition works.
