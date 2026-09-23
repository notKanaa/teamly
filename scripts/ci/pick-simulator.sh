#!/usr/bin/env bash
# Prints the UDID of an available iPhone simulator on the newest installed iOS runtime,
# preferring "iPhone 17", then any "iPhone <number>", then any iPhone.
# If the newest runtime has no iPhone device, one is created. Diagnostics go to stderr.
set -euo pipefail

devices_json="$(xcrun simctl list devices available -j)"
udid="$(jq -r '
  [ .devices | to_entries[]
    | select(.key | test("SimRuntime[.]iOS-"))
    | (.key | capture("iOS-(?<a>[0-9]+)-(?<b>[0-9]+)") | [(.a | tonumber), (.b | tonumber)]) as $v
    | .value[]
    | select((.isAvailable // true) and (.name | startswith("iPhone")))
    | {v: $v, name, udid} ]
  | if length == 0 then empty else
      (map(.v) | max) as $newest
      | map(select(.v == $newest))
      | ( (map(select(.name == "iPhone 17")) | first)
          // (map(select(.name | test("^iPhone [0-9]+$"))) | first)
          // first )
      | .udid
    end' <<<"$devices_json")"

if [ -z "$udid" ] || [ "$udid" = "null" ]; then
  echo "No available iPhone simulator found; creating one." >&2
  runtime="$(xcrun simctl list runtimes available -j \
    | jq -r '[.runtimes[] | select(.platform == "iOS" or (.identifier | test("SimRuntime[.]iOS-")))] | sort_by(.version | split(".") | map(tonumber)) | last | .identifier // empty')"
  devicetype="$(xcrun simctl list devicetypes -j \
    | jq -r '[.devicetypes[] | select(.name | test("^iPhone [0-9]+( Pro)?$"))] | last | .identifier // empty')"
  if [ -z "$runtime" ] || [ -z "$devicetype" ]; then
    echo "Cannot create a simulator (runtime='$runtime', devicetype='$devicetype')." >&2
    xcrun simctl list runtimes >&2 || true
    exit 1
  fi
  udid="$(xcrun simctl create "iPhone CI" "$devicetype" "$runtime")"
fi

echo "Simulator: $udid" >&2
echo "$udid"
