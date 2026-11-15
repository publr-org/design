#!/bin/sh
# Rebuilds pe (ReleaseFast), the WASM engine and the UI (../editor), then restarts
# `pe view` in the background; reload the page after.
#   scripts/view.sh [doc.pubd-dir | file.fig | none] [port]
# `none` serves the file browser without a served document.
set -e
cd "$(dirname "$0")/.."
DOC=${1:-corpus/landing/landing.pubd}
PORT=${2:-8402}
PIDFILE=.zig-cache/pe-view-$PORT.pid
LOG=.zig-cache/pe-view-$PORT.log

zig build -Doptimize=ReleaseFast
zig build wasm
(cd ../editor && zig build)

if [ -f "$PIDFILE" ]; then
  kill "$(cat "$PIDFILE")" 2>/dev/null || true
  rm -f "$PIDFILE"
fi
# A pe view started some other way may hold the port too (the socket reuses the address,
# so a second one binds beside it): stop it.
for pid in $(lsof -t -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null); do
  case "$(ps -o comm= -p "$pid")" in *pe) kill "$pid" 2>/dev/null || true ;; esac
done
# Wait for the port to free up.
i=0
while lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done

mkdir -p .zig-cache
if [ "$DOC" = none ]; then set -- ; else set -- "$DOC"; fi
nohup zig-out/bin/pe view "$@" --port "$PORT" >"$LOG" 2>&1 &
echo $! >"$PIDFILE"
i=0
until curl -fs "http://127.0.0.1:$PORT/api/doc" >/dev/null 2>&1; do
  if ! kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then echo "pe view failed:"; cat "$LOG"; exit 1; fi
  [ $i -ge 300 ] && { echo "pe view did not answer; see $LOG"; exit 1; }
  sleep 0.1; i=$((i + 1))
done
echo "http://127.0.0.1:$PORT/  (pid $(cat "$PIDFILE"), log $LOG)"
