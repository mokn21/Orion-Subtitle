# Orion TV Link Protocol v1

This is an original Orion protocol. It does not reuse SARD endpoints, credentials, relay infrastructure, or proprietary message implementations.

## Transport

- Local-network TCP connection from iPad to Android TV.
- Default receiver port: `38641`.
- UTF-8 JSON Lines: one JSON object followed by one newline.
- The TV displays a QR payload containing `scheme=orion-tv`, protocol version, host, port, and a random per-TV pairing token.
- The first message must be `hello` with the token. The TV replies with `hello.ack` and protocol version 1.
- Only one active sender is needed for the initial release. The connection is local-network only; do not expose the receiver port to the public internet.

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
  "rect":{"x":0.12,"y":0.18,"width":0.32,"height":0.08},
  "ttlMs":3000
}
```

- `rect` is normalized to the original 16:9 Remote Play frame.
- All coordinates are in the range 0...1.
- Origin is bottom-left, matching Vision and the existing iPad `TranslationEntry.boundingBox`.
- The TV maps the rectangle into its displayed 16:9 video area and converts bottom-left Y to Android's top-left screen coordinates.
- The overlay uses a cover behind the Arabic text so the original English is obscured.
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
    "backgroundAlpha":0.72,
    "fontScale":0.68
  }
}
```

- `fontScale` is relative to the overlay rectangle height, not a device-specific point size.
- The default style is white Arabic text over a black cover with 72% opacity.

### Keepalive

```json
{"type":"ping","nonce":"123"}
{"type":"pong","nonce":"123"}
```

## Initial implementation boundaries

- No game video or audio is sent to the TV.
- No cloud relay or SARD backend is used.
- Pairing and data transfer stay on the local network.
- The first implementation is a receiver/overlay foundation. The iPad sender, in-app QR scanner, persistent pairing management, and TV hardware validation are separate integration steps.
- The Android `SYSTEM_ALERT_WINDOW` overlay path must be tested on the actual TV firmware while an HDMI input is active. An APK build alone cannot prove that HDMI overlay composition works.
