# Orion Subtitles TV

Standalone Android TV receiver for Orion Subtitles. This is a separate Android application; it does not embed ChiakiKit or decode PS Remote Play video.

## Implemented foundation

- Android TV launcher activity with D-pad friendly controls.
- Explicit Android "Display over other apps" permission flow.
- Foreground receiver service.
- Local TCP receiver using the original Orion JSON-Lines protocol.
- Per-TV pairing token, QR payload, and visible manual IP/port/token details.
- Transparent system overlay window with normalized 16:9 subtitle placement, Arabic RTL text, black cover, and TTL expiry.
- iPad-side TCP publisher in `App/Streaming/TVLinkPublisher.swift`.
- In-stream TV Mode setup sheet for manual IP, port, and pairing-token entry.
- Unit tests for Vision-to-screen coordinate mapping.

## Pairing

1. Connect the TV and iPad to the same trusted local network.
2. On the TV, grant "Display over other apps" permission and start the Orion receiver.
3. Read the TV's IP address, port, and pairing token from the TV app.
4. In the iPad stream screen, open the quick toolbar and choose "التلفاز".
5. Enter the TV details and connect.

The QR is displayed for future in-app scanning; the current iPad build uses manual entry.

## Build

The GitHub Actions workflow **Build Orion Subtitles TV** runs unit tests and creates a debug APK. Download the artifact named `orion-subtitles-tv-debug-apk`.

The APK is a development build and is not a Play Store release.

## Limitations before release

- The initial local TCP transport uses a pairing token but does not yet encrypt traffic. Use only on a trusted local network; TLS and revocable pairing are required before use on untrusted networks.
- The iPad does not scan the QR yet; enter the IP, port, and token manually.
- HDMI overlay behavior must be verified on the actual TV firmware while an HDMI input is active. A successful APK build does not prove hardware composition.
- No game video or audio is sent to the TV; only translated text and normalized coordinates are sent.

See [the protocol specification](../Shared/orion-tv-protocol-v1.md).
