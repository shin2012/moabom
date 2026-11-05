#!/bin/bash
# Usage: shots.sh <app path> <out dir>
set -u
APP="$1"; OUT="$2"; mkdir -p "$OUT"
BUNDLE=kr.b-612.moabom
ARGS=(-demoServer http://127.0.0.1:8977 -demoUser demo -demoPass demo-pass-1)
DEFAULT="feed library viewer viewer-video classify triage select filtered downloads watch settings categories lock"
read -r -a SCREENS <<< "${SCREENS:-$DEFAULT}"

pick() { xcrun simctl list devices available -j | python3 -c "
import json,sys
d=json.load(sys.stdin)['devices']
c=[x for k,v in d.items() if 'iOS' in k for x in v if x['name'].startswith('$1')]
c.sort(key=lambda x: x['name'])
print(c[-1]['udid'] if c else '')"; }

for kind in "iPhone" "iPad Pro"; do
  UDID=$(pick "$kind")
  [ -z "$UDID" ] && { echo "no $kind"; continue; }
  NAME=$(echo "$kind" | tr ' ' '_')
  xcrun simctl boot "$UDID" || true
  xcrun simctl bootstatus "$UDID" -b
  xcrun simctl status_bar "$UDID" override --time 9:41 --batteryLevel 100 --cellularBars 4 || true
  xcrun simctl ui "$UDID" appearance dark || true
  xcrun simctl install "$UDID" "$APP"
  first=1
  for s in "${SCREENS[@]}"; do
    xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE" "${ARGS[@]}" -screen "$s" >/dev/null
    if [ $first = 1 ]; then sleep 20; first=0; else sleep 7; fi
    xcrun simctl io "$UDID" screenshot "$OUT/${NAME}-${s}.png" >/dev/null 2>&1 && echo "shot $NAME $s"
    if xcrun simctl spawn "$UDID" launchctl list | grep -q "$BUNDLE"; then echo "alive $NAME $s"; else echo "CRASHED $NAME $s"; fi
  done
  xcrun simctl shutdown "$UDID" || true
done
