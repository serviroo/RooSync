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

print_xcresult_failure_diagnostics() {
	local result_bundle=$1 name=$2
	[[ -f "$result_bundle/Info.plist" ]] || return 0
	python3 - "$result_bundle" "$E2E_DIR/failure-diagnostics/$name" <<'PY' 2>&1 | tee "$E2E_DIR/failure-diagnostics/$name-xcresult.log" >&2
import json
import os
import re
import subprocess
import sys

result_path, output_dir = sys.argv[1:]
os.makedirs(output_dir, exist_ok=True)

def xcresult(*args, timeout=30):
	return subprocess.run(
		["xcrun", "xcresulttool", *args], capture_output=True, text=True, timeout=timeout
	)

def sanitize(value):
	value = re.sub(r"\b[A-Z2-7]{7}(?:-[A-Z2-7]{7}){7}\b", "[REDACTED_DEVICE_ID]", value)
	return re.sub(r"(?i)(Type )'[^']{24,}'", r"\1'[REDACTED_INPUT]'", value)

try:
	tests = xcresult("get", "test-results", "tests", "--path", result_path, "--compact")
	if tests.returncode:
		print("xcresult test summary unavailable")
		raise SystemExit(0)
	test_report = json.loads(tests.stdout)
except (OSError, subprocess.SubprocessError, ValueError) as error:
	print(f"xcresult test summary unavailable: {error}")
	raise SystemExit(0)

failed = []
def collect(node):
	if isinstance(node, dict):
		if node.get("nodeType") == "Test Case" and node.get("result") == "Failed":
			failed.append((node.get("nodeIdentifierURL", ""), node.get("name", "failed test")))
		for child in node.values():
			collect(child)
	elif isinstance(node, list):
		for child in node:
			collect(child)

collect(test_report.get("testNodes", []))
for test_id, test_name in failed[:6]:
	if not test_id:
		continue
	print(f"\n--- xcresult failed test: {sanitize(test_name)} ---")
	try:
		activities = xcresult(
			"get", "test-results", "activities", "--path", result_path,
			"--test-id", test_id, "--compact"
		)
		activity_report = json.loads(activities.stdout) if activities.returncode == 0 else {}
	except (OSError, subprocess.SubprocessError, ValueError):
		activity_report = {}
	titles = []
	def collect_titles(node):
		if isinstance(node, dict):
			for key in ("title", "name", "activityTitle"):
				value = node.get(key)
				if isinstance(value, str):
					titles.append(sanitize(value))
			for child in node.values():
				collect_titles(child)
		elif isinstance(node, list):
			for child in node:
				collect_titles(child)
	collect_titles(activity_report)
	for title in titles[-40:]:
		print(f"[activity] {title[:180]}")

attachment_dir = os.path.join(output_dir, "attachments")
os.makedirs(attachment_dir, exist_ok=True)
try:
	exported = xcresult(
		"export", "attachments", "--path", result_path,
		"--output-path", attachment_dir, "--only-failures", timeout=60
	)
	manifest_path = os.path.join(attachment_dir, "manifest.json")
	manifest = json.load(open(manifest_path)) if exported.returncode == 0 and os.path.isfile(manifest_path) else []
except (OSError, subprocess.SubprocessError, ValueError):
	manifest = []

for test in manifest:
	for attachment in test.get("attachments", []):
		name = attachment.get("suggestedHumanReadableName", "")
		filename = attachment.get("exportedFileName", "")
		if not (
			name.startswith("Complete Issue Description")
			or name.startswith("App UI hierarchy")
			or name.startswith("Self-add failure-time UI hierarchy")
			or name.startswith("Self-add keyboard focus state")
		):
			continue
		path = os.path.join(attachment_dir, filename)
		try:
			with open(path, encoding="utf-8", errors="replace") as attachment_file:
				lines = attachment_file.read().splitlines()
		except OSError:
			continue
		print(f"--- {sanitize(name)} ---")
		if name.startswith("Complete Issue Description"):
			print("\n".join(sanitize(line) for line in lines[:35]))
			continue
		if name.startswith("Self-add keyboard focus state"):
			print("\n".join(sanitize(line)[:240] for line in lines[:12]))
			continue
		pattern = re.compile(r"Browse View \(Picker\)|DOC\.browsingRoot|BackButton|On My iPhone|Vaults, Folder|device-id-entry|Add device|Keyboard", re.I)
		selected = set()
		for index, line in enumerate(lines):
			if pattern.search(line):
				selected.update(range(max(0, index - 1), min(len(lines), index + 2)))
		if not selected:
			selected.update(range(min(len(lines), 35)))
		for index in sorted(selected)[:80]:
			print(sanitize(lines[index])[:240])
PY
}

capture_failure_diagnostics() {
	local diagnostics="$E2E_DIR/failure-diagnostics"
	local conflict_path relative_path encoded response side base key
	local -a conflict_paths=(
		"Conflicted note.md"
		"Extensionless conflict"
		"Conflicted note (conflict copy).md"
		"Extensionless conflict (conflict copy)"
		"Legacy note (conflict copy).md"
		"Legacy extensionless (conflict copy)"
	)
	mkdir -p "$diagnostics"
	print_xcresult_failure_diagnostics "$E2E_DIR/RooSync-E2E.xcresult" ui
	print_xcresult_failure_diagnostics "$E2E_DIR/PendingFolderIDCollision-E2E.xcresult" pending-collision
	print_xcresult_failure_diagnostics "$E2E_DIR/FocusedSelfAddAndOffer-E2E.xcresult" focused-ui
	print_xcresult_failure_diagnostics "$E2E_DIR/FocusedDuoLayout-E2E.xcresult" duo-focused-ui
	{
		printf 'run_id=%s\n' "$RUN_ID"
		printf 'simulator_udid=%s\n' "${SIMULATOR_UDID:-unavailable}"
		printf 'app_folder_id=%s\n' "$APP_FOLDER_ID"
		printf 'app_folder_path=%s\n' "${APP_FOLDER:-unavailable}"
		printf 'peer_container=%s\n' "$CONTAINER_NAME"
		printf 'remaining_app_conflict=%s\n' "${APP_CONFLICT:-not-checked}"
		printf 'remaining_peer_conflict=%s\n' "${PEER_CONFLICT:-not-checked}"
	} >"$diagnostics/summary.log" 2>&1

	if [[ -n "${SIMULATOR_UDID:-}" ]]; then
		xcrun simctl spawn "$SIMULATOR_UDID" log show --last 5m --style compact \
			--predicate 'process == "runningboardd" OR process == "SpringBoard" OR process == "ReportCrash" OR process == "crashreporterd"' \
		2>&1 | grep -iE 'RooSync|com\.rooindustries\.roosync' | \
		grep -iE 'terminat|crash|signal|kill|jetsam|watchdog|memory|exit|launch' | tail -80 \
			>"$diagnostics/simulator-lifecycle.log" || true
		xcrun simctl spawn "$SIMULATOR_UDID" log show --last 10m --style compact \
			--predicate 'process CONTAINS[c] "RooSync" OR subsystem CONTAINS[c] "com.rooindustries.roosync"' \
			>"$diagnostics/roosync-simulator.log" 2>&1 || true
		xcrun simctl spawn "$SIMULATOR_UDID" log show --last 10m --style compact \
			--predicate 'process == "sharingd" OR process == "lsd" OR process CONTAINS[c] "share" OR process CONTAINS[c] "activity" OR subsystem CONTAINS[c] "com.apple.sharing" OR subsystem CONTAINS[c] "LaunchServices"' \
			>"$diagnostics/sharing-services-simulator.log" 2>&1 || true
	fi

	if ((${#DOCKER[@]})); then
		"${DOCKER[@]}" inspect --format '{{json .State}}' "$CONTAINER_NAME" \
			>"$diagnostics/docker-peer-state.log" 2>&1 || true
		"${DOCKER[@]}" logs --timestamps --tail 1000 "$CONTAINER_NAME" \
			>"$diagnostics/docker-peer.log" 2>&1 || true
		"${DOCKER[@]}" exec --user "${PEER_UID:-0}:${PEER_GID:-0}" "$CONTAINER_NAME" \
			sh -c 'for path in "/vault/Conflicted note.md" "/vault/Extensionless conflict"; do if [ -f "$path" ]; then printf "%s " "$path"; wc -c < "$path"; fi; done' \
			>"$diagnostics/docker-conflict-files.log" 2>&1 || true
		"${DOCKER[@]}" exec --user "${PEER_UID:-0}:${PEER_GID:-0}" "$CONTAINER_NAME" \
			find /vault -type f -name '*sync-conflict-*' -print \
			>"$diagnostics/peer-conflict-suffix-files.log" 2>&1 || true
	fi
	if [[ -n "${APP_FOLDER:-}" && -d "$APP_FOLDER" ]]; then
		find "$APP_FOLDER" -type f -name '*sync-conflict-*' -print \
			>"$diagnostics/app-conflict-suffix-files.log" 2>&1 || true
		while IFS= read -r conflict_path; do
			[[ -n "$conflict_path" ]] && shasum -a 256 "$conflict_path" >>"$diagnostics/app-conflict-suffix-hashes.log" 2>&1 || true
		done <"$diagnostics/app-conflict-suffix-files.log"
	fi
	if [[ -s "$diagnostics/peer-conflict-suffix-files.log" ]]; then
		while IFS= read -r conflict_path; do
			[[ -n "$conflict_path" ]] && "${DOCKER[@]}" exec --user "${PEER_UID:-0}:${PEER_GID:-0}" "$CONTAINER_NAME" sha256sum "$conflict_path" >>"$diagnostics/peer-conflict-suffix-hashes.log" 2>&1 || true
		done <"$diagnostics/peer-conflict-suffix-files.log"
	fi

	if declare -F api_request >/dev/null; then
		if [[ -n "${APP_API_KEY:-}" ]]; then
			api_request "$APP_REST" "$APP_API_KEY" GET "/rest/db/status?folder=$APP_FOLDER_ID" \
				>"$diagnostics/app-folder-status.log" 2>&1 || true
			api_request "$APP_REST" "$APP_API_KEY" GET /rest/system/connections \
				>"$diagnostics/app-connections.log" 2>&1 || true
			api_request "$APP_REST" "$APP_API_KEY" GET /rest/system/error \
				>"$diagnostics/app-system-errors.log" 2>&1 || true
			api_request "$APP_REST" "$APP_API_KEY" GET "/rest/db/file?folder=$APP_FOLDER_ID&file=Conflicted%20note.md" \
				>"$diagnostics/app-conflict-file.log" 2>&1 || true
		fi
		if [[ -n "${PEER_API_KEY:-}" ]]; then
			api_request "$PEER_REST" "$PEER_API_KEY" GET "/rest/db/status?folder=$APP_FOLDER_ID" \
				>"$diagnostics/peer-folder-status.log" 2>&1 || true
			api_request "$PEER_REST" "$PEER_API_KEY" GET /rest/system/connections \
				>"$diagnostics/peer-connections.log" 2>&1 || true
			api_request "$PEER_REST" "$PEER_API_KEY" GET /rest/system/error \
				>"$diagnostics/peer-system-errors.log" 2>&1 || true
			api_request "$PEER_REST" "$PEER_API_KEY" GET "/rest/db/file?folder=$APP_FOLDER_ID&file=Conflicted%20note.md" \
				>"$diagnostics/peer-conflict-file.log" 2>&1 || true
		fi
		if [[ -n "${APP_API_KEY:-}" && -n "${PEER_API_KEY:-}" ]]; then
			[[ -n "${LEGACY_CONFLICT_TIMESTAMP:-}" ]] && conflict_paths+=(
				"Legacy note.sync-conflict-$LEGACY_CONFLICT_TIMESTAMP.md"
				"Legacy extensionless.sync-conflict-$LEGACY_CONFLICT_TIMESTAMP"
			)
			[[ -n "${APP_CONFLICT:-}" && -n "${APP_FOLDER:-}" ]] && conflict_paths+=("${APP_CONFLICT#"$APP_FOLDER"/}")
			[[ -n "${PEER_CONFLICT:-}" && -n "${DESKTOP_FOLDER:-}" ]] && conflict_paths+=("${PEER_CONFLICT#"$DESKTOP_FOLDER"/}")
			for relative_path in "${conflict_paths[@]}"; do
				encoded="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$relative_path")"
				for side in app peer; do
					if [[ "$side" == app ]]; then base="$APP_REST"; key="$APP_API_KEY"; else base="$PEER_REST"; key="$PEER_API_KEY"; fi
					response="$(api_request "$base" "$key" GET "/rest/db/file?folder=$APP_FOLDER_ID&file=$encoded" "" 3 2>/dev/null || true)"
					printf 'path=%q side=%s ' "$relative_path" "$side" >>"$diagnostics/conflict-index-versions.log"
					python3 -c 'import json,sys
try: d=json.loads(sys.stdin.read())
except Exception: print("unavailable"); raise SystemExit
for k in ("global","local"):
 f=d.get(k,{})
 print("%sVersion=%s %sDeleted=%s %sHash=%s"%(k,"|".join(f.get("version") or []),k,f.get("deleted"),k,f.get("blocksHash")),end=" ")
print()' <<<"$response" >>"$diagnostics/conflict-index-versions.log" 2>&1 || true
				done
			done
		fi
	fi

	printf '\nE2E failure diagnostics (API keys and config XML omitted):\n' >&2
	for name in summary.log docker-peer-state.log docker-conflict-files.log app-conflict-suffix-files.log peer-conflict-suffix-files.log app-conflict-suffix-hashes.log peer-conflict-suffix-hashes.log conflict-index-versions.log app-folder-status.log app-connections.log app-system-errors.log app-conflict-file.log peer-folder-status.log peer-connections.log peer-system-errors.log peer-conflict-file.log; do
		if [[ -s "$diagnostics/$name" ]]; then
			printf '\n--- %s ---\n' "$name" >&2
			sed -n '1,120p' "$diagnostics/$name" >&2 || true
		fi
	done
	if [[ -s "$diagnostics/docker-peer.log" ]]; then
		printf '\n--- Docker peer relevant logs ---\n' >&2
		grep -iE 'error|warning|failed|marker|conflict|synced file|folder.*(state|error)' "$diagnostics/docker-peer.log" | tail -80 >&2 || true
	fi
	if [[ -s "$diagnostics/roosync-simulator.log" ]]; then
		printf '\n--- Simulator relevant logs ---\n' >&2
		grep -iE 'error|warning|failed|marker|conflict|folder|scan' "$diagnostics/roosync-simulator.log" | tail -80 >&2 || true
	fi
	if [[ -s "$diagnostics/sharing-services-simulator.log" ]]; then
		printf '\n--- Sharing-service and LaunchServices diagnostics ---\n' >&2
		grep -iE 'error|warning|fault|crash|terminat|launch|denied|share|activity|service|timeout|invalid' "$diagnostics/sharing-services-simulator.log" | tail -100 >&2 || true
	fi
	if [[ -s "$diagnostics/simulator-lifecycle.log" ]]; then
		printf '\n--- Bounded simulator crash/termination diagnostics ---\n' >&2
		cat "$diagnostics/simulator-lifecycle.log" >&2
	fi
	if [[ -s "$E2E_DIR/lima-forward.log" ]]; then
		printf '\n--- Lima forwarding log ---\n' >&2
		tail -50 "$E2E_DIR/lima-forward.log" >&2 || true
	fi
}

cleanup() {
	local status=$?
	trap - EXIT
	if [[ "$status" -ne 0 ]]; then
		capture_failure_diagnostics || true
	fi
	if [[ -n "$SIMULATOR_UDID" && "$APP_INSTALLED" == 1 ]]; then
		xcrun simctl terminate "$SIMULATOR_UDID" "$APP_BUNDLE_ID" >/dev/null 2>&1 || true
	fi
	if [[ -n "$TUNNEL_PID" ]]; then
		if [[ -n "${LIMA_HOME:-}" && -f "$LIMA_HOME/colima/ssh.config" ]]; then
			ssh -F "$LIMA_HOME/colima/ssh.config" -O cancel -L 127.0.0.1:8385:127.0.0.1:8385 lima-colima >/dev/null 2>&1 || true
			ssh -F "$LIMA_HOME/colima/ssh.config" -O cancel -L "127.0.0.1:$PEER_SYNC_PORT:127.0.0.1:$PEER_SYNC_PORT" lima-colima >/dev/null 2>&1 || true
		fi
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

if [[ "${ROOSYNC_DUO_LAYOUT_TESTS:-0}" == 1 ]]; then
	[[ "${ROOSYNC_FOCUSED_UI_TESTS:-0}" != 1 ]] || fail "Choose either generic focused UI tests or Duo layout tests, not both."
	[[ "${ROOSYNC_DUO_SIMULATOR_VERIFIED:-0}" == 1 && -n "$SIMULATOR_UDID" ]] || \
		fail "Duo layout tests require a simulator verified by the exact Duo preflight."
fi

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
	grep -nE 'error:|warning:|BUILD FAILED|TEST BUILD FAILED' "$E2E_DIR/build.log" | tail -80 >&2 || true
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
GUI_AUTH_CONFIGURED="$(python3 - "$APP_CONFIG" <<'PY'
import sys
import xml.etree.ElementTree as ET

gui = ET.parse(sys.argv[1]).getroot().find("./gui")
user = gui.findtext("user", "") if gui is not None else ""
password = gui.findtext("password", "") if gui is not None else ""
print(str(bool(user) and password.startswith(("$2a$", "$2b$", "$2y$"))).lower())
PY
)"
[[ "$GUI_AUTH_CONFIGURED" == true ]] || fail "The embedded GUI does not have a nonempty user and bcrypt password hash."

DESKTOP_FOLDER="$E2E_DIR/desktop-vault"
mkdir -p "$DESKTOP_FOLDER"
chmod 755 "$DESKTOP_FOLDER"
cp -R "$ROOT/docs/fixtures/ObsidianVault/.obsidian" "$DESKTOP_FOLDER/"
cp "$ROOT/docs/fixtures/ObsidianVault/Welcome.md" "$DESKTOP_FOLDER/"
cp "$ROOT/docs/fixtures/ObsidianVault/Conflicted note.md" "$DESKTOP_FOLDER/"

if ! "${DOCKER[@]}" image inspect "$PEER_IMAGE" >/dev/null 2>&1; then
	peer_pull_succeeded=false
	for attempt in 1 2 3; do
		if "${DOCKER[@]}" pull "$PEER_IMAGE"; then
			peer_pull_succeeded=true
			break
		fi
		if (( attempt < 3 )); then
			sleep $((attempt * 5))
		fi
	done
	[[ "$peer_pull_succeeded" == true ]] || fail "Could not pull Docker Syncthing image after three attempts."
fi

"${DOCKER[@]}" volume create "$VOLUME_NAME" >/dev/null
PEER_UID="$(id -u)"
PEER_GID="$(id -g)"
"${DOCKER[@]}" run -d --name "$CONTAINER_NAME" --user 0:0 \
	-e PUID="$PEER_UID" \
	-e PGID="$PEER_GID" \
	-e STGUIADDRESS=0.0.0.0:8384 \
	-v "$VOLUME_NAME:/var/syncthing" \
	-v "$DESKTOP_FOLDER:/vault:rw" \
	-p 127.0.0.1:8385:8384/tcp \
	-p "127.0.0.1:$PEER_SYNC_PORT:22000/tcp" \
	-p "127.0.0.1:$PEER_SYNC_PORT:22000/udp" \
	"$PEER_IMAGE" >/dev/null

PEER_REST_READY_TIMEOUT_SECONDS=300
peer_rest_deadline=$((SECONDS + PEER_REST_READY_TIMEOUT_SECONDS))
peer_rest_ready=false
while (( SECONDS < peer_rest_deadline )); do
	if curl --noproxy '*' --connect-timeout 2 --max-time 2 -fsS "$PEER_REST/rest/noauth/health" >/dev/null 2>&1; then
		peer_rest_ready=true
		break
	fi
	sleep 2
done
[[ "$peer_rest_ready" == true ]] || fail "Docker Syncthing REST API did not start on 127.0.0.1:8385 within ${PEER_REST_READY_TIMEOUT_SECONDS}s."
PEER_API_KEY="$("${DOCKER[@]}" exec "$CONTAINER_NAME" cat /var/syncthing/config/config.xml | python3 -c 'import sys,xml.etree.ElementTree as ET; node=ET.fromstring(sys.stdin.read()).find("./gui/apikey"); print(node.text if node is not None and node.text else "")')"
[[ -n "$PEER_API_KEY" ]] || fail "The Docker peer REST API key is missing."

api_request() {
	local base=$1 key=$2 method=$3 route=$4 body=${5:-} timeout=${6:-}
	local -a curl_options
	if [[ -n "$timeout" ]]; then
		curl_options=(--connect-timeout 2 --max-time "$timeout" --config - --noproxy '*' -fsS -X "$method")
	else
		curl_options=(--config - --noproxy '*' -fsS -X "$method")
	fi
	if [[ -n "$body" ]]; then
		printf 'header = "X-API-Key: %s"\n' "$key" |
			curl "${curl_options[@]}" \
				-H 'Content-Type: application/json' --data-binary "$body" "$base$route"
	else
		printf 'header = "X-API-Key: %s"\n' "$key" |
			curl "${curl_options[@]}" "$base$route"
	fi
}

peer_rest_authenticated_ready=false
while (( SECONDS < peer_rest_deadline )); do
	if api_request "$PEER_REST" "$PEER_API_KEY" GET /rest/system/status "" 2 >/dev/null 2>&1 &&
		api_request "$PEER_REST" "$PEER_API_KEY" GET /rest/config/devices "" 2 >/dev/null 2>&1; then
		peer_rest_authenticated_ready=true
		break
	fi
	sleep 2
done
[[ "$peer_rest_authenticated_ready" == true ]] || fail "Docker Syncthing authenticated REST API did not become ready within ${PEER_REST_READY_TIMEOUT_SECONDS}s."
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
printf 'Initial extensionless conflict content\n' > "$APP_FOLDER/Extensionless conflict"

add_folder() {
	local base=$1 key=$2 path=$3 device=$4 ignore_perms=$5 defaults body
	defaults="$(api_request "$base" "$key" GET /rest/config/defaults/folder)"
	body="$(python3 -c 'import json,sys; value=json.load(sys.stdin); value["id"]=sys.argv[1]; value["label"]=sys.argv[2]; value["path"]=sys.argv[3]; value["devices"]=[{"deviceID":sys.argv[4]}]; value["ignorePerms"]=sys.argv[5].lower()=="true"; print(json.dumps(value))' "$APP_FOLDER_ID" "$APP_FOLDER_LABEL" "$path" "$device" "$ignore_perms" <<<"$defaults")"
	api_request "$base" "$key" POST /rest/config/folders "$body" >/dev/null
}

add_folder "$APP_REST" "$APP_API_KEY" "$APP_FOLDER" "$PEER_ID" false
add_folder "$PEER_REST" "$PEER_API_KEY" /vault "$APP_ID" true

EXISTING_OFFER_ID="roosync-e2e-existing-offer"
EXISTING_OFFER_PATH="$APP_DATA/Documents/Vaults/Existing E2E Offer"
UNICODE_EXISTING_ID="$(python3 -c 'print("caf\u00e9-e2e")')"
UNICODE_OFFER_ID="$(python3 -c 'print("cafe\u0301-e2e")')"
UNICODE_EXISTING_LABEL="Composed Unicode E2E Folder"
UNICODE_EXISTING_PATH="$APP_DATA/Documents/Vaults/$UNICODE_EXISTING_LABEL"
mkdir -p "$EXISTING_OFFER_PATH"
mkdir -p "$UNICODE_EXISTING_PATH"
add_folder_config() {
	local base=$1 key=$2 folder_id=$3 label=$4 path=$5 device=$6 defaults body
	defaults="$(api_request "$base" "$key" GET /rest/config/defaults/folder)"
	body="$(python3 -c 'import json,sys; v=json.load(sys.stdin); v["id"]=sys.argv[1]; v["label"]=sys.argv[2]; v["path"]=sys.argv[3]; v["devices"]=[{"deviceID":sys.argv[4]}] if sys.argv[4] else []; print(json.dumps(v))' "$folder_id" "$label" "$path" "$device" <<<"$defaults")"
	api_request "$base" "$key" POST /rest/config/folders "$body" >/dev/null
}
add_folder_config "$APP_REST" "$APP_API_KEY" "$EXISTING_OFFER_ID" "Existing E2E Offer" "$EXISTING_OFFER_PATH" ""
add_folder_config "$APP_REST" "$APP_API_KEY" "$UNICODE_EXISTING_ID" "$UNICODE_EXISTING_LABEL" "$UNICODE_EXISTING_PATH" ""
PLUS_FOLDER_ID="notes+work"
PLUS_FOLDER_LABEL="Plus ID E2E Folder"
PLUS_FOLDER_PATH="$APP_DATA/Documents/Vaults/$PLUS_FOLDER_LABEL"
mkdir -p "$PLUS_FOLDER_PATH"
add_folder_config "$APP_REST" "$APP_API_KEY" "$PLUS_FOLDER_ID" "$PLUS_FOLDER_LABEL" "$PLUS_FOLDER_PATH" ""
"${DOCKER[@]}" exec --user "$PEER_UID:$PEER_GID" "$CONTAINER_NAME" \
	mkdir -p /tmp/roosync-existing /tmp/roosync-slash /tmp/roosync-empty /tmp/roosync-unicode
add_folder_config "$PEER_REST" "$PEER_API_KEY" "$EXISTING_OFFER_ID" "Remote Existing Offer" /tmp/roosync-existing "$APP_ID"
add_folder_config "$PEER_REST" "$PEER_API_KEY" "$UNICODE_OFFER_ID" "Decomposed Unicode E2E Offer" /tmp/roosync-unicode "$APP_ID"
add_folder_config "$PEER_REST" "$PEER_API_KEY" roosync-e2e-slash-label "Incoming/Notes" /tmp/roosync-slash "$APP_ID"
add_folder_config "$PEER_REST" "$PEER_API_KEY" roosync-e2e-empty-label "" /tmp/roosync-empty "$APP_ID"

CSRF_PROBE_DIR="$E2E_DIR/csrf-probe"
mkdir -p "$CSRF_PROBE_DIR"
curl --noproxy '*' -sS -o /dev/null -D "$CSRF_PROBE_DIR/root.headers" \
	-c "$CSRF_PROBE_DIR/cookies" "$APP_REST/" || fail "The unauthenticated GUI root probe failed."
CSRF_COOKIE_NAME="$(awk '$6 ~ /^CSRF-Token-/ {print $6}' "$CSRF_PROBE_DIR/cookies" | tail -1)"
CSRF_COOKIE_VALUE="$(awk -v name="$CSRF_COOKIE_NAME" '$6==name {print $7}' "$CSRF_PROBE_DIR/cookies" | tail -1)"
CSRF_HEADERS=()
if [[ -n "$CSRF_COOKIE_NAME" && -n "$CSRF_COOKIE_VALUE" ]]; then
	CSRF_HEADERS=(-H "X-$CSRF_COOKIE_NAME: $CSRF_COOKIE_VALUE")
fi
CSRF_REST_STATUS="$(curl --noproxy '*' -sS -o /dev/null -w '%{http_code}' \
	-b "$CSRF_PROBE_DIR/cookies" "${CSRF_HEADERS[@]}" -X POST \
	"$APP_REST/rest/db/scan?folder=$APP_FOLDER_ID" || true)"
[[ "$CSRF_REST_STATUS" == 401 || "$CSRF_REST_STATUS" == 403 ]] || \
	fail "An unauthenticated root-cookie/CSRF request reached REST (HTTP $CSRF_REST_STATUS)."
PEER_IGNORE_PERMS="$(api_request "$PEER_REST" "$PEER_API_KEY" GET /rest/config/folders | python3 -c 'import json,sys; folder_id=sys.argv[1]; folders=json.load(sys.stdin); folder=next((item for item in folders if item.get("id")==folder_id), None); print(str(bool(folder.get("ignorePerms"))).lower() if folder else "")' "$APP_FOLDER_ID")"
[[ "$PEER_IGNORE_PERMS" == true ]] || fail "Docker peer folder did not enable ignorePerms for its host-mounted vault."

set_folder_paused() {
	local base=$1 key=$2 paused=$3 actual
	api_request "$base" "$key" PATCH "/rest/config/folders/$APP_FOLDER_ID" "{\"paused\":$paused}" >/dev/null
	actual="$(api_request "$base" "$key" GET /rest/config/folders | python3 -c 'import json,sys; folder_id=sys.argv[1]; folders=json.load(sys.stdin); folder=next((item for item in folders if item.get("id")==folder_id), None); print(str(bool(folder.get("paused"))).lower() if folder else "")' "$APP_FOLDER_ID")"
	[[ "$actual" == "$paused" ]] || fail "Syncthing folder pause state was $actual, expected $paused."
}

set_device_paused() {
	local base=$1 key=$2 device_id=$3 paused=$4 actual
	api_request "$base" "$key" PATCH "/rest/config/devices/$device_id" "{\"paused\":$paused}" >/dev/null
	actual="$(api_request "$base" "$key" GET "/rest/config/devices/$device_id" | python3 -c 'import json,sys; print(str(bool(json.load(sys.stdin).get("paused"))).lower())')"
	[[ "$actual" == "$paused" ]] || fail "Syncthing device pause state was $actual, expected $paused."
}

wait_for_device_connection_state() {
	local base=$1 key=$2 device_id=$3 paused=$4 expected_connected connections ready
	expected_connected=false
	[[ "$paused" == true ]] || expected_connected=true
	for _ in $(seq 1 90); do
		connections="$(api_request "$base" "$key" GET /rest/system/connections)"
		ready="$(python3 -c 'import json,sys; data=json.load(sys.stdin); status=data.get("connections", {}).get(sys.argv[1], {}); paused=sys.argv[2]=="true"; connected=sys.argv[3]=="true"; print(str(bool(status.get("paused"))==paused and bool(status.get("connected"))==connected).lower())' "$device_id" "$paused" "$expected_connected" <<<"$connections")"
		[[ "$ready" == true ]] && return 0
		sleep 1
	done
	fail "Syncthing device $device_id did not reach paused=$paused, connected=$expected_connected."
}

local_file_version() {
	local base=$1 key=$2 file_query=$3
	api_request "$base" "$key" GET "/rest/db/file?folder=$APP_FOLDER_ID&file=$file_query" |
		python3 -c 'import json,sys; data=json.load(sys.stdin); print(json.dumps((data.get("local") or {}).get("version"), sort_keys=True))'
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

run_pending_folder_collision_test() {
	set_folder_paused "$APP_REST" "$APP_API_KEY" true
	xcrun simctl terminate "$SIMULATOR_UDID" "$APP_BUNDLE_ID" >/dev/null 2>&1 || true
	python3 - "$APP_DATA/Library/Preferences/com.rooindustries.roosync.plist" "$APP_FOLDER_ID" <<'PY'
import os
import plistlib
import sys

path, folder_id = sys.argv[1:]
values = {}
if os.path.exists(path):
    with open(path, "rb") as preferences_file:
        values = plistlib.load(preferences_file)
values["pauseOnBattery"] = False
values["pauseOnCellular"] = False
values["policyPausedFolders"] = [folder_id]
with open(path, "wb") as preferences_file:
    plistlib.dump(values, preferences_file)
PY
	"${DOCKER[@]}" exec --user "$PEER_UID:$PEER_GID" "$CONTAINER_NAME" \
		mkdir -p /tmp/roosync-unicode-collision
	add_folder_config "$PEER_REST" "$PEER_API_KEY" "$UNICODE_EXISTING_ID" "Canonical Collision E2E Offer" /tmp/roosync-unicode-collision "$APP_ID"
	xcodebuild -project "$ROOT/RooSync.xcodeproj" -scheme RooSync \
		-destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
		-derivedDataPath "$DERIVED_DATA" -parallel-testing-enabled NO \
		-maximum-concurrent-test-simulator-destinations 1 \
		CODE_SIGNING_ALLOWED=NO test-without-building \
		-only-testing:RooSyncUITests/RooSyncUITests/testCanonicalEquivalentPendingFolderIDsFailClosed \
		-resultBundlePath "$E2E_DIR/PendingFolderIDCollision-E2E.xcresult" >"$E2E_DIR/pending-folder-collision-test.log" 2>&1 || {
		grep -nE 'error:|failed|Failure|TEST FAILED' "$E2E_DIR/pending-folder-collision-test.log" | tail -80 >&2 || true
		fail "Canonical-equivalent pending folder IDs were not rejected; see $E2E_DIR/pending-folder-collision-test.log."
	}
	APP_DATA="$(xcrun simctl get_app_container "$SIMULATOR_UDID" "$APP_BUNDLE_ID" data)"
	APP_CONFIG="$APP_DATA/Library/Application Support/RooSync/config/config.xml"
	python3 - "$APP_CONFIG" "$APP_DATA/Library/Preferences/com.rooindustries.roosync.plist" "$APP_FOLDER_ID" <<'PY' || fail "A pending-folder collision prevented configured-folder power policy reconciliation."
import plistlib
import sys
import xml.etree.ElementTree as ET

config_path, preferences_path, folder_id = sys.argv[1:]
folder = next(
    (node for node in ET.parse(config_path).getroot().findall("folder") if node.get("id") == folder_id),
    None,
)
assert folder is not None and folder.get("paused", "false").lower() == "false"
with open(preferences_path, "rb") as preferences_file:
    preferences = plistlib.load(preferences_file)
assert folder_id not in preferences.get("policyPausedFolders", [])
PY
}

if [[ "${ROOSYNC_E2E_ONLY_PENDING_COLLISION:-0}" == 1 ]]; then
	PENDING_OFFER_READY=false
	for _ in $(seq 1 90); do
		PENDING_FOLDERS="$(api_request "$APP_REST" "$APP_API_KEY" GET /rest/cluster/pending/folders || true)"
		if python3 -c 'import json,sys; print(str(sys.argv[1] in json.load(sys.stdin)).lower())' "$UNICODE_OFFER_ID" \
			<<<"$PENDING_FOLDERS" 2>/dev/null | grep -Eq '^true$'; then
			PENDING_OFFER_READY=true
			break
		fi
		sleep 1
	done
	[[ "$PENDING_OFFER_READY" == true ]] || fail "The first Unicode-equivalent pending offer did not reach the simulator."
	run_pending_folder_collision_test
	printf '%s\n' 'PASS: pending-ID collisions fail closed while configured status and policy refresh.'
	exit 0
fi

if [[ "${ROOSYNC_DUO_LAYOUT_TESTS:-0}" == 1 ]]; then
	xcrun simctl terminate "$SIMULATOR_UDID" "$APP_BUNDLE_ID" >/dev/null 2>&1 || true
	APP_INSTALLED=1
	xctestrun_file="$(find "$DERIVED_DATA/Build/Products" -maxdepth 1 -type f -name '*.xctestrun' -print -quit)"
	[[ -n "$xctestrun_file" ]] || fail "Duo tests require the generated Xcode test run specification."
	python3 - "$xctestrun_file" <<'PY' || fail "Could not configure Duo variables in the Xcode test run specification."
import plistlib
import sys

path = sys.argv[1]
with open(path, "rb") as source:
    specification = plistlib.load(source)

test_targets = []
def collect_targets(node):
    if isinstance(node, dict):
        if node.get("BlueprintName") == "RooSyncUITests":
            test_targets.append(node)
        for child in node.values():
            collect_targets(child)
    elif isinstance(node, list):
        for child in node:
            collect_targets(child)

collect_targets(specification)
if len(test_targets) != 1:
    raise SystemExit(f"Expected one RooSyncUITests target in xctestrun, found {len(test_targets)}")

environment = test_targets[0].setdefault("TestingEnvironmentVariables", {})
environment["ROOSYNC_DUO_LAYOUT_TESTS"] = "1"
environment["ROOSYNC_DUO_SIMULATOR_VERIFIED"] = "1"
with open(path, "wb") as destination:
    plistlib.dump(specification, destination)
PY
		xcodebuild -xctestrun "$xctestrun_file" \
		-destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
		-parallel-testing-enabled NO \
		-maximum-concurrent-test-simulator-destinations 1 \
		CODE_SIGNING_ALLOWED=NO test-without-building \
		-only-testing:RooSyncUITests/RooSyncUITests/testCannotAddLocalDeviceID \
		-only-testing:RooSyncUITests/RooSyncUITests/testAcceptingOfferForExistingFolderSharesWithoutReplacingIt \
		-only-testing:RooSyncUITests/RooSyncUITests/testDuoAdaptiveLayoutAndFormsInStartingPose \
		-resultBundlePath "$E2E_DIR/FocusedDuoLayout-E2E.xcresult" >"$E2E_DIR/focused-ui-test.log" 2>&1 || {
		grep -nE 'error:|failed|Failure|TEST FAILED|signal kill' "$E2E_DIR/focused-ui-test.log" | tail -80 >&2 || true
		fail "Focused Duo UI tests failed; see $E2E_DIR/focused-ui-test.log."
	}
	python3 - "$E2E_DIR/FocusedDuoLayout-E2E.xcresult" <<'PY' || fail "The Duo layout test did not report a passed result."
import json
import subprocess
import sys

result_bundle = sys.argv[1]
report = json.loads(subprocess.check_output([
    "xcrun", "xcresulttool", "get", "test-results", "tests",
    "--path", result_bundle, "--compact",
]))
results = []
def collect(node):
    if isinstance(node, dict):
        if node.get("nodeType") == "Test Case" and node.get("name", "").startswith(
            "testDuoAdaptiveLayoutAndFormsInStartingPose"
        ):
            results.append(node.get("result"))
        for child in node.values():
            collect(child)
    elif isinstance(node, list):
        for child in node:
            collect(child)

collect(report.get("testNodes", []))
if results != ["Passed"]:
    raise SystemExit(f"Expected the Duo layout test to pass exactly once, found {results}")
PY
	duo_screenshot_dir="$E2E_DIR/DuoScreenshots"
	mkdir -p "$duo_screenshot_dir"
	xcrun xcresulttool export attachments \
		--path "$E2E_DIR/FocusedDuoLayout-E2E.xcresult" \
		--output-path "$duo_screenshot_dir"
	duo_screenshot="$(find "$duo_screenshot_dir" -type f -name '*.png' -print -quit)"
	[[ -n "$duo_screenshot" ]] || fail "Duo UI test passed but no PNG attachments were exported."
	printf '%s\n' 'PASS: exact-profile focused Duo UI tests passed.'
	exit 0
fi

if [[ "${ROOSYNC_FOCUSED_UI_TESTS:-0}" == 1 ]]; then
	xcrun simctl terminate "$SIMULATOR_UDID" "$APP_BUNDLE_ID" >/dev/null 2>&1 || true
	APP_INSTALLED=1
	xcodebuild -project "$ROOT/RooSync.xcodeproj" -scheme RooSync \
		-destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
		-derivedDataPath "$DERIVED_DATA" -parallel-testing-enabled NO \
		-maximum-concurrent-test-simulator-destinations 1 \
		CODE_SIGNING_ALLOWED=NO test-without-building \
		-only-testing:RooSyncUITests/RooSyncUITests/testCannotAddLocalDeviceID \
		-only-testing:RooSyncUITests/RooSyncUITests/testAcceptingOfferForExistingFolderSharesWithoutReplacingIt \
		-resultBundlePath "$E2E_DIR/FocusedSelfAddAndOffer-E2E.xcresult" >"$E2E_DIR/focused-ui-test.log" 2>&1 || {
		grep -nE 'error:|failed|Failure|TEST FAILED|signal kill' "$E2E_DIR/focused-ui-test.log" | tail -80 >&2 || true
		fail "Focused self-add/offer UI tests failed; see $E2E_DIR/focused-ui-test.log."
	}
	printf '%s\n' 'PASS: focused self-add and existing-folder-offer UI tests passed.'
	exit 0
fi

wait_for_file "$APP_FOLDER/Welcome.md" "Docker-to-simulator note"
wait_for_file "$DESKTOP_FOLDER/From iPhone.md" "simulator-to-Docker note"
wait_for_file "$DESKTOP_FOLDER/Extensionless conflict" "extensionless conflict fixture on Docker"
wait_for_file "$APP_FOLDER/Conflicted note.md" "base conflict fixture on simulator"
wait_for_file "$DESKTOP_FOLDER/Conflicted note.md" "base conflict fixture on Docker"
cmp "$ROOT/docs/fixtures/ObsidianVault/Welcome.md" "$APP_FOLDER/Welcome.md"
cmp "$ROOT/docs/fixtures/ObsidianVault/From iPhone.md" "$DESKTOP_FOLDER/From iPhone.md"
cmp "$ROOT/docs/fixtures/ObsidianVault/Conflicted note.md" "$APP_FOLDER/Conflicted note.md"
cmp "$ROOT/docs/fixtures/ObsidianVault/Conflicted note.md" "$DESKTOP_FOLDER/Conflicted note.md"

CONFLICT_FILE_QUERY="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' 'Conflicted note.md')"
APP_CONFLICT_BASE_VERSION="$(local_file_version "$APP_REST" "$APP_API_KEY" "$CONFLICT_FILE_QUERY")"
PEER_CONFLICT_BASE_VERSION="$(local_file_version "$PEER_REST" "$PEER_API_KEY" "$CONFLICT_FILE_QUERY")"
[[ "$APP_CONFLICT_BASE_VERSION" != null && "$PEER_CONFLICT_BASE_VERSION" != null ]] || \
	fail "The base conflict file was missing from one peer's local Syncthing index."

set_device_paused "$APP_REST" "$APP_API_KEY" "$PEER_ID" true
set_device_paused "$PEER_REST" "$PEER_API_KEY" "$APP_ID" true
wait_for_device_connection_state "$APP_REST" "$APP_API_KEY" "$PEER_ID" true
wait_for_device_connection_state "$PEER_REST" "$PEER_API_KEY" "$APP_ID" true

cp "$ROOT/docs/fixtures/ObsidianVault/Conflict-iPhone.md" "$APP_FOLDER/Conflicted note.md"
cat "$ROOT/docs/fixtures/ObsidianVault/Conflict-Docker.md" |
	"${DOCKER[@]}" exec --user "$PEER_UID:$PEER_GID" -i "$CONTAINER_NAME" \
		sh -c 'cat > "$1"' sh "/vault/Conflicted note.md"
printf 'Edited on the iPhone peer\n' > "$APP_FOLDER/Extensionless conflict"
printf 'Edited on the Docker peer\n' |
	"${DOCKER[@]}" exec --user "$PEER_UID:$PEER_GID" -i "$CONTAINER_NAME" \
		sh -c 'cat > "$1"' sh "/vault/Extensionless conflict"
cmp "$ROOT/docs/fixtures/ObsidianVault/Conflict-iPhone.md" "$APP_FOLDER/Conflicted note.md"
"${DOCKER[@]}" exec --user "$PEER_UID:$PEER_GID" "$CONTAINER_NAME" \
	cat "/vault/Conflicted note.md" | cmp - "$ROOT/docs/fixtures/ObsidianVault/Conflict-Docker.md"
api_request "$APP_REST" "$APP_API_KEY" POST "/rest/db/scan?folder=$APP_FOLDER_ID" >/dev/null
api_request "$PEER_REST" "$PEER_API_KEY" POST "/rest/db/scan?folder=$APP_FOLDER_ID" >/dev/null

APP_CONFLICT_LOCAL_VERSION="$APP_CONFLICT_BASE_VERSION"
PEER_CONFLICT_LOCAL_VERSION="$PEER_CONFLICT_BASE_VERSION"
for _ in $(seq 1 90); do
	APP_CONFLICT_LOCAL_VERSION="$(local_file_version "$APP_REST" "$APP_API_KEY" "$CONFLICT_FILE_QUERY")"
	PEER_CONFLICT_LOCAL_VERSION="$(local_file_version "$PEER_REST" "$PEER_API_KEY" "$CONFLICT_FILE_QUERY")"
	if [[ "$APP_CONFLICT_LOCAL_VERSION" != "$APP_CONFLICT_BASE_VERSION" && \
		"$PEER_CONFLICT_LOCAL_VERSION" != "$PEER_CONFLICT_BASE_VERSION" ]]; then
		break
	fi
	sleep 1
done
[[ "$APP_CONFLICT_LOCAL_VERSION" != "$APP_CONFLICT_BASE_VERSION" && \
	"$PEER_CONFLICT_LOCAL_VERSION" != "$PEER_CONFLICT_BASE_VERSION" ]] || \
	fail "Both peers did not index their conflict edits while disconnected."
cmp "$ROOT/docs/fixtures/ObsidianVault/Conflict-iPhone.md" "$APP_FOLDER/Conflicted note.md"
"${DOCKER[@]}" exec --user "$PEER_UID:$PEER_GID" "$CONTAINER_NAME" \
	cat "/vault/Conflicted note.md" | cmp - "$ROOT/docs/fixtures/ObsidianVault/Conflict-Docker.md"

set_device_paused "$APP_REST" "$APP_API_KEY" "$PEER_ID" false
set_device_paused "$PEER_REST" "$PEER_API_KEY" "$APP_ID" false
wait_for_device_connection_state "$APP_REST" "$APP_API_KEY" "$PEER_ID" false
wait_for_device_connection_state "$PEER_REST" "$PEER_API_KEY" "$APP_ID" false

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
LEGACY_CONFLICT_TIMESTAMP="$(date -u +%Y%m%d-%H%M%S)"
LEGACY_MARKDOWN_CONTENT="Legacy timestamp-only conflict copy"
LEGACY_EXTENSIONLESS_CONTENT="Legacy extensionless timestamp-only conflict copy"
printf '%s\n' "$LEGACY_MARKDOWN_CONTENT" > "$APP_FOLDER/Legacy note.sync-conflict-$LEGACY_CONFLICT_TIMESTAMP.md"
printf '%s\n' "$LEGACY_EXTENSIONLESS_CONTENT" > "$APP_FOLDER/Legacy extensionless.sync-conflict-$LEGACY_CONFLICT_TIMESTAMP"
xcrun simctl terminate "$SIMULATOR_UDID" "$APP_BUNDLE_ID" >/dev/null 2>&1 || true
APP_INSTALLED=1
xcodebuild -project "$ROOT/RooSync.xcodeproj" -scheme RooSync \
	-destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
	-derivedDataPath "$DERIVED_DATA" -parallel-testing-enabled NO \
	-maximum-concurrent-test-simulator-destinations 1 \
	CODE_SIGNING_ALLOWED=NO test-without-building \
	-only-testing:RooSyncUITests/RooSyncUITests/testFirstRunShowsDeviceIdentityAndSyncAction \
	-only-testing:RooSyncUITests/RooSyncUITests/testCannotAddLocalDeviceID \
	-only-testing:RooSyncUITests/RooSyncUITests/testEmbeddedRESTRejectsRequestsWithoutAPIKey \
	-only-testing:RooSyncUITests/RooSyncUITests/testAcceptingOfferForExistingFolderSharesWithoutReplacingIt \
	-only-testing:RooSyncUITests/RooSyncUITests/testCanonicalEquivalentFolderOfferDoesNotShareExistingFolder \
	-only-testing:RooSyncUITests/RooSyncUITests/testAcceptingUnsafeFolderLabelsUsesSafePaths \
	-only-testing:RooSyncUITests/RooSyncUITests/testPassiveRefreshFailurePreservesFolderDraftAndRecovers \
	-only-testing:RooSyncUITests/RooSyncUITests/testDuplicateExternalFolderIDIsRejected \
	-only-testing:RooSyncUITests/RooSyncUITests/testPauseE2ESyncFolder \
	-only-testing:RooSyncUITests/RooSyncUITests/testResumeE2ESyncFolder \
	-only-testing:RooSyncUITests/RooSyncUITests/testConflictCopyCanBeKept \
	-only-testing:RooSyncUITests/RooSyncUITests/testLogsExportRendersCopyActionOnOrdinarySimulator \
	-only-testing:RooSyncUITests/RooSyncUITests/testFolderStatusHandlesPlusInFolderID \
	-resultBundlePath "$E2E_DIR/RooSync-E2E.xcresult" >"$E2E_DIR/test.log" 2>&1 || {
	grep -nE 'error:|failed|Failure|TEST FAILED' "$E2E_DIR/test.log" | tail -80 >&2 || true
	fail "Simulator UI E2E failed; see $E2E_DIR/test.log."
}

APP_DATA="$(xcrun simctl get_app_container "$SIMULATOR_UDID" "$APP_BUNDLE_ID" data)"
UNICODE_EXISTING_PATH="$APP_DATA/Documents/Vaults/$UNICODE_EXISTING_LABEL"
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

E2E_FOLDERS="$(api_request "$APP_REST" "$APP_API_KEY" GET /rest/config/folders)"
python3 -c 'import json,sys; folders=json.loads(sys.argv[1]); by_id={f["id"]:f for f in folders}; main=by_id.get(sys.argv[2], {}); existing=by_id.get(sys.argv[6], {}); slash=by_id.get("roosync-e2e-slash-label", {}); empty=by_id.get("roosync-e2e-empty-label", {}); assert main.get("label")==sys.argv[3] and main.get("path")==sys.argv[4] and any(d.get("deviceID")==sys.argv[5] for d in main.get("devices", [])); assert existing.get("path")==sys.argv[7] and existing.get("label")=="Existing E2E Offer" and any(d.get("deviceID")==sys.argv[5] for d in existing.get("devices", [])); assert slash.get("label")=="Incoming/Notes" and slash.get("path", "").startswith(sys.argv[8]+"/") and "/" not in slash["path"].split("/")[-1]; assert empty.get("label")=="roosync-e2e-empty-label" and empty.get("path", "").startswith(sys.argv[8]+"/")' \
	"$E2E_FOLDERS" "$APP_FOLDER_ID" "$APP_FOLDER_LABEL" "$APP_FOLDER" "$PEER_ID" "$EXISTING_OFFER_ID" "$APP_DATA/Documents/Vaults/Existing E2E Offer" "$APP_DATA/Documents/Vaults" || \
	fail "Folder-offer acceptance or duplicate-ID rejection changed preserved config or created unsafe paths."

python3 - "$E2E_FOLDERS" "$UNICODE_EXISTING_ID" "$UNICODE_OFFER_ID" "$UNICODE_EXISTING_LABEL" "$UNICODE_EXISTING_PATH" "$PEER_ID" <<'PY' || fail "A Unicode-equivalent incoming ID shared or replaced the existing folder."
import json
import sys
import unicodedata

folders = json.loads(sys.argv[1])
existing_id, offered_id, label, path, peer_id = sys.argv[2:]
assert existing_id != offered_id
assert existing_id.encode() != offered_id.encode()
assert unicodedata.normalize("NFC", existing_id) == unicodedata.normalize("NFC", offered_id)
existing = next((folder for folder in folders if folder["id"] == existing_id), None)
assert existing is not None and existing.get("label") == label and existing.get("path") == path
assert not any(device.get("deviceID") == peer_id for device in existing.get("devices", []))
assert not any(folder["id"] == offered_id for folder in folders)
PY

grep -Eq 'Edited on the (iPhone|Docker) peer' "$APP_FOLDER/Conflicted note (conflict copy).md" || fail "The kept Markdown conflict copy has unexpected contents."
grep -Eq 'Edited on the (iPhone|Docker) peer' "$APP_FOLDER/Extensionless conflict (conflict copy)" || fail "The kept extensionless conflict copy has unexpected contents."
grep -Fxq "$LEGACY_MARKDOWN_CONTENT" "$APP_FOLDER/Legacy note (conflict copy).md" || fail "The kept legacy Markdown conflict copy has unexpected contents."
grep -Fxq "$LEGACY_EXTENSIONLESS_CONTENT" "$APP_FOLDER/Legacy extensionless (conflict copy)" || fail "The kept legacy extensionless conflict copy has unexpected contents."
if find "$APP_FOLDER" -type f -name '*sync-conflict-*' -print -quit | grep -q .; then
	fail "A conflict file remained after choosing Keep copy."
fi
[[ -f "$APP_FOLDER/Welcome.md" && -f "$DESKTOP_FOLDER/From iPhone.md" ]] || fail "A two-way synced note is missing after conflict handling."

set_folder_paused "$PEER_REST" "$PEER_API_KEY" false
wait_for_file "$DESKTOP_FOLDER/Conflicted note (conflict copy).md" "kept conflict copy on the Docker peer"
wait_for_file "$DESKTOP_FOLDER/Extensionless conflict (conflict copy)" "kept extensionless conflict copy on the Docker peer"
wait_for_file "$DESKTOP_FOLDER/Legacy note (conflict copy).md" "kept legacy Markdown conflict copy on the Docker peer"
wait_for_file "$DESKTOP_FOLDER/Legacy extensionless (conflict copy)" "kept legacy extensionless conflict copy on the Docker peer"
for _ in $(seq 1 90); do
	APP_CONFLICT="$(find "$APP_FOLDER" -type f -name '*sync-conflict-*' ! -name '.syncthing.*.tmp' -print -quit)"
	PEER_CONFLICT="$(find "$DESKTOP_FOLDER" -type f -name '*sync-conflict-*' ! -name '.syncthing.*.tmp' -print -quit)"
	[[ -z "$APP_CONFLICT" && -z "$PEER_CONFLICT" ]] && break
	sleep 1
done
[[ -z "$APP_CONFLICT" && -z "$PEER_CONFLICT" ]] || fail "The conflict reappeared after the Docker peer resumed."

run_pending_folder_collision_test

printf '%s\n' \
	'PASS: embedded iOS Syncthing core paired with Docker Syncthing.' \
	'PASS: unauthenticated root-cookie/CSRF requests were denied.' \
	'PASS: existing folder offers were accepted without replacing configuration.' \
	'PASS: empty and slash-containing folder labels were accepted with safe paths.' \
	'PASS: duplicate external folder IDs were rejected without overwriting config.' \
	'PASS: canonical-equivalent folder offers did not share unrelated configuration.' \
	'PASS: pending-ID collisions fail closed while configured status and policy refresh.' \
	'PASS: sample Obsidian vault synced in both directions.' \
	'PASS: concurrent edits created a Syncthing conflict copy.' \
	'PASS: app Keep copy preserved the conflict and removed its conflict suffix.' \
	'PASS: timestamp-only legacy conflicts kept their original extension behavior.' \
	'PASS: extensionless Syncthing conflicts were kept without retaining the conflict suffix.' \
	'PASS: kept copy synced to Docker and removed the conflict on both peers.'
