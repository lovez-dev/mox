#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
zig build autobahn-server -Dtarget=x86_64-linux-musl -Doptimize=ReleaseFast
reports="$PWD/out/autobahn"
mkdir -p "$reports"
reports=$(mktemp -d "$reports/run.XXXXXX")
cleanup() {
  case "$reports" in "$PWD"/out/autobahn/run.*) rm -rf -- "$reports" ;; *) exit 1 ;; esac
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if ! docker run --rm --init --user "$(id -u):$(id -g)" --entrypoint sh \
  -v "$PWD/zig-out/bin/mox-autobahn:/mox:ro" \
  -v "$PWD/tests/autobahn:/config:ro" -v "$reports:/reports" \
  crossbario/autobahn-testsuite@sha256:519915fb568b04c9383f70a1c405ae3ff44ab9e35835b085239c258b6fac3074 \
  /config/container.sh >"$reports/client.log" 2>&1; then
  tail -n 80 "$reports/client.log"
  if [ -f "$reports/server.log" ]; then tail -n 80 "$reports/server.log"; fi
  exit 1
fi
python3 tests/autobahn/check_report.py "$reports"
