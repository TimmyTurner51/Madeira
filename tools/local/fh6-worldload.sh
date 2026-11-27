#!/bin/bash
# Drive FH6 from Madeira's library screen through Start Game -> Main Menu -> World Load.
# Uses `iosdev see` + `iosdev tap-text` (OCR, zero image tokens) and `tools/local/afc-pull.py` (1.6s live log pull).
set -u
cd "$(dirname "$0")/../.." || exit 1

MON_SECS=200
OUT_LOG=/tmp/fh6-worldload.log
OUT_SHOT=/tmp/fh6-worldload.png
BOOT_MADEIRA=0
ALREADY_LAUNCHED=0
while [ $# -gt 0 ]; do
  case "$1" in
    --monitor-secs) MON_SECS="${2:-200}"; shift 2 ;;
    --out-log) OUT_LOG="${2:-/tmp/fh6-worldload.log}"; shift 2 ;;
    --out-shot) OUT_SHOT="${2:-/tmp/fh6-worldload.png}"; shift 2 ;;
    --boot-madeira) BOOT_MADEIRA=1; shift ;;
    --already-launched) ALREADY_LAUNCHED=1; shift ;;
    *) shift ;;
  esac
done

DEV=FF8A07FC-C3F5-5B9F-9EA6-B2CB521E6B25
LC_BUNDLE=com.kdt.livecontainer.4CDWTGR84Z
GUEST=Documents/Data/Application/EDAFB512-48D7-4839-98DA-E66816D6174E/Documents
PY="$HOME/Library/Application Support/pipx/venvs/pymobiledevice3/bin/python"

pull_log() { "$PY" tools/local/afc-pull.py "$GUEST/madeira-log.txt" "$1" >/dev/null 2>&1; }

# Convert landscape `iosdev see` OCR match (1206x555) to portrait HID (1206x2622, rot270) and tap
tap_ocr() {
  local pat="$1" dy="${2:-0}" line xl yl px py
  line=$(iosdev see 2>/dev/null | rg -i "$pat" | head -n 1 || true)
  [ -z "$line" ] && { echo "tap_ocr: '$pat' not found"; return 1; }
  xl=$(echo "$line" | awk -F'[, ]+' '{print $2}')
  yl=$(echo "$line" | awk -F'[, ]+' '{print $3}')
  yl=$((yl + dy))
  px=$(awk -v y="$yl" 'BEGIN{printf "%d", (1 - y/555.0)*1206}')
  py=$(awk -v x="$xl" 'BEGIN{printf "%d", (x/1206.0)*2622}')
  echo "tap_ocr '$pat': land=($xl,$yl) -> hid=($px,$py)"
  iosdev tap "$px" "$py" >/dev/null
}

# 0. Optionally boot LiveContainer -> Madeira + verify JIT pool >= 700 MB
if [ "$BOOT_MADEIRA" -eq 1 ]; then
  echo "=== 0. Boot LiveContainer -> Madeira + StikDebug JIT ==="
  for attempt in 1 2 3; do
    if ! iosdev ps LiveContainer 2>/dev/null | rg -q '[0-9]'; then
      iosdev launch "$LC_BUNDLE" >/dev/null 2>&1 &
      LPID=$!
      sleep 6
      kill -0 "$LPID" 2>/dev/null && kill -9 "$LPID" 2>/dev/null || true
    fi
    for w in $(seq 1 12); do
      TXT=$(iosdev see 2>/dev/null || true)
      if echo "$TXT" | rg -qi 'FORZA|Game details|Library'; then
        echo "Madeira UI ready (attempt $attempt)"
        break
      fi
      if echo "$TXT" | rg -qi 'Enable and Run Script'; then
        echo "StikDebug prompt -> tapping Enable and Run Script"
        iosdev tap-text "Enable and Run Script" >/dev/null 2>&1 || true
        sleep 8
        continue
      fi
      if echo "$TXT" | rg -qi 'My Apps'; then
        MLINE=$(echo "$TXT" | rg '  Madeira$' | head -n 1 || true)
        if [ -z "$MLINE" ]; then
          echo "LiveContainer My Apps -> scrolling for Madeira"
          iosdev swipe 600 2000 600 600 >/dev/null 2>&1 || true
          sleep 1
          continue
        fi
        MY=$(echo "$MLINE" | awk -F'[, ]+' '{print $3}')
        echo "LiveContainer found Madeira at y=$MY -> tapping Run at (1006,$((MY+40)))"
        iosdev tap 1006 $((MY + 40)) >/dev/null 2>&1 || true
        sleep 5
        continue
      fi
      sleep 3
    done
    TXT=$(iosdev see 2>/dev/null || true)
    if echo "$TXT" | rg -qi 'FORZA|Game details|Library'; then
      pull_log /tmp/fh6-boot-check.log
      POOL_LINE=$(rg 'pool-split|Allocating .*MB|JIT pool ready|JIT pool =' /tmp/fh6-boot-check.log | tail -n 3 || true)
      echo "$POOL_LINE"
      POOL_MB=$(echo "$POOL_LINE" | rg -o 'one [0-9]+MB|[0-9]+MB span|size=[0-9]+MB' | rg -o '[0-9]+' | tail -n 1 || echo 800)
      if [ "${POOL_MB:-800}" -ge 750 ]; then
        echo "JIT pool OK (${POOL_MB} MB)"
        break
      fi
      echo "JIT pool too small (${POOL_MB} MB < 750 MB) -> killing & retrying for split pool..."
    else
      echo "Attempt $attempt did not reach Madeira library; retrying..."
    fi
    iosdev kill-bundle LiveContainer >/dev/null 2>&1 || true
    sleep 3
  done
fi

# 1. Make sure we're on Forza Horizon 6 details (Play button visible), then tap Play
if [ "$ALREADY_LAUNCHED" -eq 0 ]; then
echo "=== 1. Launch FH6 from Madeira ==="
TXT=$(iosdev see 2>/dev/null || true)
if echo "$TXT" | rg -qi 'Game details' && ! echo "$TXT" | rg -qi 'Forza Horizon 6'; then
  echo "Dismissing wrong Game details sheet..."
  tap_ocr '\bDone\b' && sleep 2
  TXT=$(iosdev see 2>/dev/null || true)
fi
if ! echo "$TXT" | rg -qi '\bPlay\b'; then
  if ! echo "$TXT" | rg -qi 'Forza Horizon 6|FORZA'; then
    echo "Scrolling Madeira library to find Forza Horizon 6..."
    iosdev swipe 228 1304 880 1304 >/dev/null
    sleep 1.5
    TXT=$(iosdev see 2>/dev/null || true)
  fi
  if echo "$TXT" | rg -qi 'Forza Horizon 6'; then
    tap_ocr 'Forza Horizon 6' 0 && sleep 2
  else
    tap_ocr 'FORZA' -40 && sleep 2
  fi
  TXT=$(iosdev see 2>/dev/null || true)
fi
if ! echo "$TXT" | rg -qi '\bPlay\b'; then
  echo "ABORT: Forza Horizon 6 Play button not visible after tap:"
  echo "$TXT" | head -n 15
  exit 2
fi
echo "Confirmed Forza Horizon 6 details -> tapping Play"
tap_ocr '\bPlay\b'
fi

# 2. Wait for Start Game (poll OCR every 12s up to 168s; fail fast if LiveContainer exits)
STARTED=0
for i in $(seq 1 14); do
  sleep 12
  TXT=$(iosdev see 2>/dev/null || true)
  if echo "$TXT" | rg -qi 'Bedtime|FaceTime|Weather|Find My|GarageBand|TestFlight'; then
    echo "t+$((i*12))s: ABORT — ON HOMESCREEN (LiveContainer exited during startup)"
    pull_log "$OUT_LOG"
    rg -n 'Assertion failed|ml325 BAD BLIT|BREAKPOINT #1|UNHANDLED #1|fatal' "$OUT_LOG" | tail -n 10 || true
    exit 1
  fi
  if echo "$TXT" | rg -qi 'Start Game'; then
    echo "t+$((i*12))s: Reached Start Game -> Enter"
    iosdev key enter >/dev/null
    STARTED=1
    break
  fi
  if echo "$TXT" | rg -qi 'FHE21|unexpected error'; then
    echo "t+$((i*12))s: HIT FHE21 during startup"
    pull_log "$OUT_LOG"
    iosdev shot "$OUT_SHOT" >/dev/null
    exit 1
  fi
  if echo "$TXT" | rg -qi 'Continue' && echo "$TXT" | rg -qi 'Options|Sign Out'; then
    echo "t+$((i*12))s: Already at Main Menu!"
    STARTED=1
    break
  fi
  echo "t+$((i*12))s: booting..."
done
if [ "$STARTED" -eq 0 ]; then
  echo "ABORT: Did not reach Start Game within 168s"
  pull_log "$OUT_LOG"
  iosdev shot "$OUT_SHOT" >/dev/null
  exit 1
fi

# 3. Navigate Cloud Sync / Main Menu -> Continue (poll OCR every 8s up to 96s)
IN_WORLD=0
for i in $(seq 1 12); do
  sleep 8
  TXT=$(iosdev see 2>/dev/null || true)
  if echo "$TXT" | rg -qi 'Bedtime|FaceTime|Weather|Find My|GarageBand|TestFlight'; then
    echo "menu+$((i*8))s: ABORT — ON HOMESCREEN (LiveContainer exited during menu)"
    pull_log "$OUT_LOG"
    exit 1
  fi
  if echo "$TXT" | rg -qi 'Stop Sync & Continue'; then
    echo "menu+$((i*8))s: Cloud sync dialog -> Stop Sync & Continue"
    iosdev key down >/dev/null; sleep 1; iosdev key enter >/dev/null
    sleep 3
    iosdev key enter >/dev/null
    continue
  fi
  if echo "$TXT" | rg -qi 'Yes, Stop Sync'; then
    echo "menu+$((i*8))s: Confirm Yes, Stop Sync"
    iosdev key enter >/dev/null
    continue
  fi
  if echo "$TXT" | rg -qi 'Continue' && echo "$TXT" | rg -qi 'Options|Sign Out'; then
    echo "menu+$((i*8))s: Reached Main Menu (Continue) -> Enter to load world!"
    iosdev key enter >/dev/null
    IN_WORLD=1
    break
  fi
done
if [ "$IN_WORLD" -eq 0 ]; then
  echo "WARN: Did not see Main Menu Continue within 96s; continuing to monitor"
fi

# 4. Monitor world load every 20s via OCR (zero memory pressure on afcd; zero image tokens)
STEPS=$((MON_SECS / 20))
for i in $(seq 1 "$STEPS"); do
  sleep 20
  TXT=$(iosdev see 2>/dev/null || true)
  if echo "$TXT" | rg -qi 'Bedtime|FaceTime|Weather|Find My|GarageBand|TestFlight'; then
    echo "world+$((i*20))s: ON HOMESCREEN (LiveContainer exited / jetsam)"
    break
  fi
  HUD=$(echo "$TXT" | rg -o '(FPS|MS|MB|GPU MS|KM/H|MPH|HORIZON|PRESS|Continue|Distance|Average|Highest)[^\n]*' | tr '\n' ' ' | cut -c1-140)
  echo "world+$((i*20))s | $HUD"
  if echo "$TXT" | rg -qi 'FHE21|unexpected error'; then
    echo "world+$((i*20))s: HIT FHE21!"
    break
  fi
  if echo "$TXT" | rg -qi 'KM/H|MPH|PRESS.*MAP|HORIZON OUTPOST|FREE ROAM|FESTIVAL' && ! echo "$TXT" | rg -qi 'Longest Skill|Distance Driven|Highest Speed|Cars Owned'; then
    echo "world+$((i*20))s: LIVE 3D GAMEPLAY DETECTED ON SCREEN!! Capturing screenshot & holding 30s..."
    iosdev shot "${OUT_SHOT%.png}-live.png" >/dev/null || true
    sleep 30
    break
  fi
done

pull_log "$OUT_LOG" || true
echo "=== Summary ==="
if [ -s "$OUT_LOG" ]; then
  rg -n 'ml325-wmt|ml325 BAD BLIT|Assertion failed|ml324 F_PUNCHHOLE|ml1150 Metal|\[perf\] ml1108|\[perf\] ml1119|\[perf\] ml1109|pso-lazy-libs|pso-parallel' "$OUT_LOG" | tail -n 25
fi
iosdev shot "$OUT_SHOT" >/dev/null
echo "FINAL_SHOT=$OUT_SHOT FINAL_LOG=$OUT_LOG"
