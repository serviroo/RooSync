#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="$ROOT/.build/syncthing-v2.1.7"
OUTPUT_DIR="${1:-$ROOT/.build/third-party-licenses-v2.1.7}"
export PATH="$(go env GOPATH)/bin:$PATH"

command -v go-licenses >/dev/null || {
	printf '%s\n' 'Install github.com/google/go-licenses v1.6.0 first.' >&2
	exit 1
}
[[ -d "$SOURCE_DIR" ]] || {
	printf 'Syncthing source not found: %s\n' "$SOURCE_DIR" >&2
	exit 1
}

[[ ! -e "$OUTPUT_DIR" ]] || {
	printf 'Third-party notices already exist: %s\n' "$OUTPUT_DIR" >&2
	exit 1
}
mkdir -p "$(dirname "$OUTPUT_DIR")"
(
	cd "$SOURCE_DIR"
	go-licenses save ./... --save_path="$OUTPUT_DIR"
)
