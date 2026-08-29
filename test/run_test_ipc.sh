#!/usr/bin/env bash
# Starts a throwaway `rayforce -p <port>` server, waits for it to accept
# connections, runs test_ipc.exe against it, and tears the server down --
# regardless of whether the test passes. Invoked from dune's runtest alias
# (see test/dune); not meant to be run by hand, though it's harmless to.
set -u

if ! command -v rayforce >/dev/null 2>&1; then
  echo "run_test_ipc.sh: 'rayforce' not found on PATH -- install it (see" \
       "~/code/aur/rayforce) to run this test." >&2
  exit 1
fi

test_exe=$1

# Pid-derived port to keep parallel dune-cache/CI runs from colliding on a
# fixed port; still not collision-proof against an unrelated listener, but
# good enough for a local smoke test.
port=$((15000 + $$ % 1000))

rayforce -p "$port" >/dev/null 2>&1 &
server_pid=$!

cleanup() {
  kill "$server_pid" 2>/dev/null
  wait "$server_pid" 2>/dev/null
}
trap cleanup EXIT

# Poll for the listener instead of a fixed sleep -- /dev/tcp is a bash
# builtin (no nc/curl dependency).
tries=0
until (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; do
  exec 3<&- 2>/dev/null
  tries=$((tries + 1))
  if [ "$tries" -ge 50 ]; then
    echo "run_test_ipc.sh: rayforce -p $port never came up" >&2
    exit 1
  fi
  sleep 0.1
done
exec 3<&-

"$test_exe" "$port"
