#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE_ID="com.rooindustries.roosync"
PEER_IMAGE="syncthing/syncthing:2.1.7"
APP_REST="http://127.0.0.1:8384"
PEER_REST="http://127.0.0.1:8385"
PEER_SYNC_PORT=22002
RUN_ID="${GITHUB_RUN_ID:-$(date +%s)-$$}"
CONTAINER_NAME="roosync-e2e-$RUN_ID"
VOLUME_NAME="roosync-e2e-$RUN_ID"
E2E_DIR="$ROOT/.build/e2e/$RUN_ID"
DERIVED_DATA="$E2E_DIR/DerivedData"
APP_FOLDER_ID="roosync-e2e-vault"
APP_FOLDER_LABEL="RooSync E2E Vault"
SIMULATOR_UDID="${SIMULATOR_UDID:-}"
SIMULATOR_CREATED=0
APP_INSTALLED=0
TUNNEL_PID=""
DOCKER=()

mkdir -p "$E2E_DIR"

cleanup() {
	local status=$?
	trap - EXIT
	if [[ -n "$SIMULATOR_UDID" && "$APP_INSTALLED" == 1 ]]; then
		xcrun simctl terminate "$SIMULATOR_UDID" "$APP_BUNDLE_ID" >/dev/null 2>&1 || true
	fi
	if [[ -n "$TUNNEL_PID" ]]; then
		kill "$TUNNEL_PID" >/dev/null 2>&1 || true
	fi
	if ((${#DOCKER[@]})); then
		"${DOCKER[@]}" rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
		"${DOCKER[@]}" volume rm "$VOLUME_NAME" >/dev/null 2>&1 || true
	fi
	if [[ "$SIMULATOR_CREATED" == 1 ]]; then
		xcrun simctl shutdown "$SIMULATOR_UDID" >/dev/null 2>&1 || true
		xcrun simctl delete "$SIMULATOR_UDID" >/dev/null 2>&1 || true
	fi
	exit "$status"
}
trap cleanup EXIT

fail() {
	printf 'E2E failure: %s\n' "$*" >&2
	exit 1
}

if [[ -f "$HOME/.colima/_lima/colima/ssh.config" ]] && command -v limactl >/dev/null 2>&1; then
	export LIMA_HOME="$HOME/.colima/_lima"
	DOCKER=(limactl shell colima -- sudo -n docker)
	"${DOCKER[@]}" info >/dev/null
	ssh -F "$LIMA_HOME/colima/ssh.config" -N -o ExitOnForwardFailure=yes \
		-L 127.0.0.1:8385:127.0.0.1:8385 \
		-L "127.0.0.1:$PEER_SYNC_PORT:127.0.0.1:$PEER_SYNC_PORT" \
		lima-colima >"$E2E_DIR/lima-forward.log" 2>&1 &
	TUNNEL_PID=$!
elif command -v docker >/dev/null 2>&1; then
	DOCKER=(docker)
	if ! "${DOCKER[@]}" info >/dev/null 2>&1; then
		if [[ -d /Applications/Docker.app ]]; then
			open --background -a Docker
		fi
		for _ in $(seq 1 60); do
			"${DOCKER[@]}" info >/dev/null 2>&1 && break
			sleep 2
		done
		"${DOCKER[@]}" info >/dev/null 2>&1 || fail "Docker Desktop is not running; use a macOS runner with virtualization support."
	fi
else
	fail "Docker CLI is not installed."
fi

./Scripts/build-core.sh
xcodegen generate

if [[ -z "$SIMULATOR_UDID" ]]; then
	DEVICE_TYPE="$(xcrun simctl list -j devicetypes | python3 -c 'import json,sys; data=json.load(sys.stdin)["devicetypes"]; items=[x for x in data if x["identifier"].startswith("com.apple.CoreSimulator.SimDeviceType.iPhone")]; preferred=[x for x in items if "Pro" in x["name"]]; print((preferred or items)[0]["identifier"])')"
	IOS_RUNTIME="$(xcrun simctl list -j runtimes | python3 -c 'import json,sys; items=[x for x in json.load(sys.stdin)["runtimes"] if x.get("isAvailable") and x.get("platform") == "iOS"]; items.sort(key=lambda x: tuple(int(p) for p in x["version"].split("."))); print(items[-1]["identifier"])')"
	SIMULATOR_UDID="$(xcrun simctl create "RooSync E2E $RUN_ID" "$DEVICE_TYPE" "$IOS_RUNTIME")"
	SIMULATOR_CREATED=1
fi

xcrun simctl boot "$SIMULATOR_UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$SIMULATOR_UDID" -b
xcodebuild -project "$ROOT/RooSync.xcodeproj" -scheme RooSync \
	-destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
	-derivedDataPath "$DERIVED_DATA" CODE_SIGNING_ALLOWED=NO build-for-testing \
	>"$E2E_DIR/build.log" 2>&1 || {
	rg -n 'error:|warning:|BUILD FAILED|TEST BUILD FAILED' "$E2E_DIR/build.log" | tail -80 >&2 || true
	fail "Simulator app and UI-test build failed; see $E2E_DIR/build.log."
}

APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/RooSync.app"
xcrun simctl install "$SIMULATOR_UDID" "$APP_PATH"
APP_INSTALLED=1
xcrun simctl launch "$SIMULATOR_UDID" "$APP_BUNDLE_ID" >/dev/null

for _ in $(seq 1 90); do
	if curl --noproxy '*' -fsS "$APP_REST/rest/noauth/health" >/dev/null 2>&1; then
		break
	fi
	sleep 2
done
curl --noproxy '*' -fsS "$APP_REST/rest/noauth/health" >/dev/null || fail "Simulator core REST API did not start on 127.0.0.1:8384."

APP_DATA="$(xcrun simctl get_app_container "$SIMULATOR_UDID" "$APP_BUNDLE_ID" data)"
APP_CONFIG="$APP_DATA/Library/Application Support/RooSync/config/config.xml"
for _ in $(seq 1 30); do
	[[ -f "$APP_CONFIG" ]] && break
	sleep 1
done
[[ -f "$APP_CONFIG" ]] || fail "The simulator core did not create its configuration."
APP_API_KEY=""
APP_ID=""
for _ in $(seq 1 30); do
	APP_API_KEY="$(python3 - "$APP_CONFIG" <<'PY'
import sys
import xml.etree.ElementTree as ET

node = ET.parse(sys.argv[1]).getroot().find("./gui/apikey")
print(node.text if node is not None and node.text else "")
PY
)"
	if [[ -n "$APP_API_KEY" ]]; then
		APP_STATUS="$(curl --noproxy '*' --max-time 2 -fsS \
			-H "X-API-Key: $APP_API_KEY" "$APP_REST/rest/system/status" 2>/dev/null || true)"
		APP_ID="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("myID", ""))' \
			<<<"$APP_STATUS" 2>/dev/null || true)"
		[[ -n "$APP_ID" ]] && break
	fi
	sleep 1
done
[[ -n "$APP_ID" ]] || fail "The simulator REST API key was not persisted and accepted within 30 seconds."

DESKTOP_FOLDER="$E2E_DIR/desktop-vault"
mkdir -p "$DESKTOP_FOLDER"
chmod 777 "$DESKTOP_FOLDER"
cp -R "$ROOT/docs/fixtures/ObsidianVault/.obsidian" "$DESKTOP_FOLDER/"
cp "$ROOT/docs/fixtures/ObsidianVault/Welcome.md" "$DESKTOP_FOLDER/"
cp "$ROOT/docs/fixtures/ObsidianVault/Conflicted note.md" "$DESKTOP_FOLDER/"

"${DOCKER[@]}" volume create "$VOLUME_NAME" >/dev/null
"${DOCKER[@]}" run -d --name "$CONTAINER_NAME" --user 0:0 \
	-e STGUIADDRESS=0.0.0.0:8384 \
	-v "$VOLUME_NAME:/var/syncthing" \
	-v "$DESKTOP_FOLDER:/vault:rw" \
	-p 127.0.0.1:8385:8384/tcp \
	-p "127.0.0.1:$PEER_SYNC_PORT:22000/tcp" \
	-p "127.0.0.1:$PEER_SYNC_PORT:22000/udp" \
	"$PEER_IMAGE" >/dev/null

for _ in $(seq 1 90); do
	if curl --noproxy '*' -fsS "$PEER_REST/rest/noauth/health" >/dev/null 2>&1; then
		break
	fi
	sleep 2
done
curl --noproxy '*' -fsS "$PEER_REST/rest/noauth/health" >/dev/null || fail "Docker Syncthing REST API did not start on 127.0.0.1:8385."
PEER_API_KEY="$("${DOCKER[@]}" exec "$CONTAINER_NAME" cat /var/syncthing/config/config.xml | python3 -c 'import sys,xml.etree.ElementTree as ET; node=ET.fromstring(sys.stdin.read()).find("./gui/apikey"); print(node.text if node is not None and node.text else "")')"
[[ -n "$PEER_API_KEY" ]] || fail "The Docker peer REST API key is missing."

api_request() {
	local base=$1 key=$2 method=$3 route=$4 body=${5:-}
	if [[ -n "$body" ]]; then
		printf 'header = "X-API-Key: %s"\n' "$key" |
			curl --config - --noproxy '*' -fsS -X "$method" \
				-H 'Content-Type: application/json' --data-binary "$body" "$base$route"
	else
		printf 'header = "X-API-Key: %s"\n' "$key" |
			curl --config - --noproxy '*' -fsS -X "$method" "$base$route"
	fi
}

PEER_ID="$(api_request "$PEER_REST" "$PEER_API_KEY" GET /rest/system/status | python3 -c 'import json,sys; print(json.load(sys.stdin)["myID"])')"
APP_LOCAL_DEVICE_CONFIGURED="$(api_request "$APP_REST" "$APP_API_KEY" GET /rest/config/devices | python3 -c 'import json,sys; devices=json.load(sys.stdin); print(str(any(d.get("deviceID")==sys.argv[1] for d in devices)).lower())' "$APP_ID")"
[[ "$APP_LOCAL_DEVICE_CONFIGURED" == true ]] || fail "The core config no longer contains its local device entry."
APP_LOCAL_DEVICE_NAME="$(api_request "$APP_REST" "$APP_API_KEY" GET /rest/config/devices | python3 -c 'import json,sys; devices=json.load(sys.stdin); device=next((d for d in devices if d.get("deviceID")==sys.argv[1]), {}); print(device.get("name", ""))' "$APP_ID")"
[[ "$APP_LOCAL_DEVICE_NAME" == RooSync ]] || fail "The local core device name is not RooSync."

add_device() {
	local base=$1 key=$2 id=$3 name=$4 address=$5 defaults body
	defaults="$(api_request "$base" "$key" GET /rest/config/defaults/device)"
	body="$(python3 -c 'import json,sys; value=json.load(sys.stdin); value["deviceID"]=sys.argv[1]; value["name"]=sys.argv[2]; value["addresses"]=[sys.argv[3]] if sys.argv[3] else ["dynamic"]; print(json.dumps(value))' "$id" "$name" "$address" <<<"$defaults")"
	api_request "$base" "$key" POST /rest/config/devices "$body" >/dev/null
}

APP_DEVICE_ADDRESS="tcp://127.0.0.1:$PEER_SYNC_PORT"
add_device "$APP_REST" "$APP_API_KEY" "$PEER_ID" "Docker Syncthing E2E" "$APP_DEVICE_ADDRESS"
add_device "$PEER_REST" "$PEER_API_KEY" "$APP_ID" "RooSync Simulator" ""

APP_FOLDER="$APP_DATA/Documents/Vaults/$APP_FOLDER_LABEL"
mkdir -p "$APP_FOLDER"
cp "$ROOT/docs/fixtures/ObsidianVault/Conflicted note.md" "$APP_FOLDER/"
cp "$ROOT/docs/fixtures/ObsidianVault/From iPhone.md" "$APP_FOLDER/"

add_folder() {
	local base=$1 key=$2 path=$3 device=$4 ignore_perms=$5 defaults body
	defaults="$(api_request "$base" "$key" GET /rest/config/defaults/folder)"
	body="$(python3 -c 'import json,sys; value=json.load(sys.stdin); value["id"]=sys.argv[1]; value["label"]=sys.argv[2]; value["path"]=sys.argv[3]; value["devices"]=[{"deviceID":sys.argv[4]}]; value["ignorePerms"]=sys.argv[5].lower()=="true"; print(json.dumps(value))' "$APP_FOLDER_ID" "$APP_FOLDER_LABEL" "$path" "$device" "$ignore_perms" <<<"$defaults")"
	api_request "$base" "$key" POST /rest/config/folders "$body" >/dev/null
}

add_folder "$APP_REST" "$APP_API_KEY" "$APP_FOLDER" "$PEER_ID" false
add_folder "$PEER_REST" "$PEER_API_KEY" /vault "$APP_ID" true
PEER_IGNORE_PERMS="$(api_request "$PEER_REST" "$PEER_API_KEY" GET /rest/config/folders | python3 -c 'import json,sys; folder_id=sys.argv[1]; folders=json.load(sys.stdin); folder=next((item for item in folders if item.get("id")==folder_id), None); print(str(bool(folder.get("ignorePerms"))).lower() if folder else "")' "$APP_FOLDER_ID")"
[[ "$PEER_IGNORE_PERMS" == true ]] || fail "Docker peer folder did not enable ignorePerms for its host-mounted vault."

set_folder_paused() {
	local base=$1 key=$2 paused=$3 actual
	api_request "$base" "$key" PATCH "/rest/config/folders/$APP_FOLDER_ID" "{\"paused\":$paused}" >/dev/null
	actual="$(api_request "$base" "$key" GET /rest/config/folders | python3 -c 'import json,sys; folder_id=sys.argv[1]; folders=json.load(sys.stdin); folder=next((item for item in folders if item.get("id")==folder_id), None); print(str(bool(folder.get("paused"))).lower() if folder else "")' "$APP_FOLDER_ID")"
	[[ "$actual" == "$paused" ]] || fail "Syncthing folder pause state was $actual, expected $paused."
}

wait_for_file() {
	local path=$1 description=$2
	for _ in $(seq 1 90); do
		if [[ -f "$path" ]]; then return 0; fi
		api_request "$APP_REST" "$APP_API_KEY" POST "/rest/db/scan?folder=$APP_FOLDER_ID" >/dev/null 2>&1 || true
		api_request "$PEER_REST" "$PEER_API_KEY" POST "/rest/db/scan?folder=$APP_FOLDER_ID" >/dev/null 2>&1 || true
		sleep 2
	done
	fail "Timed out waiting for $description at $path."
}

wait_for_file "$APP_FOLDER/Welcome.md" "Docker-to-simulator note"
wait_for_file "$DESKTOP_FOLDER/From iPhone.md" "simulator-to-Docker note"
cmp "$ROOT/docs/fixtures/ObsidianVault/Welcome.md" "$APP_FOLDER/Welcome.md"
cmp "$ROOT/docs/fixtures/ObsidianVault/From iPhone.md" "$DESKTOP_FOLDER/From iPhone.md"

set_folder_paused "$APP_REST" "$APP_API_KEY" true
set_folder_paused "$PEER_REST" "$PEER_API_KEY" true
cp "$ROOT/docs/fixtures/ObsidianVault/Conflict-iPhone.md" "$APP_FOLDER/Conflicted note.md"
cp "$ROOT/docs/fixtures/ObsidianVault/Conflict-Docker.md" "$DESKTOP_FOLDER/Conflicted note.md"
set_folder_paused "$APP_REST" "$APP_API_KEY" false
set_folder_paused "$PEER_REST" "$PEER_API_KEY" false

APP_CONFLICT=""
for _ in $(seq 1 90); do
	APP_CONFLICT="$(find "$APP_FOLDER" -type f -name '*sync-conflict-*' -print -quit)"
	[[ -n "$APP_CONFLICT" ]] && break
	api_request "$APP_REST" "$APP_API_KEY" POST "/rest/db/scan?folder=$APP_FOLDER_ID" >/dev/null 2>&1 || true
	api_request "$PEER_REST" "$PEER_API_KEY" POST "/rest/db/scan?folder=$APP_FOLDER_ID" >/dev/null 2>&1 || true
	sleep 2
done
[[ -n "$APP_CONFLICT" ]] || fail "No Syncthing conflict copy appeared in the simulator vault."
grep -Eq 'Edited on the (iPhone|Docker) peer' "$APP_CONFLICT" || fail "The simulator conflict copy has unexpected contents."

set_folder_paused "$PEER_REST" "$PEER_API_KEY" true
xcrun simctl terminate "$SIMULATOR_UDID" "$APP_BUNDLE_ID" >/dev/null 2>&1 || true
APP_INSTALLED=1
xcodebuild -project "$ROOT/RooSync.xcodeproj" -scheme RooSync \
	-destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
	-derivedDataPath "$DERIVED_DATA" -parallel-testing-enabled NO \
	-maximum-concurrent-test-simulator-destinations 1 \
	CODE_SIGNING_ALLOWED=NO test-without-building \
	-only-testing:RooSyncUITests/RooSyncUITests/testFirstRunShowsDeviceIdentityAndSyncAction \
	-only-testing:RooSyncUITests/RooSyncUITests/testEmbeddedRESTRejectsRequestsWithoutAPIKey \
	-only-testing:RooSyncUITests/RooSyncUITests/testCannotAddLocalDeviceID \
	-only-testing:RooSyncUITests/RooSyncUITests/testEmbeddedRESTRejectsRequestsWithoutAPIKey \
	-only-testing:RooSyncUITests/RooSyncUITests/testPauseE2ESyncFolder \
	-only-testing:RooSyncUITests/RooSyncUITests/testResumeE2ESyncFolder \
	-only-testing:RooSyncUITests/RooSyncUITests/testConflictCopyCanBeKept \
	-resultBundlePath "$E2E_DIR/RooSync-E2E.xcresult" >"$E2E_DIR/test.log" 2>&1 || {
	rg -n 'error:|failed|Failure|TEST FAILED' "$E2E_DIR/test.log" | tail -80 >&2 || true
	fail "Simulator UI E2E failed; see $E2E_DIR/test.log."
}

APP_DATA="$(xcrun simctl get_app_container "$SIMULATOR_UDID" "$APP_BUNDLE_ID" data)"
APP_CONFIG="$APP_DATA/Library/Application Support/RooSync/config/config.xml"
APP_API_KEY=""
APP_FOLDER=""
xcrun simctl launch "$SIMULATOR_UDID" "$APP_BUNDLE_ID" >/dev/null
for _ in $(seq 1 30); do
	if [[ -f "$APP_CONFIG" ]]; then
		APP_API_KEY="$(python3 - "$APP_CONFIG" <<'PY'
import sys
import xml.etree.ElementTree as ET

node = ET.parse(sys.argv[1]).getroot().find("./gui/apikey")
print(node.text if node is not None and node.text else "")
PY
)"
		if [[ -n "$APP_API_KEY" ]] && curl --noproxy '*' --max-time 2 -fsS \
			-H "X-API-Key: $APP_API_KEY" "$APP_REST/rest/system/status" >/dev/null 2>&1; then
			APP_FOLDER="$(api_request "$APP_REST" "$APP_API_KEY" GET /rest/config/folders | python3 -c 'import json,sys; folder_id=sys.argv[1]; folders=json.load(sys.stdin); folder=next((item for item in folders if item.get("id")==folder_id), None); print(folder.get("path", "") if folder else "")' "$APP_FOLDER_ID" || true)"
			if [[ "$APP_FOLDER" == "$APP_DATA/Documents/Vaults/"* && -d "$APP_FOLDER" ]]; then
				break
			fi
		fi
	fi
	sleep 1
done
[[ "$APP_FOLDER" == "$APP_DATA/Documents/Vaults/"* && -d "$APP_FOLDER" ]] || \
	fail "The simulator did not rebase its E2E vault after the UI-test app container changed."

KEPT_COPY="$(find "$APP_FOLDER" -type f -name '*conflict copy*' -print -quit)"
[[ -n "$KEPT_COPY" ]] || fail "The app did not preserve the conflict copy."
grep -Eq 'Edited on the (iPhone|Docker) peer' "$KEPT_COPY" || fail "The kept conflict copy has unexpected contents."
if find "$APP_FOLDER" -type f -name '*sync-conflict-*' -print -quit | rg -q .; then
	fail "A conflict file remained after choosing Keep copy."
fi
[[ -f "$APP_FOLDER/Welcome.md" && -f "$DESKTOP_FOLDER/From iPhone.md" ]] || fail "A two-way synced note is missing after conflict handling."

set_folder_paused "$PEER_REST" "$PEER_API_KEY" false
wait_for_file "$DESKTOP_FOLDER/Conflicted note (conflict copy).md" "kept conflict copy on the Docker peer"
for _ in $(seq 1 90); do
	APP_CONFLICT="$(find "$APP_FOLDER" -type f -name '*sync-conflict-*' -print -quit)"
	PEER_CONFLICT="$(find "$DESKTOP_FOLDER" -type f -name '*sync-conflict-*' -print -quit)"
	[[ -z "$APP_CONFLICT" && -z "$PEER_CONFLICT" ]] && break
	sleep 1
done
[[ -z "$APP_CONFLICT" && -z "$PEER_CONFLICT" ]] || fail "The conflict reappeared after the Docker peer resumed."

printf '%s\n' \
	'PASS: embedded iOS Syncthing core paired with Docker Syncthing.' \
	'PASS: sample Obsidian vault synced in both directions.' \
	'PASS: concurrent edits created a Syncthing conflict copy.' \
	'PASS: app Keep copy preserved the conflict and removed its conflict suffix.' \
	'PASS: kept copy synced to Docker and removed the conflict on both peers.'
