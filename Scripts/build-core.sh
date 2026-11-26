#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNCTHING_VERSION="v2.1.7"
SYNCTHING_COMMIT="d6d0181f7d466381c4b39ec8fd944c364f939b32"
GOMOBILE_VERSION="v0.0.0-20260410095206-2cfb76559b7b"
SOURCE_DIR="$ROOT/.build/syncthing-$SYNCTHING_VERSION"
FRAMEWORK="$ROOT/Frameworks/RooSyncCore.xcframework"

mkdir -p "$ROOT/.build" "$ROOT/Frameworks"
if [[ ! -d "$SOURCE_DIR/.git" ]]; then
	git clone --depth 1 --branch "$SYNCTHING_VERSION" \
		https://github.com/syncthing/syncthing.git "$SOURCE_DIR"
fi
actual_commit="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
if [[ "$actual_commit" != "$SYNCTHING_COMMIT" ]]; then
	printf 'Syncthing source revision mismatch: expected %s, got %s\n' \
		"$SYNCTHING_COMMIT" "$actual_commit" >&2
	exit 1
fi

export PATH="$(go env GOPATH)/bin:$PATH"
go install "golang.org/x/mobile/cmd/gomobile@$GOMOBILE_VERSION"
gomobile init

mkdir -p "$SOURCE_DIR/lib/roosyncmobile"
cp "$ROOT/Core/Go/bridge.go" "$SOURCE_DIR/lib/roosyncmobile/bridge.go"
(
	cd "$SOURCE_DIR"
	go generate ./lib/api/auto
	go test ./lib/roosyncmobile
	go mod edit -require="golang.org/x/mobile@$GOMOBILE_VERSION"
	go mod download golang.org/x/mobile
	gomobile bind -trimpath -target=ios,iossimulator -iosversion=18.0 \
		-bundleid=com.rooindustries.roosync.core \
		-o "$FRAMEWORK" github.com/syncthing/syncthing/lib/roosyncmobile
)
