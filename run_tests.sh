#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Run the Robot Framework suite against the running lab.
#
#   ./run_tests.sh                 # everything
#   ./run_tests.sh --include cdp   # any robot option is passed through
#
# The system Python is PEP 668 "externally managed", so dependencies live in
# a virtualenv under .venv/ that this script creates on first run.
# ---------------------------------------------------------------------------
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$PROJECT_DIR/.venv"
RESULTS="$PROJECT_DIR/results"

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m  %s\n' "$*" >&2; exit 1; }

if [[ ! -x $VENV/bin/robot ]]; then
  log "creating test virtualenv in .venv (first run only)"
  python3 -m venv "$VENV" || die "python3 -m venv failed (apt install python3-venv)"
  "$VENV/bin/pip" install --quiet --disable-pip-version-check \
      robotframework paramiko || die "could not install test dependencies"
fi

# Fail early with something readable rather than six SSH timeouts.
# Captured rather than piped: `grep -q` exits on the first match, and the
# resulting SIGPIPE would trip `pipefail` and report a false failure.
lab_status="$("$PROJECT_DIR/lab.sh" status)"
grep -q ' up ' <<<"$lab_status" \
  || die "no lab nodes are running -- start them with ./lab.sh start"

mkdir -p "$RESULTS"
log "running suite (results in results/)"
exec "$VENV/bin/robot" \
    --outputdir "$RESULTS" \
    --name "IOS-XRv9000 two-node lab" \
    "$@" \
    "$PROJECT_DIR/tests/xr_lab.robot"
