#!/bin/sh
# Rebuilds pe (ReleaseFast) and the UI (../editor, where the page is built), then restarts
# `pe serve` in the background; reload the page after.
#   scripts/dev.sh [doc.pubd-dir] [renders-dir] [port]
set -e
cd "$(dirname "$0")/.."
DOC=${1:-corpus/landing/landing.pubd}
RENDERS=${2:-corpus/landing/renders}
PORT=${3:-8400}
PIDFILE=.zig-cache/pe-serve-$PORT.pid
LOG=.zig-cache/pe-serve-$PORT.log

zig build -Doptimize=ReleaseFast
(cd ../editor && zig build)

if [ -f "$PIDFILE" ]; then
  kill "$(cat "$PIDFILE")" 2>/dev/null || true
  rm -f "$PIDFILE"
fi
# Wait for the port to free up.
i=0
while lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done

mkdir -p .zig-cache
nohup zig-out/bin/pe serve "$DOC" "$RENDERS" --port "$PORT" >"$LOG" 2>&1 &
echo $! >"$PIDFILE"
i=0
until curl -fs "http://127.0.0.1:$PORT/api/state" >/dev/null 2>&1; do
  if ! kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then echo "pe serve failed:"; cat "$LOG"; exit 1; fi
  [ $i -ge 300 ] && { echo "pe serve did not answer; see $LOG"; exit 1; }
  sleep 0.1; i=$((i + 1))
done
echo "http://127.0.0.1:$PORT/  (pid $(cat "$PIDFILE"), log $LOG)"
