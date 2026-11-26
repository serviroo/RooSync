#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${1:-$HOME/RooSync-artifacts}"
APP_PATH="$ROOT/.build/DeviceDerivedData/Build/Products/Release-iphoneos/RooSync.app"
LICENSES_DIR="$ROOT/.build/third-party-licenses-v2.1.7"
ARTIFACT_ID="$(date +%Y%m%d-%H%M%S)"

case "$OUTPUT_DIR" in
	"$ROOT"|"$ROOT"/*)
		printf '%s\n' 'Choose an output directory outside the checkout.' >&2
		exit 1
		;;
esac

[[ -d "$APP_PATH" ]] || {
	printf 'Release device app not found: %s\n' "$APP_PATH" >&2
	exit 1
}
[[ -d "$LICENSES_DIR" ]] || {
	printf 'Third-party notices not found: %s\n' "$LICENSES_DIR" >&2
	exit 1
}
git -C "$ROOT" rev-parse --verify HEAD >/dev/null

PACKAGE_DIR="$ROOT/.build/package-$ARTIFACT_ID"
mkdir -p "$OUTPUT_DIR" "$PACKAGE_DIR/Payload" "$PACKAGE_DIR/source/RooSync"
cp -R "$APP_PATH" "$PACKAGE_DIR/Payload/"
APP_BUNDLE="$PACKAGE_DIR/Payload/RooSync.app"
cp "$ROOT/LICENSE" "$APP_BUNDLE/"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP_BUNDLE/"
mkdir -p "$APP_BUNDLE/third_party_licenses"
cp -R "$LICENSES_DIR/." "$APP_BUNDLE/third_party_licenses/"
ditto -c -k --sequesterRsrc --keepParent \
	"$APP_BUNDLE" \
	"$OUTPUT_DIR/RooSync-device-app-$ARTIFACT_ID.zip"
ditto -c -k --sequesterRsrc --keepParent \
	"$PACKAGE_DIR/Payload" \
	"$OUTPUT_DIR/RooSync-unsigned-$ARTIFACT_ID.ipa"
git -C "$ROOT" archive --format=tar HEAD | tar -xf - -C "$PACKAGE_DIR/source/RooSync"
cp -R "$LICENSES_DIR" "$PACKAGE_DIR/source/RooSync/third_party_licenses"
ditto -c -k --sequesterRsrc --keepParent \
	"$PACKAGE_DIR/source/RooSync" \
	"$OUTPUT_DIR/RooSync-source-$ARTIFACT_ID.zip"
shasum -a 256 "$OUTPUT_DIR"/RooSync-*-"$ARTIFACT_ID".* >"$OUTPUT_DIR/SHA256SUMS-$ARTIFACT_ID.txt"

printf 'Unsigned IPA: %s\n' "$OUTPUT_DIR/RooSync-unsigned-$ARTIFACT_ID.ipa"
printf 'Release app: %s\n' "$OUTPUT_DIR/RooSync-device-app-$ARTIFACT_ID.zip"
printf 'Source archive: %s\n' "$OUTPUT_DIR/RooSync-source-$ARTIFACT_ID.zip"
printf 'Checksums: %s\n' "$OUTPUT_DIR/SHA256SUMS-$ARTIFACT_ID.txt"
