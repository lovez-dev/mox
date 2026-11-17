#!/bin/sh
set -eu
/mox > /reports/server.log 2>&1 &
server_pid=$!
cleanup() {
  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
sleep 1
kill -0 "$server_pid"
wstest -m fuzzingclient -s /config/fuzzingclient.json
