#!/usr/bin/env bash
set -euo pipefail

expected_version="27.1"
xcode_version="$(xcodebuild -version | awk 'NR == 1 { print $2 }')"
if [[ "$xcode_version" != "$expected_version" ]]; then
	printf 'Expected Xcode %s, found %s; refusing a simulator fallback.\n' "$expected_version" "$xcode_version" >&2
	exit 1
fi

sdk_version="$(xcrun --sdk iphonesimulator --show-sdk-version)"
if [[ "$sdk_version" != "$expected_version" ]]; then
	printf 'Expected iOS Simulator SDK %s, found %s; refusing a simulator fallback.\n' "$expected_version" "$sdk_version" >&2
	exit 1
fi

device_sdk_version="$(xcrun --sdk iphoneos --show-sdk-version)"
if [[ "$device_sdk_version" != "$expected_version" ]]; then
	printf 'Expected iOS device SDK %s, found %s; refusing a release artifact fallback.\n' "$expected_version" "$device_sdk_version" >&2
	exit 1
fi

: "${GITHUB_ENV:?GITHUB_ENV must be provided by GitHub Actions}"
: "${GITHUB_RUN_ID:?GITHUB_RUN_ID must be provided by GitHub Actions}"

runtime_identifier="$(xcrun simctl list -j runtimes | python3 -c '
import json
import sys

matches = [
    runtime for runtime in json.load(sys.stdin)["runtimes"]
    if runtime.get("platform") == "iOS"
    and runtime.get("version") == "27.1"
    and runtime.get("isAvailable")
]
if len(matches) != 1:
    raise SystemExit(f"Expected exactly one available iOS 27.1 runtime, found {len(matches)}")
print(matches[0]["identifier"])
')"

device_type_identifier="$(xcrun simctl list -j devicetypes | python3 -c '
import json
import sys

matches = [device for device in json.load(sys.stdin)["devicetypes"] if device.get("name") == "iPhone Duo"]
if len(matches) != 1:
    raise SystemExit(f"Expected exactly one iPhone Duo simulator profile, found {len(matches)}")
print(matches[0]["identifier"])
')"

simulator_name="RooSync iPhone Duo E2E ${GITHUB_RUN_ID}"
simulator_udid="$(xcrun simctl create "$simulator_name" "$device_type_identifier" "$runtime_identifier")"

python3 - "$runtime_identifier" "$device_type_identifier" "$simulator_name" "$simulator_udid" <<'PY'
import json
import subprocess
import sys

expected_runtime, expected_type, expected_name, udid = sys.argv[1:]
devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "-j", "devices"]))["devices"]
matches = [
    (runtime_id, device)
    for runtime_id, runtime_devices in devices.items()
    for device in runtime_devices
    if device.get("udid") == udid
]
if len(matches) != 1:
    raise SystemExit(f"Expected exactly one created iPhone Duo simulator, found {len(matches)}")
runtime_id, device = matches[0]
if (
    runtime_id != expected_runtime
    or device.get("deviceTypeIdentifier") != expected_type
    or device.get("name") != expected_name
    or not device.get("isAvailable")
):
    raise SystemExit("Created simulator did not match the required iPhone Duo/iOS 27.1 profile")
PY

printf 'SIMULATOR_UDID=%s\n' "$simulator_udid" >>"$GITHUB_ENV"
printf 'ROOSYNC_DUO_SIMULATOR_VERIFIED=1\n' >>"$GITHUB_ENV"
printf 'Verified Xcode %s, iOS SDK %s, iOS Simulator SDK %s, iPhone Duo runtime %s, device type %s, UDID %s\n' \
	"$xcode_version" "$device_sdk_version" "$sdk_version" "$runtime_identifier" "$device_type_identifier" "$simulator_udid"
