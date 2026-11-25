#!/usr/bin/env bash
# Builds an unsigned build/Orion-Subtitles.ipa for sideloading. SideStore, AltStore and
# Sideloadly re-sign it with the installer's own Apple ID.
#
#   scripts/package-ipa.sh
#   VERSION=0.2.0 BUILD_NUMBER=7 scripts/package-ipa.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-0.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
BUNDLE_ID="${BUNDLE_ID:-com.orion.subtitles}"
TRANSLATION_PROXY_URL="${TRANSLATION_PROXY_URL:-}"
DERIVED="$ROOT/build/DerivedData-ipa"
STAGE="$ROOT/build/ipa"
OUT="$ROOT/build/Orion-Subtitles.ipa"

[ -d Frameworks/ChiakiKit.xcframework ] || scripts/build-chiaki.sh
xcodegen generate

xcodebuild -project OrionSubtitles.xcodeproj -scheme OrionSubtitles -configuration Release \
	-destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" \
	CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM="" \
	ORION_BUNDLE_ID="$BUNDLE_ID" MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
	ORION_TRANSLATION_PROXY_URL="$TRANSLATION_PROXY_URL" \
	build

rm -rf "$STAGE" "$OUT"
mkdir -p "$STAGE/Payload"
cp -R "$DERIVED/Build/Products/Release-iphoneos/OrionSubtitles.app" "$STAGE/Payload/"
APP_PLIST="$STAGE/Payload/OrionSubtitles.app/Info.plist"
python3 - "$APP_PLIST" <<'PY'
import plistlib
import sys
from pathlib import Path

plist_path = Path(sys.argv[1])
data = plistlib.loads(plist_path.read_bytes())
data["UIDeviceFamily"] = [2]
plist_path.write_bytes(plistlib.dumps(data, fmt=plistlib.FMT_BINARY))
PY
(cd "$STAGE" && zip -qry "$OUT" Payload)
echo "Built $OUT"
