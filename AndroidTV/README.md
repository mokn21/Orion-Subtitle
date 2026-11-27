# Orion Subtitles TV

Standalone Android TV receiver for Orion Subtitles. This is a separate Android application; it does not embed ChiakiKit or decode PS Remote Play video.

## Current foundation

- Android TV launcher activity with D-pad friendly controls.
- Explicit Android "Display over other apps" permission flow.
- Foreground receiver service.
- Local TCP receiver using the original Orion JSON-Lines protocol.
- QR pairing payload containing the TV's LAN address and one-time-style pairing token.
- Transparent system overlay window with normalized 16:9 subtitle placement, Arabic RTL text, black cover, and TTL expiry.
- Unit tests for Vision-to-screen coordinate mapping.

## Build

The GitHub Actions workflow **Build Orion Subtitles TV** runs unit tests and creates a debug APK. Download the artifact named `orion-subtitles-tv-debug-apk`.

The APK is a development build and is not a Play Store release.

## Current integration status

The Android receiver foundation is being developed first. The iPad sender and QR scanner are not yet connected, and HDMI overlay behavior has not yet been verified on physical TV hardware. The TV must be connected to the same local network as the iPad.

See [the protocol specification](../Shared/orion-tv-protocol-v1.md).
