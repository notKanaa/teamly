#!/usr/bin/env bash
# Prints the UDID of an available iPhone simulator on the newest installed iOS runtime,
# preferring "iPhone 17", then any "iPhone <number>", then any iPhone.
set -euo pipefail
xcrun simctl list devices available -j | jq -r '
  [ .devices | to_entries[]
    | select(.key | test("SimRuntime\.iOS-"))
    | (.key | capture("iOS-(?<a>[0-9]+)-(?<b>[0-9]+)") | [(.a | tonumber), (.b | tonumber)]) as $v
    | .value[]
    | select((.isAvailable // true) and (.name | startswith("iPhone")))
    | {v: $v, name, udid} ]
  | (map(.v) | max) as $newest
  | map(select(.v == $newest))
  | ( (map(select(.name == "iPhone 17")) | first)
      // (map(select(.name | test("^iPhone [0-9]+$"))) | first)
      // first )
  | .udid'
